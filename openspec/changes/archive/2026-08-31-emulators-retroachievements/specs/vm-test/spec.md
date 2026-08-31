## ADDED Requirements

### Requirement: Emulator launches and achievements are proven in the VM
The kiosk VM test (or a sibling node built from the same modules) SHALL
assert emulator behavior without hardware: for each BIOS-free core
family in the system table for which a freely redistributable homebrew
ROM exists, RetroArch SHALL run that ROM headless and the test SHALL
assert a successful exit and a
log line proving the core ran; each standalone emulator SHALL get a
smoke launch asserting the process starts against the asserted
configuration. A core family SHALL be exempt from the headless launch
when no ROM for it carries an explicit licence or redistribution grant
from its author, since the fixtures are fetched by a public CI run and
pushed through a public binary cache; or when the core cannot run
headless at all - a core that demands a hardware render context has no
VM to demand it of; or when the launch failed in a way nobody has yet
attributed to either the core or the fixture, which is an admission of
ignorance rather than a finding and SHALL be recorded as one. The
configuration SHALL name each exempt family, which reason applies, and
what would return it to the tested set, so an exemption is a deliberate
line someone added rather than a family the test quietly skipped, and so
no exemption is permanent merely because nothing prompts anyone to
revisit it. An exempt family is a hardware checklist item, like the
BIOS-dependent cores.
Chasing a headless launch for a core that resists one is explicitly not
required: the VM proves the configuration the flake writes, and an
emulator's own runtime behaviour is a checklist item by design.
Against a RetroAchievements endpoint mocked inside the
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
  a BIOS-free core family that has one
- **THEN** the run exits successfully and the log carries the expected
  line, and any family's failure fails the test

#### Scenario: A family with no redistributable ROM
- **WHEN** a BIOS-free core family has no ROM carrying an explicit
  licence or redistribution grant
- **THEN** the configuration names that family as exempt, the test
  launches nothing for it and stays green, and the family is covered by
  the hardware checklist instead

#### Scenario: A family whose failure nobody has explained
- **WHEN** a BIOS-free core family's headless launch fails and it is not
  known whether the core or the fixture is at fault
- **THEN** the configuration records the exemption as unattributed
  rather than as a property of the core, states what was actually
  observed, and names what would settle it

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

#### Scenario: A standalone that cannot be launched headless
- **WHEN** a standalone emulator cannot be started far enough under the
  VM's headless drivers to read its configuration
- **THEN** the test proves what it can - that the binary runs - and the
  configuration records that this one proves less than the others, and
  why, so the weaker check is a stated exception rather than an
  assertion that quietly means less than its neighbours

#### Scenario: Offline boot without a cache
- **WHEN** the VM test boots with RetroAchievements enabled, no cached
  token and no route to the mocked endpoint
- **THEN** the frontend still comes up, no supporting configuration
  carries the account name or token while each one's
  achievements-enabled and hardcore settings are written as declared,
  and the journal records the failed login
