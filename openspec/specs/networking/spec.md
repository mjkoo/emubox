## Purpose

The box joins the family's WiFi from declared configuration with no interaction at first boot, and exposes nothing on the family LAN.

## Requirements

### Requirement: The family WiFi is a declared connection
The system SHALL carry a network profile for the family's SSID that exists on every boot without anyone creating it, connects automatically when the SSID is in range, and takes its pre-shared key from the secrets file at runtime. The PSK SHALL NOT be in the Nix store or the repository as plaintext.

#### Scenario: First boot at the family's house
- **WHEN** the box is powered on with the family's SSID in range and no network has ever been configured on this root
- **THEN** it obtains an address on that network within 60 seconds with no user action

#### Scenario: The profile survives the root wipe
- **WHEN** the machine reboots
- **THEN** the declared profile is still listed by the network manager before any user logs in

#### Scenario: The PSK is only on the runtime path
- **WHEN** the Nix store and the repository are searched for the PSK
- **THEN** the box's PSK appears only in the encrypted secrets file and the runtime-generated connection file; the committed test values do not count, per the secrets capability's carve-out

### Requirement: Wired Ethernet is managed too
A wired link SHALL be brought up with DHCP automatically whenever a cable is present, so the install and any later wired session need no configuration.

#### Scenario: Cable plugged in
- **WHEN** an Ethernet cable with a DHCP server behind it is connected
- **THEN** the link obtains an address without user action

### Requirement: Nothing listens on the LAN
The firewall SHALL be enabled with no inbound ports opened on any non-loopback interface. Any service that must accept connections SHALL bind to loopback only.

#### Scenario: No LAN-facing listeners
- **WHEN** the listening TCP and UDP sockets are enumerated on a running system
- **THEN** every TCP listener, and every UDP listener other than the DHCP client's, is bound to a loopback address, and the firewall's allowed-port set is empty
