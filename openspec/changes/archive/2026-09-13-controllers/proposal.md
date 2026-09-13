## Why

The box promises "a controller-only route back to the frontend", but delivers
it for RetroArch alone: the emulators capability enforces the two RetroArch
gamepad combos and, for every standalone emulator, fullscreen and nothing
else. A family member who launches Dolphin, Azahar, PCSX2, PPSSPP, DuckStation
or ScummVM holding only a pad has no way back to the frontend, and where an
emulator's own default binds a keyboard rather than a pad, no way to play
either. The only escape is a keyboard the box does not have, or the power
button. This change delivers a way back for five of them. Azahar is the one it
cannot reach at the version the flake pins: Azahar keeps each hotkey as a
keyboard sequence and nothing else, so it offers no action a pad can be bound
to that leaves it, and its way back is recorded as deferred to a later change
rather than promised here.

Nothing else pins which physical USB-A port is player 1, so player order is
whatever enumeration order the kernel happens to produce. The box has four
recorded USB-A ports and a family that expects the pad in the left-hand one to
be player 1; today which pad gets which index is decided by whichever device
the kernel happened to enumerate first. What is fixed here is that order for
the emulators that read controllers through the system's game controller
library, which is the route the session's enumeration hint reaches. Which
emulators those are is determined per emulator rather than assumed, RetroArch
included, whose joypad driver upstream defaults to `udev` rather than that
library, and where an emulator turns out to enumerate controllers through a
backend of its own, the recorded order is not promised for it and that limit
is recorded instead.

If this is not done, the appliance ships games that cannot be exited, and
possibly cannot be played, and the failure is only discovered when a real pad
is first plugged into real hardware - by which point it is a redesign rather
than a configuration change.

## What Changes

- A new controllers capability owns which physical port is which player: the
  udev rules that name each recorded port `/dev/input/emubox-pN`, and the
  session hint that makes every emulator reading controllers through SDL
  enumerate those nodes first and in that order - which reaches RetroArch only
  if the determination finds its joypad driver to be SDL's.
- Every standalone emulator but one gains a controller-only route back to the
  frontend that ends the emulator's process, with no prompt in between that a
  pad cannot answer. The exception is Azahar: at the pinned version it persists
  a hotkey as a keyboard sequence and nothing else, so no pad binding can reach
  its exit, and its route back is deferred to a change of its own and recorded
  as a known limit, while its gameplay bindings are owned like any other
  emulator's. Where an emulator asks for confirmation before closing by
  default, the flake owns the setting that suppresses it, and where one exits
  to the frontend only when launched with a particular option, the frontend's
  launch command for it carries that option, as PPSSPP's gains
  `--pause-menu-exit`. The route back is enforced at the anchor every other
  owned setting written into an emulator's file is - before the frontend
  starts, each relaunch included. Gameplay bindings are added too, wherever an
  emulator's own defaults cannot survive the flake owning the file they live
  in: defaults compiled into the emulator survive and are left unrestated,
  defaults generated into a file the flake owns do not, and there the flake
  declares the complete gameplay set for every player each system it serves
  supports, up to player four, which is where the box's four recorded
  controller ports put the ceiling. Players are counted by a system's native
  controller ports, without a multiplayer accessory such as a multitap, so
  PlayStation and PlayStation 2 get two. Where an emulator leaves a further
  player's controller slot disconnected by default, the flake also owns the
  setting that connects that slot, in the same tier as the bindings, since a binding for a disconnected slot
  is a pad that plays nothing. Any other setting a binding depends on to
  reach a pad, such as the device a group of bindings is resolved against, is
  owned in that binding's tier: enforced with the route back, seeded with
  gameplay bindings, and enforced with a gameplay binding that depends on the
  pad's identity, as set out below. The exception is a flag that decides
  whether the stored binding beside it is read at all, such as Azahar's
  `<key>\default` companions, which
  is enforced whatever its binding's tier, since a stale one discards a
  player's own binding as readily as the flake's. Where such a setting must
  name the pad itself and the emulator offers no form naming no particular
  device, its value is a bring-up fact, recorded from the real pad beside the
  port paths, read with a nixpkgs tool the box carries for it - `sdl-jstest`,
  or an equivalent the per-emulator determination confirms - that prints the
  pad's SDL device name and joystick GUID in the form the emulators store
  them, rather than derived by hand: until then neither it nor any binding depending on it is
  declared, nothing stands in for it, and that emulator's pad play and route
  back wait for bring-up. A gameplay binding that depends on such a fact is
  enforced rather than seeded, with every setting it depends on to reach a
  pad, so it is written at the first launch after the fact is recorded,
  whatever the emulator wrote there in the meantime; seeded, it would be kept
  out for good by an emulator that had already filled those settings with its
  own values, as Azahar does whenever it saves its configuration. The
  emulators this touches rebind only through dialogs that need a mouse or a
  keyboard, so a player on the box loses nothing by it.
- `emubox-status` becomes a real status command: an aggregator that runs
  reporters registered by each capability. The backup reporter is today's
  program under its existing `--status` interface; the controllers reporter
  adds slot and pad-mode state. **BREAKING** for nobody outside the box - the
  command name, its lack of arguments and its backup output are unchanged -
  but `emubox-status` stops being a second name for `emubox-restic-backup`.
- No RetroArch controller configuration is added. The packaged joypad
  autoconfig already covers the pad this box uses, and the frontend's two
  gamepad combos are already owned by the emulators capability. RetroArch's
  joypad driver is left as it is; which one it enumerates controllers through
  is determined with the standalones', and decides whether the recorded port
  order reaches it.
- No on-screen configuration surface is added. Controller behaviour is decided
  by the flake: a standalone emulator's controller settings are written in their
  tiers before the frontend starts, and the core-based frontend's two gamepad combos are
  delivered at each game's launch. An on-screen settings entry would need a
  frontend custom system that does not exist yet and belongs with the change
  that creates one.
- Wireless pads are deliberately out of scope, and that is a scope decision
  rather than an omission. The box's kiosk session is a single-window Wayland
  compositor running the frontend and nothing else: no window manager, no
  system tray, no keyboard and no mouse, so no existing wireless-pad manager
  can be launched or driven there. Nor is there a way in from elsewhere - the
  box exposes nothing on the family LAN, so there is no remote session an
  administrator could run a wireless setup command from until the
  remote-administration capability arrives. Every remaining route needs
  somebody to carry out a manual setup step at the box, and this project drops
  a feature rather than accept a manual setup step. The primary controller
  interface is wired pads in the recorded USB ports, which is what the box
  actually ships with and what this change makes work seamlessly; wireless pads
  return attached to whatever change brings a surface that can pair them. The
  Bluetooth driver settings already present in the tree are left exactly as
  they are: this change neither adds pairing configuration nor removes those
  lines, and removing them belongs to the change that next revisits wireless
  pads.

## Capabilities

### New Capabilities

- `controllers`: which physical port is which player, and what the flake owns
  in each standalone emulator's input configuration.
- `status`: one operator command that aggregates the health each capability
  registers with it, and what its exit code means.

### Modified Capabilities

- `vm-test`: gains the assertion group for slot symlinks, the session hint,
  the owned input keys, and the aggregated status output.
- `emulators`: its ownership requirement calls the two RetroArch combos "the
  only controller-only routes out of a running game". That is a closed claim,
  not a floor, and the built system contradicts it the moment a standalone
  emulator gains its own route back. The clause is narrowed to the core-based
  frontend, and the capability's purpose stops claiming a controller-only
  route back in every emulator, so each route back has exactly one owner: the
  core-based frontend's stays with `emulators`, and every standalone
  emulator's moves to `controllers`.
  The delta reproduces the requirement whole and changes one thing besides
  that clause: the enforced values gain, for every standalone whose first
  start rejects a configuration file this system prepared, the key that start
  checks, PCSX2's settings version being the one known now. The configuration
  editor creates PCSX2's file before PCSX2 has
  ever run, and PCSX2 offers to reset a file without that version to its
  defaults - a question a pad-only box cannot answer well, since declining
  leaves PCSX2 refusing to start and accepting discards every seeded value,
  which the seed tier never restores. That already affects the box as it
  ships, and the seeded PCSX2 slot setting this change adds depends on it.
- `backups`: its status requirement promises the newest local snapshot, the
  last off-site backup and the last weekly maintenance run on every box, while
  only the local snapshot layer runs unconditionally. The delta narrows that
  promise to the layers a box actually runs and changes nothing else.

`controllers` is the capability that owns the route back out of a standalone
emulator, and the `emulators` delta above is what makes that true in the specs
rather than only in the code. The standalone input keys are contributed into
the same owned-files option the emulators capability already uses, at file
paths built from the configuration directories the emulators module exposes,
so the mechanism and the file locations are shared while the ownership is not.

`backups` needs a small delta, narrower than it first looked. Its status
requirement promises the newest local snapshot, the last off-site backup and
the last weekly maintenance run on every box, but only the local snapshot
layer is declared unconditionally: the two off-site layers exist only where
off-site backup is enabled, which is off by default. So on the box as it
ships, the requirement promises status for two layers that do not run, and
reporting them would warn forever about units that were never meant to exist.
The delta narrows exactly that promise - the local layer is reported on every
box, the off-site layers only where they run - and changes nothing else. The
requirement still never names the command that prints the report, so moving
that command's name onto an aggregator leaves the rest of it true.

## Impact

- `modules/controllers/default.nix`: gains the session hint, the owned input
  key tables - including the settings that connect each further player's
  controller slot and any enforced setting that suppresses an emulator's exit
  confirmation, contributed into files the emulators capability owns - and
  the status reporter registration, and, where the determination finds
  pad-identity facts are needed, puts the tool that captures them on the
  system path. Its existing udev rule
  generator is unchanged, and its existing wireless driver lines are left
  untouched.
- `modules/status/default.nix`: new, and the status capability's owner. It
  declares the reporters option every capability registers against, renders the
  registered list to its stable path under `/etc`, and puts the aggregator on
  the system path.
- `modules/default.nix`: gains the new status module in its imports list. A
  module directory that list does not name is never evaluated, so this is what
  makes the reporters option exist for the modules that register against it.
- `modules/emulators/default.nix`: gains an internal, read-only option
  exposing each standalone emulator's configuration directory, derived from
  the bindings the module already uses for its own owned files, which the
  controllers module builds its owned file paths from; that option changes no
  emulator behaviour. Two changes in the module do, deliberately: the
  frontend's PSP launch command gains `--pause-menu-exit`, so PPSSPP's pause
  menu offers an Exit that ends the program and returns to the frontend in
  place of its exit to PPSSPP's own menu; and the enforced values gain the
  key each standalone's first start checks where that start rejects a file
  this system prepared, PCSX2's `UI.SettingsVersion = 1` being the one known
  now, which fixes a first-start reset prompt the box has today. Its spec
  delta narrows a clause the code already satisfies and adds those acceptance
  keys to the enforced values, and the input keys
  are contributed from the controllers module into the same owned-files
  option.
- `modules/backups/default.nix`: registers its status reporter outside the
  off-site enable guard, so the local snapshot layer is reported on every box
  and the off-site layers only where off-site backup is enabled.
- `pkgs/emubox-status`: new, and registered in the package set like every other
  program this project writes, so it reaches the overlay, is offered as a
  standalone package output and is pushed to the public cache.
  `pkgs/emubox-restic-backup`: loses the
  `emubox-status` alias and its `argv[0]` dispatch, gains systemd on the runtime
  path its wrapper prefixes so its `systemctl` and `journalctl` calls resolve
  when the aggregator runs it as a subprocess, and gains a way to limit
  `--status` to the local snapshot layer for a box with off-site backup off;
  the default `--status` report and its exit statuses are unchanged.
- `hosts/emubox/facts.nix`: the recorded port paths stay empty until hardware
  bring-up, so the slot mechanism is inert on the real box until then and the
  VM test is what proves it. If the per-emulator determination finds an owned
  value that must carry the pad's own identity, those values join the port
  paths as bring-up facts: declared under a new
  `emubox.facts.controllerIdentities` option, which `modules/facts.nix`
  declares beside `controllerPorts`, and declared empty in this file until
  bring-up, like the port paths, with every owned key that needs one, and
  every binding that depends on such a key, left undeclared until it is
  recorded, so that emulator's pad play and route back wait for bring-up.
  Those values are read at bring-up from the real pad with the capture tool
  the box carries, whose output the determination confirms matches the form
  each emulator stores, and the empty option's comment names that tool as the
  port paths' comment names `udevadm`. If it finds identity-free forms
  everywhere, the file is unchanged.
- `tests/`: a new controllers node carrying the wired slot fixture, the session
  hint and the owned-key assertions, and the kiosk node's boot adaptations,
  preferably factored out of `tests/kiosk.nix` into a test module both nodes
  import; plus additions to the kiosk and install nodes.
- `justfile`: a recipe that runs the new VM test beside the two that already
  have one, and its evaluation gate gains the one host-only check this change
  adds, since that hand-maintained list is what evaluates such a check on a
  machine with no Linux builder.
- `README.md`: the status command's broadened scope, described as aggregating
  the reports registered with it rather than as the whole box's health, with
  the BIOS check remaining its own command, and
  including what its backups section holds on a box with off-site backup off;
  the count of VM tests, which it states as two in more than one place and
  which becomes three; and the line
  calling the two RetroArch combos the only controller-only routes out of a
  running game, which standalone emulators no longer leave true; and, for each
  emulator the determination finds the recorded port order does not reach,
  RetroArch included, that limit.
- No new external dependency: the joypad autoconfig, and the pad-identity
  capture tool where one is installed, come from the pinned nixpkgs.
