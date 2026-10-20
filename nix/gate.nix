{ buildGoModule }:
buildGoModule {
  pname = "nbh-gate";
  version = "0.1.0";
  src = ../gate;
  vendorHash = "sha256-L623YmIVgX8sM7C5GTKZOm+uRt2DgIsPlJbhbHox7l4=";
  subPackages = [ "cmd/nbh-gate" ];
  env.CGO_ENABLED = "0";
  meta.mainProgram = "nbh-gate";
}
