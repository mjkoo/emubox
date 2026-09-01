## ADDED Requirements

### Requirement: Save placement and recovery are proven in the VM
The kiosk VM test, or a sibling built from the same modules, SHALL use a local
restic repository and test credentials to prove save routing and recovery
without Backblaze. It SHALL assert that the implemented route declaration
matches every field of the authoritative finite table, including every declared
setting and mandatory mount,
including ScummVM; exercise each deterministic route or record a specific
exemption; verify migration ordering and conflicts; and prove persistence. It
SHALL also prove native snapshot retention windows, snapshot-consistent backup,
the finite exclusion list and default inclusion, verified fixture restore,
failure visibility, transient cleanup, future scheduling, priority settings,
and runtime secret permissions. It SHALL reject malformed typed roots and home
exclusions, prove fail-closed idempotent repository initialization and later
timer retry, preserve timeout inequalities in scaled timing tests, pair health
markers to exact invocations, and keep local operation available during cloud
failure.

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
- **WHEN** roots or home exclusions contain duplicates, traversal, escape, aliases, or save-route overlap
- **THEN** evaluation fails and no restic inputs are generated

#### Scenario: Snapshot-consistent restore is verified
- **WHEN** the VM backs up known fixture bytes, changes the live file, and restores with verification
- **THEN** restored bytes match the source snapshot rather than the later live file

#### Scenario: Failed backup supersedes prior success
- **WHEN** a successful backup is followed by a forced failure
- **THEN** current status shows failure, the transient source is removed, and the future timer remains enabled

#### Scenario: Interrupted backup artifact is reconciled
- **WHEN** the VM presents a transient source artifact at boot or between two backups without reboot
- **THEN** reconciliation removes it before the next backup creates its source snapshot

#### Scenario: Maintenance overlaps a backup activation
- **WHEN** bounded weekly maintenance holds its native lock as a backup activation begins
- **THEN** the backup retry window outlasts maintenance and that backup proceeds after release

#### Scenario: Repository initialization retries safely
- **WHEN** initialization first sees a non-absence failure and a later timer activation can open the repository
- **THEN** the first activation fails without initialization and the later activation proceeds without manual intervention

#### Scenario: Scaled timeout model is exercised
- **WHEN** VM timing constants are scaled down for an overlap test
- **THEN** maintenance remains shorter than retry-lock and the full post-lock backup budget remains available

#### Scenario: Health marker is not from the latest invocation
- **WHEN** a successful marker is followed by a failed invocation or a malformed or mismatched marker
- **THEN** status reports the latest layer unhealthy and does not reuse the older success

#### Scenario: Cloud is unavailable
- **WHEN** initialization or backup cannot reach its repository
- **THEN** gameplay, display, save routes, and local snapshot creation still operate

#### Scenario: Cloud backup is rolled back
- **WHEN** cloud init, backup, and maintenance units are disabled after migration
- **THEN** all save mappings remain active and a table-routed write survives reboot
