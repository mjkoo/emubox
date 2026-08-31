## Why

E4 made the emulators usable, so the box can now create family save data, but
that data has neither enforced placement nor tested local and off-site recovery.
Without this change, a disk failure, emulator path regression, corrupt write, or
accidental deletion can permanently lose progress despite the roadmap's central
"nothing save-like can be lost" promise.

## What Changes

- Route every supported emulator's saves, states, memory cards, NAND, and SD
  data to declared paths under `/data/saves`, using owned settings or mandatory
  bind mounts as each emulator supports.
- Add read-only btrfs history for `/data` with 48 hourly and 14 daily recovery
  points.
- Back up a fresh data snapshot to an encrypted restic repository in a private
  Backblaze B2 bucket through its S3-compatible endpoint.
- Separate frequent backup creation from weekly retention, prune, and partial
  data checks, using boot-relative timers and idle resource priority.
- Add a monthly restore-and-compare drill, post-session save leak detection,
  a root-only restic operator wrapper, and `emubox-status` backup reporting.
- Add B2 and repository credentials to the existing sops secret set and make
  placeholder credentials block installation.
- Extend VM coverage to prove save placement and persistence, snapshot-backed
  backup and restore, backup-set completeness, failure reporting, and service
  hardening against a local restic repository.
- Document the standard B2 setup: a private dedicated bucket, retained prior
  file versions, and a bucket-scoped read/write key. The repository is not
  claimed to be immutable against compromise of the box; append-only off-box
  maintenance is outside this change.

## Capabilities

### New Capabilities

- `saves`: Declared emulator save placement, mandatory bind mounts, persistent
  fallback coverage, and leak detection.
- `backups`: Local btrfs history, snapshot-consistent encrypted off-site
  backups, retention and integrity checks, restore drills, and operator status.

### Modified Capabilities

- `secrets`: Add the B2 application key, key identifier, and restic repository
  password to the required encrypted secret set and install placeholder guard.
- `vm-test`: Prove save routing and the complete local backup/restore path in
  the NixOS VM without requiring real cloud credentials.

## Impact

The change primarily affects `modules/saves`, emulator-owned values passed to
`emubox-prepare`, kiosk session teardown, persistence state, sops declarations,
the install guard and runbook, project-owned operator programs, and the kiosk
VM test. It adds btrbk alongside the existing restic package and requires a B2
account-side bucket and scoped application key before hardware installation.
