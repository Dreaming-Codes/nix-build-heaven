# Hook mode through `builders = @file`, so nh and nixos-rebuild need no flags.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nbh;
  cc = cfg.cache;
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
    cache = {
      enable = lib.mkEnableOption "the Nix Build Heaven S3 cache as a substituter, with this host's roots kept in it";
      account = lib.mkOption {
        type = lib.types.strMatching "[0-9]{12}";
        description = "AWS account that owns the bucket. nbh-cache refuses a key of any other account.";
      };
      region = lib.mkOption {
        type = lib.types.str;
        example = "eu-north-1";
        description = "AWS region of the bucket. Set it explicitly so every host resolves the same cache.";
      };
      bucket = lib.mkOption {
        type = lib.types.str;
        description = "S3 bucket of the cache.";
      };
      publicKey = lib.mkOption {
        type = lib.types.str;
        description = "Public half of the key that signs the cache's narinfos.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = config.networking.hostName;
        defaultText = lib.literalExpression "config.networking.hostName";
        description = "Host name of the read key, and of the roots/<host> object only that key may write.";
      };
      profile = lib.mkOption {
        type = lib.types.str;
        default = "nbh-cache-${cc.host}";
        defaultText = lib.literalExpression ''"nbh-cache-''${config.services.nbh.cache.host}"'';
        description = "Profile in credentialsFile that holds this host's key.";
      };
      credentialsFile = lib.mkOption {
        type = lib.types.str;
        description = "AWS shared credentials file with the profile named by `profile`, readable by root only.";
      };
      priority = lib.mkOption {
        type = lib.types.int;
        default = 50;
        description = "Substituter priority. cache.nixos.org is 40, so upstream wins for paths both serve.";
      };
      url = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "s3://${cc.bucket}?region=${cc.region}&profile=${cc.profile}&priority=${toString cc.priority}";
        defaultText = lib.literalMD "the `s3://` URL built from bucket, region, profile and priority";
      };
      roots = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Write this host's system closure to roots/<host> whenever the system profile changes, so the cache GC keeps it.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.nbh-cache;
      };
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
      aws = {
        account = lib.mkOption {
          type = lib.types.nullOr (lib.types.strMatching "[0-9]{12}");
          default = null;
          description = "AWS account the gate's key must belong to. Set means `--backend aws`; the gate checks it with STS and refuses to start on any other account.";
        };
        credentialsFile = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/nbh-gate/aws.credentials";
          description = "AWS shared credentials file, readable by root. The gate reads no other credential source.";
        };
        profile = lib.mkOption {
          type = lib.types.str;
          default = "nbh-gate";
        };
        region = lib.mkOption {
          type = lib.types.str;
          example = "eu-north-1";
          description = "AWS region the gate launches builders in. Required once account is set.";
        };
      };
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cc.enable (lib.mkMerge [
      {
        nix.settings.extra-substituters = [ cc.url ];
        nix.settings.extra-trusted-public-keys = [ cc.publicKey ];
        systemd.services.nix-daemon.environment.AWS_SHARED_CREDENTIALS_FILE = cc.credentialsFile;
      }
      (lib.mkIf cc.roots {
        systemd.services.nbh-cache-roots = {
          description = "Write this host's system closure to the Nix Build Heaven cache roots";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          path = [ config.nix.package ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.escapeShellArgs [
              (lib.getExe cc.package)
              "--bucket" cc.bucket
              "--region" cc.region
              "--aws-account" cc.account
              "--credentials-file" cc.credentialsFile
              "--profile" cc.profile
              "roots"
              "--host" cc.host
              "/nix/var/nix/profiles/system"
              "/run/current-system"
              "/run/booted-system"
            ];
            Restart = "on-failure";
            RestartSec = 60;
          };
        };
        systemd.paths.nbh-cache-roots = {
          wantedBy = [ "multi-user.target" ];
          pathConfig.PathChanged = "/nix/var/nix/profiles";
        };
      })
    ]))
    (lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = !lib.hasInfix "connecttimeout" (lib.toLower config.programs.ssh.extraConfig);
          message = "services.nbh: no ConnectTimeout in programs.ssh.extraConfig. ssh must wait for the banner while nbh-gate holds the connection through a builder boot.";
        }
      ];
      nix.distributedBuilds = true;
      nix.settings.builders = lib.mkForce "@${cfg.machinesFile}";
      nix.settings.builders-use-substitutes = true;
      # nix-daemon runs ssh as root. Keepalives end a session on a reclaimed
      # Spot builder in about a minute.
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
              "run"
              "--listen" "127.0.0.1:${toString cfg.port}"
              "--pki" cfg.pkiDir
              "--machines-file" cfg.machinesFile
              "--machines-entry" entry
            ]
            ++ lib.optionals (cfg.gate.aws.account != null) [
              "--backend" "aws"
              "--aws-account" cfg.gate.aws.account
              "--credentials-file" cfg.gate.aws.credentialsFile
              "--profile" cfg.gate.aws.profile
              "--region" cfg.gate.aws.region
            ]
            ++ cfg.gate.extraArgs
          );
          Restart = "always";
          RestartSec = 1;
          # 78 is a key of the wrong AWS account. Retrying cannot fix it.
          RestartPreventExitStatus = 78;
          StateDirectory = "nbh-gate";
          StateDirectoryMode = "0700";
        };
      };
    })
  ]))
  ];
}
