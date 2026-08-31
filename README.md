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
overlays/, pkgs/   the packages the flake builds: vendored, and its own
tests/             VM tests (disko install, kiosk session), test values and key
secrets/           sops files (encrypted); recipients in .sops.yaml
```

## Development

`direnv allow` (or `nix develop`) provides every tool the justfile needs;
`just` lists the recipes. `just check-all` runs everything that can run
on this machine: the formatting, flake check and evaluation steps CI runs,
plus the workflow lint. Evaluating the host and the Linux checks works
from macOS; building the host (`just build`, `just closure-check`) needs
an `x86_64-linux` builder, and the two VM tests (`just vm-test` for the
disko install test, `just kiosk-test` for the kiosk session) need one that
exposes KVM. CI builds all of it on every push.

One local gap is worth knowing about: the kiosk session script is a
`writeShellApplication`, so shellcheck runs when it is *built*, and nothing
in `just check-all` builds anything. An edit to it can pass every check
macOS can run and still fail CI. `just session-check` builds just that
script on an `x86_64-linux` builder (no KVM, seconds rather than a closure)
and is the quick way to check it.

`emubox-prepare` is Python, so `nix flake check` and `nix fmt` cover more
than Nix. Its unit tests, `ruff check`, `ruff format --check` and `ty check`
run in the package's own `checkPhase`, and `checks.<system>.emubox-prepare`
is defined for every system, so `nix flake check` runs them natively on
macOS with no VM involved. `nix fmt` formats Python as well as Nix, and
`nix fmt -- --ci` (what `just fmt-check` and CI run) checks both.

The `emubox` Cachix cache (`https://emubox.cachix.org`) holds what
cache.nixos.org never has, the flake's `cache-roots` output, in three
kinds: the redistributable unfree emulator cores, the vendored packages,
and the programs this project writes itself. Every one of them carries a
licence permitting redistribution of the form pushed - for the cores that
is enforced by the selection, which admits only cores whose licence
metadata records that permission, rather than merely asserted. CI pushes it after a green
run (`just cache-push` does the same by hand with `CACHIX_AUTH_TOKEN`
set), the box substitutes from it once `binaryCachePublicKey` is set in
`hosts/emubox/facts.nix`, and a local builder gains the same by adding the
cache to its own `nix.settings`.

### Packages the flake builds

`pkgs/` holds what this project builds rather than takes from nixpkgs,
built against the flake's own nixpkgs and exposed both through the overlay
and as `packages.x86_64-linux.*`. Each `package.nix` opens with where it
came from and why it is here. Three are vendored, because the pinned
nixpkgs no longer carries them; the fourth is the project's own.

- `es-de`, the frontend, is built from source at release 3.4.1 with the
  in-app updater compiled out, from the derivation nixpkgs removed in PR
  #454867. The build fails if the installed find rules stop naming the
  NixOS RetroArch core directory.
- `freeimage` is ES-DE's only image backend and the reason nixpkgs removed
  both: it carries more than thirty unpatched CVEs, listed unchanged in
  its `knownVulnerabilities`, plus three small fixes forward against the
  newer libjpeg, OpenEXR and libtiff, recorded in its header. The flake
  permits it by name in `permittedInsecurePackages`; the accepted risk (it
  only ever decodes images the admin put on the box, and CI builds it
  whenever its inputs change) is recorded beside that permission in
  `flake.nix`.
- `duckstation` is the unmodified upstream `x86_64` AppImage of a pinned
  release, extracted and run inside an FHS wrapper, never built from
  patched source. nixpkgs dropped its derivation at upstream's request
  when the licence became CC-BY-NC-ND 4.0, which permits redistributing
  unmodified copies non-commercially with attribution and forbids
  derivatives; that is what lets the public cache hold it. To bump it,
  edit `version` in `pkgs/duckstation/package.nix`, set
  `hash = lib.fakeHash`, rebuild, and record the hash the failed fetch
  reports; nothing else in the file changes.
- `emubox-prepare` is not vendored: it is this project's own program, the
  config editor the kiosk session runs before every launch of the frontend
  (see below). One stdlib-only Python file, whose unit tests, lint and type
  check run in its build.

The repository itself is MIT licensed (`LICENSE`), which is what the
programs it writes carry onto the public cache. The vendored packages keep
their upstream licences, recorded in each `package.nix`.

## Kiosk session

Power-on reaches the game library with nobody touching a keyboard. SDDM
logs `player` in automatically and starts the `emubox` Wayland session,
whose script loops: assert the settings the flake owns, then run the
frontend full screen under the `cage` compositor. When ES-DE exits the
loop relaunches it after two seconds, so quitting a game or a crash
mid-play returns to the library rather than to a blank screen.

A frontend that cannot stay up ends somewhere a person can act. A run
shorter than 60 seconds counts as a crash; three in a row and the session
script exits. Because SDDM's autologin is configured for the first start
only (`relogin = false`), what appears then is its login greeter, not
another doomed relaunch. `admin` can log in there and read the journal,
choosing the recovery desktop from the greeter's session list rather than
the pre-selected `emubox` session, which is `player`'s. A reboot restores
automatic login and starts over.

The frontend runs in ES-DE's kiosk UI mode: no metadata editor, no
scraper, no collection editing, every game still launchable. The full menu
is behind an unlock sequence, `emubox.kiosk.passkey`, which defaults to
ES-DE's own `uuddlrlrba` until the host sets another. Kiosk mode is
reasserted before every launch, so unlocking the full menu once does not
leave the box unlocked after the next restart.

`emubox-prepare` is what asserts it. The flake owns exactly these ES-DE
settings - the UI mode, the unlock sequence, the ROM and media directories
under `/data`, the `linear-es-de` theme, the `en_US` language and the quit
menu - and leaves every other setting as the frontend last wrote it, so a
preference changed in ES-DE's own menus survives a reboot. A settings file
that cannot be read (truncated by a frontend killed mid-write, say) is
replaced rather than treated as a failure, because the alternative is the
family staring at a greeter.

`emubox.kiosk.customSystems` takes the complete contents of an ES-DE
custom `es_systems.xml`, `<systemList>` wrapper included, written verbatim
to `/data/es-de/custom_systems/`. Empty, its default, means no such file
exists and a stale one from an earlier configuration is removed.

Power off and reboot come from the frontend's own QUIT menu, each behind a
confirmation, and reach logind as `player` through a polkit rule. Upstream
ES-DE hides that menu entirely in kiosk mode, so `pkgs/es-de` carries a
patch that shows it and, in kiosk mode, offers only those two entries:
quitting the frontend would just be relaunched by the loop, and the box
refuses to suspend.

## BIOS files

Emulators read firmware and BIOS images from `/data/bios`, a directory
`modules/library` lays down as `2775 player player`: group `player` with the
setgid bit set, the same layout `/data/roms` uses and for the same reason -
whatever the admin copies in over SSH lands group-owned `player` with no
separate `chown` needed to make it readable by the session that runs as
`player`. The flake declares which files belong there as a nix attrset (a
short id, a path under `/data/bios`, a human name and a checksum with the
algorithm that produced it - sha256, md5 or crc32, matching whichever
algorithm the real published reference for that file actually uses),
rendered to `/etc/emubox/bios-inventory.json` on the running system. Getting
the actual files onto the box is still the admin's job - copyrighted BIOS
and firmware images are exactly what nothing in this repository or its
public cache may redistribute - the inventory only lets the box tell the
admin whether what they put there is the file it expects. A file under
`/data/bios` the inventory does not name is harmless: it is neither
validated nor required, only reported as an informational extra.

The inventory covers the systems that cannot run anything at all without
firmware. It does not (yet) cover three of them, and that gap is deliberate
rather than an oversight: PCSX2 validates a BIOS only by file size and an
internal `ROMVER` string, never a hash, so there is nothing to check
against; blueMSX needs whole `Databases`/`Machines` directory trees copied
from a full install rather than one file with one checksum; Arcade's BIOS is
a per-game board ROM set that lives beside each game's own files, not a
single fixed image an inventory entry can name. For systems that could in
principle be checked, an entry is only added once a source this project can
stand behind publishes a checksum for it - see
`modules/emulators/default.nix` for the current inventory and which systems
are still waiting on one.

Systems whose BIOS is optional are not declared either, and for a different
reason: they play games without it. Atari 7800 and GBA both run fine with no
BIOS image, and Dreamcast uses Flycast's HLE BIOS by default. Nothing in the
inventory names them, so `emubox-check-bios` will never ask for those files
or report them missing - an admin who drops one in gets an `EXTRA` line and
the emulator picks it up regardless.

### Checking what's there

`emubox-check-bios` reads the inventory and reports on `/data/bios` without
changing anything:

```
emubox-check-bios /etc/emubox/bios-inventory.json /data/bios
```

- `OK` - the file is present and its checksum matches.
- `MISMATCH` - the file is present but its checksum does not match; both the
  expected and the actual value are printed.
- `MISSING` - the file is absent, or present but unreadable.
- `EXTRA` - the file is present under `/data/bios` but not declared in the
  inventory; purely informational.

`EXTRA` lines never affect the exit status. The command exits successfully
only when every declared file is `OK`, and non-zero if anything declared is
`MISSING` or a `MISMATCH`, so a script can gate on it. It never writes to
`/data/bios` or anywhere else.

## RetroAchievements

One RetroAchievements account is shared by the whole box; there is no
per-player login. The credentials live in `secrets/secrets.yaml` as
`retroachievements_username` and `retroachievements_password`,
`REPLACE-BEFORE-INSTALL` placeholders in the committed file until an admin
fills them in with `just secrets-edit`; `just install` refuses to run while
either still holds a placeholder, the same guard that protects the WiFi and
admin-password secrets (see Install, below).

`emubox.retroachievements.enable` defaults to true and `.hardcore` defaults
to false: a freshly installed box with real credentials and a working
network unlocks achievements everywhere with nobody touching an emulator
menu, and hardcore's stricter rules (no save states, no rewind, no cheats)
are opt-in rather than the default. `emubox.retroachievements.apiUrl`
defaults to the real RetroAchievements API and only needs setting to point
`emubox-prepare`'s login at a different endpoint - a mock server in the
kiosk VM test, or a self-hosted RetroAchievements-compatible service; it
must be an `http://` or `https://` URL, since `emubox-prepare` posts the
login there directly. The account password itself never
reaches any emulator's configuration file - only the session token the
login exchanges it for does, and DuckStation gets that token in the
encrypted form it expects to find on disk rather than in plain text (see
the bump runbook in `pkgs/duckstation/package.nix` for the scheme).
Setting `emubox.retroachievements.enable = false` does more than stop new
logins: on the next launch it actively removes the account's credentials
from the box - the account name and session token in every supporting
emulator's configuration, PPSSPP's separate token file, and the cached login
token under `/data` - so switching the feature off takes the token off the
disk rather than leaving the last one there unused.

RetroAchievements being unreachable, offline, rejected, or simply disabled
all cost only the achievements: the frontend still starts on its normal
schedule, and a failed or skipped login is recorded in the journal rather
than shown to whoever is holding the controller.

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

## Bring-up checklist

Items that need the physical box, the real TV or a controller in hand, and
so are settled at bring-up rather than in CI. The `TODO(bring-up)` comments
in `hosts/emubox/facts.nix` mark the two facts; this list is where the rest
live, and there is no second list. Where an item exists because a test
stopped short of covering something, the evidence for stopping lives beside
that test and is linked from the item - the item itself is still here, so
this list stays the one place to read what is unproven.

- The four USB-A `ID_PATH` values in physical port order, and the connector
  the TV is actually on (`hdmiOutput`): both `TODO(bring-up)` in
  `hosts/emubox/facts.nix`.
- A stable `by-id` disk path replacing today's probe-order
  `by-diskseq` one, once the real disk is known (see "Reinstall and disk
  swap").
- Boot time under 30 seconds, measured power-on to the frontend being
  usable. This is the end-to-end number for a person waiting in front of
  the TV; it is not the kiosk session's 60-second crash window, nor the
  kiosk VM test's 120-second wait budget, and none of the three is derived
  from the others.
- The TV's native mode driven without overscan or rescaling.
- Power off from the patched quit menu, chosen on a controller, on the real
  TV: that the menu applies is proven by the build, but how it looks and
  that the sequence works end to end is not.
- The unlock sequence entered on a controller. The kiosk VM test proves the
  configured passkey reaches the settings file; that entering it unlocks
  the full menu is ES-DE's own behaviour and needs real input.
- One game launched per system that needs firmware, once the files are in
  `/data/bios` and `emubox-check-bios` reports them `OK`. Nothing in CI can
  load any of these, because neither this repository nor its cache may
  carry the firmware: Atari Lynx, Famicom Disk System, Sega CD, Saturn,
  PS1, PC Engine CD, Arcade, Nintendo DS, PS2, Amiga, MSX, Intellivision
  and ColecoVision. A clean `emubox-check-bios` is not evidence for PS2,
  MSX, ColecoVision or Arcade in particular: the inventory declares nothing
  for those four on purpose, for the reasons the BIOS section above gives,
  so their firmware is unchecked as well as unproven.
- One game launched per core family the kiosk VM test names exempt from its
  headless launches. Six of the eighteen BIOS-free families never actually
  run a ROM in CI: Atari 7800 and Neo Geo Pocket, for want of a homebrew
  ROM carrying an author's own licence; N64, Dreamcast and Vectrex, whose
  cores force a real GL or Vulkan driver that a headless VM has none of;
  and SNES, where the fixture hangs for a reason nobody has yet pinned on
  either the core or that particular ROM. `exemptFamilies` in
  `tests/kiosk.nix` carries each family's evidence and what would return it
  to CI.
- ScummVM and DuckStation coming up full screen against their written
  configuration. The other four standalones are smoke-launched against
  theirs in the VM; these two cannot be. ScummVM only answers `--version`,
  which never opens `scummvm.ini`, and DuckStation crashes constructing its
  QApplication before it reads argv at all, so CI proves only that the
  binary runs.
- A RetroAchievements achievement actually unlocking, on RetroArch and on
  DuckStation. The kiosk VM test asserts what the flake wrote - RetroArch's,
  Dolphin's and PCSX2's tokens read back from their settings files,
  PPSSPP's from the raw file it keeps its token in, and DuckStation's by
  decrypting it with a second implementation of the scheme - which is not
  the same as any emulator accepting one. DuckStation is the one to check
  first: its token is the only one this project encrypts itself, so it is
  the only one a future DuckStation bump could silently invalidate.
- Real performance per system. The VM asserts that PCSX2 is set to native
  internal resolution and DuckStation to PGXP with upscaling, never that
  either holds frame rate on this box's iGPU. A system that disappoints
  here is settled by changing its values in `modules/emulators`, not by
  anything CI can catch first.
