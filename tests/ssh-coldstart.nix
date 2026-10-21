{ self, pkgs }:
let
  common = import ./common.nix { inherit self pkgs; };
in
pkgs.testers.runNixOSTest {
  name = "nbh-ssh-coldstart";
  nodes = {
    builder = common.builder;
    client =
      { nodes, ... }:
      {
        imports = [ common.client ];
        nix.settings.trusted-users = [ "root" ];
        services.nbh.gate.extraArgs = [
          "--backend" "fake"
          "--fake-addr" "${nodes.builder.networking.primaryIPAddress}:22"
          "--fake-boot-delay" "20s"
          "--idle-grace" "15s"
        ];
      };
  };
  testScript =
    { nodes, ... }:
    let
      downDropIn = pkgs.writeText "down.conf" ''
        [Service]
        ExecStart=
        ExecStart=${nodes.client.systemd.services.nbh-gate.serviceConfig.ExecStart} --fake-down
      '';
    in
    ''
      import re, time
      pki = "${common.pki}"

      def build(tag, extra="", user="alice", check=True, prefix=""):
          nonce = f"{tag}-{time.time_ns()}"
          cmd = f"nix-build /etc/nbh/probe.nix --argstr nonce {nonce} --no-out-link {extra}"
          if user == "alice":
              cmd = f"su - alice -c '{cmd}'"
          else:
              cmd = f"NIX_REMOTE=daemon {prefix}{cmd}"
          t0 = time.monotonic()
          if check:
              blog = client.succeed(cmd + " 2>&1")
          else:
              _, blog = client.execute(cmd + " 2>&1")
          return time.monotonic() - t0, blog

      client.start()
      client.wait_for_unit("nbh-gate.service")
      client.wait_until_succeeds(f"test -s {pki}/ssh_host_ca")
      # Atomic, like EC2 user-data: a half-written file reads as "not nbh v1" and nbh-keys exits.
      client.succeed(f"nbh-gate userdata {pki} > /var/lib/fake-imds/user-data.tmp && mv /var/lib/fake-imds/user-data.tmp /var/lib/fake-imds/user-data")
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
          assert "cannot build on" not in blog, blog

      with subtest("warm: second build splices straight to the serving builder"):
          d, blog = build("warm")
          print(f"MEASURED warm_build_s={d:.1f}")
          assert blog.count("on 'ssh-ng://nbh@nbh-builder") >= 2, blog
          assert d < 20, f"{d:.1f} s, as long as a 20 s builder boot"

      with subtest("dead-man sees an ssh-ng build as busy (an nbh session or a nixbld process)"):
          nonce = f"busy-{time.time_ns()}"
          client.succeed(f"su - alice -c 'nix-build /etc/nbh/probe.nix --argstr nonce {nonce} --argstr busy 20 --no-out-link' > /tmp/busy.log 2>&1 &")
          builder.wait_until_succeeds("ps -eo user= | grep -q '^nixbld'", timeout=60)
          print(builder.succeed("ps -eo user,comm | grep -E '^(nbh|nixbld)' || true"))
          builder.succeed("pgrep -u nbh -x nix-daemon")
          builder.succeed("systemctl start nbh-deadman.service")
          out = builder.succeed("journalctl -u nbh-deadman.service -n 3 -o cat")
          print(out)
          assert re.search(r"idle [0-1] s", out), out
          client.wait_until_succeeds("grep -q '^/nix/store/.*nbh-probe-b' /tmp/busy.log", timeout=120)
          print(client.succeed("cat /tmp/busy.log"))
          # Between builds, with nbh's user manager still lingering, the builder is idle.
          builder.succeed("touch -d '-5 min' /run/nbh-deadman/last-busy && systemctl start nbh-deadman.service")
          out = builder.succeed("journalctl -u nbh-deadman.service -n 3 -o cat")
          print(out)
          assert re.search(r"idle 3\d\d s", out), out
          last_close = time.monotonic()

      with subtest("terminate after idle: idle-grace 15 s after the last build"):
          client.wait_until_succeeds("journalctl -u nbh-gate.service | grep -q 'terminate '", timeout=60)
          d = time.monotonic() - last_close
          print(f"MEASURED terminate_after_last_build_s={d:.1f}")
          assert d <= 25, d

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
