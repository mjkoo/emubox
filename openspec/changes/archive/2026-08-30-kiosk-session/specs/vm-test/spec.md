## ADDED Requirements

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

## MODIFIED Requirements

### Requirement: The test runs in CI and locally
Each VM test SHALL be part of `nix flake check` so CI runs it on every push, and SHALL be runnable with a documented recipe on any `x86_64-linux` builder that exposes KVM; CI's runner is the one the tests are built on, and no local KVM builder is assumed.

#### Scenario: CI runs the test
- **WHEN** a push to `main` or a pull request runs CI
- **THEN** every VM test the flake defines is built and any one's failure fails the job
