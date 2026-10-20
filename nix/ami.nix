# The builder AMI: nixpkgs' amazon image plus the builder module, as a raw disk
# for coldsnap. User-data carries SSH material, not a NixOS configuration, so
# amazon-init must not interpret it.
{ lib, ... }:
{
  services.nbh.builder.enable = true;
  amazonImage.format = "raw";
  virtualisation.amazon-init.enable = lib.mkForce false;
  services.amazon-ssm-agent.enable = lib.mkForce false;
  documentation.enable = false;
  system.stateVersion = "26.11";
}
