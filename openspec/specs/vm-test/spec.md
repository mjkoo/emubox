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
