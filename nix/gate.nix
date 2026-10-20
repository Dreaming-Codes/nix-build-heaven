{ buildGoModule }:
buildGoModule {
  pname = "nbh-gate";
  version = "0.1.0";
  src = ../gate;
  vendorHash = "sha256-7f1ak6fR7iZ+sBTsxsMT2DJp1sBcjJnZ7Nz8QNo8QOQ=";
  subPackages = [ "cmd/nbh-gate" ];
  env.CGO_ENABLED = "0";
  meta.mainProgram = "nbh-gate";
}
