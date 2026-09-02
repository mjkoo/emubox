## MODIFIED Requirements

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

An owned key SHALL appear exactly once in the file the emulator reads.
Emulator configuration formats permit a key to appear more than once - a
repeated assignment in a flat file, or a section header written twice in
a file with sections - and every reader these formats are written for
resolves such a repeat to one entry. So "the file holds the flake's
value" is not enough on its own: a copy left holding an older value is
the one the emulator obeys, and the discrepancy is invisible, because a
file that already carries the flake's value somewhere reports nothing to
change on the next launch and every launch after it. Repeats of an owned
key SHALL therefore be reduced to the single assignment carrying the
flake's value. This SHALL hold for the RetroAchievements account name
and token in particular, where a surviving stale copy is a bearer
credential rather than a preference. A key the flake does not own SHALL
keep every one of its assignments, and a key of the same name belonging
to a section the flake does not own SHALL be left alone entirely.

#### Scenario: First launch seeds every emulator config
- **WHEN** the frontend is about to launch and an emulator's
  configuration file does not exist
- **THEN** the file exists before the frontend launches and carries
  every owned value

#### Scenario: Owned key drifted
- **WHEN** an owned key in an emulator's configuration holds a different
  value than the flake declares at the next launch of the frontend
- **THEN** the key holds the flake's value before the frontend launches

#### Scenario: Owned key is assigned more than once
- **WHEN** an emulator's configuration assigns one owned key twice,
  whether as a repeated line or under a section header that appears
  twice, and the frontend is about to launch
- **THEN** exactly one assignment of that key remains, holding the
  flake's value, and a later launch reports the file already correct
  rather than changing it again

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
