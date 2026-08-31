# Per-host facts every module may read. Declared here so the software stack
# evaluates on its own (VM test, a second host); values are set per host.
{ lib, ... }:
{
  options.emubox.facts = {
    binaryCachePublicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Public key of the `emubox` Cachix cache (`emubox.cachix.org-1:...`),
        which holds the store paths cache.nixos.org never has (the unfree
        emulator cores and what pkgs/ builds). Null until the cache exists;
        the substituter is only configured once it is set.
      '';
    };
    disk = lib.mkOption {
      type = lib.types.str;
      default = "/dev/disk/by-diskseq/1";
      description = "The single M.2 SSD, as seen by disko / nixos-anywhere.";
    };
    controllerPorts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "ID_PATH of USB-A ports 1..4, in player order. Empty = no slot symlinks.";
    };
    hdmiOutput = lib.mkOption {
      type = lib.types.str;
      default = "HDMI-A-1";
      description = "DRM connector the TV is attached to.";
    };
  };
}
