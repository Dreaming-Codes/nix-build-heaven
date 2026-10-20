# Phase 3: the real nbh-gate on a Determinate client, with the fake EC2 backend
# "launching" the builder VM after a 20 s boot delay. Repeats proof/coldstart.txt
# with the gate, then checks terminate-after-drain and the unreachable fallback.
{ self, pkgs }:
let
  common = import ./common.nix { inherit self pkgs; };
  gate = pkgs.lib.getExe self.packages.x86_64-linux.gate;
in
pkgs.testers.runNixOSTest {
  name = "nbh-gate-coldstart";
  nodes = {
    inherit (common) builder;
    client =
      { nodes, ... }:
      {
        imports = [ common.client ];
        nix.settings.trusted-users = [ "root" ];
        services.nbh.gate.extraArgs = [
          "-backend" "fake"
          "-fake-addr" "${nodes.builder.networking.primaryIPAddress}:50051"
          "-fake-boot-delay" "20s"
          "-idle-grace" "10s"
        ];
      };
  };
  testScript =
    { nodes, ... }:
    ''
      import re, time
      pki = "${common.pki}"

      def build(tag, extra="", user="alice"):
          nonce = f"{tag}-{time.time_ns()}"
          cmd = f"nix-build /etc/nbh/probe.nix --argstr nonce {nonce} --no-out-link {extra}"
          if user == "alice":
              cmd = f"su - alice -c '{cmd}'"
          else:
              cmd = f"NIX_REMOTE=daemon {cmd}"
          t0 = time.monotonic()
          blog = client.succeed(cmd + " 2>&1")
          return time.monotonic() - t0, blog

      client.start()
      client.wait_for_unit("nbh-gate.service")
      client.wait_until_succeeds(f"test -s {pki}/ca.key")
      client.succeed(f"nbh-gate userdata {pki} > /var/lib/fake-imds/user-data")
      builder.start()
      builder.wait_for_open_port(50051, timeout=120)
      client.wait_until_succeeds("grep -q nbh-builder /run/nbh/machines")

      with subtest("cold start: gate holds the first connection through the 20 s boot, build runs remotely"):
          d, blog = build("cold")
          print(f"MEASURED cold_build_s={d:.1f}")
          assert blog.count("on 'grpc://nbh-builder") >= 2, blog
          assert d >= 20, f"finished in {d:.1f} s, before the fake builder booted"
          journal = client.succeed("journalctl -u nbh-gate.service")
          assert len(re.findall(r"launched \S+ as i-fake", journal)) == 1, journal

      with subtest("warm: second build splices straight to the serving builder"):
          d, blog = build("warm")
          print(f"MEASURED warm_build_s={d:.1f}")
          assert blog.count("on 'grpc://nbh-builder") >= 2, blog
          assert d < 10, d
          last_close = time.monotonic()

      with subtest("terminate after drain: idle-grace 10 s + 5 s recheck"):
          client.wait_until_succeeds("journalctl -u nbh-gate.service | grep -q 'terminate '", timeout=60)
          d = time.monotonic() - last_close
          print(f"MEASURED terminate_after_last_build_s={d:.1f}")
          assert 14 <= d <= 25, d
          client.wait_until_succeeds("journalctl -u nbh-gate.service | grep -q 'session .* ended, billed'", timeout=60)

      with subtest("fallback: cloud unreachable, machines file empty, local build adds under 10 s"):
          client.succeed(
              "mkdir -p /run/systemd/system/nbh-gate.service.d && "
              "printf '[Service]\\nExecStart=\\nExecStart=%s -fake-down\\n' "
              "\"$(systemctl show -p ExecStart --value nbh-gate.service | sed -n 's/.*argv\\[\\]=\\([^;]*\\);.*/\\1/p')\" "
              "> /run/systemd/system/nbh-gate.service.d/down.conf && systemctl daemon-reload && systemctl restart nbh-gate.service"
          )
          client.wait_until_succeeds("test ! -s /run/nbh/machines", timeout=30)
          d_off, _ = build("nbh-off", "--max-jobs 1 --builders @/dev/null", user="root")
          d_down, blog = build("down", "--max-jobs 1", user="root")
          print(f"MEASURED local_with_nbh_down_s={d_down:.1f} local_with_nbh_off_s={d_off:.1f}")
          assert "grpc://" not in blog, blog
          assert d_down - d_off < 10, (d_down, d_off)
    '';
}
