{ rustPlatform }:
rustPlatform.buildRustPackage {
  pname = "nbh-gate";
  version = "0.2.0";
  src = ../gate;
  cargoLock.lockFile = ../gate/Cargo.lock;
  meta.mainProgram = "nbh-gate";
}
