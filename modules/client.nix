# Client side: the Determinate-compatible plugin, the machines file the gate
# owns, and the gate itself. Hook mode, so nh and nixos-rebuild are unchanged.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nbh;
  query = lib.concatStringsSep "&" [
    "ca-cert=${cfg.tlsDir}/ca.crt"
    "client-cert=${cfg.tlsDir}/client.crt"
    "client-key=${cfg.tlsDir}/client.key"
    "connect-timeout=${toString cfg.connectTimeout}"
  ];
  entry = "grpc://nbh-builder:${toString cfg.port}?${query} x86_64-linux - ${toString cfg.maxJobs} 1 ${lib.concatStringsSep "," cfg.features}";
in
{
  options.services.nbh = {
    enable = lib.mkEnableOption "builds on an elastic Nix Build Heaven builder";
    plugin = lib.mkOption {
      type = lib.types.package;
      description = "Output of nix-build-heaven.lib.pluginFor, built for the host's Determinate input.";
    };
    tlsDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nbh-gate/pki";
      description = "ca.crt, client.crt and client.key; ca.key too when the gate mints builder certificates.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 50051;
    };
    connectTimeout = lib.mkOption {
      type = lib.types.int;
      default = 150;
      description = "Seconds nix keeps retrying while the gate refuses connections for a booting builder.";
    };
    maxJobs = lib.mkOption {
      type = lib.types.int;
      default = 192;
    };
    features = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "big-parallel" "benchmark" ];
    };
    machinesFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/nbh/machines";
    };
    machinesEntry = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = entry;
    };
    gate = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run nbh-gate. Off means something else owns the machines file and nbh-builder.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.gate;
      };
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      nix.settings.plugin-files = [ "${cfg.plugin}/nix-grpc-store.so" ];
      nix.distributedBuilds = true;
      nix.settings.builders = lib.mkForce "@${cfg.machinesFile}";
      nix.settings.builders-use-substitutes = true;
      systemd.tmpfiles.rules = [
        "d ${dirOf cfg.machinesFile} 0755 root root -"
        "f ${cfg.machinesFile} 0644 root root -"
      ];
    }
    (lib.mkIf cfg.gate.enable {
      networking.hosts."127.0.0.1" = [ "nbh-builder" ];
      systemd.services.nbh-gate = {
        description = "Nix Build Heaven gate";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          ExecStartPre = "${lib.getExe cfg.gate.package} pki-init ${cfg.tlsDir} ${config.networking.hostName}";
          ExecStart = lib.escapeShellArgs (
            [
              (lib.getExe cfg.gate.package)
              "-listen" "127.0.0.1:${toString cfg.port}"
              "-machines-file" cfg.machinesFile
              "-machines-entry" entry
            ]
            ++ cfg.gate.extraArgs
          );
          Restart = "always";
          RestartSec = 1;
          StateDirectory = "nbh-gate";
          StateDirectoryMode = "0700";
        };
      };
    })
  ]);
}
