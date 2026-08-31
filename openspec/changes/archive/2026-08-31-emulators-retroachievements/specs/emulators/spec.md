## Purpose

Which emulator serves each game system, the launch configuration the
flake owns in each emulator so every game starts full screen with the
right BIOS and uniform hotkeys, the frontend's per-system emulator
overrides, and the BIOS directory with its checking tool.

## ADDED Requirements

### Requirement: Each system launches with its assigned emulator
The frontend SHALL launch every configured game system with the emulator
the configuration assigns it - the RetroArch core or standalone program
from the design's system table - full screen, with no emulator setup
screen in the path from choosing a game to playing it. Systems whose
assigned emulator differs from the frontend's bundled default SHALL get
that assignment through the frontend's custom systems definition, so the
frontend's own files stay unmodified. PS1 SHALL launch DuckStation, with
the Beetle PSX HW core remaining selectable in the frontend as the
alternate emulator so PS1 survives a broken DuckStation.

#### Scenario: Game launch uses the assigned emulator
- **WHEN** a game is chosen in the frontend for a system whose assigned
  emulator differs from the frontend's default
- **THEN** the assigned emulator is the process that runs the game

#### Scenario: PS1 alternate present
- **WHEN** the frontend's alternate emulator list for PS1 is read
- **THEN** DuckStation is the default entry and Beetle PSX HW is offered

### Requirement: The flake owns each emulator's launch settings
Before every launch of the frontend - the same anchor the `kiosk`
capability defines, each relaunch included - every emulator's
configuration file SHALL exist and carry the values the flake owns, and
every unowned key SHALL be left exactly as the emulator last wrote it; a
file that cannot be read SHALL be replaced by one carrying the owned
values, and the session goes on. The owned values SHALL pin at least:
for RetroArch, the core directory (the flake's packaged cores and no
other source), the system directory `/data/bios`, a 30 second save
autosave interval, fullscreen, the menu entries for downloading cores or
content disabled, and the uniform hotkey set; for every standalone,
fullscreen and the per-emulator performance choices the design settles
(Wii dual core off in Dolphin, native internal resolution in PCSX2,
geometry correction and upscaling in DuckStation).

#### Scenario: First launch seeds every emulator config
- **WHEN** the frontend is about to launch and an emulator's
  configuration file does not exist
- **THEN** the file exists before the frontend launches and carries
  every owned value

#### Scenario: Owned key drifted
- **WHEN** an owned key in an emulator's configuration holds a different
  value than the flake declares at the next launch of the frontend
- **THEN** the key holds the flake's value before the frontend launches

#### Scenario: Unowned key preserved
- **WHEN** a setting the flake does not own was changed inside an
  emulator's own menus and that emulator's configuration file is
  readable
- **THEN** the changed value is still there at the next launch of the
  frontend

#### Scenario: Emulator config unreadable
- **WHEN** the frontend is about to launch and an emulator's
  configuration file exists but cannot be read as that emulator's
  format, for example truncated by an emulator killed mid-write
- **THEN** it is replaced by a file carrying every owned value before
  the frontend launches, and the session goes on to launch the frontend
  rather than ending

### Requirement: BIOS files live in one place and are checkable
Emulators SHALL read firmware and BIOS images from `/data/bios`, laid
out under the names the configuration's declared BIOS inventory lists. The system SHALL
provide `emubox-check-bios`, a report-only command that compares
`/data/bios` against the declared name and checksum list and reports
each file as present and matching, present with a wrong checksum, or
missing; files present under `/data/bios` but not declared SHALL be
listed as informational extras without affecting the exit status. It
SHALL modify nothing and SHALL exit successfully when everything
declared matches and unsuccessfully otherwise, so scripts can gate on
it.

#### Scenario: Complete BIOS set
- **WHEN** every declared file is present under `/data/bios` with the
  declared checksum and `emubox-check-bios` runs
- **THEN** it reports every file as matching and exits successfully

#### Scenario: Missing or wrong file
- **WHEN** a declared file is absent or its checksum differs and
  `emubox-check-bios` runs
- **THEN** the report names that file and its state and the exit status
  is unsuccessful, and `/data/bios` is unmodified
