# The builder AMI: nixpkgs' amazon image plus the builder module, as a raw disk
# for coldsnap. User-data carries TLS material, not a NixOS configuration, so
# amazon-init must not interpret it.
{ config, lib, ... }:
{
  services.nbh.builder.enable = true;
  # Both, so one image serves either client transport while ssh-ng is evaluated.
  # The security group must then open 22 as well as 50051.
  services.nbh.builder.transports = [ "grpc" "ssh-ng" ];
  amazonImage.format = "raw";
  virtualisation.amazon-init.enable = lib.mkForce false;
  services.amazon-ssm-agent.enable = lib.mkForce false;
  services.openssh.enable = lib.mkForce (lib.elem "ssh-ng" config.services.nbh.builder.transports);
  documentation.enable = false;
  system.stateVersion = "26.11";
}
