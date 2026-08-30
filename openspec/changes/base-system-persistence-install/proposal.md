## Why

The scaffold (E0) evaluates and boots in the VM, but every base-system and persistence behaviour is still a `TODO(design 4)` comment in the modules: root is not actually wiped, there are no secrets, the box would not join WiFi, and there is no repeatable install. Every later epic (kiosk, emulators, saves, remote) stands on a base that boots from a clean OS state each time, keeps exactly the listed state, and can decrypt secrets, so this is the first change after the scaffold and it must land before the VM test can grow.

## What Changes

- Ephemeral root made real: the `@root` btrfs subvolume is replaced by a blank one in the initrd on every boot, before any filesystem is mounted; `/persist` and `/data` are mounted early enough that persisted state is bound into the root and secrets are decrypted on every boot; the persisted list is finalized for this epic (later epics add their own entries); the `/data` directory layout is created on every boot.
- Secrets bootstrapped: the repository declares the admin's age recipient and the host's; an encrypted secrets file is created holding the WiFi credentials and the `admin` password hash; the box decrypts it at boot and `admin`'s password comes from it.
- Networking: the family's WiFi is a declared NetworkManager profile whose PSK comes from secrets, so the box joins the network on first boot at the family's house with no interaction; the firewall stays on with nothing listening on the LAN.
- Base system finished: HDMI as the default PipeWire sink, journald size caps, plus the settled boot/graphics/power/nix-gc options already in the scaffold are confirmed by the spec rather than left implicit.
- Install runbook: `nixos-anywhere` over Ethernet with the pre-generated host key injected into `/persist`, a post-install checklist, and a reinstall/disk-swap path ("run nixos-anywhere, restore `/data`"). Pushing configuration changes to the installed box is not part of this change: nothing listens on the LAN, so there is no path to push over until E10's tunnel, and E10 owns the deploy command.
- VM test grows from "boots" to: boots with the real bootloader path and a real btrfs layout, reboots, survives a power cut, and asserts that `/etc/machine-id` survives while a file dropped in `/root` does not, and that the sops secrets decrypt.
- No behaviour is removed. Hardware-only lines (i915 binds, HDMI audio actually plays, disk id, NIC variant) stay on the E12 bring-up checklist and are not gated here.

## Capabilities

### New Capabilities
- `persistence`: ephemeral OS root with an explicit, finite list of persisted state under `/persist`; the `/data` layout that user data lives in; what is deliberately not persisted.
- `secrets`: one sops file, its recipients, where the host decryption key lives, and the secrets this change consumes (WiFi PSK, admin password hash).
- `networking`: declarative WiFi from secrets, the firewall posture, what may listen where.
- `base-system`: boot loader and splash, graphics and audio defaults, power and sleep policy, Nix store hygiene, log caps.
- `install`: the install and reinstall procedure, its inputs, and the post-install checks.
- `vm-test`: what the CI VM test proves for this layer and how it exercises the bootloader and persistence paths.

### Modified Capabilities
- none (there are no main specs yet; E0 landed without any).

## Impact

- `modules/persistence`, `modules/secrets`, `modules/hardware` (base + networking), `modules/recovery` (admin password), `modules/library` (`/data` tmpfiles stays where it is), `hosts/emubox/disko.nix` (unchanged; its partition label is verified in the VM), `tests/default.nix`, `.sops.yaml`, `secrets/secrets.yaml` (new, encrypted), `secrets/README.md`, `README.md` (install runbook), `justfile` (secrets and install recipes), `tests/values.nix` (new, plaintext test values), `tests/test_host_ed25519_key{,.pub}` (new, committed test host key), `secrets/test.yaml` (new, encrypted to the test key), `.github/workflows/ci.yml` (KVM device access for the build users), `flake.nix` (the VM check is repointed at disko's install test on the host configuration, and a builder-side check that the test values are absent from the closure is added).
- Inputs already present (`impermanence`, `sops-nix`, `disko`, `nixos-anywhere` in the devShell); no new flake inputs.
- Admin-side, outside the repo: an age key for the admin and a pre-generated host SSH key, both kept out of git. The VM test requires KVM, which no local builder can offer (Apple Silicon cannot provide x86_64 KVM), so the test runs in CI: a GitHub repository with Actions is required from this change on (`ACCT`: GitHub, the admin's existing account), and the Mac's OrbStack builder covers everything short of the VM run.
- Independent of E2 (vendored packages); E3 and everything after depend on this change.
