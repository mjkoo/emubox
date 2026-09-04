## MODIFIED Requirements

### Requirement: The kiosk session is proven in a second VM
A second VM test SHALL boot the host's software modules as a plain test node with a graphical stack (no disk layout, no boot loader, enough memory for the frontend, a virtual GPU) and SHALL assert, on that node: the display manager active, `player` holding the seat's active session, the frontend running inside the compositor within the test's startup budget, the settings file carrying the flake-owned values including the unlock sequence the configuration declares, a seeded frontend setting changed between boots still holding the changed value after the reboot, the custom systems file present for a non-empty definition and absent for an empty one, a relaunch after the frontend is killed, a reboot returning to the frontend, and, after three consecutive short runs, no frontend running with the display manager still serving a login. The `kiosk` capability owns the constants these assertions check against; the wait budgets and test-only thresholds it uses to do so are implementation choices of the test, not requirements. The install test is unchanged by this requirement and keeps its display manager off. Which VM tests `nix flake check` runs, and that each is runnable on its own, is stated once by the "The test runs in CI and locally" requirement and is not restated here.

#### Scenario: Session assertions
- **WHEN** the kiosk test node has booted
- **THEN** each behaviour this requirement lists is asserted on that node, and the test fails if any assertion does not hold

#### Scenario: Seeded survival assertion
- **WHEN** the kiosk test changes a seeded frontend setting's entry in the settings file between boots and reboots the node
- **THEN** the test asserts the changed value is still in the settings file after the frontend is up again, and fails if it was reverted
