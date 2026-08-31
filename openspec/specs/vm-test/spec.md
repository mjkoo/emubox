## Purpose

CI proves what the host configuration guarantees on every push, without hardware. In a VM twice over: through the same boot path the real box uses, for the base layer's ephemeral root, persisted state, secrets and networking declaration and the presence of the programs the box installs; and on a plain node with a graphical stack, for the kiosk session. Outside a VM once: the config editor's unit tests, lint and type check, which run on every system the flake is checked on, the admin's Mac included.

## Requirements

### Requirement: The VM boots through the real boot path
The VM test SHALL boot its node through the UEFI boot loader and the initrd, on a disk that carries the same btrfs subvolume layout as the box, so that the root rollback and the early mounts are exercised rather than bypassed.

#### Scenario: Layout matches the box
- **WHEN** the test node has booted
- **THEN** `/`, `/nix`, `/persist`, `/data` and `/data/cache` are each a btrfs subvolume mount, and the boot went through the boot loader rather than a direct kernel load

### Requirement: Persistence is proven across a reboot
The test SHALL boot the node, record `/etc/machine-id`, write a marker under `/root` and a marker under `/data`, reboot, and assert the `/root` marker is gone, the `/data` marker remains, the machine-id is unchanged and the journal lists two boots. It SHALL then cut the node's power without a clean shutdown and assert the node boots again with the root wiped.

#### Scenario: Two-boot assertion
- **WHEN** the test reboots the node after writing the markers
- **THEN** all four assertions hold

#### Scenario: Power cut
- **WHEN** a marker is written under `/root` and the node is stopped without a clean shutdown, then started
- **THEN** the node reaches multi-user with no filesystem repair prompt and the marker is gone

### Requirement: Secrets decrypt in the VM
The test node SHALL decrypt a test-only secrets file holding non-secret test values, encrypted to a test SSH host key committed for that purpose and converted to age the way the box's own key is, and the test SHALL assert the declared secrets exist with the expected values and modes and that `admin` can log in with the test password.

#### Scenario: Test secrets present
- **WHEN** the test node has booted
- **THEN** the WiFi PSK and admin password secrets exist on the runtime path with the declared owner and mode

#### Scenario: Closure carries no test secret
- **WHEN** the closure of the host configuration extended with the test module is built
- **THEN** a builder-side check over that closure finds neither the test PSK nor the test password hash in any store path

#### Scenario: Admin console login
- **WHEN** the test logs in as `admin` on a virtual console with the test password
- **THEN** a shell prompt is reached

### Requirement: Networking declaration is proven
The test SHALL assert the family WiFi profile is listed by the network manager with the PSK substituted from the test secret, and that no non-loopback listener other than the DHCP client's exists.

#### Scenario: Profile and listeners
- **WHEN** the test node has booted
- **THEN** the declared profile is listed, its generated connection file carries the test PSK, and every listening TCP socket, and every UDP socket other than the DHCP client's, is bound to loopback

### Requirement: Vendored programs are installed in the booted system
The test SHALL assert, on the booted node, that the frontend and the vendored emulator are installed on the system's program path and that the frontend reports the pinned version, so that a package that fails to build or is dropped from the host closure fails CI rather than being discovered on the box.

#### Scenario: Programs present
- **WHEN** the test node has booted
- **THEN** `es-de` and `duckstation` are executable files on the system's program path

#### Scenario: Frontend version
- **WHEN** the test runs `es-de --version` on the booted node, which has no display
- **THEN** the command succeeds and its output contains `ES-DE 3.4.1`

### Requirement: The kiosk session is proven in a second VM
A second VM test SHALL boot the host's software modules as a plain test node with a graphical stack (no disk layout, no boot loader, enough memory for the frontend, a virtual GPU) and SHALL assert, on that node: the display manager active, `player` holding the seat's active session, the frontend running inside the compositor within the test's startup budget, the settings file carrying the flake-owned values including the unlock sequence the configuration declares, the custom systems file present for a non-empty definition and absent for an empty one, a relaunch after the frontend is killed, a reboot returning to the frontend, and, after three consecutive short runs, no frontend running with the display manager still serving a login. The `kiosk` capability owns the constants these assertions check against; the wait budgets and test-only thresholds it uses to do so are implementation choices of the test, not requirements. The install test is unchanged by this requirement and keeps its display manager off. Which VM tests `nix flake check` runs, and that each is runnable on its own, is stated once by the "The test runs in CI and locally" requirement and is not restated here.

#### Scenario: Session assertions
- **WHEN** the kiosk test node has booted
- **THEN** each behaviour this requirement lists is asserted on that node, and the test fails if any assertion does not hold

### Requirement: The config editor is tested without a VM
The program that seeds and asserts configuration files SHALL be unit-tested, linted and type-checked as part of its build, and those checks SHALL run under `nix flake check` on every system the flake is checked on, including the admin's macOS machine.

#### Scenario: Editor checks on macOS
- **WHEN** `nix flake check` runs on the admin's macOS machine
- **THEN** the config editor's tests, lint and type check run and their failure fails the check

### Requirement: The test runs in CI and locally
Each VM test SHALL be part of `nix flake check` so CI runs it on every push, and SHALL be runnable with a documented recipe on any `x86_64-linux` builder that exposes KVM; CI's runner is the one the tests are built on, and no local KVM builder is assumed.

#### Scenario: CI runs the test
- **WHEN** a push to `main` or a pull request runs CI
- **THEN** every VM test the flake defines is built and any one's failure fails the job

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
