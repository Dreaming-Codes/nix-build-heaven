# The AWS builder: nix-grpc-daemon behind mTLS, certificates from EC2 user-data,
# and a dead-man switch that powers the instance off when nobody uses it.
{ grpcSrc }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nbh.builder;
  keys = "/run/nbh-keys";
  metrics = "127.0.0.1:9184";
in
{
  imports = [ "${grpcSrc}/nixos/server.nix" ];

  options.services.nbh.builder = {
    enable = lib.mkEnableOption "the Nix Build Heaven remote builder";
    userDataUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://169.254.169.254/latest/user-data";
      description = "IMDSv2 user-data URL holding the TLS material minted by nbh-gate.";
    };
    idleTimeout = lib.mkOption {
      type = lib.types.int;
      default = 600;
      description = "Seconds with no clients and no builds before the builder powers off.";
    };
    maxUptime = lib.mkOption {
      type = lib.types.int;
      default = 3 * 3600;
      description = "Seconds of uptime after which the builder powers off regardless.";
    };
    checkInterval = lib.mkOption {
      type = lib.types.str;
      default = "30s";
    };
  };

  config = lib.mkIf cfg.enable {
    services.nix-grpc-daemon = {
      enable = true;
      listen = "0.0.0.0:50051";
      idleTimeout = null;
      roles = [ "builder" "scheduler" ];
      trustClients = true;
      metricsListen = metrics;
      minFree = lib.mkDefault "5G";
      tls = {
        certFile = "${keys}/server.crt";
        keyFile = "${keys}/server.key";
        clientCaFile = "${keys}/client-ca.crt";
      };
    };

    systemd.services.nbh-keys = {
      description = "Fetch builder TLS material from EC2 user-data";
      wantedBy = [ "multi-user.target" ];
      before = [ "nix-grpc-daemon.service" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.curl pkgs.jq pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 1;
      };
      unitConfig.StartLimitIntervalSec = 0;
      script = ''
        base=${lib.escapeShellArg cfg.userDataUrl}
        imds=''${base%/latest/*}
        token=$(curl -sf --max-time 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' "$imds/latest/api/token")
        ud=$(curl -sf --max-time 5 -H "X-aws-ec2-metadata-token: $token" "$base")
        [ "$(jq -r .nbh <<<"$ud")" = 1 ] || { echo "user-data is not nbh v1" >&2; exit 1; }
        install -d -m 0750 -g nix-grpc-daemon ${keys}
        umask 027
        jq -r .server_cert <<<"$ud" > ${keys}/server.crt
        jq -r .server_key <<<"$ud" > ${keys}/server.key
        jq -r .client_ca <<<"$ud" > ${keys}/client-ca.crt
        chgrp nix-grpc-daemon ${keys}/*
      '';
    };
    systemd.services.nix-grpc-daemon = {
      requires = [ "nbh-keys.service" ];
      after = [ "nbh-keys.service" ];
    };

    systemd.services.nbh-deadman = {
      description = "Power off when idle or past the uptime cap";
      path = [ pkgs.curl pkgs.gawk pkgs.coreutils pkgs.systemd ];
      serviceConfig.Type = "oneshot";
      script = ''
        state=/run/nbh-deadman
        mkdir -p $state
        [ -e $state/last-busy ] || touch $state/last-busy
        up=$(cut -d. -f1 /proc/uptime)
        if [ "$up" -ge ${toString cfg.maxUptime} ]; then
          echo "uptime $up s reached the ${toString cfg.maxUptime} s cap, powering off"
          systemctl poweroff
          exit 0
        fi
        if load=$(curl -sf --max-time 5 http://${metrics}/metrics); then
          busy=$(awk '
            /^nix_grpc_sched\{kind="(clients|queued)"\}/ { s += $NF }
            /^nix_grpc_sched_system\{/ && /kind="running"/ { s += $NF }
            END { print (s > 0) ? 1 : 0 }' <<<"$load")
          [ "$busy" = 1 ] && touch $state/last-busy
        fi
        idle=$(( $(date +%s) - $(stat -c %Y $state/last-busy) ))
        echo "idle $idle s, uptime $up s"
        if [ "$idle" -ge ${toString cfg.idleTimeout} ]; then
          echo "idle for $idle s, powering off"
          systemctl poweroff
        fi
      '';
    };
    systemd.timers.nbh-deadman = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.checkInterval;
        OnUnitActiveSec = cfg.checkInterval;
        AccuracySec = "1s";
      };
    };

    nix.settings = {
      substituters = [
        "https://install.determinate.systems?priority=20"
        "https://cache.nixos.org?priority=40"
        "https://nix-community.cachix.org?priority=41"
        "https://numtide.cachix.org?priority=43"
        "https://cache.xinux.uz?priority=44"
        "https://cache.nixos-cuda.org?priority=45"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
        "cache.xinux.uz:BXCrtqejFjWzWEB9YuGB7X2MV4ttBur1N8BkwQRdH+0="
        "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      ];
      # Matches the client hosts, so __noChroot derivations build remotely too.
      sandbox = "relaxed";
      max-jobs = "auto";
      cores = 0;
      # No kvm: non-metal EC2 instances do not expose /dev/kvm, so VM tests stay local.
      system-features = [ "benchmark" "big-parallel" ];
      experimental-features = [ "nix-command" "flakes" ];
    };

    networking.firewall.allowedTCPPorts = [ 50051 ];
  };
}
