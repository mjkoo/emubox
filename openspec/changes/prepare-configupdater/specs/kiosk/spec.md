## MODIFIED Requirements

### Requirement: The flake owns some frontend settings and leaves the rest
Before every launch of the frontend, including each relaunch, the system SHALL ensure the frontend's settings file exists and carries the values the flake owns: kiosk UI mode, the unlock sequence, the ROM and media directories under `/data`, the theme, the `en_US` language and the quit menu enabled. When that file can be read as the frontend's settings format, every other setting SHALL keep the key and the value the frontend last wrote, so that a change made in the frontend's own menus survives a reboot; when it cannot, the scenario below governs.

An owned setting the flake declares a value for SHALL appear exactly once in the file the frontend reads, holding that value. A settings file that already carries a setting more than once is a shape a hand edit or an interrupted write can leave behind, and "the file holds the flake's value" is not enough on its own: the frontend resolves a repeated setting to one of them, so a copy left holding an older value is the one it obeys. Repeats of an owned setting SHALL therefore be reduced to the single entry carrying the flake's value. When the file can be read as the frontend's settings format, a setting the flake does not own SHALL keep every one of its entries, repeats included; which of them the frontend obeys is not this system's to decide. When it cannot, the unreadable-file scenario below governs and the replacement carries only the owned values.

#### Scenario: First start seeds the file
- **WHEN** the frontend is about to launch and no settings file exists under `/data/es-de`
- **THEN** a settings file exists before the frontend launches and carries every owned value

#### Scenario: Owned key drifted
- **WHEN** the frontend is about to launch and an owned key in the settings file holds a different value than the flake declares
- **THEN** the key holds the flake's value before the frontend launches

#### Scenario: Owned key appears more than once
- **WHEN** the frontend is about to launch and the settings file carries two or more entries for one owned setting
- **THEN** exactly one entry for that setting remains, holding the flake's value, and a later launch leaves the file unchanged rather than changing it again

#### Scenario: Unowned key repeats
- **WHEN** the settings file carries two or more entries for a setting the flake does not own
- **THEN** every one of them is still there at the next launch of the frontend

#### Scenario: Unowned key preserved
- **WHEN** a setting the flake does not own was changed through the frontend's menus during an earlier launch of the frontend and the settings file is readable
- **THEN** it holds the changed value at the next launch of the frontend

#### Scenario: Settings file unreadable
- **WHEN** the frontend is about to launch and a settings file exists under `/data/es-de` but cannot be read as the frontend's settings format, for example truncated by a frontend that was killed mid-write
- **THEN** it is replaced by a settings file carrying every owned value before the frontend launches, and the session goes on to launch the frontend rather than ending
