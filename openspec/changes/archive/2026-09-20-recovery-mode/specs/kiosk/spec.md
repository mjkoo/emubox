## MODIFIED Requirements

### Requirement: Power-on lands in the frontend without a login
Booted through the entry the box normally boots, the box SHALL log the `player` user into the kiosk session automatically at boot and SHALL start the frontend, full screen, under a Wayland compositor. A boot entry that deliberately logs nobody in is outside that guarantee and is the `recovery` capability's to describe: on such a boot nothing is logged in automatically and no frontend starts until somebody logs in at the prompt. What the screen shows between power-on and the session is the `base-system` capability's silent-boot guarantee, not this one's. The frontend SHALL read and write its application data under `/data/es-de`, its ROMs under `/data/roms` and its media under `/data/media`, which is where the `persistence` capability's root-wipe guarantee applies.

#### Scenario: Frontend up after boot
- **WHEN** the box is powered on into the entry it normally boots
- **THEN** within 60 seconds of the graphical target the frontend is running as `player` inside the compositor, and `player` holds the seat's active session

#### Scenario: Frontend data is persistent
- **WHEN** the frontend writes its settings, gamelists or collections
- **THEN** the files land under `/data/es-de`, where the `persistence` capability's guarantee that `/data` survives the root wipe applies to them

### Requirement: The frontend is kept up, and a broken frontend ends at the greeter
When the frontend exits, the session SHALL relaunch it. A frontend that exits within 60 seconds of launch counts as a crash; after three consecutive crashes the session SHALL end and the display manager SHALL show its login greeter, with no further automatic login for as long as that display manager keeps running. A frontend that ran longer than 60 seconds resets the count. A reboot into the system as normally booted SHALL restore automatic login; a boot entry that deliberately logs nobody in is outside this guarantee and is the `recovery` capability's to describe.

#### Scenario: Relaunch after exit
- **WHEN** the frontend process ends after running for more than 60 seconds
- **THEN** a new frontend process is running within 15 seconds

#### Scenario: Crash loop ends at the greeter
- **WHEN** the frontend exits within 60 seconds of launch three times in a row
- **THEN** the session ends, the greeter is shown, and no automatic login happens while that display manager keeps running

#### Scenario: Reboot restores the kiosk
- **WHEN** the box is rebooted from the greeter into the normal boot entry
- **THEN** it logs `player` in automatically and starts the frontend
