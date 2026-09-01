## Why

E4 made the emulators usable, so the box can now create family save data, but
that data has neither enforced placement nor tested local and off-site recovery.
Without this change, disk failure, emulator path regression, corrupt writes, or
accidental deletion can permanently lose progress.

## What Changes

- Route every supported emulator's save-like data to declared paths under
  `/data/saves`, including ScummVM's save directory.
- Migrate every changed setting-directed or bind-mounted route before the new
  setting or mount activates, stopping safely on conflicts.
- Add read-only btrfs history using native hourly and daily retention buckets.
- Back up a fresh data snapshot to encrypted restic in a private Backblaze B2
  bucket, using restic's native locks and conventional maintenance.
- Back up four typed roots: saves, the complete ES-DE state directory, BIOS, and the complete
  persistent `player` home. Generate exclusions only for a finite declaration
  of reconstructible caches strictly below `player` home.
- Initialize or open the restic repository through an idempotent network-only
  gate, while keeping gameplay and local snapshots independent of cloud state.
- Add a root-only restic operator wrapper and `emubox-status` reporting that
  pairs systemd invocation outcomes with parseable same-invocation journal
  markers for exact recovery points.
- Add B2 and repository credentials to sops and block installation on enabled
  placeholder credentials.
- Extend VM coverage for routing, migration, snapshot backup, verified restore,
  failure reporting, transient cleanup, and scheduling.
- Document a private dedicated B2 bucket, 30 days of prior file versions, and a
  bucket-scoped read/write key without claiming immutability.

## Capabilities

### New Capabilities

- `saves`: Declared emulator save placement, conflict-safe migration, mandatory
  bind mounts, and persistent fallback coverage.
- `backups`: Local btrfs history, snapshot-consistent encrypted off-site
  backups, retention and integrity checks, operator restore, and status.

### Modified Capabilities

- `secrets`: Add B2 and restic credentials and their install placeholder guard.
- `vm-test`: Prove save routing, migration, and local backup/restore without
  real cloud credentials.
- `install`: Make disk-swap recovery match the four protected backup roots and
  reconstruct excluded ROM, media, cache, and local-history data separately.

## Impact

The change affects `modules/saves`, emulator-owned preparation values,
persistence state, sops declarations, the install guard and runbook,
project-owned operator programs, and kiosk and disk VM tests. It adds btrbk and
requires a B2 bucket and scoped application key only when off-site backup is
enabled; cloud failure never blocks gameplay or local history.
