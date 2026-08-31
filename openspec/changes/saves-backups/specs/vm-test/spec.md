## ADDED Requirements

### Requirement: Save placement and recovery are proven in the VM
The kiosk VM test, or a sibling VM built from the same modules, SHALL use a
local restic repository and non-secret test credentials to prove the `saves`
and `backups` capabilities without contacting Backblaze. It SHALL assert every
declared save setting and mandatory mount resolves beneath `/data/saves`, write
known save bytes through each independently configured path that has a
deterministic headless fixture, reboot and verify persistence, and record an
explicit reason for any runtime path that cannot be exercised in the VM. It
SHALL also prove local snapshot creation and retention, backup from one fresh
snapshot, included and excluded path coverage, restore byte equality, separate
maintenance failure, persistent result reporting, timer and priority settings,
and runtime secret permissions.

#### Scenario: Save route survives reboot
- **WHEN** the VM writes known bytes through a declared emulator save path and reboots
- **THEN** the bytes remain and the resolved file is beneath that emulator's `/data/saves` directory

#### Scenario: Runtime save fixture is unavailable
- **WHEN** an independently configured emulator save path cannot be exercised deterministically without hardware or redistributable game content
- **THEN** the test still asserts its owned setting or mount and records why runtime write evidence is absent and what would remove the exemption

#### Scenario: Backup-set regression
- **WHEN** the VM creates known files in every included area, every excluded area, and an unexpected location beneath the `player` home, then runs a backup
- **THEN** the restic snapshot contains every included and unexpected-home file and contains none of the explicitly excluded files

#### Scenario: Snapshot-consistent restore
- **WHEN** the VM starts a backup from a fresh local snapshot, changes the live source, and runs the restore drill
- **THEN** the restored bytes match the captured snapshot rather than the later live file and the drill records success

#### Scenario: Maintenance failure does not block backup
- **WHEN** the VM forces the maintenance job to fail
- **THEN** status records the maintenance failure and a subsequent backup creation succeeds independently

