## MODIFIED Requirements

### Requirement: The flake owns each emulator's launch settings
The flake owns a setting in one of two tiers. An **enforced** setting is
asserted before every launch of the frontend - the same anchor the `kiosk`
capability defines, each relaunch included: written if missing, corrected
if it holds another value, reduced to one assignment if repeated, and
removable. A **seeded** setting is written only when no assignment of it
exists among the places that belong to it; once an assignment exists,
whatever value it holds - the flake's default, a changed one, or empty -
the setting SHALL be left untouched: not corrected, not reduced, not
removed. Both tiers together are the owned settings; everything else in a
file is unowned. A setting belongs to exactly one tier: a declaration that
places the same setting in both tiers of one file is a configuration error
and SHALL be refused when the rendered declaration is validated, before
this system contacts RetroAchievements for its login and before it
touches any file, credential files included, whether the overlap is
declared outright or arises when a RetroAchievements target key lands on
a setting its file seeds. A declaration that places a setting
RetroAchievements manages under the seeded tier is a configuration error
and SHALL be refused before the system is built or, failing that, before
any file is written.

Eight of RetroArch's enforced settings are delivered at launch rather than
through `retroarch.cfg`; the launch-time delivery requirement below names
them. Every file-level rule in this requirement - presence, drift
correction, exactly-once, duplicate reduction, removal, and the
byte-order-mark and file-content rules - applies to the enforced settings
this system writes into a file and SHALL NOT be applied to those
launch-delivered settings, for which `retroarch.cfg` is never edited.

Before every launch of the frontend, every emulator's configuration file
SHALL exist and carry every enforced value the flake declares in it -
except the launch-delivered RetroArch settings, which take effect without
being written to the emulator's file - and carry an assignment of every
seeded setting. Every unowned key SHALL keep the key, the value and the
section the emulator last wrote, though presentation the emulator does not
read - spacing around a delimiter, indentation, a line's position within
its section - is not guaranteed. A file that cannot be read SHALL be
replaced by one carrying the owned values of both tiers - a recreated file
is missing every key, so seeded settings return to the flake's defaults
there and only there - and the session goes on.

The enforced values SHALL pin at least: for RetroArch, the core directory
(the flake's packaged cores and no other source), the system directory
`/data/bios`, a 30 second save autosave interval, fullscreen, the menu
entries for downloading cores or content disabled, and the two controller
button combos that open the menu and quit the game - the only
controller-only routes out of a running game - all of which reach
RetroArch at launch rather than through `retroarch.cfg`; for RetroArch in
`retroarch.cfg` itself, the save and state directories the `saves`
capability routes; for every standalone, fullscreen. The seeded defaults
SHALL include at least: RetroArch's menu skin and its keyboard hotkeys,
and the per-emulator performance choices (Wii dual core off in Dolphin,
native internal resolution in PCSX2, geometry correction and upscaling in
DuckStation) - tuning a player may change in an emulator's own menus and
keep.

An emulator's own writer may prefix its flat configuration file with a
UTF-8 byte order mark - PPSSPP's does, on every save. A flat
configuration file that differs from a readable file only by that
leading mark SHALL be read as its format, with the mark counted as part
of neither the first line nor any key, and a write SHALL leave the mark
leading the file exactly as the emulator put it. A file containing only
the mark SHALL be treated as an empty file. The mark anywhere other
than the very start of the file receives nothing from this rule: it is
content like any other codepoint, and whichever rule already applies to
the line carrying it governs.

In a file with sections, an owned key is a key together with the section
the flake declares it under; the same key name under a different section
is a different key and is not owned. The places that belong to it are
every instance of that declared section, and the region above the first
section header, which belongs to no section and so to no other section's
owner. In a file without sections, such as RetroArch's, an owned key is a
key name and every assignment of it in the file belongs to it. This
holds for both tiers.

An enforced key the flake declares a value for and writes into the file
SHALL appear exactly once among the places that belong to it, holding
that value. An enforced key the flake declares for removal SHALL appear
zero times among them. Emulator configuration formats permit a key to
appear more than once there: a repeated assignment in a flat file, a
repeated assignment inside one section, or a section header written twice
so that the same key appears under each. A reader resolves such a repeat
to one entry, so "the file holds the flake's value" is not enough on its
own: a copy left holding an older value is the one the emulator obeys,
and the discrepancy is invisible, because a file that already carries the
flake's value somewhere reports nothing to change on the next launch and
every launch after it. Repeats of an enforced key this system writes
SHALL therefore be reduced to the single assignment carrying the flake's
value, or to none at all when the flake declares it for removal. This
SHALL hold for the RetroAchievements account name and token in
particular, where a surviving stale copy is a bearer credential rather
than a preference. The launch-delivered RetroArch settings are outside
this paragraph entirely: a copy of one in `retroarch.cfg`, stale or
repeated, is neither corrected nor reduced nor removed by this system. A
seeded key, by contrast, SHALL keep every one of its assignments, exactly
as an unowned key does: once the file carries the setting, which
assignment the emulator obeys is not this system's to decide. Only an
enforced key may be declared for removal; a declaration marking a seeded
key for removal is a configuration error and SHALL be refused rather than
acted on: preparation fails when the rendered declaration is validated,
before this system contacts RetroAchievements for its login and before it
touches any file, and nothing is launched, rather than acting on the rest
of the declaration.

When the file can be read as that emulator's format, a key the flake
does not own SHALL keep every one of its assignments, and a key of the
same name belonging to a section the flake does not own SHALL be left
alone entirely. When it cannot, the unreadable-file scenario below
governs and the replacement carries only the owned values.

#### Scenario: First launch seeds every emulator config
- **WHEN** the frontend is about to launch and an emulator's
  configuration file does not exist
- **THEN** the file exists before the frontend launches and carries
  every owned value of both tiers that this system writes into it

#### Scenario: Owned key drifted
- **WHEN** an enforced key this system writes into an emulator's
  configuration holds a different value than the flake declares at the
  next launch of the frontend
- **THEN** the key holds the flake's value before the frontend launches

#### Scenario: Seeded key absent
- **WHEN** the frontend is about to launch and an emulator's readable
  configuration file carries no assignment of a seeded setting among the
  places that belong to it
- **THEN** the file carries the flake's default for it before the
  frontend launches

#### Scenario: Seeded key changed by a player
- **WHEN** a seeded setting was changed inside an emulator's own menus,
  so its assignment differs from the flake's default, and the frontend
  is about to launch
- **THEN** the changed value is still there before and after the launch,
  on that launch and every launch after it

#### Scenario: Seeded key present and empty
- **WHEN** an emulator's readable configuration assigns a seeded setting
  an empty value and the frontend is about to launch
- **THEN** the assignment is left exactly as the emulator wrote it

#### Scenario: Seeded key repeated
- **WHEN** an emulator's readable configuration assigns one seeded
  setting two or more times among the places that belong to it, and an
  enforced key elsewhere in that file needs updating at the next launch
  of the frontend
- **THEN** every one of those assignments is still there afterwards

#### Scenario: Seeded key declared for removal
- **WHEN** the flake's declaration marks a seeded setting for removal,
  including through a RetroAchievements target that names a setting its
  file seeds, and the frontend is about to launch
- **THEN** preparation fails while the rendered declaration is being
  validated, before this system contacts RetroAchievements for its login
  and before it touches any file, credential files included, reporting
  the file and the setting, and the frontend is not launched

#### Scenario: A setting declared in both tiers
- **WHEN** the flake's declaration, as rendered for preparation, names
  one setting of one file under both the enforced and the seeded tier,
  and the frontend is about to launch
- **THEN** preparation fails while the rendered declaration is being
  validated, before this system contacts RetroAchievements for its login
  and before it touches any file, credential files included, reporting
  the file and the setting, and the frontend is not launched

#### Scenario: Owned key declared for removal is assigned more than once
- **WHEN** the flake declares an enforced key for removal and an
  emulator's readable configuration assigns that key two or more times
  among the places belonging to it
- **THEN** no assignment of it remains anywhere among those places before
  the frontend launches

#### Scenario: Owned key is assigned more than once
- **WHEN** an emulator's configuration assigns one enforced key this
  system writes twice, whether as a repeated line inside one section, as
  a repeated line in a file with no sections, or under a section header
  that appears twice, and the frontend is about to launch
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

#### Scenario: Emulator writes a leading byte order mark
- **WHEN** an emulator's flat configuration file leads with a UTF-8
  byte order mark and is otherwise readable as that emulator's format,
  and an owned key in it needs updating at the next launch of the
  frontend
- **THEN** the file still carries every unowned key with the value the
  emulator wrote, rather than being replaced by one carrying only the
  owned values, and the mark still leads the file afterwards

#### Scenario: A settled file with a byte order mark stays untouched
- **WHEN** an emulator's flat configuration file leads with a UTF-8
  byte order mark, is otherwise readable, and already carries every
  owned value this system writes into it
- **THEN** the file is not written at the next launch of the frontend,
  on that launch and every launch after it

#### Scenario: Emulator config unreadable
- **WHEN** the frontend is about to launch and an emulator's
  configuration file exists but cannot be read as that emulator's
  format, for example truncated by an emulator killed mid-write
- **THEN** it is replaced by a file carrying every owned value of both
  tiers that this system writes into it before the frontend launches,
  and the session goes on to launch the frontend rather than ending

## ADDED Requirements

### Requirement: RetroArch's static enforced settings are delivered at launch
Eight of RetroArch's enforced settings have values fixed at build time
and are delivered at launch rather than written into `retroarch.cfg`: the
core directory, the system directory, the autosave interval, fullscreen,
the two updater menu entries and the two controller button combos. They
SHALL be delivered to RetroArch through configuration the flake provides
read-only at launch, which RetroArch reads on every start and which takes
precedence over `retroarch.cfg` for those settings. Those settings SHALL
take effect regardless of what `retroarch.cfg` holds for them, and this
system SHALL NOT edit `retroarch.cfg` to assert, correct, reduce or
remove them - a stale copy there is overridden at every load and is left
alone, where "left alone" means this system does not edit it. RetroArch
itself rewrites `retroarch.cfg` from its effective settings when it
exits, so a copy there may come to hold the flake's value; that is the
emulator's own write, outside this system's guarantees, and nothing here
depends on it or prevents it. The flake-provided configuration SHALL
carry, at least, every one of those eight settings with the flake's
values and the RetroArch package wrapper's own asset, autoconfig and
core-info directory paths, and SHALL carry no credential and no seeded
setting. Every other
enforced RetroArch setting - the save and state directories the `saves`
capability routes, and the RetroAchievements credentials and switches,
which are decided at runtime - and every seeded RetroArch setting stays
in `retroarch.cfg` under the ownership requirement's rules.

#### Scenario: Stale value in the emulator's own file loses
- **WHEN** `retroarch.cfg` assigns one of the launch-delivered settings a
  different value than the flake declares and RetroArch launches
- **THEN** RetroArch runs with the flake's value, and the next launch of
  the frontend does not write `retroarch.cfg` for that setting

#### Scenario: The delivered configuration is complete
- **WHEN** the flake's RetroArch package is built
- **THEN** the configuration it delivers at launch exists, carries every
  one of the eight launch-delivered settings with the flake's value
  alongside the package wrapper's own asset, autoconfig and core-info
  directory paths, and carries no credential and no seeded setting

#### Scenario: Save directories stay in the emulator's own file
- **WHEN** the frontend is about to launch
- **THEN** `retroarch.cfg` carries the save and state directories the
  `saves` capability routes as enforced settings, written and corrected
  there under the ownership requirement, and the launch-time
  configuration does not carry them
