## Purpose

What the box shows and does from power-on to the frontend: the automatic session, the loop that keeps the frontend up and the failure state when it cannot, the frontend's restricted configuration and where its data lives, which settings the flake owns and which it leaves to the frontend, and power off and reboot from the frontend.

## Requirements

### Requirement: Power-on lands in the frontend without a login
The box SHALL log the `player` user into the kiosk session automatically at boot and SHALL start the frontend, full screen, under a Wayland compositor. What the screen shows between power-on and the session is the `base-system` capability's silent-boot guarantee, not this one's. The frontend SHALL read and write its application data under `/data/es-de`, its ROMs under `/data/roms` and its media under `/data/media`, which is where the `persistence` capability's root-wipe guarantee applies.

#### Scenario: Frontend up after boot
- **WHEN** the box is powered on
- **THEN** within 60 seconds of the graphical target the frontend is running as `player` inside the compositor, and `player` holds the seat's active session

#### Scenario: Frontend data is persistent
- **WHEN** the frontend writes its settings, gamelists or collections
- **THEN** the files land under `/data/es-de`, where the `persistence` capability's guarantee that `/data` survives the root wipe applies to them

### Requirement: The frontend runs restricted
The frontend SHALL run in its kiosk UI mode: the main menu reduced to volume and the quit entry the power-off requirement below defines, with no metadata editor, no collection editing, no scraper access and no favourites toggling; every game remains launchable. The full menu SHALL be reachable only by entering the unlock sequence declared by the configuration (`emubox.kiosk.passkey`, the frontend's own default sequence unless the host sets another), and the restriction SHALL be reasserted before every launch of the frontend, including each relaunch after it exits - the anchor every requirement in this capability means by "before the frontend launches".

#### Scenario: Kiosk mode at every start
- **WHEN** the frontend launches, including after the admin unlocked the full menu during an earlier launch
- **THEN** it is in kiosk mode

#### Scenario: Unlock sequence from the configuration
- **WHEN** the host sets `emubox.kiosk.passkey`
- **THEN** that sequence, and not the frontend's default, unlocks the full menu

### Requirement: Power off and reboot from the frontend
In kiosk mode the frontend's menu SHALL offer power off and reboot, each behind a confirmation, and choosing one SHALL power the box off or reboot it as `player` without a password. The menu SHALL NOT offer to quit the frontend or to suspend the box in kiosk mode.

#### Scenario: Power off from the menu
- **WHEN** `player` chooses power off in the frontend's menu and confirms
- **THEN** the box powers off cleanly

#### Scenario: No quit or suspend in kiosk mode
- **WHEN** the frontend's quit menu is opened in kiosk mode
- **THEN** it lists power off and reboot and nothing else

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

### Requirement: Custom systems come from the configuration
The configuration SHALL accept a custom systems definition (`emubox.kiosk.customSystems`) that the frontend reads as its custom systems file, complementing the bundled systems. When it is empty, no custom systems file SHALL exist.

#### Scenario: Definition present
- **WHEN** `emubox.kiosk.customSystems` is non-empty and the frontend is about to launch
- **THEN** the frontend's custom systems file under `/data/es-de` holds exactly that definition

#### Scenario: Definition empty
- **WHEN** `emubox.kiosk.customSystems` is empty and a custom systems file exists from an earlier configuration
- **THEN** the file is removed before the frontend launches

#### Scenario: Definition empty and no file present
- **WHEN** `emubox.kiosk.customSystems` is empty and no custom systems file exists
- **THEN** none is created, and the session goes on to launch the frontend rather than treating the absent file as a failure

### Requirement: The frontend is kept up, and a broken frontend ends at the greeter
When the frontend exits, the session SHALL relaunch it. A frontend that exits within 60 seconds of launch counts as a crash; after three consecutive crashes the session SHALL end and the display manager SHALL show its login greeter, with no further automatic login for as long as that display manager keeps running. A frontend that ran longer than 60 seconds resets the count. A reboot SHALL restore automatic login.

#### Scenario: Relaunch after exit
- **WHEN** the frontend process ends after running for more than 60 seconds
- **THEN** a new frontend process is running within 15 seconds

#### Scenario: Crash loop ends at the greeter
- **WHEN** the frontend exits within 60 seconds of launch three times in a row
- **THEN** the session ends, the greeter is shown, and no automatic login happens while that display manager keeps running

#### Scenario: Reboot restores the kiosk
- **WHEN** the box is rebooted from the greeter
- **THEN** it logs `player` in automatically and starts the frontend
