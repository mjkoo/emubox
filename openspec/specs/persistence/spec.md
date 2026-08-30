## Purpose

The operating-system root starts blank on every boot, an explicit and finite list of OS state survives under `/persist`, and the family's data lives on `/data`, outside the wipe mechanism, so that nothing save-like can ever be on an ephemeral path.

## Requirements

### Requirement: The OS root is ephemeral
Every boot SHALL start from an empty root filesystem: any file written to a path that is not in the persisted list, and not on `/nix`, `/persist`, `/data` or the `/boot` ESP, SHALL be gone at the next boot. The wipe SHALL happen before the root is used, not during shutdown, so that cutting the power cannot skip it.

#### Scenario: A file under /root does not survive a reboot
- **WHEN** a file is created under `/root` and the machine is rebooted (cleanly or by cutting power)
- **THEN** the file does not exist after the reboot

#### Scenario: Drift under /etc does not accumulate
- **WHEN** a file is created under `/etc` at a path the configuration does not manage or persist, and the machine reboots
- **THEN** the file does not exist after the reboot

### Requirement: Listed OS state survives reboots
The following SHALL persist across reboots: `/etc/machine-id`, the ed25519 SSH host key, `/var/lib/nixos`, `/var/lib/systemd`, `/var/lib/bluetooth`, `/var/lib/NetworkManager`, `/var/log`, and `/var/lib/emubox`. The persisted list SHALL be declared in one place so a later change can extend it.

#### Scenario: machine-id is stable
- **WHEN** the machine boots twice
- **THEN** `/etc/machine-id` has the same content on both boots

#### Scenario: Logs from the previous boot remain readable
- **WHEN** the machine has booted at least twice
- **THEN** the journal lists both boots and the previous boot's entries can be read

#### Scenario: Persistent timers keep their stamps
- **WHEN** a `Persistent=true` timer has fired and the machine reboots
- **THEN** the timer's last-trigger stamp is still present so a missed run is detected rather than repeated or skipped

### Requirement: Persistent volumes are mounted before the root is populated
`/persist` and `/data` SHALL be mounted early enough that the persisted state is bound into the root, secrets are decrypted, and users are created on every boot. `/persist` and `/data` SHALL be treated alike: a boot on which either cannot be mounted SHALL stop in the initrd rather than continue with an empty root.

#### Scenario: Persisted paths are bind-mounted at boot
- **WHEN** the system reaches multi-user
- **THEN** each persisted directory and file resolves to storage under `/persist`, and `/data` is a mounted filesystem rather than a directory on the root

#### Scenario: A missing persistent volume stops the boot
- **WHEN** the `/persist` or the `/data` volume cannot be mounted
- **THEN** the initrd enters emergency mode and the boot does not proceed to the normal target or the graphical session; no root is populated and no service that consumes persisted state or secrets starts

### Requirement: The /data layout exists from the first boot
On every boot the system SHALL ensure the `/data` layout exists with the declared ownership: `home/`, `roms/`, `bios/`, `saves/`, `es-de/`, `media/`, `cache/`, with the `player` account owning what it writes to, and `player`'s home at `/data/home/player`.

#### Scenario: First boot on an empty /data
- **WHEN** the system boots with an empty `/data`
- **THEN** every declared directory exists with the declared owner and mode, and `player`'s home directory exists under `/data/home/player`

#### Scenario: Data under /data survives a reboot
- **WHEN** a file is written under `/data/home/player` and the machine reboots
- **THEN** the file still exists with the same content

### Requirement: Runtime-only state is not persisted
`/tmp` SHALL be empty at boot and `/run` SHALL be a memory-backed filesystem, so that flags written there (such as the session mode flag) never outlive a boot.

#### Scenario: /tmp is clean at boot
- **WHEN** a file is written under `/tmp` and the machine reboots
- **THEN** the file does not exist after the reboot
