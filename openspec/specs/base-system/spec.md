## Purpose

The settled OS-level policies of the appliance: how it boots, what it shows and plays by default, how it treats power, and how it keeps its disk and logs bounded.

## Requirements

### Requirement: Silent UEFI boot with reachable rollback
The box SHALL boot with a UEFI boot loader that keeps at most 10 generations, shows no menu unless a key is held, and shows a graphical splash instead of kernel or console text.

#### Scenario: Normal boot shows no text
- **WHEN** the box is powered on with no key held
- **THEN** no boot menu is shown, the kernel logs nothing at error level or less severe to the console, and a splash is displayed until the session starts

#### Scenario: A previous generation is reachable
- **WHEN** a key is held during power-on
- **THEN** a boot menu lists the retained generations, and no more than 10 are retained

### Requirement: HDMI is the default audio output
When an HDMI audio sink is present it SHALL be the default sink for new audio streams, by declaration rather than by remembered choice, so a fresh root or a re-plugged cable does not route audio elsewhere.

#### Scenario: HDMI sink selected at boot
- **WHEN** the system boots with an HDMI sink available
- **THEN** the default sink is the HDMI sink

### Requirement: The box is either on or off
Suspend, hibernate and hybrid sleep SHALL be impossible; pressing the power button SHALL power the box off immediately; cutting power SHALL be a supported way to turn it off.

#### Scenario: Suspend is refused
- **WHEN** a suspend is requested
- **THEN** the request is refused and the system stays up

#### Scenario: Power cut then boot
- **WHEN** power is cut while the system is running and then restored
- **THEN** the next boot reaches the same state as after a clean shutdown with no repair prompt

### Requirement: A hung kernel resets the box
A hardware watchdog SHALL be armed so that a kernel hang of more than 30 seconds results in a reset rather than a frozen screen.

#### Scenario: Watchdog armed
- **WHEN** the system is running
- **THEN** the service manager reports a runtime watchdog of 30 seconds

### Requirement: Disk and log usage stay bounded
Old system generations SHALL be collected automatically, the store SHALL be de-duplicated automatically, the journal SHALL be size-capped and persistent, memory-backed swap SHALL be used instead of disk swap, and the SSD SHALL be trimmed periodically.

#### Scenario: Hygiene timers exist
- **WHEN** the system is running
- **THEN** timers for garbage collection, store optimisation and trim are active, swap is memory-backed, and the journal's on-disk cap is in effect

### Requirement: Intel graphics and firmware are provided
The system SHALL ship the Intel media driver, the VPL runtime, redistributable firmware and CPU microcode so the N150's GPU and WiFi work without manual driver steps.

#### Scenario: Driver set in the closure
- **WHEN** the system closure is built
- **THEN** the graphics driver set includes the Intel media driver and the VPL runtime, and firmware and microcode updates are enabled

### Requirement: Locale and time zone
The system SHALL use the `en_US.UTF-8` locale and the `America/New_York` time zone.

#### Scenario: Time zone applied
- **WHEN** the current time is queried on the box
- **THEN** it is reported in Eastern time
