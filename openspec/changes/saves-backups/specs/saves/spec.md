## Purpose

Keeps every emulator-created save, state, memory card, and mutable console
storage on declared persistent paths while retaining safe fallback coverage.

## ADDED Requirements

### Authoritative save-route definitions

The following table is the complete, authoritative save-route declaration.
`$HOME` means `/data/home/player`. A semicolon separates independently migrated
paths. An `owned` setting is a configuration key managed by EmuBox. A
`mandatory bind mount` is a mount that must succeed before kiosk start. Each
row's preparation and migration steps run in the stated order.

| Store | Legacy path(s) | Destination | Route mechanism | Preparation and migration order | Required evidence or exemption |
|---|---|---|---|---|---|
| RetroArch saves | `$HOME/.config/retroarch/saves` | `/data/saves/retroarch/saves` | owned `retroarch.cfg` key `savefile_directory` | create destination, migrate legacy tree, then write key | parsed owned-key assertion and deterministic core save write |
| RetroArch states | `$HOME/.config/retroarch/states` | `/data/saves/retroarch/states` | owned `retroarch.cfg` key `savestate_directory` | create destination, migrate legacy tree, then write key | parsed owned-key assertion and deterministic state write |
| Dolphin memory cards | `$HOME/.local/share/dolphin-emu/GC` | `/data/saves/dolphin/GC` | mandatory bind mount | create destination, migrate covered legacy tree, then mount | mount-source assertion and deterministic card fixture |
| Dolphin Wii data | `$HOME/.local/share/dolphin-emu/Wii` | `/data/saves/dolphin/Wii` | mandatory bind mount | create destination, migrate covered legacy tree, then mount | mount-source assertion and deterministic Wii fixture or fixture exemption naming the unavailable title |
| Dolphin states | `$HOME/.local/share/dolphin-emu/StateSaves` | `/data/saves/dolphin/StateSaves` | mandatory bind mount | create destination, migrate covered legacy tree, then mount | mount-source assertion and deterministic state write |
| DuckStation memory cards | `$HOME/.local/share/duckstation/memcards` | `/data/saves/duckstation/memcards` | mandatory bind mount | create destination, migrate covered legacy tree, then mount | mount-source assertion and deterministic card fixture |
| DuckStation states | `$HOME/.local/share/duckstation/savestates` | `/data/saves/duckstation/savestates` | mandatory bind mount | create destination, migrate covered legacy tree, then mount | mount-source assertion and deterministic state write |
| PCSX2 memory cards | `$HOME/.config/PCSX2/memcards` | `/data/saves/pcsx2/memcards` | mandatory bind mount | create destination, migrate covered legacy tree, then mount | mount-source assertion and deterministic card fixture |
| PCSX2 states | `$HOME/.config/PCSX2/sstates` | `/data/saves/pcsx2/sstates` | mandatory bind mount | create destination, migrate covered legacy tree, then mount | mount-source assertion and deterministic state write |
| PPSSPP savedata | `$HOME/.config/ppsspp/PSP/SAVEDATA` | `/data/saves/ppsspp/SAVEDATA` | mandatory bind mount | create destination, migrate covered legacy tree, then mount | mount-source assertion and deterministic savedata fixture |
| PPSSPP states and metadata | `$HOME/.config/ppsspp/PSP/PPSSPP_STATE` | `/data/saves/ppsspp/PPSSPP_STATE` | mandatory bind mount | create destination, migrate covered legacy tree, then mount | mount-source assertion and deterministic state plus metadata fixture |
| Azahar NAND | `$HOME/.local/share/azahar-emu/nand` | `/data/saves/azahar/nand` | mandatory bind mount | create destination, migrate covered legacy tree, then mount | mount-source assertion and deterministic NAND fixture or fixture exemption naming the unavailable title |
| Azahar SD card | `$HOME/.local/share/azahar-emu/sdmc` | `/data/saves/azahar/sdmc` | mandatory bind mount | create destination, migrate covered legacy tree, then mount | mount-source assertion and deterministic SD fixture or fixture exemption naming the unavailable title |
| ScummVM saves | `$HOME/.local/share/scummvm/saves` | `/data/saves/scummvm/saves` | owned `[scummvm] savepath` in `scummvm.ini` | create destination, migrate legacy tree, then write key | parsed owned-key assertion and deterministic save fixture or fixture exemption naming the unavailable game engine |

The declaration is closed: implementation SHALL NOT infer additional routes
from emulator names or scan the home directory. A pinned emulator bump SHALL
revalidate every affected row. Every row SHALL receive its stated configuration
or mount evidence and deterministic write, except only the narrow fixture
exemption described by that row. melonDS is supported through its RetroArch
cores and inherits both RetroArch rows.

### Requirement: Every emulator writes save data to its declared save tree
Every supported emulator SHALL implement every row of the authoritative finite
save-route table above exactly, including its legacy path or paths,
destination, owned setting key or mandatory bind mount, ordering, and evidence
or narrow exemption. It SHALL place save-like data beneath its directory in
`/data/saves`: RetroArch saves and states; Dolphin memory cards, Wii data, and
states; DuckStation and PCSX2 memory cards and states; PPSSPP savedata, states,
and state metadata; Azahar NAND and SD-card data; and ScummVM saves. Placement SHALL be
established before kiosk start and on an empty first boot.

#### Scenario: First boot has writable save destinations
- **WHEN** the box starts with an empty `/data`
- **THEN** every declared emulator save destination exists beneath `/data/saves` and is writable by `player`

#### Scenario: Emulator writes a save
- **WHEN** any supported emulator, including ScummVM, writes through a declared save route
- **THEN** the file resolves beneath that emulator's directory in `/data/saves`

### Requirement: Required save mounts fail before gameplay
Where a supported setting cannot redirect save-like data, the emulator's
expected directory SHALL be a mandatory mount backed by `/data/saves`. The kiosk
SHALL NOT start if a required mount is absent or resolves elsewhere.

#### Scenario: Required mount is present
- **WHEN** the kiosk session is about to start
- **THEN** every required save mount is active with backing beneath `/data/saves`

#### Scenario: Required mount cannot be established
- **WHEN** a required save mount fails during boot
- **THEN** the kiosk does not start and the journal identifies the mount and destination

### Requirement: Existing save data migrates before routes activate
Every row in the authoritative finite save-route table SHALL migrate existing
files before its owned setting or mount activates. Identical files MAY be
deduplicated, but conflicting source and destination files SHALL stop activation,
name both paths, and overwrite neither. Migration SHALL be idempotent across
upgrades.

#### Scenario: Route declaration differs from the table
- **WHEN** an implemented legacy path, destination, setting key, bind mechanism, order, or evidence declaration differs from its table row
- **THEN** evaluation rejects the implementation before kiosk activation

#### Scenario: Setting-directed route has existing data
- **WHEN** an upgrade finds files at an old path for an emulator redirected by a setting
- **THEN** migration completes before the new setting is installed or used

#### Scenario: Bind-mounted route has existing data
- **WHEN** an upgrade finds files at a path that a required mount will cover
- **THEN** migration completes before that mount becomes active

#### Scenario: Migration encounters a conflict
- **WHEN** source and destination contain different data for the same relative path
- **THEN** activation stops, both paths are reported, and neither file is overwritten

### Requirement: Save data survives reboot and path drift
Files beneath `/data/saves` and anywhere beneath the persistent `player` home
SHALL survive reboot. The complete home, except finite declared cache
exclusions, SHALL be in the off-site backup set. Cache exclusions SHALL be
strict normalized descendants of `player` home and SHALL NOT equal, contain,
fall beneath, or alias any declared save route.

#### Scenario: Declared save survives reboot
- **WHEN** an emulator writes known bytes beneath `/data/saves` and the box reboots
- **THEN** the same file and bytes remain

#### Scenario: Save-like file uses an unlisted home path
- **WHEN** an emulator writes outside its declared route but beneath `player` home
- **THEN** the file persists and is included in the next backup unless explicitly excluded

### Requirement: Backup rollback preserves save placement
Disabling or rolling back off-site backup SHALL disable only cloud init, backup,
and maintenance services. It SHALL keep every authoritative save bind mount and
owned path setting active, SHALL NOT reverse-migrate or delete save data, and
SHALL preserve local snapshots independently.

#### Scenario: Off-site backup is rolled back
- **WHEN** the operator disables the cloud backup services after save migration
- **THEN** every save route still resolves to its declared `/data/saves` destination and a subsequent write survives reboot
