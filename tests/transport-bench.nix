# grpc:// against ssh-ng:// on the same builder VM (both transports enabled),
# no gate: closure copy of a fresh 64 MiB input and a 64 MiB output, small
# build latency, and whether builders-use-substitutes makes the builder fetch
# an input from a binary cache instead of receiving it from the client.
# TCG timings: crypto and copies are emulated, so only the ratio means much.
{ self, pkgs }:
let
  common = import ./common.nix { inherit self pkgs; };
  bulk = pkgs.writeText "bulk.nix" ''
    { nonce, blob, subst ? "" }:
    derivation {
      name = "nbh-bulk-''${nonce}";
      system = "x86_64-linux";
      builder = "${pkgs.bash}/bin/bash";
      args = [ "-c" "${pkgs.coreutils}/bin/cat ''${blob} ''${if subst == "" then "" else builtins.storePath subst} > /dev/null; ${pkgs.coreutils}/bin/head -c 67108864 /dev/urandom > $out" ];
    }
  '';
in
pkgs.testers.runNixOSTest {
  name = "nbh-transport-bench";
  nodes = {
    builder =
      { nodes, ... }:
      {
        imports = [ common.builder ];
        virtualisation.diskSize = 4096;
        services.nbh.builder.transports = [ "grpc" "ssh-ng" ];
        nix.settings.substituters = pkgs.lib.mkForce [ "http://${nodes.client.networking.primaryIPAddress}:8170" ];
        # The cache below is unsigned; signatures are not what is measured here.
        nix.settings.require-sigs = false;
      };
    client =
      { nodes, ... }:
      {
        imports = [ common.client ];
        virtualisation.diskSize = 4096;
        services.nbh.gate.enable = false;
        services.nbh.transport = "ssh-ng";
        nix.settings.plugin-files = [ "${self.packages.x86_64-linux.plugin}/nix-grpc-store.so" ];
        nix.settings.trusted-users = [ "root" ];
        networking.hosts.${nodes.builder.networking.primaryIPAddress} = [ "nbh-builder" ];
        networking.firewall.allowedTCPPorts = [ 8170 ];
        environment.etc."nbh/bulk.nix".source = bulk;
      };
  };
  testScript = ''
    import time, json
    pki = "${common.pki}"
    entries = {
        "grpc": f"grpc://nbh-builder:50051?ca-cert={pki}/ca.crt&client-cert={pki}/client.crt&client-key={pki}/client.key&connect-timeout=30 x86_64-linux - 4 1 big-parallel,benchmark",
        "ssh-ng": f"ssh-ng://nbh@nbh-builder:22 x86_64-linux {pki}/ssh_client 4 1 big-parallel,benchmark - -",
    }
    marker = {"grpc": "on 'grpc://nbh-builder", "ssh-ng": "on 'ssh-ng://nbh@nbh-builder"}

    client.start()
    client.wait_for_unit("fake-imds.service")
    client.succeed(f"nbh-gate pki-init {pki} client")
    client.succeed(f"nbh-gate userdata {pki} > /var/lib/fake-imds/user-data")
    client.succeed("mkdir -p /var/lib/cache && cd /var/lib/cache && (${pkgs.python3}/bin/python3 -m http.server 8170 > /tmp/http.log 2>&1 &)")
    client.wait_for_open_port(8170)
    builder.start()
    builder.wait_for_open_port(50051, timeout=180)
    builder.wait_for_open_port(22, timeout=60)

    def use(t):
        client.succeed(f"echo '{entries[t]}' > /run/nbh/machines")

    def timed(cmd):
        t0 = time.monotonic()
        out = client.succeed(cmd + " 2>&1")
        return time.monotonic() - t0, out

    results = {"grpc": {"small": [], "bulk": []}, "ssh-ng": {"small": [], "bulk": []}}
    with subtest("small two-step build, 3 runs each, alternating"):
        for i in range(3):
            for t in ("grpc", "ssh-ng"):
                use(t)
                d, out = timed(f"nix-build /etc/nbh/probe.nix --argstr nonce small-{t}-{i}-{time.time_ns()} --no-out-link")
                assert out.count(marker[t]) >= 2, out
                results[t]["small"].append(round(d, 2))
        print("MEASURED small " + json.dumps({t: results[t]["small"] for t in results}))

    with subtest("64 MiB fresh input up, 64 MiB output back, 3 runs each, alternating"):
        for i in range(3):
            for t in ("grpc", "ssh-ng"):
                use(t)
                blob = f"/tmp/blob-{t}-{i}"
                client.succeed(f"head -c 67108864 /dev/urandom > {blob}")
                d, out = timed(f"NIX_REMOTE=daemon nix-build /etc/nbh/bulk.nix --argstr nonce bulk-{t}-{i}-{time.time_ns()} --arg blob {blob} --no-out-link")
                assert marker[t] in out, out
                path = out.strip().splitlines()[-1]
                assert client.succeed(f"stat -c %s {path}").strip() == "67108864"
                results[t]["bulk"].append(round(d, 2))
        print("MEASURED bulk " + json.dumps({t: results[t]["bulk"] for t in results}))

    with subtest("builders-use-substitutes: the builder fetches a cached input itself"):
        for t in ("grpc", "ssh-ng"):
            use(t)
            client.succeed(f"head -c 33554432 /dev/urandom > /tmp/subst-{t}")
            p = client.succeed(f"nix-store --add /tmp/subst-{t}").strip()
            client.succeed(f"nix --extra-experimental-features nix-command copy --to file:///var/lib/cache {p}")
            client.succeed("truncate -s0 /tmp/http.log")
            client.succeed(f"head -c 16 /dev/urandom > /tmp/tiny-{t}")
            d, out = timed(f"NIX_REMOTE=daemon nix-build /etc/nbh/bulk.nix --argstr nonce subst-{t}-{time.time_ns()} --arg blob /tmp/tiny-{t} --argstr subst {p} --no-out-link")
            assert marker[t] in out, out
            h = p.split("/")[-1].split("-")[0]
            log = client.succeed("cat /tmp/http.log")
            got_narinfo = f"GET /{h}.narinfo HTTP/1.1\" 200" in log
            got_nar = "GET /nar/" in log and "\" 200" in log
            builder.succeed(f"nix-store --check-validity {p}")
            print(f"MEASURED substitute transport={t} narinfo_200={got_narinfo} nar_fetched={got_nar} build_s={d:.1f}")
            print(log)
            results[t]["substituted"] = got_narinfo and got_nar
    print("MEASURED summary " + json.dumps(results))
  '';
}
