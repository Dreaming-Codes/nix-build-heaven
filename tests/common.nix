# Shared VM test nodes: a Determinate Nix client that also serves fake IMDS
# user-data, and a builder running the real builder module.
{ self, pkgs }:
let
  pki = "/var/lib/nbh-gate/pki";
  probe = pkgs.writeText "probe.nix" ''
    { nonce }:
    let
      mk = name: script: derivation {
        inherit name;
        system = "x86_64-linux";
        builder = "/bin/sh";
        args = [ "-c" script ];
      };
      a = mk "nbh-probe-a-''${nonce}" "echo a-''${nonce} > $out";
    in
    mk "nbh-probe-b-''${nonce}" "read x < ''${a}; echo \"$x b\" > $out"
  '';
in
{
  inherit pki probe;

  client =
    { nodes, lib, ... }:
    {
      imports = [ self.nixosModules.client ];
      virtualisation.memorySize = pkgs.lib.mkDefault 2048;
      nix.package = self.packages.x86_64-linux.determinateNix;
      nix.settings = {
        substituters = lib.mkForce [ ];
        experimental-features = [ "nix-command" ];
        max-jobs = 0;
      };
      services.nbh = {
        enable = true;
        plugin = self.packages.x86_64-linux.plugin;
        tlsDir = pki;
        connectTimeout = 60;
        maxJobs = 4;
      };
      environment.systemPackages = [ self.packages.x86_64-linux.gate ];
      environment.etc."nbh/probe.nix".source = probe;
      users.users.alice = {
        isNormalUser = true;
      };
      networking.firewall.allowedTCPPorts = [ 8169 ];
      systemd.services.fake-imds = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${./fake-imds.py} /var/lib/fake-imds/user-data 8169";
        serviceConfig.StateDirectory = "fake-imds";
      };
    };

  builder =
    { nodes, ... }:
    {
      imports = [ self.nixosModules.builder ];
      virtualisation.memorySize = pkgs.lib.mkDefault 2048;
      virtualisation.cores = 2;
      services.nbh.builder = {
        enable = true;
        userDataUrl = "http://${nodes.client.networking.primaryIPAddress}:8169/latest/user-data";
      };
      services.nix-grpc-daemon.minFree = "0";
      services.nix-grpc-daemon.logLevel = "debug";
      nix.settings.substituters = pkgs.lib.mkForce [ ];
    };
}
