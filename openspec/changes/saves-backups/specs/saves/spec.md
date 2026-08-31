## Purpose

Keeps every emulator-created save, state, memory card, and mutable console
storage on declared persistent paths and detects new writes outside them.

## ADDED Requirements

### Requirement: Every emulator writes save data to its declared save tree
Every supported emulator SHALL place its save-like data beneath its own
directory in `/data/saves`: saves and states for RetroArch; GameCube memory
cards, Wii mutable data, and states for Dolphin; memory cards and states for
DuckStation and PCSX2; savedata, states, and state metadata for PPSSPP; and NAND
and SD-card data for Azahar. A RetroArch core, including melonDS, SHALL inherit
RetroArch's declared save and state paths. The placement SHALL be established
before the kiosk session starts and SHALL apply on an empty first boot without
an emulator setup screen.

#### Scenario: First boot has writable save destinations
- **WHEN** the box starts with an empty `/data`
- **THEN** every declared emulator save destination exists beneath `/data/saves` and is writable by `player` before the kiosk session starts

#### Scenario: Emulator writes a save
- **WHEN** a supported emulator writes any declared save-like file
- **THEN** the file resolves beneath that emulator's directory in `/data/saves`

#### Scenario: RetroArch core writes a save
- **WHEN** any configured RetroArch core writes a save or state
- **THEN** it resolves beneath `/data/saves/retroarch` without a core-specific setup step

### Requirement: Required save mounts fail before gameplay
Where an emulator cannot direct a save-like directory to `/data/saves` through
a supported setting, its expected directory SHALL be a mandatory mount backed
by the declared `/data/saves` destination. The kiosk session SHALL NOT start if
a required save mount is absent or resolves anywhere else, so gameplay cannot
silently write to an unprotected fallback path.

#### Scenario: Required mount is present
- **WHEN** the kiosk session is about to start
- **THEN** every required emulator save mount is active and its backing path resolves beneath `/data/saves`

#### Scenario: Required mount cannot be established
- **WHEN** a required emulator save mount fails during boot
- **THEN** the kiosk session does not start and the failed mount and destination are reported in the journal

### Requirement: Save data survives reboot and emulator path drift
Files beneath `/data/saves` and files written anywhere beneath the persistent
`player` home SHALL survive a reboot. The complete `player` home, except for
explicit reconstructible caches, SHALL belong to the off-site backup set, so an
emulator path regression is a reported organization defect rather than an
unprotected save.

#### Scenario: Declared save survives reboot
- **WHEN** an emulator writes known bytes beneath `/data/saves` and the box reboots
- **THEN** the same file and bytes are present after reboot

#### Scenario: Save-like file escapes its declared path
- **WHEN** an emulator writes a new save-like file elsewhere beneath the `player` home
- **THEN** the file survives reboot and is included in the next off-site backup unless it is inside an explicitly declared reconstructible cache

### Requirement: Session teardown reports unexpected player-home writes
After each frontend session, the system SHALL compare writes beneath the
`player` home with the declared save, configuration, and reconstructible-cache
paths. It SHALL persist the paths and time of the latest unexpected-write
result for operator inspection. Findings SHALL NOT prevent the frontend from
relaunching because the files remain persistent and protected by the backup
set.

#### Scenario: Unexpected write is found
- **WHEN** a frontend session ends after creating a file outside every declared save, configuration, and cache path
- **THEN** the path is recorded as an unexpected write and the frontend relaunch continues

#### Scenario: Session writes only declared paths
- **WHEN** a frontend session ends after writing only declared save, configuration, and cache paths
- **THEN** the persisted result records that no unexpected writes were found

