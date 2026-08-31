# Design section 4: ephemeral root, persistent OS state under /persist.
# User data is deliberately outside this mechanism: player's home is on
# /data and is never wiped (design section 9, layer 1).
{
  config,
  lib,
  utils,
  ...
}:
let
  # The partition the root subvolume lives on, as disko declares it
  # (/dev/disk/by-partlabel/disk-main-root: disko's default label for the
  # `root` partition of disk `main`); the same on the box and in the VM.
  rootPartition = config.fileSystems."/".device;
  rootDevice = "${utils.escapeSystemdPath rootPartition}.device";
  persistedDirs = map (d: d.dirPath) config.environment.persistence."/persist".directories;
in
{
  # Every boot starts from a blank root: before sysroot.mount, replace the
  # @root subvolume with a freshly created one. A new subvolume is exactly
  # what a blank snapshot would be, with no install-time snapshot to keep
  # correct. Subvolumes nested under @root (systemd creates /var/lib/machines
  # and /var/lib/portables as subvolumes) go first, deepest first, since
  # btrfs refuses to delete a parent that still has children.
  boot.initrd.systemd.services.rollback-root = {
    description = "Recreate the @root subvolume";
    unitConfig = {
      DefaultDependencies = false;
      # Never wipe a mounted root. The unit is ordered before sysroot.mount,
      # so this is false on the run that matters; it exists so that any
      # future re-queue of the unit while /sysroot is up (see
      # RemainAfterExit below) is a skipped, logged no-op rather than the
      # deletion of the live root. A skipped wipe shows up as surviving
      # markers in the install test.
      ConditionPathIsMountPoint = "!/sysroot";
    };
    # The partition's device unit is what sysroot.mount itself waits for;
    # the fstab generator also hangs it on initrd-root-device.target for the
    # /sysroot entry. Depend on both so the unit can never run before the
    # partition exists.
    requires = [ rootDevice ];
    after = [
      rootDevice
      "initrd-root-device.target"
    ];
    before = [ "sysroot.mount" ];
    # Requiring, not wanting: the root cannot be mounted without the wipe
    # having run.
    requiredBy = [ "sysroot.mount" ];
    wantedBy = [ "initrd.target" ];
    serviceConfig = {
      Type = "oneshot";
      # Stay "active (exited)" for the rest of the initrd. Without this a
      # finished oneshot is inactive, and the switch-root transaction
      # (initrd-nixos-activation has RequiresMountsFor=/sysroot/run, which
      # re-queues a start job on sysroot.mount and, through its Requires=,
      # on this unit) ran the wipe a second time under the mounted root and
      # deleted the live @root; the first CI run of the install test showed
      # exactly that. With RemainAfterExit the second start job is a no-op.
      RemainAfterExit = true;
    };
    script = ''
      set -o pipefail
      mkdir -p /btrfs-top
      mount -t btrfs -o subvol=/ ${rootPartition} /btrfs-top
      if [ -e /btrfs-top/@root ]; then
        # `btrfs subvolume list -o` prints `ID <n> gen <n> top level <n>
        # path <path>` per nested subvolume; field 9 onward is the path.
        # Reverse-sorted so a child is deleted before its parent.
        btrfs subvolume list -o /btrfs-top/@root \
          | cut -d ' ' -f 9- \
          | sort -r \
          | while read -r nested; do
              btrfs subvolume delete "/btrfs-top/$nested"
            done
        btrfs subvolume delete /btrfs-top/@root
      fi
      btrfs subvolume create /btrfs-top/@root
      # The mount lives in the initrd namespace and is discarded at
      # switch-root; a transiently busy unmount must not stop the boot.
      umount -l /btrfs-top || true
    '';
  };

  # impermanence bind-mounts the neededForBoot directories (/var/log,
  # /var/lib/nixos) in the initrd, but its script that creates their
  # /persist counterparts runs in the activation step those mounts are
  # ordered before, so on the very first boot after an install the mounts
  # would fail and the stage-2 mounts would take over while that boot's
  # /var/lib/nixos uid and gid maps landed on the ephemeral root. Create
  # every persisted directory before any of those mounts instead.
  boot.initrd.systemd.services.persist-dirs = {
    description = "Create the persisted directories under /persist";
    unitConfig = {
      DefaultDependencies = false;
      RequiresMountsFor = [ "/sysroot/persist" ];
    };
    after = [ "sysroot.mount" ];
    before = map (d: "${utils.escapeSystemdPath "/sysroot${d}"}.mount") persistedDirs ++ [
      "initrd-nixos-activation.service"
    ];
    # Required, like persist-machine-id: a failure here must stop the boot
    # rather than leave the neededForBoot directories on the ephemeral root.
    requiredBy = [ "initrd-nixos-activation.service" ];
    wantedBy = [ "initrd.target" ];
    serviceConfig = {
      Type = "oneshot";
      # Run once: the switch-root transaction re-queues this unit through
      # the requiredBy above (same mechanism as rollback-root's). The
      # mkdirs are idempotent, so a second run would only be noise.
      RemainAfterExit = true;
    };
    # Created root:root 0755. impermanence mirrors an existing /persist
    # directory's ownership onto the root side, so a persisted directory
    # that needs another owner or mode must be declared with `user`,
    # `group` or `mode` here AND created accordingly; today every entry is a
    # plain root-owned path.
    script = lib.concatMapStringsSep "\n" (d: "mkdir -p /sysroot/persist${d}") persistedDirs;
  };

  # /etc/machine-id is bound to its persisted copy in the initrd, before
  # stage-2 activation, rather than by impermanence's stage-2 unit. On a
  # blank root PID 1 finds no /etc/machine-id, treats the boot as a first
  # boot, writes "uninitialized" to the ephemeral root and overmounts a
  # transient id; impermanence's unit then sees an existing mount, leaves it
  # alone (its own machine-id workaround sits behind that same findmnt
  # check), and the id would change every boot. With the bind in place
  # before PID 1 starts, it reads the persisted id, or on the box's very
  # first boot finds an empty writable file, generates an id and writes it
  # there, which lands on /persist. A service rather than a mount unit
  # because a fresh @root has no /etc to mount onto. impermanence's
  # ConditionFirstBoot override on systemd-machine-id-commit.service (set
  # because /etc/machine-id is in the file list) is what keeps the bind in
  # place afterwards: that unit would otherwise unmount it on every boot.
  boot.initrd.systemd.services.persist-machine-id = {
    description = "Bind /etc/machine-id to /persist before activation";
    unitConfig = {
      DefaultDependencies = false;
      RequiresMountsFor = [ "/sysroot/persist" ];
    };
    after = [ "sysroot.mount" ];
    before = [ "initrd-nixos-activation.service" ];
    # Required, so a failed bind stops the boot instead of silently
    # reproducing the changing id.
    requiredBy = [ "initrd-nixos-activation.service" ];
    wantedBy = [ "initrd.target" ];
    serviceConfig = {
      Type = "oneshot";
      # Run once: re-queued by the switch-root transaction like the other
      # two initrd oneshots; a second run would stack a second bind mount
      # on the same file.
      RemainAfterExit = true;
    };
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
