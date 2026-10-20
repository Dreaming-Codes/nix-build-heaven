# ssh-ng alternative to Phase 3: the same gate with -transport ssh-ng holds the
# daemon's ssh connection while the fake EC2 "boots" the builder VM for 20 s
# and splices it to the builder's sshd. Also measures how the ssh-ng hook
# reacts to a gate that resets instead (the grpc gate's behaviour).
{ self, pkgs }:
let
  common = import ./common.nix { inherit self pkgs; };
  listener = ./plugin-probe/listener.py;
in
pkgs.testers.runNixOSTest {
  name = "nbh-ssh-coldstart";
  nodes = {
    builder = {
      imports = [ common.builder ];
      services.nbh.builder.transports = [ "ssh-ng" ];
    };
    client =
      { nodes, ... }:
      {
        imports = [ common.client ];
        nix.settings.trusted-users = [ "root" ];
        services.nbh = {
          transport = "ssh-ng";
          plugin = pkgs.lib.mkForce null;
        };
        services.nbh.gate.extraArgs = [
          "-backend" "fake"
          "-fake-addr" "${nodes.builder.networking.primaryIPAddress}:22"
          "-fake-boot-delay" "20s"
          "-idle-grace" "10s"
        ];
      };
  };
  testScript =
    { nodes, ... }:
    let
      downDropIn = pkgs.writeText "down.conf" ''
        [Service]
        ExecStart=
        ExecStart=${nodes.client.systemd.services.nbh-gate.serviceConfig.ExecStart} -fake-down
      '';
      entry = nodes.client.services.nbh.machinesEntry;
    in
    ''
      import re, time
      pki = "${common.pki}"
      entry = "${entry}"

      def build(tag, extra="", user="alice", check=True):
          nonce = f"{tag}-{time.time_ns()}"
          cmd = f"nix-build /etc/nbh/probe.nix --argstr nonce {nonce} --no-out-link {extra}"
          if user == "alice":
              cmd = f"su - alice -c '{cmd}'"
          else:
              cmd = f"NIX_REMOTE=daemon {cmd}"
          t0 = time.monotonic()
          if check:
              blog = client.succeed(cmd + " 2>&1")
          else:
              _, blog = client.execute(cmd + " 2>&1")
          return time.monotonic() - t0, blog

      client.start()
      client.wait_for_unit("nbh-gate.service")
      client.wait_until_succeeds(f"test -s {pki}/ssh_host_ca")
      client.succeed(f"nbh-gate userdata {pki} > /var/lib/fake-imds/user-data")
      print(client.succeed("cat /run/nbh/machines"))
      builder.start()
      builder.wait_for_open_port(22, timeout=180)
      client.wait_until_succeeds("grep -q nbh-builder /run/nbh/machines")

      with subtest("auth: the CA-certified host key and the gate's client key log in; a foreign key does not"):
          ip = "${nodes.builder.networking.primaryIPAddress}"
          ssh = f"ssh -o HostKeyAlias=nbh-builder -o UserKnownHostsFile={pki}/ssh_known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes -o IdentitiesOnly=yes"
          client.succeed(f"{ssh} -i {pki}/ssh_client nbh@{ip} true")
          client.succeed("ssh-keygen -q -t ed25519 -N ''' -f /tmp/stranger")
          client.fail(f"{ssh} -i /tmp/stranger nbh@{ip} true")
          client.fail(f"{ssh} -i {pki}/ssh_client root@{ip} true")
          # Without the CA line the per-boot host key is unknown and refused.
          client.fail(f"ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes -o BatchMode=yes -i {pki}/ssh_client nbh@{ip} true")
          builder.succeed("journalctl -u sshd | grep -q 'Accepted publickey for nbh'")

      with subtest("cold start: gate holds the ssh connection through the 20 s boot, one attempt, build runs remotely"):
          d, blog = build("cold")
          print(blog)
          print(f"MEASURED cold_build_s={d:.1f}")
          assert blog.count("on 'ssh-ng://nbh@nbh-builder") >= 2, blog
          assert d >= 20, f"finished in {d:.1f} s, before the fake builder booted"
          journal = client.succeed("journalctl -u nbh-gate.service")
          print(journal)
          assert len(re.findall(r"launched \S+ as i-fake", journal)) == 1, journal
          assert "refuse connection" not in journal, journal
          assert "cannot build on" not in blog, blog

      with subtest("warm: second build splices straight to the serving builder"):
          d, blog = build("warm")
          print(f"MEASURED warm_build_s={d:.1f}")
          assert blog.count("on 'ssh-ng://nbh@nbh-builder") >= 2, blog
          assert d < 20, f"{d:.1f} s, as long as a 20 s builder boot"

      with subtest("dead-man sees an ssh-ng build as busy (an nbh session or a nixbld process)"):
          nonce = f"busy-{time.time_ns()}"
          client.succeed(f"su - alice -c 'nix-build /etc/nbh/probe.nix --argstr nonce {nonce} --argstr busy 20 --no-out-link' > /tmp/busy.log 2>&1 &")
          builder.wait_until_succeeds("ps -eo user= | grep -q '^nbh$'", timeout=60)
          print(builder.succeed("ps -eo user,comm | grep -E '^(nbh|nixbld)' || true"))
          builder.succeed("systemctl start nbh-deadman.service")
          out = builder.succeed("journalctl -u nbh-deadman.service -n 3 -o cat")
          print(out)
          assert re.search(r"idle [0-1] s", out), out
          client.wait_until_succeeds("grep -q nbh-probe-b /tmp/busy.log", timeout=120)
          last_close = time.monotonic()

      with subtest("terminate after drain: idle-grace 10 s + 5 s recheck"):
          client.wait_until_succeeds("journalctl -u nbh-gate.service | grep -q 'terminate '", timeout=60)
          d = time.monotonic() - last_close
          print(f"MEASURED terminate_after_last_build_s={d:.1f}")
          assert d <= 25, d

      with subtest("a resetting gate (grpc-style refuse): ssh-ng does not retry"):
          client.succeed("python3 ${listener} rst 2299 > /tmp/rst.log 2>&1 &")
          client.wait_for_open_port(2299)
          bad = entry.replace(":2222", ":2299")
          d1, blog1 = build("rst-local", f"--max-jobs 1 --builders '{bad}'", user="root")
          print(blog1)
          a1 = int(client.succeed("grep -c accept /tmp/rst.log").strip())
          print(f"MEASURED reset_maxjobs1_s={d1:.1f} accepts={a1} remote={'ssh-ng://' in blog1 and 'building' in blog1}")
          client.succeed("truncate -s0 /tmp/rst.log")
          d0, blog0 = build("rst-nolocal", f"--max-jobs 0 --builders '{bad}' --option connect-timeout 5", user="root", check=False)
          print(blog0)
          a0 = int(client.succeed("grep -c accept /tmp/rst.log || true").strip() or 0)
          print(f"MEASURED reset_maxjobs0_s={d0:.1f} accepts={a0}")

      with subtest("fallback: cloud unreachable, machines file empty, local build adds under 10 s"):
          client.succeed(
              "mkdir -p /run/systemd/system/nbh-gate.service.d && "
              "cp ${downDropIn} /run/systemd/system/nbh-gate.service.d/down.conf && "
              "systemctl daemon-reload && systemctl restart nbh-gate.service"
          )
          client.wait_until_succeeds("test ! -s /run/nbh/machines", timeout=30)
          d_off, _ = build("nbh-off", "--max-jobs 1 --builders @/dev/null", user="root")
          d_down, blog = build("down", "--max-jobs 1", user="root")
          print(f"MEASURED local_with_nbh_down_s={d_down:.1f} local_with_nbh_off_s={d_off:.1f}")
          assert "ssh-ng://" not in blog, blog
          assert d_down - d_off < 10, (d_down, d_off)
    '';
}
