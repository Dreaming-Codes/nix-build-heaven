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
        client = import ./modules/client.nix { inherit self; };
      };

      checks.${system} = {
        inherit (self.packages.${system}) gate nbh-cache;
        builder-image = import ./tests/builder-image.nix { inherit self pkgs; };
        ssh-coldstart = import ./tests/ssh-coldstart.nix { inherit self pkgs; };
      };
    };
}
