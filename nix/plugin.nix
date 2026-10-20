# The nix-grpc-store client plugin for a Determinate Nix flake input, built with
# that Nix's own nixpkgs so libstdc++ matches the process that dlopen()s it
# (DESIGN.md F3), and patched for Determinate's addTempRoots signature (F2).
# $out/nix-grpc-store.so is the file to put in plugin-files.
{
  grpcSrc,
  determinate,
  system,
}:
let
  detNix = determinate.inputs.nix;
  dpkgs = detNix.inputs.nixpkgs.legacyPackages.${system};
  libs = { inherit (detNix.packages.${system}) nix-store nix-util; };
  scope = dpkgs.callPackage "${grpcSrc}/nix/packages" { nixPackages = libs; };
  plugin = (scope.pluginFor { inherit libs; }).overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ../patches/determinate-addTempRoots.patch ];
  });
  # The plugin installs under the Nix base version that pkg-config reports
  # (2.35.2 for Determinate 3.23.1), not Determinate's own version.
  baseVersion = dpkgs.lib.fileContents "${detNix}/.version";
in
dpkgs.runCommand "nix-grpc-store-plugin-${baseVersion}" { passthru = { inherit plugin baseVersion; }; } ''
  so=${plugin}/lib/nix/nix-grpc-store-versions/${baseVersion}/nix-grpc-store.so
  if [ ! -e "$so" ]; then
    echo "plugin was not built for Nix ${baseVersion}; found:" >&2
    ls ${plugin}/lib/nix/nix-grpc-store-versions >&2
    exit 1
  fi
  mkdir $out
  ln -s "$so" $out/nix-grpc-store.so
''
