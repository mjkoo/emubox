## MODIFIED Requirements

### Requirement: Persistence is proven across a reboot
The test SHALL boot the node, record `/etc/machine-id`, write a marker under `/root` and a marker under `/data`, reboot, and assert the `/root` marker is gone, the `/data` marker remains, the machine-id is unchanged and the reboot adds a boot the journal still lists, whose predecessor is readable. It SHALL then cut the node's power without a clean shutdown and assert the node boots again with the root wiped.

The boot count is asserted across the reboot rather than against a literal
total. How many times the test restarts the node is a property of the test, not
of the system: the reconciliation coverage this change adds restarts it too, so
a fixed total of two would have to be revised every time the test gains or
loses a restart. The persistence capability asks only that the machine has
booted at least twice and that the previous boot's entries can be read.

#### Scenario: Two-boot assertion
- **WHEN** the test reboots the node after writing the markers
- **THEN** all four assertions hold

#### Scenario: Power cut
- **WHEN** a marker is written under `/root` and the node is stopped without a clean shutdown, then started
- **THEN** the node reaches multi-user with no filesystem repair prompt and the marker is gone

## ADDED Requirements

### Requirement: Save placement and recovery are proven in the VM
The kiosk VM test, or a sibling built from the same modules, SHALL use a local
restic repository and test credentials to prove save routing and recovery
without Backblaze. It SHALL assert that the implemented route declaration
matches every field of the authoritative finite table, including every declared
setting and mandatory mount,
including ScummVM; exercise each deterministic route or record a specific
exemption; verify migration ordering and conflicts; and prove persistence. It
SHALL also prove that retained local snapshots are read-only and do not
recursively capture the sibling `@cache` and `@snapshots` subvolumes,
snapshot-consistent backup, the finite exclusion list and default inclusion,
failure visibility, transient cleanup, future scheduling, priority settings,
and runtime secret permissions. It SHALL reject lexically malformed typed roots
and home exclusions at evaluation, reject symlink escape and aliasing against
the source snapshot before restic runs, prove the repository initialization
gate is fail-closed, pair health markers to exact invocations, and keep local
operation available during cloud failure.

The VM proves the seams this project builds: the route table, the migration,
the snapshot transaction, and the wiring between them. It SHALL NOT re-prove
restic, btrbk or systemd themselves. Where the logic is pure it is proven by
the helper's own unit tests, which run natively on the administrator's Mac and
report a located failure in seconds rather than one assertion per CI build.

#### Scenario: Save route survives reboot
- **WHEN** the VM writes known bytes through a declared emulator save path and reboots
- **THEN** the bytes remain beneath that emulator's `/data/saves` directory

#### Scenario: Runtime save fixture is unavailable
- **WHEN** a route, including ScummVM, cannot be exercised deterministically
- **THEN** the test asserts its setting or mount and records the reason and condition for removing the exemption

#### Scenario: Upgrade migrates every changed route
- **WHEN** the VM upgrades with files at setting-directed and bind-mounted legacy paths
- **THEN** migration precedes activation and a forced conflict blocks activation without overwriting data

#### Scenario: Backup set honors explicit exclusions
- **WHEN** the VM backs up fixtures in every exclusion and an arbitrary unlisted player-home path
- **THEN** each exclusion is absent and the unlisted file is present

#### Scenario: Path declarations are invalid
- **WHEN** roots or home exclusions contain duplicates, traversal, the home root, or lexical save-route overlap
- **THEN** evaluation fails and no restic inputs are generated

#### Scenario: Filesystem path aliases protected data
- **WHEN** a home exclusion resolves through a symlink ancestor outside player home or onto a save route or another exclusion in the source snapshot
- **THEN** backup fails before invoking restic and reports the invalid declaration

#### Scenario: Backup captures the source snapshot, not the live file
- **WHEN** the VM backs up known fixture bytes and changes the live file while the source snapshot is open
- **THEN** the backed-up bytes are the source snapshot's rather than the later live file's

Restoring those bytes back through the local double would exercise the double's
own copy, not this project. Verified restore is proven where it is real: the
documented manual procedure and the one `restic restore --verify` against B2 in
the E12 rollout checklist.

#### Scenario: Failed backup supersedes prior success
- **WHEN** a successful backup is followed by a forced failure
- **THEN** current status shows failure, the transient source is removed, and the future timer remains enabled

#### Scenario: Interrupted backup artifact is reconciled
- **WHEN** the VM presents a transient source artifact at boot or between two backups without reboot
- **THEN** reconciliation removes it before the next backup creates its source snapshot

#### Scenario: Repository initialization gate is fail-closed
- **WHEN** initialization cannot open its repository
- **THEN** the backup's own activation fails without invoking restic's backup, and status reports that layer unhealthy rather than its previous success

#### Scenario: Health marker is not from the latest invocation
- **WHEN** a successful backup is followed by an invocation of the same unit that runs and fails
- **THEN** status reports that layer unhealthy and does not reuse the earlier success marker

Malformed, mismatched and never-run markers, the lock timeout inequalities
`M < R` and `B >= P + R + E`, and the precise-absence initialization result are
proven by the helper's unit tests and by evaluation-time assertions. The VM
proves only that a marker reaches the journal under the unit's current
invocation and that status reads it there.

#### Scenario: Cloud is unavailable
- **WHEN** initialization or backup cannot reach its repository
- **THEN** gameplay, display, save routes, and local snapshot creation still operate

#### Scenario: Cloud backup is rolled back
- **WHEN** the cloud backup and maintenance units and timers are stopped after migration
- **THEN** all save mappings remain active and a table-routed write survives reboot

Rollback itself is declarative: `/etc/systemd/system` is read-only on the box,
so `systemctl disable` cannot persist a change and turning off-site backup off
means `emubox.backups.enable = false` and a rebuild, which is evaluated rather
than run in a VM. What the VM proves is the runtime half, that taking the cloud
jobs away touches neither the save mounts nor the data beneath them.
