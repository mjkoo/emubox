## ADDED Requirements

### Requirement: Emulator launches and achievements are proven in the VM
The kiosk VM test (or a sibling node built from the same modules) SHALL
assert emulator behavior without hardware: for each BIOS-free core
family in the system table, RetroArch SHALL run a freely redistributable
homebrew ROM headless and the test SHALL assert a successful exit and a
log line proving the core ran; each standalone emulator SHALL get a
smoke launch asserting the process starts against the asserted
configuration. Against a RetroAchievements endpoint mocked inside the
test network, the test SHALL assert that each supporting emulator's
configuration carries the account name and token - DuckStation's by
decrypting the stored value the way the pinned DuckStation version does
- that no configuration contains the password, and that the hardcore
option is reflected in every supporting configuration in both its
positions. The test
SHALL also boot with no cached token and no route to the endpoint and
assert the frontend still comes up with achievements absent and the
journal recording the failed login. Systems
whose core needs BIOS images, and real performance, remain hardware
checklist items, not VM assertions.

#### Scenario: Core families launch headless
- **WHEN** the VM test runs RetroArch headless with the homebrew ROM of
  a BIOS-free core family
- **THEN** the run exits successfully and the log carries the expected
  line, and any family's failure fails the test

#### Scenario: Tokens asserted against a mock
- **WHEN** the VM test boots with RetroAchievements enabled, test
  credentials and the mocked endpoint
- **THEN** every supporting emulator's configuration carries the mock's
  token in that emulator's at-rest form and no configuration carries the
  password

#### Scenario: Standalones smoke launch
- **WHEN** the VM test smoke-launches a standalone emulator against the
  asserted configuration
- **THEN** the process starts successfully, and any standalone's
  failure fails the test

#### Scenario: Offline boot without a cache
- **WHEN** the VM test boots with RetroAchievements enabled, no cached
  token and no route to the mocked endpoint
- **THEN** the frontend still comes up, no supporting configuration
  carries the account name or token while each one's
  achievements-enabled and hardcore settings are written as declared,
  and the journal records the failed login
