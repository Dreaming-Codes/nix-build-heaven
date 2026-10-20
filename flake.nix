{
  description = "Nix Build Heaven: one elastic Spot builder per build session for Dreaming-Codes/nixos";

  inputs = {
    # Same revision as Dreaming-Codes/nixos@7d20c80, so `follows` changes nothing.
    nixpkgs.url = "github:NixOS/nixpkgs/6aa7ad7f840d5a5bf17020b231d1c8d87a71995b";
    # Lorenzo's locked Determinate 3.23.1 (Nix 2.35.2 base), the version the plugin must load into.
    determinate.url = "https://api.flakehub.com/f/pinned/DeterminateSystems/determinate/3.23.1/01a10edb-9034-7171-81fd-c25275e39c48/source.tar.gz";
    terranix = {
      url = "github:terranix/terranix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-grpc-store = {
      url = "github:Mic92/nix-grpc-store/199d78a4a8d45b480acde25f4a191e6034f94c5d";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      determinate,
      nix-grpc-store,
      terranix,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      pluginFor = determinateInput: import ./nix/plugin.nix {
        grpcSrc = nix-grpc-store;
        determinate = determinateInput;
        inherit system;
      };
    in
    {
      lib = { inherit pluginFor; };

      packages.${system} = {
        gate = pkgs.callPackage ./nix/gate.nix { };
        plugin = pluginFor determinate;
        determinateNix = determinate.inputs.nix.packages.${system}.default;
        ami = self.nixosConfigurations.builder-ami.config.system.build.amazonImage;
        # OpenTofu JSON for the AWS side; scripts/tofu.sh applies it with local state.
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
        builder = import ./modules/builder.nix { grpcSrc = nix-grpc-store; };
        client = import ./modules/client.nix { inherit self; };
      };

      checks.${system} = {
        inherit (self.packages.${system}) gate plugin;
        phase1-hook-build = import ./tests/hook-build.nix { inherit self pkgs; };
        phase2-builder-image = import ./tests/builder-image.nix { inherit self pkgs; };
        phase3-gate-coldstart = import ./tests/gate-coldstart.nix { inherit self pkgs; };
        ssh-coldstart = import ./tests/ssh-coldstart.nix { inherit self pkgs; };
      };
    };
}
