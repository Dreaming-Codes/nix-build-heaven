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
  features = lib.concatStringsSep "," cfg.features;
  grpc = cfg.transport == "grpc";
  entry =
    if grpc then
      "grpc://nbh-builder:${toString cfg.port}?${query} x86_64-linux - ${toString cfg.maxJobs} 1 ${features}"
    # ssh-ng: the host key column stays "-" because ssh_config below trusts the
    # gate's host CA for nbh-builder; a pinned key could not change per boot.
    else
      "ssh-ng://${sshUser}@nbh-builder:${toString cfg.port} x86_64-linux ${cfg.tlsDir}/ssh_client ${toString cfg.maxJobs} 1 ${features} - -";
  sshUser = "nbh";
in
{
  options.services.nbh = {
    enable = lib.mkEnableOption "builds on an elastic Nix Build Heaven builder";
    transport = lib.mkOption {
      type = lib.types.enum [ "grpc" "ssh-ng" ];
      default = "grpc";
      description = ''
        grpc needs the nix-grpc-store plugin; the gate resets connections while
        the builder boots and the plugin retries. ssh-ng is built into Nix; the
        gate holds the connection through the boot and ssh waits for the banner.
      '';
    };
    plugin = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Output of nix-build-heaven.lib.pluginFor, built for the host's Determinate input. grpc only.";
    };
    tlsDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nbh-gate/pki";
      description = "ca.crt, client.crt and client.key; ca.key too when the gate mints builder certificates.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = if grpc then 50051 else 2222;
      description = "Local port the gate listens on as nbh-builder.";
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
    (lib.mkIf grpc {
      assertions = [
        {
          assertion = cfg.plugin != null;
          message = "services.nbh.plugin is required with transport grpc";
        }
      ];
      nix.settings.plugin-files = [ "${cfg.plugin}/nix-grpc-store.so" ];
    })
    (lib.mkIf (!grpc) {
      # nix-daemon runs ssh as root. No ConnectTimeout: ssh then waits for the
      # banner while the gate holds the connection through a boot. Keepalives
      # end a session on a reclaimed Spot builder in about a minute.
      programs.ssh.extraConfig = ''
        Host nbh-builder
          HostKeyAlias nbh-builder
          UserKnownHostsFile ${cfg.tlsDir}/ssh_known_hosts
          StrictHostKeyChecking yes
          IdentitiesOnly yes
          ServerAliveInterval 15
          ServerAliveCountMax 4
      '';
    })
    {
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
              "-retry-hold" "${toString cfg.connectTimeout}s"
              "-transport" cfg.transport
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
