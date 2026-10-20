# Phase 1: Determinate Nix 3.23.1's nix-daemon loads the patched plugin and, with
# max-jobs 0, builds a two-derivation chain on the builder over grpc:// + mTLS.
{ self, pkgs }:
let
  common = import ./common.nix { inherit self pkgs; };
in
pkgs.testers.runNixOSTest {
  name = "nbh-hook-build";
  nodes = {
    inherit (common) builder;
    # No gate in this test: the machines file points straight at the builder.
    client =
      { nodes, ... }:
      {
        imports = [ common.client ];
        services.nbh.gate.enable = false;
        networking.hosts.${nodes.builder.networking.primaryIPAddress} = [ "nbh-builder" ];
      };
  };
  testScript =
    { nodes, ... }:
    ''
      import time
      pki = "${common.pki}"
      entry = "${nodes.client.services.nbh.machinesEntry}"

      client.start()
      client.wait_for_unit("fake-imds.service")
      client.succeed(f"nbh-gate pki-init {pki} client")
      client.succeed(f"nbh-gate userdata {pki} > /var/lib/fake-imds/user-data")
      client.succeed(f"echo '{entry}' > /run/nbh/machines")

      builder.start()
      builder.wait_for_unit("nix-grpc-daemon.service")
      builder.wait_for_open_port(50051)

      with subtest("Determinate client nix-daemon is Determinate 3.23.1"):
          out = client.succeed("nix --version")
          assert "Determinate Nix 3.23.1" in out, out

      with subtest("mTLS: no client certificate is rejected, the gate's client certificate is accepted"):
          client.fail(f"nix store info --store 'grpc://nbh-builder:50051?ca-cert={pki}/ca.crt&connect-timeout=5' 2>&1")
          client.succeed(f"nix store info --store 'grpc://nbh-builder:50051?ca-cert={pki}/ca.crt&client-cert={pki}/client.crt&client-key={pki}/client.key&connect-timeout=5'")

      with subtest("unprivileged user builds through the nix-daemon with max-jobs 0, entirely on the builder"):
          nonce = str(int(time.time()))
          blog = client.succeed(f"su - alice -c 'nix-build /etc/nbh/probe.nix --argstr nonce {nonce} --no-out-link' 2>&1")
          print(blog)
          out = blog.strip().splitlines()[-1]
          assert out.startswith("/nix/store/") and out.endswith(f"nbh-probe-b-{nonce}"), out
          assert client.succeed(f"cat {out}").strip() == f"a-{nonce} b"
          assert blog.count("on 'grpc://nbh-builder") >= 2, "both derivations must say they built on the builder"
          builder.succeed(f"nix-store --check-validity {out}")
    '';
}
