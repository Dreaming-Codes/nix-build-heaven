let
  f = builtins.getFlake "git+file:///workspace/nbh/nix-build-heaven?ref=refs/heads/client-module-key";
  sys = f.inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      { imports = [ f.nixosModules.client ]; }
      { imports = [ f.nixosModules.client ]; }
      { boot.loader.grub.enable = false; fileSystems."/" = { device = "none"; fsType = "tmpfs"; }; system.stateVersion = "26.05";
        networking.hostName = "DreamingDesk"; services.nbh.enable = true; services.nbh.gate.aws.account = "845087560967"; }
    ];
  };
in sys.config.systemd.services.nbh-gate.serviceConfig.RestartPreventExitStatus
