# The physical Beelink EQ14. Everything hardware-bound lives here or in the
# modules this file enables; the software stack is in ../../modules.
{ inputs, ... }:
{
  imports = [
    "${inputs.nixos-hardware}/common/cpu/intel/alder-lake"
    inputs.nixos-hardware.nixosModules.common-pc-ssd
    ./facts.nix
    ./disko.nix
  ];

  networking.hostName = "emubox";
  nixpkgs.hostPlatform = "x86_64-linux";

  # Never change after the first install.
  system.stateVersion = "26.05";
}
