{ self, pkgs }:
let
  common = import ./common.nix { inherit self pkgs; };
in
pkgs.testers.runNixOSTest {
  name = "nbh-builder-image";
  nodes = {
    builder = {
      imports = [ common.builder ];
      services.nbh.builder = {
        idleTimeout = 60;
        checkInterval = "3s";
      };
    };
    capped = {
      imports = [ common.builder ];
      virtualisation.memorySize = 1024;
      services.nbh.builder = {
        maxUptime = 150;
        checkInterval = "3s";
      };
    };
    client =
      { nodes, ... }:
      {
        imports = [ common.client ];
        services.nbh.gate.enable = false;
        services.nbh.port = 22;
        networking.hosts.${nodes.builder.networking.primaryIPAddress} = [ "nbh-builder" ];
      };
  };
  testScript =
    { nodes, ... }:
    ''
      import time
      pki = "${common.pki}"

      client.start()
      client.wait_for_unit("fake-imds.service")
      client.succeed(f"nbh-gate pki-init {pki} client")
      client.succeed("echo '${nodes.client.services.nbh.machinesEntry}' > /run/nbh/machines")

      with subtest("builder waits for user-data and serves once it appears"):
          builder.start()
          builder.wait_until_succeeds("journalctl -u nbh-keys.service | grep -q 'user-data not available yet'", timeout=120)
          builder.fail("nc -z 127.0.0.1 22")
          client.succeed(f"nbh-gate userdata {pki} > /var/lib/fake-imds/user-data")
          builder.wait_for_open_port(22, timeout=60)

      with subtest("client builds through the builder with its user-data host certificate"):
          nonce = str(int(time.time()))
          blog = client.succeed(f"su - alice -c 'nix-build /etc/nbh/probe.nix --argstr nonce {nonce} --no-out-link' 2>&1")
          out = blog.strip().splitlines()[-1]
          assert blog.count("on 'ssh-ng://nbh@nbh-builder") >= 2, blog
          builder.succeed(f"nix-store --check-validity {out}")
          build_done = time.monotonic()

      with subtest("dead-man: still up well inside the idle window, off after it"):
          time.sleep(30)
          builder.succeed("true")
          builder.wait_for_shutdown()
          idle_to_off = time.monotonic() - build_done
          print(f"MEASURED idle_to_poweroff_s={idle_to_off:.1f} (idleTimeout 60 s, check every 3 s)")
          assert 57 <= idle_to_off <= 80, idle_to_off

      with subtest("boot to serving"):
          t0 = time.monotonic()
          capped.start()
          capped.wait_for_open_port(22, timeout=300)
          boot_to_serving = time.monotonic() - t0
          kernel_to_serving = float(capped.succeed("cut -d' ' -f1 /proc/uptime"))
          print(f"MEASURED boot_to_serving_s={boot_to_serving:.1f} uptime_at_serving_s={kernel_to_serving:.1f}")
          print(capped.succeed("systemd-analyze; systemd-analyze critical-chain sshd.service || true"))

      with subtest("dead-man: uptime cap powers off an idle-forever builder"):
          capped.wait_for_shutdown()
          print(f"MEASURED capped_off_after_start_s={time.monotonic() - t0:.1f} (maxUptime 150 s)")
          assert time.monotonic() - t0 >= 150
    '';
}
