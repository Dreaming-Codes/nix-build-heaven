let
  pkgs = import (builtins.getFlake "nixpkgs") { system = "x86_64-linux"; };
  w = pkgs.writeText;
  leaf = w "nbh-proto-leaf" "leaf ${toString builtins.currentTime}";
  mid = w "nbh-proto-mid" "mid -> ${leaf}";
in {
  root = w "nbh-proto-root" "root -> ${mid} ${pkgs.hello}";
  unrelated = w "nbh-proto-unrelated" "unrelated ${toString builtins.currentTime}";
  recent = w "nbh-proto-recent" "recent ${toString builtins.currentTime}";
}
