## MODIFIED Requirements

### Requirement: Power-on lands in the frontend without a login
Booted through the entry the box normally boots, the box SHALL log the `player` user into the kiosk session automatically at boot and SHALL start the frontend, full screen, under a Wayland compositor. When folders are pending generation at that start, the session SHALL first run the bounded generation step, showing progress when it generates and handling a held claim or a failed window as the library capability specifies, and the frontend SHALL start within the same time after that step ends; the step itself is bounded in time by a deadline the session holds around the windowed step, a little above generation's overall time limit, and five-second bounds for capturing the attempted work and for failure recording, all of which the `library` capability owns. A boot entry that deliberately logs nobody in is outside that guarantee and is the `recovery` capability's to describe: on such a boot nothing is logged in automatically and no frontend starts until somebody logs in at the prompt. What the screen shows between power-on and the session is the `base-system` capability's silent-boot guarantee, not this one's. The frontend SHALL read and write its application data under `/data/es-de`, its ROMs under `/data/roms` and its media under `/data/media`, which is where the `persistence` capability's root-wipe guarantee applies.

#### Scenario: Frontend up after boot
- **WHEN** the box is powered on into the entry it normally boots with nothing pending generation
- **THEN** within 60 seconds of the graphical target the frontend is running as `player` inside the compositor, and `player` holds the seat's active session

#### Scenario: Frontend up after boot with folders pending
- **WHEN** the box is powered on into the entry it normally boots with folders pending generation
- **THEN** the library's bounded generation step completes or skips according to its failure and concurrency rules, and within 60 seconds of that step ending the frontend is running as `player` inside the compositor, and `player` holds the seat's active session

#### Scenario: Frontend data is persistent
- **WHEN** the frontend writes its settings, gamelists or collections
- **THEN** the files land under `/data/es-de`, where the `persistence` capability's guarantee that `/data` survives the root wipe applies to them

### Requirement: The frontend runs restricted
The frontend SHALL run in its kiosk UI mode: the main menu reduced to volume and the quit entry the power-off requirement below defines, with no metadata editor, no collection editing, the frontend's own built-in scraper closed and no favourites toggling; every game remains launchable. A scrape the household may start from the frontend is provided only through the Tools entry the `library` capability describes, not through the frontend's own scraper. The full menu SHALL be reachable only by entering the unlock sequence declared by the configuration (`emubox.kiosk.passkey`, the frontend's own default sequence unless the host sets another), and the restriction SHALL be reasserted before every launch of the frontend, including each relaunch after it exits - the anchor every requirement in this capability means by "before the frontend launches".

#### Scenario: Kiosk mode at every start
- **WHEN** the frontend launches, including after the admin unlocked the full menu during an earlier launch
- **THEN** it is in kiosk mode

#### Scenario: Unlock sequence from the configuration
- **WHEN** the host sets `emubox.kiosk.passkey`
- **THEN** that sequence, and not the frontend's default, unlocks the full menu

### Requirement: Custom systems come from the configuration
The configuration SHALL accept custom system definitions from any number of
its modules, and the frontend SHALL read all of them, in a stable order, as its
one custom systems file, complementing the bundled systems. A definition SHALL
reach the file with its text unchanged. When no module contributes one, no
custom systems file SHALL exist.

#### Scenario: Definition present
- **WHEN** one or more modules contribute definitions and the frontend is about to launch
- **THEN** the frontend's custom systems file under `/data/es-de` is a single well-formed systems document holding exactly those definitions, each once

#### Scenario: Two contributors
- **WHEN** two modules each contribute definitions
- **THEN** the file holds both sets, and building the configuration twice yields the same file

#### Scenario: Definition empty
- **WHEN** no module contributes a definition and a custom systems file exists from an earlier configuration
- **THEN** the file is removed before the frontend launches

#### Scenario: Definition empty and no file present
- **WHEN** no module contributes a definition and no custom systems file exists
- **THEN** none is created, and the session goes on to launch the frontend rather than treating the absent file as a failure

### Requirement: The frontend is kept up, and a broken frontend ends at the greeter
When the frontend exits, the session SHALL relaunch it. A frontend that exits within 60 seconds of launch counts as a crash; after three consecutive crashes the session SHALL end and the display manager SHALL show its login greeter, with no further automatic login for as long as that display manager keeps running. A frontend that ran longer than 60 seconds resets the count. An exit that a Tools entry asked for is a requested restart: it SHALL NOT count as a crash however short the run was, a requested restart SHALL also reset the consecutive-crash count to zero whatever the run's length, and the request SHALL cover that one exit only, so a frontend that then crashes on its own still counts, as the first of a new run of crashes. A request the frontend has not honoured by exiting within 15 seconds SHALL lapse, and the exit that eventually follows SHALL count as usual. When folders are pending generation at a relaunch, the session SHALL first run the bounded generation step, showing progress when it generates and handling a held claim or a failed window as the library capability specifies, and the new frontend process SHALL be running within 15 seconds of that step ending; the step itself is bounded in time by a deadline the session holds around the windowed step, a little above generation's overall time limit, and five-second bounds for capturing the attempted work and for failure recording, all of which the `library` capability owns. A reboot into the system as normally booted SHALL restore automatic login; a boot entry that deliberately logs nobody in is outside this guarantee and is the `recovery` capability's to describe.

#### Scenario: Relaunch after exit
- **WHEN** the frontend process ends after running for more than 60 seconds and nothing is pending generation
- **THEN** a new frontend process is running within 15 seconds

#### Scenario: Relaunch with folders pending
- **WHEN** the frontend process ends and folders are pending generation
- **THEN** the library's bounded generation step completes or skips according to its failure and concurrency rules, and a new frontend process is running within 15 seconds of that step ending

#### Scenario: Crash loop ends at the greeter
- **WHEN** the frontend exits within 60 seconds of launch three times in a row
- **THEN** the session ends, the greeter is shown, and no automatic login happens while that display manager keeps running

#### Scenario: Requested restarts are not crashes
- **WHEN** a Tools entry asks for a restart within 60 seconds of launch, three times in a row
- **THEN** the frontend is relaunched each time and the session does not end

#### Scenario: A request covers one exit
- **WHEN** a requested restart is followed by three exits within 60 seconds that nothing requested
- **THEN** the session ends at the greeter

#### Scenario: A request the frontend ignores lapses
- **WHEN** a Tools entry asks for a restart 10 seconds after the frontend's launch, the frontend keeps running, and it exits on its own 50 seconds after its launch
- **THEN** that exit counts as a crash

#### Scenario: A requested restart resets the crash count
- **WHEN** two exits within 60 seconds that nothing requested are followed by a requested restart and then one more exit within 60 seconds that nothing requested
- **THEN** the frontend is relaunched and the session does not end, because the requested restart reset the count and the last exit is the first of a new run of crashes

#### Scenario: Reboot restores the kiosk
- **WHEN** the box is rebooted from the greeter into the normal boot entry
- **THEN** it logs `player` in automatically and starts the frontend

#### Scenario: A termination request fails
- **WHEN** a Tools entry cannot deliver its frontend termination request and returns failure, and the frontend later crashes
- **THEN** that failed request does not excuse the later crash or reset its count
