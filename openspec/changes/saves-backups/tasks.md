## 1. Path Model, Migration, and Save Placement

- [x] 1.1 Add evaluation tests and implement separate `saveRoutes`, `bindMappings`, typed backup roots, and finite `homeCacheExclusions`; prove roots are exactly `/data/saves`, the complete `/data/es-de`, `/data/bios`, and `/data/home/player`, and that ROM/media/cache/snapshot storage are outside rather than excluded.
- [x] 1.2 Add negative evaluation fixtures proving exclusions reject duplicates, `..`, home itself, and lexical equality/ancestor/descendant overlap with save routes, while arbitrary unlisted player-home paths remain included.
- [x] 1.3 Verify the authoritative finite save-route table in the `saves` capability spec against every pinned emulator, including ScummVM, then add evaluation and preparation tests proving the implemented declaration exactly matches every table field and add owned settings for its setting-directed rows.
- [ ] 1.4 Add module tests and required bind mounts for remaining routes; prove sources resolve beneath `/data/saves` and a forced mount failure prevents kiosk start.
- [x] 1.5 Add conflict-safe idempotent migration for every changed setting-directed and bind-mounted route; upgrade tests SHALL prove migration completes before settings or mounts activate, equal data is accepted, and conflicts overwrite neither path.
- [ ] 1.6 Extend kiosk VM assertions to cover each route including ScummVM, deterministic writes or explicit fixture exemptions, and reboot persistence; leave `just kiosk-test` passing in CI.
- [ ] 1.7 Add rollback tests proving that turning off-site backup off keeps all save settings and bind mounts active, performs no reverse migration or deletion, and preserves a subsequent routed write across reboot. The declarative half (`emubox.backups.enable = false`) is evaluated; the VM covers the runtime half by stopping the units and timers, since `/etc` is read-only and `systemctl disable` cannot persist.
- [x] 1.8 Leave `just check-all` and `just session-check` passing as the group evidence.

## 2. Local Snapshot History

- [x] 2.1 Add disk-layout assertions and the root-only sibling `@snapshots` subvolume; prove `@cache` and `@snapshots` are separate from the `@data` source.
- [x] 2.2 Add timer and retention tests and btrbk configuration for hourly snapshots, all real points for 48 hours, one representative from each populated daily bucket in the preceding 14 days with overlap, no violation for empty downtime buckets, no fabricated points, and read-only retained points.
- [ ] 2.3 Extend the disk VM test to prove btrbk runs, its retained snapshots are read-only, and `@cache` and `@snapshots` are not recursively captured; leave the time-bucket retention arithmetic to btrbk and the declared policy to 2.2. Leave `just vm-test` passing in CI.
- [x] 2.4 Leave `just check-all` passing as the group evidence.

## 3. Snapshot-Consistent Restic Backup

- [x] 3.1 Add orchestration tests and a root-only backup program that creates and mounts one transient read-only source, invokes restic, and finally cleans it on success, failure, and timeout.
- [ ] 3.2 Add boot and start-of-backup reconciliation tests and service ordering; prove a simulated interruption artifact is removed before a later backup creates a snapshot both after reboot and without reboot.
- [x] 3.3 Add service and evaluation tests encoding `M=3h`, `R=3h15m`, `P=10m`, `E=4h`, and `B=7h25m`; validate `M<R` and `B>=P+R+E` at evaluation, keep final cleanup available outside `B`, and prove same-service non-overlap, missed activation non-queueing, and future scheduling. Restic's own lock waiting is not re-proven in a scaled VM run.
- [x] 3.4 Add dependency-graph tests and run the idempotent restic-init gate as the first step of backup and maintenance, each ordered after `/data`, secrets, and network-online; prove it opens first, initializes only on the precise absent result, fails closed on the job's own activation rather than as a dependency failure that leaves status showing the previous success, and is retried by later independent backup and maintenance timer activations.
- [x] 3.5 Add secret and option tests and implement validated B2 settings, root-only sops inputs, generated restic environment, test secrets, and enabled-only placeholder handling; prove disabled off-site services consume no backup secrets.
- [ ] 3.6 Add a local-repository VM scenario proving snapshot consistency, typed-root inclusion, every home-only exclusion, an arbitrary included unlisted home path, no credential exposure, and pre-restic rejection when a declared exclusion resolves through a symlink ancestor outside player home or aliases a save route or another exclusion.
- [ ] 3.7 Add one VM case proving the init gate is fail-closed (init fails on its own invocation, the backup never reaches one) and one proving a failed backup; prove cloud failure leaves gameplay and local snapshots available, transient cleanup occurs at the next same-boot run, current failure is visible, and a future timer stays enabled. The auth/network/timeout matrix behind `initialize()` stays in the helper's unit tests. Leave project package checks, `just check-all`, and `just closure-check` passing.

## 4. Maintenance, Status, and Restore

- [x] 4.1 Add maintenance tests and implement weekly 14-daily, 8-weekly, 12-monthly retention, prune, and `check --read-data-subset=10%` using native exclusive locks; prove the whole sequence including wait respects `M`, overlap respects `M<R`, and backup retains `E` after lock acquisition.
- [x] 4.2 Add journal-marker tests and emit parseable same-invocation local path/time, backup snapshot/repository/host-tag/time, and maintenance repository/completion/newest-protected-snapshot markers; make missing protected snapshots and missing or malformed success markers fail their unit.
- [x] 4.3 Add status output tests and implement latest-systemd-invocation pairing with its exact marker, 2-hour, 8-hour, and 14-day thresholds, never-run and last-failed warnings, and optional non-authoritative live confirmation; prove malformed, mismatched, and older markers cannot mask a later failure.
- [x] 4.4 Add the root-only restic wrapper with command-policy tests proving inspection and `restore --verify` reuse automation inputs without accepting arbitrary global-option injection, including a negative non-root invocation test.
- [ ] 4.5 Extend the VM scenario with successful backup, forced later failure that actually runs, exact-invocation marker status instead of stale success, cleaned source, and enabled future schedule. The marker matrix stays in the helper's unit tests; verified restore is proven against real B2 in 5.2, not through the local double.
- [x] 4.6 Expose project-owned programs through overlay, host, package outputs, and cache roots; leave native tests, `just check-all`, and relevant builds passing.

## 5. Operations and Full Evidence

- [x] 5.1 Update install and recovery docs with the private dedicated B2 bucket, 30-day prior versions as last-resort aid, scoped read/write key, repository initialization, manual `restic restore --verify`, native lock retry behavior, and explicit non-immutability boundary.
- [x] 5.2 Add the E12 account-side acceptance checklist and durable evidence fields for one normal real-B2 backup and verified restore, without any corruption or historical-object recovery drill.
- [x] 5.3 Update README documentation for save routes, migration, local retention, schedules, status, wrapper use, and VM coverage; verify no committed document cites `.scratch/`.
- [x] 5.4 Leave `just check-all`, all new package builds, `just session-check`, and `just closure-check` passing, with KVM-only checks explicitly awaiting CI.
- [ ] 5.5 Leave `just vm-test` and `just kiosk-test` passing in CI with evidence for migration, ScummVM, read-only non-recursive local snapshots, snapshot-consistent backup, exclusions, fail-closed init, cleanup, status, and secret modes.
