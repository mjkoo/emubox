## Context

See `proposal.md`. `/data` is the `@data` btrfs subvolume and contains a
separately mounted `@cache`. `player` home is persistent below `/data`, emulator
configuration is asserted before frontend launch, and `modules/saves` is a
restic placeholder. The appliance is often powered off and cloud availability
must never be required for gameplay.

## Goals / Non-Goals

**Goals:**

- Make every save route explicit, migrated before activation, and testable.
- Use conventional btrbk and restic behavior with minimal custom machinery.
- Make protected data default-on and reconstructible exclusions finite.
- Make local snapshot, backup, and maintenance health directly observable.

**Non-Goals:**

- Immutability against compromised root or automated provider-object repair.
- Automated restore drills, source manifests, leak detection, or a parallel job
  result database.
- Backing up ROMs, scraped media, caches, or local snapshot storage.
- Adding a second maintenance host or notifications.

## Decisions

### 1. Typed roots, save routes, and home exclusions are distinct

The backup roots are exactly the snapshot equivalents of `/data/saves`,
`/data/es-de`, `/data/bios`, and
`/data/home/player`. ROMs, scraped media, the data-cache subvolume, and snapshot
storage are outside those roots rather than exclusions. `saveRoutes` and
`bindMappings` separately describe emulator placement.

`homeCacheExclusions` is the one finite exclusion declaration. Every entry must
be a strict normalized descendant of `/data/home/player`. Evaluation rejects
duplicates, `..`, the home root itself, symlink escape or aliasing, and any
equality, ancestor, descendant, or alias overlap with a save route. Nix passes
restic the typed roots plus an exclude file generated only from
`homeCacheExclusions`. Dynamic classification and session leak observation are
rejected as complex and unnecessary for this recovery tier.

### 2. The finite save-route declaration uses conventional placement

The `saves` capability spec owns the complete save-route table and its normative
field definitions. The declaration uses a conventional emulator setting when
the pinned build exposes a stable path setting and a mandatory bind mount at
the conventional application directory otherwise. Keeping that authority in
the capability spec makes the route contract survive archival independently of
this design rationale.

Before any changed setting is written or mount becomes active, a one-time,
idempotent migration handles the old path. Equal files may collapse; differing
files at the same relative path stop migration and name both paths without
overwriting. Migration units order before preparation and the save-mount target.
This applies equally to setting-directed and bind-mounted routes, avoiding an
upgrade window in which old data becomes hidden or split.

### 3. btrbk uses native time-bucket retention

A sibling `@snapshots` subvolume is mounted root-only at `/data/.snapshots`.
btrbk creates hourly read-only snapshots of `@data`, keeping every real point
within the most recent 48 hours plus one representative from each populated
daily bucket in the preceding 14 days. Empty buckets caused by downtime contain
no point and are not violations; one point may satisfy both buckets. A
boot-relative timer resumes normally but does not fabricate missed snapshots.
`@cache` and `@snapshots` are separate nested subvolumes and are not recursively
captured. Exact-count retention is rejected because it conflicts with btrbk's
time-bucket model.

### 4. Each backup owns and reliably cleans a fresh source snapshot

The backup service takes a named read-only snapshot under
`/data/.snapshots/restic/`, mounts it read-only beneath `/run/emubox`, invokes
restic with generated input files, and removes the mount and snapshot in a
finally-style cleanup path for success, failure, and timeout. The same
reconciler runs at boot and at the start of every backup, removing stale
artifacts left by termination or power loss before creating a new source
snapshot. This handles a hard interruption even when the host does not reboot.
A short filesystem lock protects local snapshot creation/removal.
Reading the newest scheduled snapshot was rejected because it can be stale;
reading live paths was rejected because it is not transactionally consistent.

### 5. Restic uses its native repository locks

Backup uses restic's native non-exclusive append lock; `forget`, `prune`, and
`check` use native exclusive locks. There is no external repository mutex or
queue. Weekly maintenance is staggered from four-hour backups. The timeout
algebra is explicit: maintenance's entire sequence, including lock wait, has
maximum `M = 3h`; backup uses `R = 3h15m` for `--retry-lock`, `P = 10m` before
restic, and `E = 4h` after acquiring the lock, so its activation bound is
`B = P + R + E = 7h25m`. Evaluation validates `M < R` and
`B >= P + R + E`; scaled tests preserve both inequalities and the post-lock
budget. Cleanup has a separately available `ExecStopPost` or equivalent final
path and is not charged to `B`.

Maintenance therefore cannot by itself exhaust backup's retry window. Other
lockers may exhaust `R`; that is a visible failed activation. Because `B`
exceeds the four-hour cadence, systemd's same service does not overlap itself
and a timer activation missed while it remains active is not queued. Future
timer activations remain enabled. This is restic's conventional concurrency
model and avoids duplicating its lock and stale-lock semantics.

### 6. Direct restic-to-B2 uses conventional scoped credentials

Non-secret options declare enablement, endpoint, bucket, and optional prefix.
sops supplies the B2 key identifier, application key, and restic password as
root-only files mapped to restic's environment. The key is read/write and
restricted to one private bucket, including deletion needed for lock cleanup,
forget, and prune. Backblaze prior versions are retained for 30 days only as a
last-resort aid. Object Lock and automated historical-object recovery are
rejected because they complicate prune and are outside normal restic recovery.
E12 performs one real-B2 backup and `restic restore --verify` rollout check.

### 7. Service dependencies isolate local operation from cloud state

Local snapshotting depends only on `/data` being mounted as btrfs. An
idempotent `restic-init` oneshot orders after `/data`, backup secrets, and
`network-online`. It first opens the configured repository. Only restic's
precise nonexistent-repository result permits initialization; authentication,
network, corruption, and every other error fail closed. Backup and maintenance
require and order after init, causing later independent timer activations to
retry the gate. Their timers are enabled independently from local snapshots.

Gameplay, display, save preparation and mounts, and local snapshots have no
dependency on network, backup secrets, init, backup, or maintenance. With
off-site backup disabled, no backup unit consumes its secrets. Coupling cloud
readiness into the kiosk or local-history graph was rejected because an outage
must not reduce local appliance functionality.

### 8. Systemd invocation outcomes and journal markers define health

The backup runs 10 minutes after boot and every 4 hours. Weekly maintenance runs
`forget`, `prune`, and `check --read-data-subset=10%`. Services use idle CPU and
I/O priority and bounded runtime. `emubox-status` reads systemd outcomes and
parseable same-invocation journal markers. A successful local marker contains
the canonical read-only snapshot path and creation time. A successful backup
marker contains restic snapshot ID, repository ID, host/tag selector, and
timestamp. A successful maintenance marker contains repository ID, completion
time, and the newest matching protected snapshot ID after all operations; no
matching snapshot fails maintenance.

Status pairs the latest systemd invocation with a marker emitted by that exact
invocation. Missing, malformed, or mismatched markers are unhealthy, and a
later failure supersedes an older success. Optional live repository confirmation
may add a warning but cannot erase the last known outcome. Freshness warnings
are 2 hours for local snapshot, 8 hours for backup, and 14 days for
maintenance/check; never-run also warns. Persisting custom JSON state was
rejected because it creates a second authority.

### 9. Restore remains a conventional operator operation

A root-only wrapper permits repository inspection and restore, including
`restic restore --verify`, with the same repository and secret inputs used by
automation. VM coverage restores known fixture bytes and verifies them. The
runbook documents manual restore, and E12 runs one real-provider restore.
Automated monthly restore-and-compare and embedded manifests are rejected as
disproportionate custom machinery for nice-to-have save backups.

## Risks / Trade-offs

- [Pinned emulator paths, especially ScummVM, vary] -> Verify against each
  pinned build and require setting/mount evidence plus a narrow runtime exemption
  only where deterministic exercise is unavailable.
- [Migration may block gameplay on conflicting data] -> Fail before route
  activation and report both paths rather than risk silent loss.
- [A B2 key on the box can delete repository objects] -> Scope it to one bucket,
  retain 30 days of prior versions, and make no immutability claim.
- [A lock retry window can expire for causes other than bounded maintenance] ->
  Record the activation as failed while leaving future scheduling enabled.
- [A long backup overlaps later four-hour timer elapses] -> Rely on systemd's
  non-overlap for the same service, document that missed activations are not
  queued, and preserve future timer activation.
- [Repository initialization sees an ambiguous error] -> Initialize only after
  restic's precise nonexistent-repository result; fail every other error.
- [A journal marker is absent or belongs to another invocation] -> Mark the
  layer unhealthy rather than falling back to an older success.
- [Power loss bypasses in-process cleanup] -> Reconcile named stale transient
  artifacts at boot and at each backup start before creating a new snapshot.
- [No automated restore drill] -> Exercise verified fixture restore in the VM,
  document manual restore, and perform one real-B2 rollout restore in E12.

## Migration Plan

1. Add the sibling snapshot subvolume without moving `@data`.
2. Implement every row in the authoritative save-route table in the `saves`
   capability spec, including
   ScummVM. Run conflict-safe migration in each row's declared order before
   owned configuration or its mandatory bind mount activates.
3. Add secret placeholders and test credentials; only enabled unresolved backup
   placeholders block installation.
4. When off-site backup is enabled, provision the private bucket, retain prior
   versions for 30 days, create the scoped read/write key, and enable the
   independent init, backup, and maintenance timers. Init first opens an
   existing repository and creates one only on the precise absent result.
5. During E12, run one real-B2 backup and `restic restore --verify` of known data.

Rollback disables the cloud init, backup, and maintenance timers and services.
It keeps every save bind mount, owned path setting, and migrated file active so
the stable `/data/saves` layout remains usable. No rollback step reverse-migrates
or deletes save data. Rollback evidence SHALL prove cloud units are disabled
while every declared save route still resolves to its spec-declared destination and a
post-rollback write survives reboot.
