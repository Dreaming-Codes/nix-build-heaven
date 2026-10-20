{ buildGoModule }:
buildGoModule {
  pname = "nbh-gate";
  version = "0.1.0";
  src = ../gate;
  vendorHash = null;
  subPackages = [ "cmd/nbh-gate" ];
  env.CGO_ENABLED = "0";
  meta.mainProgram = "nbh-gate";
}
