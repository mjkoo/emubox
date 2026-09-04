# One disk, btrfs, subvolume per lifecycle (design section 3).
#   @root    /            wiped every boot (persistence module)
#   @nix     /nix
#   @persist /persist     OS state that must survive
#   @data    /data        the family's stuff, snapshotted, backed up
#   @cache   /data/cache  reproducible caches, survive reboot, never backed up
#   @snapshots /data/.snapshots root-only local recovery history of @data
{ config, ... }:
let
  btrfsOpts = [
    "compress=zstd"
    "noatime"
  ];
in
{
  disko.devices.disk.main = {
    type = "disk";
    device = config.emubox.facts.disk;
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          priority = 1;
          name = "ESP";
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [ "-f" ];
            subvolumes = {
              "@root" = {
                mountpoint = "/";
                mountOptions = btrfsOpts;
              };
              "@nix" = {
                mountpoint = "/nix";
                mountOptions = btrfsOpts;
              };
              "@persist" = {
                mountpoint = "/persist";
                mountOptions = btrfsOpts;
              };
              "@data" = {
                mountpoint = "/data";
                mountOptions = btrfsOpts;
              };
              "@cache" = {
                mountpoint = "/data/cache";
                mountOptions = btrfsOpts;
              };
              "@snapshots" = {
                mountpoint = "/data/.snapshots";
                mountOptions = btrfsOpts;
              };
            };
          };
        };
      };
    };
  };

  # Needed before the persistence bind mounts and sops decryption run.
  fileSystems."/persist".neededForBoot = true;
  fileSystems."/data".neededForBoot = true;
}
