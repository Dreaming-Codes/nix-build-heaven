{ lib, ... }:
{
  services.nbh.builder.enable = true;
  amazonImage.format = "raw";
  # User-data is nbh SSH material, not a NixOS configuration.
  virtualisation.amazon-init.enable = lib.mkForce false;
  services.amazon-ssm-agent.enable = lib.mkForce false;
  documentation.enable = false;
  system.stateVersion = "26.11";
}
