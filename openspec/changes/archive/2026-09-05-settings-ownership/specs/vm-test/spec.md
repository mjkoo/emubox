## MODIFIED Requirements

### Requirement: The kiosk session is proven in a second VM
A second VM test SHALL boot the host's software modules as a plain test node with a graphical stack (no disk layout, no boot loader, enough memory for the frontend, a virtual GPU) and SHALL assert, on that node: the display manager active, `player` holding the seat's active session, the frontend running inside the compositor within the test's startup budget, the settings file carrying the flake-owned values including the unlock sequence the configuration declares (enforced values by value, seeded values by presence), a seeded frontend setting changed while the frontend is stopped still holding the changed value after the reboot, RetroArch's launch-delivered settings winning at runtime over a stale copy in `retroarch.cfg`, the custom systems file present for a non-empty definition and absent for an empty one, a relaunch after the frontend is killed, a reboot returning to the frontend, and, after three consecutive short runs, no frontend running with the display manager still serving a login. A headless launch of RetroArch that the test performs with launch-time configuration of its own SHALL join that configuration onto the flake's launch-time configuration in the one place RetroArch reads it from, rather than replacing the flake's, and the flake's configuration it joins onto SHALL be the one the node's RetroArch wrapper actually passes, not a copy the test derives for itself; a launch that discarded the flake's configuration would prove nothing about it. The `kiosk` capability owns the constants these assertions check against; the wait budgets and test-only thresholds it uses to do so are implementation choices of the test, not requirements. The install test is unchanged by this requirement and keeps its display manager off. Which VM tests `nix flake check` runs, and that each is runnable on its own, is stated once by the "The test runs in CI and locally" requirement and is not restated here.

#### Scenario: Session assertions
- **WHEN** the kiosk test node has booted
- **THEN** each behaviour this requirement lists is asserted on that node, and the test fails if any assertion does not hold

#### Scenario: Seeded survival assertion
- **WHEN** the kiosk test, with the frontend stopped and the session at the greeter, changes a seeded frontend setting's entry in the settings file to a value the frontend accepts, then reboots the node
- **THEN** the test asserts the changed value is still in the settings file once the frontend is up again, and fails if it was reverted

#### Scenario: Launch-delivered settings win at runtime
- **WHEN** the kiosk test writes a stale value for one of RetroArch's launch-delivered settings into `retroarch.cfg` and then launches RetroArch headless with the flake's launch-time configuration in effect
- **THEN** the test asserts the value in effect after that launch is the flake's, and fails if the stale value was in effect
