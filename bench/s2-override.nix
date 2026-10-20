# Override scenario: a cache-busting change to libinput in DreamingDesk's own
# nixpkgs instance, like a local patch or a nixpkgs bump that touches it. The
# targets are the packages in DreamingDesk's closure that depend on libinput.
{ host ? "path:/workspace/nbh/nixos" }:
let
  flake = builtins.getFlake host;
  sys = flake.nixosConfigurations.DreamingDesk.extendModules {
    modules = [
      {
        nixpkgs.overlays = [
          (_: prev: { libinput = prev.libinput.overrideAttrs { NBH_CACHE_BUST = "1"; }; })
        ];
      }
    ];
  };
  pkgs = sys._module.args.pkgs;
  kde = pkgs.kdePackages;
in
{
  inherit (pkgs) libinput niri libinput-gestures xf86-input-libinput;
  inherit (kde)
    kwin kwin-x11 plasma-workspace plasma-desktop kdeplasma-addons kinfocenter
    powerdevil bluedevil plasma-pa print-manager xdg-desktop-portal-kde;
}
