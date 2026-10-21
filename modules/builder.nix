{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nbh.builder;
  keys = "/run/nbh-ssh";
  userDataFields = lib.importJSON ../gate/user-data-fields.json;
  cache = import ../nix/cache.nix;
  field =
    name:
    if lib.elem name userDataFields then
      ".${name}"
    else
      throw "builder.nix reads user-data field ${name}, which nbh-gate does not write (gate/user-data-fields.json)";
in
{
  options.services.nbh.builder = {
    enable = lib.mkEnableOption "the Nix Build Heaven remote builder";
    userDataUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://169.254.169.254/latest/user-data";
      description = "IMDSv2 user-data URL holding the SSH material minted by nbh-gate.";
    };
    idleTimeout = lib.mkOption {
      type = lib.types.int;
      default = 600;
      description = "Seconds with no ssh-ng session and no builds before the builder powers off.";
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
    assertions = [
      {
        assertion = lib.all (s: lib.any (u: lib.hasPrefix u s) cache.upstream) config.nix.settings.substituters;
        message = "services.nbh.builder: substituters must be install.determinate.systems or cache.nixos.org only. Any other cache's key can sign any path the builder uploads to ours.";
      }
      {
        assertion = !lib.elem "kvm" config.nix.settings.system-features;
        message = "services.nbh.builder: no kvm in nix.settings.system-features. Non-metal EC2 instances have no /dev/kvm, so VM tests must stay local.";
      }
    ];
    # nbh runs the client's `nix-daemon --stdio`, so it must be trusted.
    users.users.nbh = {
      isSystemUser = true;
      group = "nbh";
      useDefaultShell = true;
    };
    users.groups.nbh = { };
    nix.settings.trusted-users = [ "nbh" ];
    environment.systemPackages = [ (pkgs.callPackage ../nix/nbh-cache.nix { }) ];
    services.openssh = {
      enable = true;
      openFirewall = true;
      hostKeys = lib.mkForce [ ];
      authorizedKeysFiles = lib.mkForce [ "${keys}/authorized_keys.%u" ];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = lib.mkForce "no";
        AllowUsers = [ "nbh" ];
      };
      extraConfig = ''
        HostKey ${keys}/ssh_host_ed25519_key
        HostCertificate ${keys}/ssh_host_ed25519_key-cert.pub
      '';
    };
    systemd.services.sshd = {
      requires = [ "nbh-keys.service" ];
      after = [ "nbh-keys.service" ];
    };

    systemd.services.nbh-keys = {
      description = "Fetch the builder's SSH material from EC2 user-data";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.curl pkgs.jq pkgs.coreutils ];
      # Retry inside the unit: a failed oneshot fails sshd's start job for
      # good, so Restart= would leave the builder up but never serving.
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        base=${lib.escapeShellArg cfg.userDataUrl}
        imds=''${base%/latest/*}
        until token=$(curl -sf --max-time 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' "$imds/latest/api/token") &&
          ud=$(curl -sf --max-time 5 -H "X-aws-ec2-metadata-token: $token" "$base"); do
          echo "user-data not available yet, retrying"
          sleep 1
        done
        [ "$(jq -r ${field "nbh"} <<<"$ud")" = 1 ] || { echo "user-data is not nbh v1" >&2; exit 1; }
        install -d -m 0755 ${keys}
        (umask 077; jq -r ${field "ssh_host_key"} <<<"$ud" > ${keys}/ssh_host_ed25519_key)
        jq -r ${field "ssh_host_cert"} <<<"$ud" > ${keys}/ssh_host_ed25519_key-cert.pub
        jq -r ${field "ssh_authorized_keys"} <<<"$ud" > ${keys}/authorized_keys.nbh
        chmod 0644 ${keys}/ssh_host_ed25519_key-cert.pub ${keys}/authorized_keys.nbh
      '';
    };

    systemd.services.nbh-deadman = {
      description = "Power off when idle or past the uptime cap";
      path = [ pkgs.procps pkgs.gnugrep pkgs.coreutils pkgs.systemd ];
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
        # Busy is an ssh-ng session or a running build. A TCP connection on 22
        # cannot say it, since scanners hit 22 all day; an authenticated session
        # runs `nix-daemon --stdio` as nbh. Any nbh process cannot either: PAM
        # leaves nbh's systemd --user running after logout.
        if pgrep -u nbh -x nix-daemon > /dev/null || ps -eo user= | grep -q '^nixbld'; then
          touch $state/last-busy
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
      ];
      trusted-public-keys = cache.upstreamKeys ++ [ cache.publicKey ];
      # Matches the client hosts, so __noChroot derivations build remotely too.
      sandbox = "relaxed";
      max-jobs = "auto";
      cores = 0;
      system-features = lib.mkForce [ "benchmark" "big-parallel" ];
      experimental-features = [ "nix-command" "flakes" ];
    };
  };
}
