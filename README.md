# emubox

A NixOS retro-emulation appliance for a Beelink EQ14 (Intel N150): boots
straight into a controller-driven ES-DE game library, ephemeral OS root
with persistent family data on `/data`, RetroAchievements, versioned
off-site save backups, and remote administration over Tailscale.

## Layout

```
flake.nix          inputs, nixosConfigurations.emubox, packages, checks, devShell
hosts/emubox/      the physical box: hardware facts, disko layout
modules/           the software stack, one directory per concern
modules/library/   scraping, generation, ingest permissions and status
overlays/, pkgs/   the packages the flake builds: vendored, and its own
pkgs/emubox-library/  unprivileged library commands and their tests
tests/             VM tests (disko install, kiosk session, controllers, mode switching), test values and key
secrets/           sops files (encrypted); recipients in .sops.yaml
```

## Development

`direnv allow` (or `nix develop`) provides every tool the justfile needs;
`just` lists the recipes. `just check-all` runs everything that can run
on this machine: the formatting, flake check and evaluation steps CI runs,
plus the workflow lint. Evaluating the host and the Linux checks works
from macOS; building the host (`just build`, `just closure-check`) needs
an `x86_64-linux` builder, and the VM tests (`just vm-test` for the
disko install test, `just kiosk-test` for the kiosk session, `just
controllers-test` for the controllers node, and `just mode-test` for mode
switching, plus `just library-test` for nonvisual library integration) need one
that exposes KVM. CI builds all of it on every push.

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
nixpkgs no longer carries them; the rest are the project's own.

- `es-de`, the frontend, is built from source at release 3.4.1 with the
  in-app updater compiled out, from the derivation nixpkgs removed in PR
  #454867. The build fails if the installed find rules stop naming the
  NixOS RetroArch core directory.
- `freeimage` is ES-DE's only image backend and the reason nixpkgs removed
  both: it carries more than thirty unpatched CVEs, listed unchanged in
  its `knownVulnerabilities`, plus three small fixes forward against the
  newer libjpeg, OpenEXR and libtiff, recorded in its header. The flake
  permits it by name in `permittedInsecurePackages`. External ScreenScraper
  artwork, including household-triggered downloads, reaches this vulnerable
  decoder. That accepted risk is recorded in `flake.nix`; CI build checks
  do not make those inputs trusted.
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
  (see below). One Python file over a small pinned closure - `cryptography`
  for the DuckStation token transform, the standard library for the
  settings files it edits - whose unit tests, lint and type check run in
  its build.
- `emubox-check-bios`, `emubox-save-migrate`, `emubox-restic-backup`,
  `emubox-status` and `emubox-controllers-status` are the project's own
  too, each a small Python program whose unit tests, lint and type check
  run in its build the same way.

The repository itself is MIT licensed (`LICENSE`), which is what the
programs it writes carry onto the public cache. The vendored packages keep
their upstream licences, recorded in each `package.nix`.

## Kiosk session

Power-on into the normal boot entry reaches the game library with nobody
touching a keyboard. SDDM logs `player` in automatically and starts the
`emubox` Wayland session,
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
the pre-selected `emubox` session, which is `player`'s. On a healthy box,
`emubox-mode desktop` provides the switch without waiting for a crash; see
[Desktop and recovery](#desktop-and-recovery) for the administrator route.
The greeter and recovery boot entry remain the routes when the session
cannot be trusted. A reboot into the normal entry restores automatic login
and starts over.

The frontend runs in ES-DE's kiosk UI mode: no metadata editor, no
scraper, no collection editing, every game still launchable. The full menu
is behind an unlock sequence, `emubox.kiosk.passkey`, which defaults to
ES-DE's own `uuddlrlrba` until the host sets another. Kiosk mode is
reasserted before every launch, so unlocking the full menu once does not
leave the box unlocked after the next restart.

`emubox-prepare` is what asserts it, and it owns a setting in one of two
tiers. Enforced settings are written if missing and corrected before
every launch: the UI mode, the unlock sequence, the ROM and media
directories under `/data`, and the quit menu. Seeded settings are
written only when the file has no entry for them and then left alone
forever: the `linear-es-de` theme and the `en_US` language, so an admin who
picks another theme or language in ES-DE's own menus keeps it. Every
setting the flake does not own stays as the frontend last wrote it, so a
preference changed in ES-DE's own menus survives a reboot. A settings file
that cannot be read (truncated by a frontend killed mid-write, say) is
replaced rather than treated as a failure, because the alternative is the
family staring at a greeter - and that replacement is the one case where a
seeded setting returns to the flake's default.

The same two tiers govern the emulators' own configuration files.
Fullscreen, the BIOS and core directories, the first-run wizards and the
two controller button combos that open the menu and quit a game - the
core-based frontend's only controller-only routes out of a running game -
are enforced. RetroArch's menu skin and its keyboard hotkeys, and the
per-emulator performance choices (Wii dual core off in Dolphin, native
internal resolution in PCSX2, geometry correction and upscaling in
DuckStation), are seeded: tuning a player may change in an emulator's own
menus and keep. RetroArch's eight static enforced settings reach it
through a read-only file the flake's wrapper passes at every launch rather
than through `retroarch.cfg`, so a stale copy there loses without being
edited. RetroArch's `udev` joypad driver does not read the recorded port
order, so that order is not promised to reach it.

Every standalone emulator but Azahar gains its own controller-only route
back to the frontend, and none of them asks for confirmation first.
Dolphin, PCSX2 and DuckStation stop on Back and Start pressed together. On
PPSSPP, Back and Start together open its pause menu, whose last entry,
Exit, ends it (that entry exists because the frontend launches PPSSPP with
`--pause-menu-exit`). ScummVM stops on Guide; in the handful of engines
whose own keymaps take Guide for something else, press Start to open
ScummVM's main menu instead, then move the pointer to Quit with the left
stick and press A. Dolphin's route back arrives only once bring-up records the
pad's SDL device name, since its `Device` lines must name the pad itself;
until then it has neither its gameplay bindings nor its route back. Azahar
has no pad-bindable route back at the pinned version, since it persists
hotkeys as keyboard key sequences rather than controller input; that gap
is deferred to a later change.

`emubox.kiosk.customSystems` takes a list of unwrapped ES-DE `<system>`
fragments. Modules can each contribute definitions; the kiosk combines them
under one `<systemList>` and writes the result to
`/data/es-de/custom_systems/`. An empty list, the default, removes a stale
file from an earlier configuration. For example:

```nix
emubox.kiosk.customSystems = [
  ''
    <system>
      <name>example</name>
      <fullname>Example</fullname>
      <path>/data/roms/example</path>
      <extension>.example</extension>
      <command>/bin/true %ROM%</command>
      <platform>example</platform>
      <theme>example</theme>
    </system>
  ''
];
```

Power off and reboot come from the frontend's own QUIT menu, each behind a
confirmation, and reach logind as `player` through a polkit rule. Upstream
ES-DE hides that menu entirely in kiosk mode, so `pkgs/es-de` carries a
patch that shows it and, in kiosk mode, offers only those two entries:
quitting the frontend would just be relaunched by the loop, and the box
refuses to suspend.

## Desktop and recovery

`emubox-mode` switches the running box without a reboot. It takes exactly
one argument: `desktop` for Plasma or `kiosk` for the game library. The
command needs root; `admin` reaches root through passwordless sudo. On a
healthy box the route is a keyboard and a virtual console: attach a keyboard
(the box is otherwise driven by controllers), press Ctrl-Alt-F6 from the
game library or from inside a game, log in as `admin` and run
`sudo emubox-mode desktop`. The sixth console is the one to use: it is
reserved for a login prompt, where a lower one may be the display manager's.
Only an account with a password gets past that prompt, and `player` has none;
Ctrl-Alt-F1, or Ctrl-Alt-F2 if the first shows nothing, returns to the game
library as it was left. There is no switch in the frontend and no network
shell provided by this feature.

The desktop on the TV runs as `player`. From a terminal there, first run
`su - admin` and enter the administrator password, then run
`sudo emubox-mode kiosk` to return to the game library. Sudo at that point
needs no password. `sudo emubox-mode desktop` uses the same route to request
a fresh desktop session.

The command warns that the current graphical session will end. A successful
exit reports only that the mode was recorded and the display-manager restart
was accepted; it does not confirm what has appeared on the TV. A refusal or
failure names what went wrong and which mode the next automatic session will
start. Wait for the new screen before running `emubox-mode` again: a second
switch while the display manager is still logging `player` in can leave the
TV with no session and no login prompt until the box is rebooted.

The desktop consumes its selection when it starts. Ending it leaves a login
prompt, without starting the frontend or arranging a later session to return
to the desktop. On a system using the normal boot entry, `emubox-mode kiosk`
or a display-manager restart brings the game library back. Rebooting into
the normal boot entry also brings it back.

If the session cannot be trusted, use the greeter or the recovery entry in
the boot menu. That entry disables automatic login and pre-selects Plasma:
it reaches a login prompt and starts no frontend. Log in there to reach the
desktop; `emubox-mode` refuses in that configuration because nothing would
read its selection. No mode selection survives a reboot through either entry.

## Library

`modules/library` configures ingest permissions, scraping and generation;
`pkgs/emubox-library` provides `emubox-scrape`, `emubox-library-generate`
and the `library` status reporter. Scraping is manual. There is no timer or
ROM-directory watcher, and a failed fetch can be resumed with the same command.

The route available on the box today uses removable media. From the admin's
console, run `sudo emubox-mode desktop` as described under Desktop and recovery.
In the session account's desktop, mount the media and create each destination
system folder first, using the file manager's New Folder action or a terminal:

```sh
mkdir -p /data/roms/nes
cp /run/media/player/MY_USB/nes/*.nes /data/roms/nes/
```

Replace the media path and system name with yours. Copy the game files into
the created folder. Copying a whole folder reproduces its source permissions
and can leave `admin` unable to write into it; the root's default ACL makes a
folder created with plain `mkdir` writable by the admin. It does not repair
existing directories or directories created with restrictive explicit modes.
The destination's setgid bit gives new files the `player` group.

Once remote administration is configured, the SSH route from another machine
is:

```sh
ssh admin@emubox 'mkdir -p /data/roms/nes'
rsync -rt --no-perms --no-owner --no-group --chmod=ugo+rX,Dg+w ./nes/ admin@emubox:/data/roms/nes/
ssh -t admin@emubox 'sudo -u player emubox-scrape'
```

Use the box's configured address in place of `emubox`. Avoid `rsync -a`: archive
mode preserves source permissions and attempts to preserve ownership, which
can defeat the destination's shared access rules. The command above leaves
ownership to the destination and makes new game files readable. This SSH route
waits on remote administration, which is not provided by the library feature;
sshd is currently loopback-only. The frontend route works without SSH.

Create a ScreenScraper account and set `screenscraper_username` and
`screenscraper_password` with `just secrets-edit` before installation.
Both placeholders always block `just install`. The runtime config is owned
by `player`, mode `0400`; credentials do not appear in process arguments.
`emubox.library.threads` defaults to 1; use only the concurrency your account
allows. From an admin console, start a fetch with:

```sh
sudo -u player emubox-scrape
```

Art appears at the next frontend start. Generation runs before the frontend
with progress on the display, preserving favourites, play counts and emulator
choices. A failed progress window does not trigger a hidden generation retry.
The household can instead select **Tools > Update game art**: it shows scrape
progress and restarts the frontend when the fetch ends. This holds the TV
until the scrape finishes; the first run can be long, while later runs only
fetch games missing from the cache and are usually short.

Run `emubox-status` as `admin` without sudo to see each folder's game, gamelist
and unscraped counts, unmapped systems, the last fetch result, failures and
pending generation. A game with a gamelist entry but no description still
counts as unscraped. An incomplete scan reports unavailable counts explicitly.

After deployment, test a small folder of a few ROMs with real credentials:
run `sudo -u player emubox-scrape`, inspect `emubox-status`, restart the frontend
and confirm descriptions and art. Then exercise Tools with physical input.
Record the software revision and results using
[the hardware checklist](docs/library-hardware-tests.md). CI proves nonvisual
contracts using local imports and fixtures; it does not prove service-account
acceptance, display rendering or physical frontend interaction.

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
layout (`@root @nix @persist @data @cache @snapshots` on btrfs), the closure is
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
- ScreenScraper credentials: `screenscraper_username` and
  `screenscraper_password` are set, and
  `sudo stat -c '%a %U' /run/secrets/rendered/skyscraper.ini` reports
  `400 player`. Complete the small real-account scrape and manual hardware
  checklist under Library.
- WiFi profile present: `nmcli connection show family-wifi`, and the box
  joins the network when the SSID is in range.
- Ephemeral root: `sudo touch /root/marker`, reboot, the file is gone
  while `/etc/machine-id` is unchanged.
- `admin` logs in on a console with the password whose hash is in the
  secrets file: with a keyboard attached, Ctrl-Alt-F6 from the game library
  switches to the console reserved for a login prompt (the kiosk session
  holds one of the first two), and Ctrl-Alt-F1 or F2 switches back. The VM
  test proves the compositor acts on that key; that the box's own keyboard
  produces it is checked here.
- The same switch works from inside a running game, and nothing typed at the
  console reaches the emulator left running behind it.
- No failed units: `systemctl --failed` is empty.

### Pushing configuration changes

Not provided by this layer: nothing on the box listens on the LAN, so
there is no address to push to. The Tailscale node and the `deploy` recipe arrive
with the remote-administration change. Until then a changed configuration
reaches the box by reinstalling (below, restoring protected data), or by hand at
the desktop. On a healthy box, press Ctrl-Alt-F6 on an attached keyboard, log
in as `admin` on that console and run
`sudo emubox-mode desktop`; in the desktop's terminal, run `su - admin`
because the desktop runs as `player`. If the session cannot be trusted, use
the greeter or recovery boot entry and log in as `admin` instead. The mode
command does not work in the recovery boot configuration.

As `admin`, clone the repository somewhere that
survives a reboot (`/home/admin` is on the ephemeral root; `sudo mkdir
/data/admin && sudo chown admin /data/admin` makes a place that lasts),
copy in your edited `secrets/secrets.yaml` (a fresh clone has the
placeholders), and run `sudo nixos-rebuild switch --flake .#emubox` (sudo
needs no password).

### Off-site backup setup and recovery

Off-site backup is deliberately a conventional restic repository in a
Backblaze B2 S3-compatible bucket, not restic's native `b2:` backend. Set
`emubox.backups.enable = true` and declare the B2 regional S3 endpoint,
dedicated private bucket, and optional repository prefix in the host
configuration. Then use `just secrets-edit` to set `b2_key_id`,
`b2_application_key`, and `restic_password` before installing.

Create a standard B2 `Read and Write` application key limited to this one
bucket. It needs the list, read, write, and delete access normal restic
operations use; do not use the account-wide master key. Deletion is necessary
because lock cleanup, `forget`, and `prune` remove repository objects.
Configure B2 lifecycle handling to retain previous file versions for 30 days.
Those versions are only a last-resort provider aid, not the normal restore path.

Each backup and maintenance activation begins by opening the repository,
initializing it only when restic identifies it as absent. An authentication,
network, or other repository error fails that activation without creating or
replacing anything, and `emubox-status` reports the layer unhealthy rather than
its last success. The backup timer starts 10 minutes
after boot and every four hours thereafter. Weekly maintenance runs restic
retention, prune, and `check --read-data-subset=10%`; that percentage is a
random subset chosen by restic for that run, not a rotating coverage guarantee.

All emulator save-like data has a declared route beneath `/data/saves`. On an
upgrade, its conflict-safe migration runs before the emulator setting or bind
mount becomes active. Equal existing files are accepted; a differing same-path
file stops activation and names both paths instead of overwriting either one.
The complete route declaration is rendered on the box as
`/etc/emubox/save-routes.json`.

Local history is independent of B2. btrbk creates root-only read-only hourly
snapshots beneath `/data/.snapshots`, retaining all real points from the latest
48 hours and one representative from each populated daily bucket in the prior
14 days. It neither fabricates downtime points nor captures the separate cache
or snapshot subvolumes.

Use `sudo emubox-status` first; it is installed on every box, whether or
not off-site backup is enabled. It aggregates the reports registered with
it - on this box, the backups and controllers reports, not the whole box's
health; the BIOS check stays its own command, `emubox-check-bios` (see BIOS
files, above). Each section opens with its name and `ok`, `warn`, `fail` or
`did not run`, with the report's own lines indented beneath it, and the
command exits with the worst of them: 0 when every section is ok, 1 for a
warning, 2 for a failure or a report that could not run. A report still
running after 60 seconds counts as one that could not run; under every
section but an `ok` one, whatever the report wrote to its error stream is
shown too; and when the command cannot read its own list of reports, it
says so on one line and exits 2. Its backups section reports the
authoritative outcome of the latest local snapshot, backup, and maintenance
invocation, with a journal query when one needs attention; with off-site
backup disabled, that section carries only the local snapshot layer,
neither off-site layer. `sudo restic-emubox` is restic itself with the
same repository and root-only credentials automation uses, so `snapshots`,
`stats`, `ls` and `find` all work as documented upstream. It is restricted to
root by the permissions on the credentials file it reads, not by a command
allowlist.

For a normal recovery, restore to a new directory and verify while restoring:

```
sudo install -d -m 0700 /data/recovery/restic-restore
sudo restic-emubox snapshots
sudo restic-emubox restore --verify <snapshot-id> --target /data/recovery/restic-restore
```

Inspect the recovered data before replacing anything live. The restored tree
contains the four protected roots as `saves`, `es-de`, `bios`, and
`home/player`. Do not restore over a running `/data`; use the recovery
specialisation or otherwise stop the kiosk and relevant services before
promoting recovered files.

Restic uses its own native repository locks. Backups retry a compatible lock
for up to 3 hours 15 minutes; weekly maintenance has a 3-hour bound. A lock
that outlasts the retry window produces a visible failed activation, while
future timer activations remain enabled. There is no project-specific remote
lock or job queue to repair.

This is recovery, not immutability. A root compromise or this bucket-scoped
read/write/delete key can alter or delete repository objects. The 30-day B2
prior-version window can sometimes help, but it is not Object Lock and is not
an automated historical-object recovery procedure. Keep the restic password
and B2 credentials separately recoverable.

The install VM uses a local test repository and test-only credentials. It
exercises migration and the declared routes including ScummVM, local retention
windows, snapshot-consistent backup, exclusions and default home inclusion,
native-lock failure behavior, cleanup, status, and verified fixture restore.
It never contacts B2. `just vm-test`, `just kiosk-test`, and `just
controllers-test` require a Linux KVM builder and are CI evidence; `just
check-all`, `just session-check`, and `just closure-check` are the local
gates described above.

### Reinstall and disk swap

Run `just install` again. With the same host key the secrets decrypt on
first boot with no change to `secrets/secrets.yaml` and existing
`known_hosts` entries stay valid. Then either restore the four protected roots
from a verified restic restore - `/data/saves`, `/data/es-de`, `/data/bios`,
and `/data/home/player` - or start with their empty, correctly laid out
directories. Recreate ROMs, scraped media, caches, and local snapshot history
separately; they are intentionally outside the off-site backup set. Nothing
on the old disk is needed; a replacement disk only has to appear at the path
`hosts/emubox/facts.nix` names (a probe-order
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
in `hosts/emubox/facts.nix` mark those facts; this list is where the rest
live, and there is no second list. Where an item exists because a test
stopped short of covering something, the evidence for stopping lives beside
that test and is linked from the item - the item itself is still here, so
this list stays the one place to read what is unproven.

- The four USB-A `ID_PATH` values in physical port order, the connector the
  TV is actually on (`hdmiOutput`), and the pad's SDL device name and SDL
  joystick GUID into `emubox.facts.controllerIdentities`: all
  `TODO(bring-up)` in `hosts/emubox/facts.nix`. Capture the identity values
  from the real pad under Linux with `sudo env SDL_VIDEODRIVER=dummy
  sdl2-jstest --list` (nixpkgs `sdl-jstest`) and copy them in the form it
  prints; check that the GUID's second-to-last byte is not the HIDAPI
  signature `0x68`, and that every emulator reports the same device name.
  This is the gate for Dolphin's and Azahar's pad play and for Dolphin's
  route back: their items below are checked only once it is recorded.
- One connected pad enumerating as exactly one controller, and two
  connected pads as exactly one controller each, with the recorded ports
  active: checked through the system's game controller library in
  recorded order, and through RetroArch, whose recorded order is not
  promised, in whatever order it presents them.
- A pad connected mid-game takes the lowest free player index whatever its
  port, checked in PCSX2 or DuckStation, which the recorded order reaches
  and whose bindings need no recorded pad identity; on RetroArch, record
  the order observed instead of expecting this.
- A pad disconnected and reconnected mid-game likewise takes the lowest
  free player index, regaining its former one only when no lower index is
  free - with players one and two both disconnected and player two's pad
  reconnected first, that pad becomes player one - checked in PCSX2 or
  DuckStation, which the recorded order reaches and whose bindings need no
  recorded pad identity; on RetroArch, record the order observed instead.
- A pad in the second port alone is player one, and a pad then connected
  to the first port mid-game takes player two, the lowest free index,
  until the next game launch applies the recorded order: checked in PCSX2
  or DuckStation, which the recorded order reaches and whose bindings need
  no recorded pad identity; on RetroArch, record the order observed
  instead.
- Each standalone's pad play and route back: on Dolphin, PCSX2,
  DuckStation, PPSSPP and ScummVM the pad plays and its route back ends
  the emulator and returns to the frontend with no prompt in between
  (Dolphin checked in the kiosk session, since its hotkeys and gameplay
  input need window focus; ScummVM's checked by navigating its main menu
  to Quit with the pad - left stick to move the pointer, A to click - in
  the engines where Start opens that menu instead of Guide quitting
  directly); on Azahar the pad plays, but leaving it still needs the
  route back deferred to a later change. A second pad unit whose USB
  revision differs will not play in Azahar until its own GUID is recorded
  too.
- PCSX2's first start on a freshly prepared box raises no settings prompt.
- With two pads connected, player two's pad plays in a two-player game on
  Dolphin, PCSX2 and DuckStation.
- With a pad in each recorded port, `emubox-status` reports every slot
  resolved and raises no unaccepted-mode warning; if it does warn, the
  vendor and product pair the pad reports is recorded and added to
  `acceptedControllerModes` in `modules/controllers/default.nix`.
- Whether the wired pad persists its mode across disconnects.
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
- Real performance per system. The VM asserts that the flake declares
  PCSX2's native internal resolution and DuckStation's PGXP with upscaling
  and that both keys reach the files on disk - both are seeded, so a player
  who changes either keeps the change - never that either holds frame rate
  on this box's iGPU. A system that disappoints
  here is settled by changing its values in `modules/emulators`, not by
  anything CI can catch first.
- E12 off-site backup acceptance, recorded below after one normal real-B2
  backup and a verified restore. This is a rollout check, not a corruption
  drill or historical-object recovery drill.

### E12 off-site backup acceptance record

Run this once after the real bucket, key, and secrets are provisioned. Use a
known non-sensitive fixture inside one protected root. Record only identifiers,
timestamps, commands, and byte-comparison results - never the B2 application
key, restic password, or fixture contents.

| Field | Record |
|---|---|
| Date and operator | `TODO(E12)` |
| B2 bucket and regional S3 endpoint | `TODO(E12)` |
| Repository ID and restic snapshot ID | `TODO(E12)` |
| Protected-root fixture path | `TODO(E12)` |
| Normal backup unit invocation and successful marker | `TODO(E12)` |
| Restore command with `--verify` | `TODO(E12)` |
| Restored fixture byte comparison | `TODO(E12)` |
| `emubox-status` after the run | `TODO(E12)` |

The acceptance succeeds only when the normal scheduled or manually started
backup reaches B2, `restic-emubox restore --verify` succeeds into a fresh
directory, and the recovered fixture bytes match. Do not delete, corrupt, or
recover historical B2 objects for this check.
