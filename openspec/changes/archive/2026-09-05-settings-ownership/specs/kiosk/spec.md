## MODIFIED Requirements

### Requirement: The flake owns some frontend settings and leaves the rest
The flake owns a frontend setting in one of two tiers. An **enforced**
setting is asserted before every launch of the frontend, including each
relaunch: written if missing, corrected if it holds another value,
reduced to one entry if repeated. A **seeded** setting is written only
when the settings file carries no entry for it; once an entry exists,
whatever value it holds - the flake's default, one chosen in the
frontend's menus, or empty - it SHALL be left untouched: not corrected,
not reduced, not removed. Both tiers together are the owned settings. A
setting belongs to exactly one tier: a declaration that places the same
setting in both tiers is a configuration error and SHALL be refused when
the rendered declaration is validated, before this system contacts
RetroAchievements for its login and before it touches any file,
credential files included - preparation fails and the frontend is not
launched, rather than one tier silently winning.

Before every launch of the frontend the system SHALL ensure the
frontend's settings file exists and carries the enforced values: kiosk UI
mode, the unlock sequence, the ROM and media directories under `/data`
and the quit menu enabled. The theme and the frontend language are
seeded, with the flake's defaults; a player's choice of either in the
frontend's own menus is a preference this capability promises to keep.
When the file can be read as the frontend's settings format, every other
setting SHALL keep the key and the value the frontend last wrote, so that
a change made in the frontend's own menus survives a reboot; when it
cannot, the unreadable-file scenario below governs and the replacement
carries the owned values of both tiers - which is the one case where a
seeded setting returns to the flake's default.

An enforced setting SHALL appear exactly once in the file the frontend
reads, holding the flake's value. A settings file that already carries a
setting more than once is a shape a hand edit or an interrupted write can
leave behind, and "the file holds the flake's value" is not enough on its
own: the frontend resolves a repeated setting to one of them, so a copy
left holding an older value is the one it obeys. Repeats of an enforced
setting SHALL therefore be reduced to the single entry carrying the
flake's value. A seeded setting, like an unowned one, SHALL keep every
one of its entries, repeats included; which of them the frontend obeys is
not this system's to decide. When the file can be read as the frontend's
settings format, a setting the flake does not own SHALL keep every one of
its entries, repeats included.

#### Scenario: First start seeds the file
- **WHEN** the frontend is about to launch and no settings file exists
  under `/data/es-de`
- **THEN** a settings file exists before the frontend launches and
  carries every owned value of both tiers

#### Scenario: Owned key drifted
- **WHEN** the frontend is about to launch and an enforced key in the
  settings file holds a different value than the flake declares
- **THEN** the key holds the flake's value before the frontend launches

#### Scenario: Theme chosen in the frontend's menus survives
- **WHEN** the theme or the frontend language was changed through the
  frontend's own menus during an earlier launch, so its entry differs
  from the flake's default, and the box reboots
- **THEN** the changed value is still in the settings file at the next
  launch of the frontend, and the frontend starts with it

#### Scenario: Seeded key absent
- **WHEN** the frontend is about to launch and the readable settings
  file carries no entry for a seeded setting
- **THEN** the file carries the flake's default for it before the
  frontend launches

#### Scenario: A setting declared in both tiers
- **WHEN** the flake's declaration, as rendered for preparation, names
  one frontend setting under both the enforced and the seeded tier, and
  the frontend is about to launch
- **THEN** preparation fails while the rendered declaration is being
  validated, before this system contacts RetroAchievements for its login
  and before it touches any file, the settings file and credential files
  included, reporting the file and the setting, and the frontend is not
  launched

#### Scenario: Owned key appears more than once
- **WHEN** the frontend is about to launch and the settings file carries
  two or more entries for one enforced setting
- **THEN** exactly one entry for that setting remains, holding the
  flake's value, and a later launch leaves the file unchanged rather
  than changing it again

#### Scenario: Unowned key repeats
- **WHEN** the settings file carries two or more entries for a setting
  the flake does not own
- **THEN** every one of them is still there at the next launch of the
  frontend

#### Scenario: Unowned key preserved
- **WHEN** a setting the flake does not own was changed through the
  frontend's menus during an earlier launch of the frontend and the
  settings file is readable
- **THEN** it holds the changed value at the next launch of the frontend

#### Scenario: Settings file unreadable
- **WHEN** the frontend is about to launch and a settings file exists
  under `/data/es-de` but cannot be read as the frontend's settings
  format, for example truncated by a frontend that was killed mid-write
- **THEN** it is replaced by a settings file carrying every owned value
  of both tiers before the frontend launches, and the session goes on to
  launch the frontend rather than ending
