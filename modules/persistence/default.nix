# Design section 4: ephemeral root, persistent OS state under /persist.
# User data is deliberately outside this mechanism: player's home is on
# /data and is never wiped (design section 9, layer 1).
{ lib, ... }:
let
  # disko labels the partition `disk-<disk>-<partition>`; the same on the
  # box and in the VM test.
  rootPartition = "/dev/disk/by-partlabel/disk-main-root";
in
{
  # Every boot starts from a blank root: before sysroot.mount, replace the
  # @root subvolume with a freshly created one. A new subvolume is exactly
  # what a blank snapshot would be, with no install-time snapshot to keep
  # correct. Subvolumes nested under @root (systemd creates /var/lib/machines
  # and /var/lib/portables as subvolumes) go first, since btrfs refuses to
  # delete a parent that still has children.
  boot.initrd.systemd.services.rollback-root = {
    description = "Recreate the @root subvolume";
    unitConfig.DefaultDependencies = "no";
    # initrd-root-device.target is where the fstab generator hangs the root
    # partition's device unit, so the partition is present by then.
    after = [ "initrd-root-device.target" ];
    before = [ "sysroot.mount" ];
    # Requiring, not wanting: the root cannot be mounted without the wipe
    # having run.
    requiredBy = [ "sysroot.mount" ];
    wantedBy = [ "initrd.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /btrfs-top
      mount -t btrfs -o subvol=/ ${rootPartition} /btrfs-top
      if [ -e /btrfs-top/@root ]; then
        btrfs subvolume list -o /btrfs-top/@root \
          | cut -d ' ' -f 9- \
          | while read -r nested; do
              btrfs subvolume delete "/btrfs-top/$nested"
            done
        btrfs subvolume delete /btrfs-top/@root
      fi
      btrfs subvolume create /btrfs-top/@root
      umount /btrfs-top
    '';
  };

  # /etc/machine-id is bound to its persisted copy in the initrd, before
  # stage-2 activation, rather than by impermanence's stage-2 unit. On a
  # blank root PID 1 finds no /etc/machine-id, treats the boot as a first
  # boot, writes "uninitialized" to the ephemeral root and overmounts a
  # transient id; impermanence's unit then sees an existing mount, leaves it
  # alone, and the id would change every boot. With the bind in place before
  # PID 1 starts, it reads the persisted id, or initialises the (empty)
  # persisted file in place on the very first boot. A service rather than a
  # mount unit because a fresh @root has no /etc to mount onto.
  boot.initrd.systemd.services.persist-machine-id = {
    description = "Bind /etc/machine-id to /persist before activation";
    unitConfig = {
      DefaultDependencies = "no";
      RequiresMountsFor = [ "/sysroot/persist" ];
    };
    after = [ "sysroot.mount" ];
    before = [ "initrd-nixos-activation.service" ];
    wantedBy = [ "initrd.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /sysroot/persist/etc /sysroot/etc
      [ -e /sysroot/persist/etc/machine-id ] || touch /sysroot/persist/etc/machine-id
      [ -e /sysroot/etc/machine-id ] || touch /sysroot/etc/machine-id
      mount --bind /sysroot/persist/etc/machine-id /sysroot/etc/machine-id
    '';
  };

  # The persisted list. Later changes append here (cloudflared state, restic
  # cache) rather than declare their own.
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/lib/nixos"
      "/var/lib/systemd"
      "/var/lib/bluetooth"
      "/var/lib/NetworkManager"
      "/var/log"
      "/var/lib/emubox"
      # TODO(design 12): cloudflared state, restic cache.
    ];
    files = [
      # Kept in the list so it is declared with the rest; the initrd unit
      # above does the binding and impermanence's unit finds it mounted.
      "/etc/machine-id"
      # The only host key: services.openssh.hostKeys (modules/remote) is
      # ed25519 only, and it is the sops decryption key.
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
    ];
  };

  # Deliberately not persisted: /tmp, /root, and the mode flag on /run.
  boot.tmp.cleanOnBoot = lib.mkDefault true;
}
