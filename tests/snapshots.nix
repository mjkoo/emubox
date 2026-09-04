# Evaluation-only guard for the local btrbk snapshot history. The VM test
# exercises btrfs and btrbk at runtime; this keeps the declared topology and
# retention policy from drifting before that expensive check reaches CI.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  host = self.nixosConfigurations.emubox;
  subvolumes = host.config.disko.devices.disk.main.content.partitions.root.content.subvolumes;
  snapshots = subvolumes."@snapshots" or null;
  cache = subvolumes."@cache" or null;
  data = subvolumes."@data" or null;
  snapshotMount = host.config.fileSystems."/data/.snapshots";
  instance = host.config.services.btrbk.instances.local;
  settings = instance.settings;
  service = host.config.systemd.services.btrbk-local.serviceConfig;
  timer = host.config.systemd.timers.btrbk-local.timerConfig;
in
assert lib.assertMsg
  (
    snapshots != null
    && snapshots.mountpoint == "/data/.snapshots"
    && cache != null
    && cache.mountpoint == "/data/cache"
    && data != null
    && data.mountpoint == "/data"
    &&
      lib.unique [
        snapshots.name
        cache.name
        data.name
      ] == [
        "@snapshots"
        "@cache"
        "@data"
      ]
  )
  "tests/snapshots.nix: @snapshots and @cache must be sibling btrfs subvolumes, not paths captured by @data";
assert lib.assertMsg (
  snapshotMount.options == [
    "compress=zstd"
    "noatime"
    "subvol=@snapshots"
  ]
  && service.User == "root"
  && service.Group == "root"
) "tests/snapshots.nix: the snapshot subvolume and btrbk service must be root-only";
assert lib.assertMsg
  (
    instance.onCalendar == "hourly"
    && timer.Persistent == true
    && settings.timestamp_format == "long"
    && settings.snapshot_preserve_min == "48h"
    && settings.snapshot_preserve == "14d"
    && settings.snapshot_dir == "/data/.snapshots"
    && settings.subvolume."/data".snapshot_name == "data"
  )
  "tests/snapshots.nix: btrbk must retain all real points for 48 hours and one populated daily bucket for 14 days";
pkgs.runCommand "emubox-snapshots" { } ''
  touch "$out"
''
