# Client side: the machines file the gate owns, ssh options for nbh-builder,
# and the gate itself. Hook mode, so nh and nixos-rebuild are unchanged.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nbh;
  features = lib.concatStringsSep "," cfg.features;
  # The host key column stays "-": ssh_config below trusts the gate's host CA
  # for nbh-builder, and a pinned key could not change per boot.
  entry = "ssh-ng://nbh@nbh-builder:${toString cfg.port} x86_64-linux ${cfg.pkiDir}/ssh_client ${toString cfg.maxJobs} 1 ${features} - -";
in
{
  options.services.nbh = {
    enable = lib.mkEnableOption "builds on an elastic Nix Build Heaven builder";
    pkiDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nbh-gate/pki";
      description = "The gate's SSH host CA, client key and ssh_known_hosts.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 2222;
      description = "Local port the gate listens on as nbh-builder.";
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
      nix.distributedBuilds = true;
      nix.settings.builders = lib.mkForce "@${cfg.machinesFile}";
      nix.settings.builders-use-substitutes = true;
      # nix-daemon runs ssh as root. No ConnectTimeout: ssh then waits for the
      # banner while the gate holds the connection through a boot. Keepalives
      # end a session on a reclaimed Spot builder in about a minute.
      programs.ssh.extraConfig = ''
        Host nbh-builder
          HostKeyAlias nbh-builder
          UserKnownHostsFile ${cfg.pkiDir}/ssh_known_hosts
          StrictHostKeyChecking yes
          IdentitiesOnly yes
          ServerAliveInterval 15
          ServerAliveCountMax 4
      '';
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
          ExecStartPre = "${lib.getExe cfg.gate.package} pki-init ${cfg.pkiDir} ${config.networking.hostName}";
          ExecStart = lib.escapeShellArgs (
            [
              (lib.getExe cfg.gate.package)
              "-listen" "127.0.0.1:${toString cfg.port}"
              "-machines-file" cfg.machinesFile
              "-machines-entry" entry
              "-transport" "ssh-ng"
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
