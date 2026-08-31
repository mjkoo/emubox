## Context

See `proposal.md` for motivation. `/data` is the `@data` btrfs subvolume and
already contains a separately mounted `@cache` subvolume at `/data/cache`.
`player`'s complete home is below `/data`, while emulator configuration is
asserted by `emubox-prepare` before each frontend launch. `modules/saves` is
currently a restic placeholder and the session has an explicit leak-check hook.

The appliance is often powered off, has one internal disk, and must never make
cloud availability a prerequisite for gameplay. The flake's pinned packages and
NixOS options are authoritative during implementation. Account provisioning is
an explicit pre-install chore, but operation after installation is declarative
and unattended.

## Goals / Non-Goals

**Goals:**

- Make each save route explicit, idempotent, and testable before gameplay.
- Keep local recovery, cloud backup, maintenance, verification, and reporting
  independently observable.
- Use one definition of protected and reconstructible paths across services,
  tests, leak detection, and operator tools.
- Fail before gameplay when an essential save bind mount is absent, while
  allowing cloud failures and leak findings to leave the kiosk usable.

**Non-Goals:**

- Protect against physical loss with local snapshots or against compromised
  root credentials with B2 version history.
- Back up ROMs, scraped media, caches, or the local snapshot tree.
- Add a second maintenance host, notifications, controller behavior, or the E12
  hardware drills.
- Guarantee a runtime save operation for an emulator that lacks a deterministic
  headless fixture; such paths still require configuration or mount evidence.

## Decisions

### 1. One declarative path model drives every consumer

`modules/saves` defines an internal attrset for each protected path: live path,
snapshot-relative path, role (`save`, `frontend`, `home`, or `bios`), and any
excludes. It also defines emulator save destinations and bind-mount mappings.
Nix renders the model as root-owned JSON for project tools and as the restic
files/exclude inputs. Evaluation assertions reject a protected path nested
under an excluded path or a bind target outside `/data/saves`.

This avoids separate hand-maintained path lists drifting between restic,
restore comparison, leak detection, and tests. The alternative was to use each
tool's native configuration independently, which makes the backup-set coverage
claim impossible to prove from one source of truth.

### 2. Prefer owned emulator settings; use fail-closed bind mounts otherwise

`emubox-prepare` gains save-location keys for RetroArch, DuckStation, and PCSX2.
Dolphin, PPSSPP, and Azahar use bind mounts from the paths they expect beneath
the persistent home to corresponding directories under `/data/saves`. melonDS
inherits RetroArch's paths. Implementation first verifies exact keys and paths
against the pinned emulator versions and records source evidence beside each
mapping.

Mount sources and targets are created before local filesystems. Mount units are
required by a save-mount target, and the kiosk session orders after and requires
that target. A failed mount therefore reaches the existing recoverable greeter
state rather than allowing a game to write through an empty mountpoint. A
symlink-only design was rejected because PPSSPP is known not to treat symlinked
memstick paths reliably and a missing link does not provide the same ordering
or failure semantics.

### 3. Snapshot storage is a sibling subvolume

Disk layout gains an `@snapshots` subvolume mounted root-only at
`/data/.snapshots`. btrbk snapshots `@data` into it. Because `@cache` and
`@snapshots` are nested mounts backed by separate subvolumes, neither cache
contents nor the snapshot tree is recursively captured in an `@data` snapshot.
btrbk retains 48 hourly and 14 daily snapshots through an hourly monotonic
systemd timer. `Persistent=true` causes one catch-up activation, not a burst for
every missed interval.

Putting snapshots inside `@data` was rejected because it invites recursion and
ambiguous retention. Putting them under `/persist` would mix high-volume family
history with small OS state and still would not protect against disk loss.

### 4. Backup orchestration creates a dedicated fresh snapshot

The backup service takes a named read-only btrfs snapshot under
`/data/.snapshots/restic/`, bind-mounts it read-only at a stable root under
`/run/emubox`, writes a content manifest for the protected save tree, invokes
restic with rendered include and exclude files relative to that stable root,
and removes only that transient snapshot after restic has recorded its snapshot
ID and source manifest. A lock prevents overlap with local snapshot retention,
maintenance, and restore drills.

Using the newest scheduled btrbk snapshot was rejected because it may predate
the backup by almost an hour. Reading live paths was rejected because files
from one emulator transaction could be captured at different moments.

### 5. Use standard direct restic-to-B2 credentials

The host declares backup enablement, the S3 endpoint, bucket name, and optional
repository prefix as non-secret options. sops supplies the B2 key identifier,
application key, and restic password as root-only files. A generated root-only
environment file maps them to `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`RESTIC_REPOSITORY`, and `RESTIC_PASSWORD_FILE`; service logs never print it.
The repository URL has the form `s3:https://<endpoint>/<bucket>/<prefix>`.

The application key is restricted to the dedicated private bucket and has
read/write access, including deletion. That is the least privilege compatible
with restic lock cleanup, `forget`, and `prune`. Backblaze prior file versions
are retained for at least 30 days as a recovery aid and the runbook proves
version recovery before rollout. Object Lock is not required: a fixed lock does
not renew protection for old deduplicated packs referenced by newer snapshots,
and locked objects can cause prune to fail.

Two alternatives were rejected. A no-delete host key cannot perform routine
restic maintenance. A truly append-only host plus a privileged off-box
maintenance job provides a stronger compromise boundary, but introduces a
second machine, scheduler, and secret lifecycle outside this appliance.

### 6. Separate creation, maintenance, and verification schedules

The backup unit runs 10 minutes after boot and every 4 hours thereafter.
Weekly maintenance runs `forget` with daily, weekly, and monthly retention,
then prune, then `check --read-data-subset=10%`. The monthly drill restores the
newest restic snapshot to a directory created under `/data/.restore`, compares
the save subtree against the stored source manifest, records the result, and
removes the restore directory. Temporary restore data lives on `/data` because
the root filesystem is deliberately small and ephemeral.

All three services use idle CPU scheduling and idle I/O priority, have bounded
runtime, persist concise result records beneath `/var/lib/emubox`, and do not
order the kiosk after cloud availability. Splitting maintenance from backup
creation prevents a slow check or prune from delaying the next recovery point.
Automatic prune after every backup was rejected for the same reason and because
it expands every routine backup's destructive credential exposure window.

### 7. Result vocabulary is shared and deliberately small

Every scheduled layer stores an atomic JSON result with the same state field:

| State | Meaning | Status treatment |
|---|---|---|
| `never-run` | No result record exists | warning |
| `succeeded` | The last completed invocation met its checks | success until stale |
| `failed` | The last completed invocation failed | warning with unit and journal hint |
| `running` | A persisted start record has no completion yet | warning if older than the unit timeout |

Each record also carries start and completion times, the relevant snapshot or
repository ID, and a short non-secret reason. `emubox-status` derives staleness
from the layer's schedule rather than adding another stored state. Leak-check
records use the same states plus a finding count and paths.

### 8. Project tools are small packaged programs

Save drill, leak check, status, and the root-only restic wrapper are packaged
like `emubox-prepare`, using Python where structured manifests and comparison
benefit from it and shell only for thin system command orchestration. Unit tests
cover manifest validation, classification, atomic result writes, stale-state
rendering, and byte comparison. The wrapper permits inspection and restore
subcommands, refuses arbitrary restic global options before the subcommand, and
executes with the same generated environment and path definition as services.

Duplicating substantial JSON and error handling in generated shell scripts was
rejected because those paths need native macOS unit tests as well as build-time
shellcheck.

## Risks / Trade-offs

- [Pinned emulator paths differ from the roadmap's draft names] -> Verify every
  key and directory against the exact packaged version before adding it; record
  an explicit VM runtime exemption where a real write cannot be generated.
- [A required bind mount failure prevents family gameplay] -> This is
  intentional fail-closed behavior; the existing SDDM greeter and journal are
  the recovery surface, and the mount error names the failed path.
- [The box's B2 key can delete repository objects] -> Scope it to one bucket,
  retain provider-side prior versions for 30 days, test recovery, and avoid an
  immutability claim. A separate append-only architecture remains a future
  change if the threat model expands.
- [B2 historical-version recovery is not a native restic workflow] -> Keep the
  procedure operator-run, validate it before rollout, and make ordinary restore
  drills use normal restic snapshots.
- [Snapshot and backup jobs consume disk or affect gameplay] -> Bound local and
  cloud retention, exclude reconstructible bulk data, apply idle priorities and
  timeouts, serialize repository mutation, and surface stale or failed state.
- [Monthly comparison races with live changes] -> Compare restored bytes with
  the manifest captured from the immutable backup source snapshot, not with the
  current live tree.

## Migration Plan

1. Add the sibling snapshot subvolume and mount. Existing installations create
   it declaratively without moving `@data`.
2. Create save destinations and activate verified mounts before enabling the
   corresponding owned emulator paths.
3. Add encrypted secret placeholders and test values. Install remains blocked
   until enabled production backup placeholders are replaced.
4. Provision the private B2 bucket, retain prior versions for at least 30 days,
   create the bucket-scoped read/write key, initialize the repository, and run
   the documented VM backup, restore, and version-recovery gate.
5. Enable timers only after repository initialization succeeds. Existing files
   in persistent emulator paths are copied once to their declared destination
   before a mount covers the old path; conflicts stop migration and name both
   paths rather than overwriting either.

Rollback disables the timers and save-mount target before removing mounts.
Because all migrated files remain under `/data`, rolling back the NixOS
generation does not delete them. The admin can restore the previous path from
the declared destination if an older generation requires it.
