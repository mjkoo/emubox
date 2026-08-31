## 1. Path Model and Save Placement

- [ ] 1.1 Add failing evaluation and unit tests for one declarative protected-path, exclude, save-destination, and bind-mount model, then implement the model and its rendered manifest so the tests reject paths beneath exclusions and bind sources outside `/data/saves`.
- [ ] 1.2 Verify save keys and expected directories against every pinned emulator build, record the evidence beside the model, and add failing `emubox-prepare` tests followed by owned save settings for RetroArch, DuckStation, and PCSX2 until the package check passes.
- [ ] 1.3 Add failing module tests followed by first-boot save directories and Dolphin, PPSSPP, and Azahar bind mounts ordered through a required save-mount target; prove each target resolves beneath `/data/saves` and a forced mount failure prevents the kiosk session from starting.
- [ ] 1.4 Add a conflict-safe one-time migration for files already present at paths a bind mount will cover, with tests proving identical data is accepted, conflicting data stops with both paths named, and no source is overwritten.
- [ ] 1.5 Extend the kiosk VM save assertions to cover every declared setting and mount plus deterministic runtime writes and explicit exemptions, then prove known bytes beneath `/data/saves` survive reboot with `just kiosk-test` in CI.
- [ ] 1.6 Run `just check-all` and `just session-check`, and leave both passing as the task-group evidence for save placement and kiosk ordering.

## 2. Local Snapshot History

- [ ] 2.1 Add failing disk-layout assertions followed by the sibling `@snapshots` subvolume mounted root-only at `/data/.snapshots`, and prove `@cache` and `@snapshots` are separate from the protected `@data` snapshot source.
- [ ] 2.2 Add failing timer and retention tests followed by btrbk configuration for read-only `@data` snapshots, 48 hourly and 14 daily recovery points, serialization, and one boot-relative catch-up activation.
- [ ] 2.3 Extend the disk VM test to create, inspect, and expire local recovery points while proving cache and snapshot contents are not recursively captured; leave `just vm-test` passing in CI.
- [ ] 2.4 Run `just check-all` and leave it passing as the task-group evaluation and formatting evidence.

## 3. Snapshot-Consistent Restic Backup

- [ ] 3.1 Add failing orchestration tests followed by a root-only backup program that creates one fresh read-only snapshot, mounts it at a stable runtime root, captures the save manifest, runs restic from rendered include and exclude inputs, records the restic snapshot ID atomically, and removes only its transient snapshot.
- [ ] 3.2 Add failing service tests followed by independent backup and weekly maintenance units and timers with the declared boot-relative cadence, retention, prune, 10 percent data check, lock serialization, timeouts, idle CPU scheduling, and idle I/O priority.
- [ ] 3.3 Add failing secret and option tests followed by backup enablement, validated B2 endpoint/bucket/prefix options, root-only sops credentials, generated restic environment, test secrets, and install placeholder handling; prove disabled backups consume no backup secrets.
- [ ] 3.4 Add a local-repository VM scenario that mutates a live file after snapshot creation and proves the restic snapshot contains the earlier bytes, every included and unexpected-home fixture, and none of the explicit exclusions.
- [ ] 3.5 Force weekly maintenance to fail in the VM, then prove its persisted failure does not prevent a subsequent backup and that neither command output nor the system closure exposes test credentials.
- [ ] 3.6 Run the project-owned program package checks, `just check-all`, and `just closure-check`, and leave them passing as the task-group evidence.

## 4. Restore Drill, Leak Detection, and Status

- [ ] 4.1 Add failing unit tests followed by the shared atomic result-record implementation for `never-run`, `running`, `succeeded`, and `failed`, including timeout and schedule-derived stale rendering without secret-bearing reasons.
- [ ] 4.2 Add failing restore-comparison tests followed by `emubox-save-drill` and its monthly timer, proving it restores the newest restic snapshot under `/data/.restore`, compares against the captured source manifest, persists success or named differences, and always cleans temporary data.
- [ ] 4.3 Add failing path-classification tests followed by `emubox-leakcheck` at kiosk session teardown, proving expected writes record success, unexpected writes persist their paths, and either outcome allows frontend relaunch.
- [ ] 4.4 Add failing output tests followed by `emubox-status` v1 and the root-only `restic-saves` wrapper, proving all required layers, timestamps, stale or failed hints, and repository IDs render without secrets and the wrapper cannot inject arbitrary global restic options.
- [ ] 4.5 Extend the local-repository VM scenario to prove a successful byte-for-byte drill, a named mismatch failure, persisted status across reboot, leak findings, and wrapper reuse of the automated repository inputs.
- [ ] 4.6 Expose every new project-owned program through the overlay, host, package outputs, and cache roots, then leave native unit checks, `just check-all`, `just session-check`, and the relevant package builds passing.

## 5. Operations and Full Evidence

- [ ] 5.1 Update the install and recovery documentation with private B2 bucket creation, at least 30 days of prior-version retention, bucket-scoped read/write key capabilities, repository initialization, routine restore, and the explicit non-immutability boundary; verify every command uses the declared S3 endpoint form and no real credential.
- [ ] 5.2 Add the account-side acceptance checklist and durable evidence fields for one real-credential VM backup and restore plus recovery of an earlier B2 object version, while keeping the checklist incomplete until the admin performs it.
- [ ] 5.3 Update README capability and development documentation for save locations, local snapshots, service schedules, status interpretation, manual wrapper use, and CI-only VM coverage; verify no committed document cites `.scratch/`.
- [ ] 5.4 Run `just check-all`, build every new project-owned package, run `just session-check` and `just closure-check`, and leave all locally available checks passing with any KVM-only tests explicitly awaiting CI.
- [ ] 5.5 Leave `just vm-test` and `just kiosk-test` passing in CI, with the test output evidencing save persistence, local retention, snapshot-consistent backup, exclusions, maintenance isolation, restore comparison, leak detection, status, and runtime secret modes.
