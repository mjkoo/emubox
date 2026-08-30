# emubox

A NixOS retro-emulation appliance for a Beelink EQ14 (Intel N150): boots
straight into a controller-driven ES-DE game library, ephemeral OS root
with persistent family data on `/data`, RetroAchievements, versioned
off-site save backups, and remote administration over a Cloudflare Tunnel.

## Layout

```
flake.nix          inputs, nixosConfigurations.emubox, packages, checks, devShell
hosts/emubox/      the physical box: hardware facts, disko layout
modules/           the software stack, one directory per concern
overlays/, pkgs/   vendored packages (ES-DE, freeimage, DuckStation)
tests/             VM test module (disko install test), test values and test key
secrets/           sops files (encrypted); recipients in .sops.yaml
```

## Development

`direnv allow` (or `nix develop`) provides every tool the justfile needs;
`just` lists the recipes. `just check-all` runs everything that can run
on this machine: the formatting, flake check and evaluation steps CI runs,
plus the workflow lint. Evaluating the host and both Linux checks works
from macOS; building the host (`just build`, `just closure-check`) needs
an `x86_64-linux` builder, and the VM test (`just vm-test`) needs one that
exposes KVM. CI builds all of it on every push.

The `emubox` Cachix cache (`https://emubox.cachix.org`) holds what
cache.nixos.org never has: the unfree emulator cores and the vendored
packages, the flake's `cache-roots` output. CI pushes it after a green
run (`just cache-push` does the same by hand with `CACHIX_AUTH_TOKEN`
set), the box substitutes from it once `binaryCachePublicKey` is set in
`hosts/emubox/facts.nix`, and a local builder gains the same by adding the
cache to its own `nix.settings`.

## Install

One command over Ethernet installs or reinstalls the box from the flake,
the secrets file and the admin-held host key. The flake's hardware facts
(`hosts/emubox/facts.nix`, nixos-hardware) are authoritative; nothing is
generated on the box.

### Prerequisites

- The admin's age key at `~/.config/sops/age/keys.txt` (`age-keygen -o
  ~/.config/sops/age/keys.txt`), its public half as `admin` in
  `.sops.yaml`.
- The box's SSH host key: `just host-key` generates
  `~/.config/emubox/ssh_host_ed25519_key` if absent and prints the age
  recipient to put in `.sops.yaml` as `emubox` (set `EMUBOX_HOST_KEY` to
  keep it elsewhere). Keep both keys outside git and backed up together:
  the host key is the box's identity and its ability to decrypt
  `secrets/secrets.yaml`, so every install of this host uses the same one.
- `secrets/secrets.yaml` with the real WiFi SSID, PSK and admin password
  hash (`just secrets-edit`; the committed file holds placeholders, see
  `secrets/README.md`), re-keyed with `just secrets-rekey` after a
  recipient changes.
- The box booted from the stock NixOS installer ISO with root SSH access:
  in the live session run `sudo passwd` to set a root password, or put
  your public key in `/root/.ssh/authorized_keys`. nixos-anywhere connects
  as `root`.
- Ethernet between the box and the network, and Secure Boot off in the
  EQ14's firmware.

### The command

```
just install <box-address>
```

`just install` refuses to run while `secrets/secrets.yaml` still holds
placeholders, stages `persist/etc/ssh/ssh_host_ed25519_key{,.pub}` from
the host key and runs
`nixos-anywhere --flake .#emubox --extra-files <staging> root@<box>`:
the disk named in `hosts/emubox/facts.nix` is partitioned to the disko
layout (`@root @nix @persist @data @cache` on btrfs), the closure is
installed, the host key lands on `@persist`, and the box reboots into the
configuration with no further prompts. Further arguments are passed to
`nixos-anywhere`. Always install through the recipe: a box installed
without the staged key generates its own on first boot, that key is not a
recipient of the secrets file, and every secret then fails to decrypt,
which looks like a sops problem rather than a missing key.

From macOS the closure is built by the configured `x86_64-linux` builder
and copied to the box. Without a builder, nixos-anywhere detects that it
cannot build for the box and builds on it instead (`--build-on auto`, its
default); `just install <box> --build-on remote` forces that. The box then
compiles the few configuration derivations itself and substitutes the
rest, slow but correct.

### After the first boot

- Secrets decrypted: `sudo ls -l /run/secrets /run/secrets-for-users`
  shows `wifi_ssid`, `wifi_psk` and `admin_password_hash` (mode 0400; the
  directories are not readable without sudo). They are installed by an
  activation step, not a unit: `sudo journalctl -b | grep -i sops` shows
  its output, and a host key that does not match a recipient leaves the
  box at a console with the failing secret named there.
- WiFi profile present: `nmcli connection show family-wifi`, and the box
  joins the network when the SSID is in range.
- Ephemeral root: `sudo touch /root/marker`, reboot, the file is gone
  while `/etc/machine-id` is unchanged.
- `admin` logs in on a console with the password whose hash is in the
  secrets file: Ctrl-Alt-F3 switches to a free virtual console (the kiosk
  session holds one of the first two; a getty appears on any free one).
- No failed units: `systemctl --failed` is empty.

### Pushing configuration changes

Not provided by this layer: nothing on the box listens on the LAN, so
there is no address to push to. The tunnel and the `deploy` recipe arrive
with the remote-administration change. Until then a changed configuration
reaches the box by reinstalling (below, restoring `/data`), or by hand at
the recovery desktop: as `admin`, clone the repository somewhere that
survives a reboot (`/home/admin` is on the ephemeral root; `sudo mkdir
/data/admin && sudo chown admin /data/admin` makes a place that lasts),
copy in your edited `secrets/secrets.yaml` (a fresh clone has the
placeholders), and run `sudo nixos-rebuild switch --flake .#emubox` (sudo
needs no password).

### Reinstall and disk swap

Run `just install` again. With the same host key the secrets decrypt on
first boot with no change to `secrets/secrets.yaml` and existing
`known_hosts` entries stay valid. Then either restore `/data` from backup
or start with the empty, correctly laid out `/data` the first boot
creates. Nothing on the old disk is needed; a replacement disk only has to
appear at the path `hosts/emubox/facts.nix` names (a probe-order
`by-diskseq` path today, which holds for a single M.2; a stable `by-id`
path is a bring-up item once the real disk is known).

### If `/persist` or `/data` cannot be mounted

The boot stops in the initrd's emergency mode by design rather than
continuing with an empty root: both volumes are needed for boot, and a
root populated without them would have no persisted state, no secrets and
no user data. Fix the disk, or reinstall.
