## Purpose

Which emulator serves each game system, the launch configuration the
flake owns in each emulator so every game starts full screen with the
right BIOS and uniform hotkeys, the frontend's per-system emulator
overrides, and the BIOS directory with its checking tool.

## Requirements
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
every unowned key SHALL keep the key, the value and the section the
emulator last wrote, though presentation the emulator does not read -
spacing around a delimiter, indentation, a line's position within its
section - is not guaranteed; a
file that cannot be read SHALL be replaced by one carrying the owned
values, and the session goes on. The owned values SHALL pin at least:
for RetroArch, the core directory (the flake's packaged cores and no
other source), the system directory `/data/bios`, a 30 second save
autosave interval, fullscreen, the menu entries for downloading cores or
content disabled, and the uniform hotkey set; for every standalone,
fullscreen and the per-emulator performance choices the design settles
(Wii dual core off in Dolphin, native internal resolution in PCSX2,
geometry correction and upscaling in DuckStation).

In a file with sections, an owned key is a key together with the section
the flake declares it under; the same key name under a different section
is a different key and is not owned. The places that belong to it are
every instance of that declared section, and the region above the first
section header, which belongs to no section and so to no other section's
owner. In a file without sections, such as RetroArch's, an owned key is a
key name and every assignment of it in the file belongs to it.

An owned key the flake declares a value for SHALL appear exactly once
among the places that belong to it, holding that value. An owned key the
flake declares for removal SHALL appear zero times among them. Emulator configuration formats permit a key to
appear more than once there: a repeated assignment in a flat file, a
repeated assignment inside one section, or a section header written
twice so that the same key appears under each. A reader resolves such a
repeat to one entry, so "the file holds the flake's value" is not enough
on its own: a copy left holding an older value is the one the emulator
obeys, and the discrepancy is invisible, because a file that already
carries the flake's value somewhere reports nothing to change on the
next launch and every launch after it. Repeats of an owned key SHALL
therefore be reduced to the single assignment carrying the flake's value,
or to none at all when the flake declares it for removal. This SHALL hold for the RetroAchievements account name and token
in particular, where a surviving stale copy is a bearer credential
rather than a preference.

When the file can be read as that emulator's format, a key the flake
does not own SHALL keep every one of its assignments, and a key of the
same name belonging to a section the flake does not own SHALL be left
alone entirely. When it cannot, the unreadable-file scenario below
governs and the replacement carries only the owned values.

#### Scenario: First launch seeds every emulator config
- **WHEN** the frontend is about to launch and an emulator's
  configuration file does not exist
- **THEN** the file exists before the frontend launches and carries
  every owned value

#### Scenario: Owned key drifted
- **WHEN** an owned key in an emulator's configuration holds a different
  value than the flake declares at the next launch of the frontend
- **THEN** the key holds the flake's value before the frontend launches

#### Scenario: Owned key declared for removal is assigned more than once
- **WHEN** the flake declares an owned key for removal and an emulator's
  readable configuration assigns that key two or more times among the
  places belonging to it
- **THEN** no assignment of it remains anywhere among those places before
  the frontend launches

#### Scenario: Owned key is assigned more than once
- **WHEN** an emulator's configuration assigns one owned key twice,
  whether as a repeated line inside one section, as a repeated line in a
  file with no sections, or under a section header that appears twice,
  and the frontend is about to launch
- **THEN** exactly one assignment of that key remains, holding the
  flake's value, and a later launch leaves the file unchanged rather
  than changing it again

#### Scenario: Unowned key repeats
- **WHEN** an emulator's readable configuration assigns a key the flake
  does not own two or more times, and an owned key elsewhere in that file
  needs updating at the next launch of the frontend
- **THEN** every one of those assignments is still there afterwards,
  holding the values the emulator wrote, each under the section it was
  written in

#### Scenario: A same-named key belongs to somebody else
- **WHEN** an emulator's configuration assigns a key of the same name
  under a section the flake does not own
- **THEN** that assignment is left exactly as the emulator wrote it

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
