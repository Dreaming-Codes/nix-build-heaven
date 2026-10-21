{
  description = "Nix Build Heaven: one elastic Spot builder per build session for Dreaming-Codes/nixos";

  inputs = {
    # Same revision as Dreaming-Codes/nixos@7d20c80, so `follows` changes nothing.
    nixpkgs.url = "github:NixOS/nixpkgs/6aa7ad7f840d5a5bf17020b231d1c8d87a71995b";
    # Lorenzo's locked Determinate 3.23.1 (Nix 2.35.2 base), so the VM test clients run the hosts' Nix.
    determinate.url = "https://api.flakehub.com/f/pinned/DeterminateSystems/determinate/3.23.1/01a10edb-9034-7171-81fd-c25275e39c48/source.tar.gz";
    terranix = {
      url = "github:terranix/terranix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      determinate,
      terranix,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system} = {
        gate = pkgs.callPackage ./nix/gate.nix { };
        nbh-cache = pkgs.callPackage ./nix/nbh-cache.nix { };
        determinateNix = determinate.inputs.nix.packages.${system}.default;
        ami = self.nixosConfigurations.builder-ami.config.system.build.amazonImage;
        infra = terranix.lib.terranixConfiguration {
          inherit system;
          modules = [ ./infra ];
        };
      };

      nixosConfigurations.builder-ami = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          "${nixpkgs}/nixos/maintainers/scripts/ec2/amazon-image.nix"
          self.nixosModules.builder
          ./nix/ami.nix
        ];
      };

      nixosModules = {
        builder = ./modules/builder.nix;
        # The key lets two modules of one host both import this without a duplicate-option error.
        client = {
          key = "nix-build-heaven/modules/client.nix";
          _file = ./modules/client.nix;
          imports = [ (import ./modules/client.nix { inherit self; }) ];
        };
      };

      checks.${system} = {
        inherit (self.packages.${system}) gate nbh-cache;
        builder-image = import ./tests/builder-image.nix { inherit self pkgs; };
        ssh-coldstart = import ./tests/ssh-coldstart.nix { inherit self pkgs; };
        client-imported-twice =
          let
            host = nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                { imports = [ self.nixosModules.client ]; }
                { imports = [ self.nixosModules.client ]; }
                {
                  boot.loader.grub.enable = false;
                  fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
                  system.stateVersion = "26.05";
                  services.nbh.enable = true;
                  services.nbh.gate.aws.account = "123456789012";
                  services.nbh.gate.aws.region = "us-east-1";
                }
              ];
            };
          in
          pkgs.writeText "client-imported-twice" host.config.systemd.services.nbh-gate.serviceConfig.ExecStart;

        # The gate reads the CA from --pki, so a moved pkiDir must reach it too.
        client-pki-dir =
          let
            host = nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.client
                {
                  boot.loader.grub.enable = false;
                  fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
                  system.stateVersion = "26.05";
                  services.nbh.enable = true;
                  services.nbh.pkiDir = "/run/secrets/nbh-pki";
                }
              ];
            };
            exec = host.config.systemd.services.nbh-gate.serviceConfig.ExecStart;
          in
          assert nixpkgs.lib.assertMsg (nixpkgs.lib.hasInfix "--pki /run/secrets/nbh-pki " exec)
            "nbh-gate ExecStart lacks --pki for a moved pkiDir: ${exec}";
          pkgs.writeText "client-pki-dir" exec;

        # Every cache value comes from the host config, and a missing one fails eval.
        client-cache =
          let
            lib = nixpkgs.lib;
            hostWith =
              cache:
              lib.nixosSystem {
                inherit system;
                modules = [
                  self.nixosModules.client
                  {
                    boot.loader.grub.enable = false;
                    fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
                    system.stateVersion = "26.05";
                    networking.hostName = "example";
                    services.nbh.cache = {
                      enable = true;
                      credentialsFile = "/run/secrets/nbh-cache";
                    } // cache;
                  }
                ];
              };
            values = {
              account = "123456789012";
              region = "us-east-1";
              bucket = "example-cache";
              publicKey = "example-cache-1:AAAA";
            };
            config = (hostWith values).config;
            url = config.services.nbh.cache.url;
            exec = config.systemd.services.nbh-cache-roots.serviceConfig.ExecStart;
            fails = attrs: !(builtins.tryEval (hostWith attrs).config.system.build.toplevel.drvPath).success;
          in
          assert lib.assertMsg (url == "s3://example-cache?region=us-east-1&profile=nbh-cache-client&priority=50") "cache url: ${url}";
          assert lib.assertMsg (lib.elem "example-cache-1:AAAA" config.nix.settings.extra-trusted-public-keys) "cache key missing from trusted-public-keys";
          assert lib.assertMsg (lib.hasSuffix ''"--bucket" "example-cache" "--region" "us-east-1" "--aws-account" "123456789012" "--credentials-file" "/run/secrets/nbh-cache" "--profile" "nbh-cache-client" "roots" "--host" "example" "/nix/var/nix/profiles/system" "/run/current-system" "/run/booted-system"'' exec) "nbh-cache-roots ExecStart: ${exec}";
          assert lib.assertMsg (lib.all (n: fails (removeAttrs values [ n ])) (lib.attrNames values)) "a cache without account, region, bucket or publicKey still evaluated";
          pkgs.writeText "client-cache" "${url}\n${exec}\n";
      };
    };
}
