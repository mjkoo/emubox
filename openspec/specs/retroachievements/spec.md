## Purpose

One shared RetroAchievements account for the whole box: how the login
happens without anyone typing credentials on the box, how the session
token reaches every supporting emulator, the single hardcore switch, and
what happens when the network or the service is away.

## Requirements
### Requirement: One login reaches every supporting emulator
When RetroAchievements is enabled, the system SHALL log in to the
RetroAchievements API with the credentials from the declared secrets
store and SHALL ensure, before every launch of the frontend - the
`kiosk` capability's anchor - that each supporting emulator's
configuration carries the account name and the session token in the form
that emulator reads at rest: plain for RetroArch, Dolphin, PCSX2 and
PPSSPP, and for DuckStation the encrypted form the pinned DuckStation
version derives from the box's machine id and the account name, so
DuckStation accepts it with no login of its own. No manual login step
SHALL exist anywhere: a freshly installed box with credentials in its
secrets and a working network SHALL unlock achievements in every
supporting emulator without a person touching an emulator menu. The
account password SHALL NOT be written to any emulator configuration.

#### Scenario: Fresh box logs in everywhere
- **WHEN** a box with RetroAchievements enabled, credentials in the
  secrets store and a reachable RetroAchievements API boots to the
  frontend
- **THEN** each supporting emulator's configuration carries the account
  name and a token the emulator accepts, DuckStation's in its encrypted
  at-rest form, and no configuration file anywhere contains the password

#### Scenario: DuckStation accepts the written token
- **WHEN** DuckStation starts after the system wrote its configuration
- **THEN** it treats the stored credentials as a valid saved login
  rather than prompting for one

### Requirement: Hardcore mode is one switch
The configuration SHALL expose a single hardcore option
(`emubox.retroachievements.hardcore`), default off, and every supporting
emulator's hardcore setting SHALL follow it. Off keeps save states,
rewind and cheats available.

#### Scenario: Default is off
- **WHEN** the host does not set the hardcore option and the frontend
  is about to launch
- **THEN** every supporting emulator's configuration has hardcore mode
  disabled

#### Scenario: Flipping the switch
- **WHEN** the host sets the hardcore option to true
- **THEN** every supporting emulator's configuration has hardcore mode
  enabled before the frontend launches

### Requirement: The network never blocks the session
The login SHALL be bounded by a short timeout, and its token SHALL be
cached on the box, so that after one successful login the box keeps
unlocking achievements-capable sessions without network access to the
RetroAchievements API. When no cached token exists and the API cannot be
reached, the session SHALL start normally with achievements simply
absent, and the failure SHALL be recorded in the journal. A reachable
API SHALL be consulted on every login, so a credential change on the
service side is noticed; the cached token serves only when the API
cannot be reached. When the API rejects the credentials, the cached
token SHALL be dropped so a later run with working credentials logs in
fresh, and the rejection SHALL be recorded in the journal. When
RetroAchievements is disabled, no login SHALL be attempted and every supporting emulator's
achievements feature SHALL be off; the account name and session token
SHALL additionally be removed from every configuration and cache that
holds them, so switching the feature off leaves no credential of the
account's on the box.

#### Scenario: Offline with a cached token
- **WHEN** the box boots with no route to the RetroAchievements API and
  a token cached from an earlier login
- **THEN** the frontend is up within its normal budget and each
  supporting emulator's configuration carries the cached token

#### Scenario: Offline with no cached token
- **WHEN** the box boots with no route to the RetroAchievements API and
  no cached token
- **THEN** the frontend is up within its normal budget, achievements are
  absent, and the journal records the failed login

#### Scenario: Rejected credentials drop the cache
- **WHEN** the box boots with a cached token and the RetroAchievements
  API rejects the login attempt
- **THEN** the cached token is deleted, the session starts with
  achievements absent, the journal records the rejection, and a later
  boot with working credentials and a reachable API logs in fresh

#### Scenario: Disabled
- **WHEN** RetroAchievements is disabled in the configuration
- **THEN** no request is made to the RetroAchievements API and each
  supporting emulator's configuration has achievements disabled

#### Scenario: Disabled after having been enabled
- **WHEN** RetroAchievements is disabled on a box that previously
  logged in
- **THEN** the account name and the session token are gone from every
  supporting emulator's configuration and from every file the system
  cached them in, so a box with the feature off is not holding the
  account's credentials
