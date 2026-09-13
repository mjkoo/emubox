## Context

See proposal.md for motivation. This section records only the state of the
tree and of pinned nixpkgs that shapes the approach, because several
assumptions that would otherwise have driven this change turned out to be
wrong, and each removes or replaces work.

**The frontend's core-based emulator needs no controller configuration.** nixpkgs'
`wrapRetroArch` already sets `joypad_autoconfig_dir` to the
`retroarch-joypad-autoconfig` package (`pkgs/by-name/re/retroarch-bare/package.nix:174`),
and `modules/emulators/default.nix:151` builds RetroArch through that wrapper.
The profile `Microsoft X-Box 360 pad.cfg` in that package declares
`input_vendor_id = "1118"` and `input_product_id = "654"` - decimal for
`0x045e:0x028e`, which is what the box's pad reports in its default mode under
the in-kernel `xpad` driver, and why every such pad looks identical to every
emulator. The profile maps every button and axis and binds
`input_menu_toggle_btn = "8"`, the Guide button. So a pad reaches the RetroArch
menu already, alongside the two device-independent combos
`modules/emulators/default.nix:196-231` owns. That settles RetroArch's
autoconfig and its menu, not its player order: which pad RetroArch calls player
one depends on the joypad driver it enumerates controllers through, and that is
the per-emulator determination's to record, as the paragraph below on which
emulators the enumeration order reaches sets out.

**Those two combos are settled.** `input_menu_toggle_gamepad_combo = "2"`
(both stick clicks) and `input_quit_gamepad_combo = "4"` (Start plus Select)
carry a recorded justification: RetroArch evaluates both keys independently
against the same frame's button bits, so combos sharing a button leave one of
them dead. This change does not reopen that.

**`emubox-status` is not a status program.** It is `emubox-restic-backup`
under a second name - `makeWrapper` creates the alias
(`pkgs/emubox-restic-backup/package.nix:52`) and the program forces `--status`
when `argv[0]` ends in `emubox-status`
(`pkgs/emubox-restic-backup/emubox_restic_backup.py:459`). The backups spec is
accurate about that scope and never names the command; `README.md:378` is what
over-promises, telling the administrator to run it first as a general entry
point.

**The obvious VM fixture for a gamepad cannot work.** Attaching an emulated USB HID device
on a fixed port does not fire the udev rule, because the rule requires
`ENV{ID_INPUT_JOYSTICK}=="1"`, which udev's `input_id` builtin sets from an
evdev node's button capabilities, and no emulated USB device QEMU offers
(`usb-kbd`, `usb-mouse`, `usb-tablet`) presents gamepad capabilities. Decision
5 replaces it.

**What did hold, and is now simpler than assumed.** In pinned nixpkgs `SDL2`
is `sdl2-compat` 2.32.70, a shim over SDL3, so every consumer that reaches
controllers through SDL funnels into one backend and there is no
SDL2-versus-SDL3 split to reason about. In SDL3's
`src/joystick/linux/SDL_sysjoystick.c`, `LINUX_JoystickInit` reads
`SDL_HINT_JOYSTICK_DEVICE` at line 999, splits it on `:`, and calls
`MaybeAddDevice` on each path before any general scan, so listed nodes enter
the joystick list first and in the listed order. `MaybeAddDevice` rejects a
device already listed by comparing `sb.st_rdev` (line 484), which is why a
symlink and its `eventN` target collapse to one entry rather than doubling the
pad. The hint is read through `SDL_GetHint`, so an environment variable
exported once in the session reaches SDL3 whether a consumer linked
sdl2-compat or SDL3 directly.

**Which emulators that reaches is not established.** The frontend, Dolphin,
PCSX2, PPSSPP, Azahar and DuckStation are the consumers whose SDL dependency
has been read, "the frontend" there being ES-DE; ScummVM, which this change
installs, launches and gives an owned route back to, is not among them and has
not been checked. Nor is RetroArch, the frontend's core-based emulator, which
runs most of the box's systems: a linked SDL shows linkage, not the joypad
driver RetroArch enumerates controllers through, and the tree sets none, while
upstream RetroArch's `configuration.c` defaults to the `udev` joypad driver
whenever the build has udev support. So the list above is
what has been read rather than a closed membership, and nothing here should be
taken as settling that every emulator on the box enumerates controllers through
that one backend. Three things follow, and each is where it belongs rather than
here: the per-emulator determination asks each emulator, RetroArch among them,
which input interface it enumerates controllers through at the pinned version
and records where that was read; the port-order requirement is scoped to emulators that read controllers
through the system's game controller library rather than promised for every
emulator; and Decision 3 says what happens for an emulator whose answer is a
native input backend of its own.

The scaffold in `modules/controllers/default.nix` already carries a correct
udev rule generator over `emubox.facts.controllerPorts`.

## Goals / Non-Goals

**Goals:**

- Reuse the existing owned-settings machinery for input keys rather than
  adding a second path into emulator configuration.
- Keep the controllers capability owning controller keys, even where they land
  in a file another capability also writes.
- Make the status aggregator additive, so the backup program's behaviour is
  untouched and later capabilities register rather than negotiate.

**Non-Goals:**

- Strict slots, where an empty first port means no player one and a
  mid-game connection never reorders. It needs a virtual pad per port that
  always exists and forwards events from whatever is connected. The candidate
  proxy requires all inputs present at start and does not forward force
  feedback, so the box's pads would lose rumble, to fix a case the specs
  already accept.
- Wireless pads, in every part: no pairing mechanism, no command that opens
  one, and no assertion about one. The kiosk session is a single-window Wayland
  compositor running the frontend and nothing else - no window manager, no
  system tray, no keyboard and no mouse - so no existing manager for wireless
  pads can be launched or driven on the box, and nothing is exposed on the
  family LAN either, so there is no remote session an administrator could drive
  one from until the remote-administration capability lands. Every route that
  is left costs somebody a manual setup step at the box, and this project drops
  a feature rather than accept one. The primary controller interface is wired
  pads in the recorded USB ports, and that is what this change makes work.
  Wireless pads return with whatever change brings a surface that can pair
  them. The wireless driver lines already in the tree are neither added to nor
  removed here: taking them out belongs to that later change, not to this one.
- Any on-screen surface. Controller behaviour is decided by the flake, and an
  on-screen settings entry would need a frontend custom system that does not
  exist.
- Recording real hardware values. `controllerPorts` stays empty until bring-up,
  so the slot mechanism is inert on the real box and the VM test stands in for
  it; so does any value naming the pad itself that Decision 2 finds an
  emulator requires.

## Shared status vocabulary

Three capabilities now describe health, so the words are fixed here and the
requirements reference them rather than each inventing a scale.

| State | Meaning | Exit status |
|---|---|---|
| `ok` | The reporter ran and found nothing wrong | 0 |
| `warn` | The reporter ran and found something an administrator should act on, but the box is serving its purpose | 1 |
| `fail` | The reporter ran and found the capability not doing its job | 2 |
| _did not run_ | The reporter could not be executed, or exited with any status outside the three above | any other |

Those three statuses are the whole alphabet, and the fourth row is what makes
the table total. A reporter exiting 7 has said nothing the aggregator can
translate, and inventing a meaning for it would let a crash masquerade as a
finding, so it is read as a reporter that failed to run.

"Failed to run" is also detected ahead of any exit status wherever it can be:
a reporter whose command is missing or is not executable is recognised as such
before it is invoked, and reported as not having run rather than as any of the
three states. Keeping that separate from the exit status is what lets `warn`
keep its meaning - "the box is serving its purpose" is not a sentence to apply
to a report that never happened - and it is why the backup program needs no
change to fit.

A reporter may use only part of the alphabet. `emubox-restic-backup --status`
returns 0 or 1 and never 2, so the backups section reports `ok` or `warn` and
never `fail` on its own. That is a property of that program, recorded here
rather than fixed: this change leaves the backup program's status behaviour
untouched, and an off-site layer needing attention is exactly what `warn`
describes.

One consequence of that narrow alphabet is recorded here rather than repaired:
that reporter cannot distinguish its own crash from a finding. It exits 1 for
a layer that needs attention and, being a Python program, exits 1 again if it
raises, so a crashed backup reporter is read as `warn`. The aggregator's
separate detection covers the case it can cover - a command that is missing or
not executable is recognised as not having run before it is invoked, which is
the failure mode a packaging or path mistake produces - and what is left is a
crash inside a program that did run, misreported one step too mild. Buying the
distinction back means giving the backup program a distinct crash status,
which changes shipped behaviour that this change is otherwise not touching,
for a case whose symptom is already a section the administrator is being told
to look at.

The command's own exit status is the maximum over its reports, so `ok` only
when every report was `ok`. A reporter that could not run counts as `fail` for
its own section and never suppresses another's.

A reporter still running after one minute is stopped and read as not having
run, so one hung report cannot hold the command open or keep the reports after
it from running. Each section opens with a `name: state` line at the left
margin, and everything the reporter printed is indented beneath it, so nothing
a reporter prints - a blank line, or a line shaped like a header - can be read
as the start of another section. Wherever a section's state is anything but
`ok`, the reporter's error stream is shown in it too, since a crashed
reporter's traceback is what an administrator sent to that section needs. A
failure of the aggregator itself, its reporter list missing or malformed
included, prints one line naming it and exits as a report that did not run
counts. Two reporters registered under one name are refused at evaluation,
since each labels its own section.

**How a reporter is executed, and who owns its dependencies.** A reporter is
registered as a complete argv, and the aggregator executes exactly that argv
without modifying `PATH` - it adds nothing, prepends nothing and inherits the
environment it was started in. The registering module is therefore responsible
for its reporter's own runtime closure: whatever the reporter shells out to has
to be reachable from the program itself, through its own wrapper, not from
whatever happened to be on the administrator's `PATH`.

That is a contract rather than a note because getting it wrong is invisible.
The one reporter this change registers over an existing program calls bare
`systemctl` and `journalctl`, while that program's wrapper prefixes `PATH` with
btrfs, restic and util-linux alone. Run from an administrator's shell those two
resolve out of the system path and nothing looks wrong; launched as a
subprocess of the aggregator they do not, and the program raises a
file-not-found error and exits 1 before printing a single layer. Exit 1 from
that reporter is `warn` in the table above, so a reporter broken by a missing
runtime dependency would read as a real finding about the backups. The fix
belongs where the contract puts it - in the reporter's own package - and the
aggregator's job is to leave the environment alone so that a closure which is
right stays right.

## Decisions

### 1. Keep the udev generator; add the hint through the proven path

`modules/controllers/default.nix` keeps its rule generator unchanged: it maps
each `emubox.facts.controllerPorts` entry, in list order, to
`/dev/input/emubox-pN`, matching `SUBSYSTEM`, `KERNEL`, `ENV{ID_INPUT_JOYSTICK}`
and `ENV{ID_PATH}`. Rules apply on hotplug, so the "connected after boot"
scenario is udev's behaviour rather than ours.

The module adds `environment.sessionVariables.SDL_JOYSTICK_DEVICE`, the
`emubox-pN` paths joined with `:` in port order, under `lib.mkIf (ports != [ ])`.

Why `environment.sessionVariables` rather than an export in the session
script: its delivery into the `player` session is already proven by the kiosk
test's `/proc/<pid>/environ` assertion (`tests/kiosk.nix:947-959`), so this
reuses a path known to work. The alternative, adding a second export inside
`emubox-session`, would put the hint on a path nothing yet asserts and would
scope it to the session script rather than to the login session, which is the
wrong scope for a variable an administrator's own shell may want.

Why the guard rather than an empty string: an empty hint is still a hint, and
SDL would parse it, attempt to open the empty path and discard it. Declaring
nothing is what the specs require and is honest about a box whose ports have
not been recorded.

### 2. Input keys are owned through the existing editor, contributed by `controllers`

The keys land as new `emubox.kiosk.ownedFiles` entries contributed from
`modules/controllers/default.nix`. The option merges with `recursiveUpdate`, so
two modules can contribute entries for the same file, and the controllers
capability keeps ownership of controller keys while the editor, its tiers and
its recreate policy stay exactly as they are. Which files are new to the editor
is the per-emulator determination's output rather than a fixed number: that
determination names, for each emulator and each system the frontend assigns
it, the configuration file holding that system's bindings, and every one of
those the editor does not already own arrives as a new entry with its own
`format`. The ones known so far are Dolphin's `GCPadNew.ini`, its Wii profile
`WiimoteNew.ini` and `Hotkeys.ini`, and PPSSPP's `controls.ini`, which is a
different file from the `ppsspp.ini` the emulators capability already owns and
so needs an entry of its own. All of them are INI with sections, a format the
editor already handles, so no new editor is needed, and a further file the
determination names in that format needs none either. Not every controller key
lands in a new file: the controllers capability also contributes keys into
files the emulators capability already owns, among them the settings that
connect a further player's controller slot, which live in `Dolphin.ini`,
`PCSX2.ini` and DuckStation's `settings.ini`, and Azahar's gameplay bindings
with their companions and the keys of the profile array they are read
through, which live in its `qt-config.ini`.

Where those files live is not typed out a second time. Each standalone
emulator's configuration path is today a private binding inside
`modules/emulators/default.nix`, and a path the controllers module retyped and
misspelled would give a file that carries every owned key, passes every VM
check and is read by nothing. So `modules/emulators/default.nix` declares an
internal, read-only option, `emubox.emulators.configDirs`, exposing each
standalone emulator's configuration directory, derived from the same bindings
that module already uses for its own `ownedFiles` entries so the two cannot
drift; and every owned file path `modules/controllers` contributes is built
from it. That includes the files new to the editor - Dolphin's `GCPadNew.ini`,
`WiimoteNew.ini` and `Hotkeys.ini`, and PPSSPP's `controls.ini` - which sit in
the same directories as the files the emulators capability already owns.
`modules/controllers` then contains no literal emulator configuration path.
The option says where an emulator's files are and nothing about their
content, so it is not the alternative rejected below, and it changes no
observable behaviour.

The option fixes the directory and not the file name. The controllers module
still names each file new to the editor, and a misspelled file name gives a
file read by nothing just as a misspelled directory does; the controllers
node's checks read their paths from the node's own rendered owned-values
document, so they agree with any misspelling, and wherever a file's keys wait
on a pad-identity fact the kiosk node's hand-typed pins leave them out, so no
other check types that file's name either. So the checks that guard these
paths cover file names as well as directories: evaluating the host
configuration confirms every contributed path lies under a directory the
option exposes, and the controllers VM test hand-types the full expected path
of every owned file new to the editor, each file name taken from the
determination's recorded evidence of the emulator's own file names - its
source, or a file its writer produced - and asserts that set equals the set of
new paths in the node's rendered owned-values document, so a misspelled name
fails as a path the emulator never reads.

Rejected: putting the tables in `modules/emulators`. It would co-locate the
keys with the emulator knowledge, but it would make the emulators capability
own behaviour the controllers spec is responsible for, which is the boundary
problem a later audit would report.

Tier assignment follows the settled meaning of the two tiers:

- The route back to the frontend is **enforced**, for the reason the two
  RetroArch combos are enforced: a player who unbinds it strands the family.
- The setting that suppresses an emulator's exit confirmation is **enforced**
  with the route back it serves, since a route back that stops at a dialog a
  pad cannot answer strands the family just as surely.
- Gameplay bindings are **seeded**, so a player who rebinds keeps the change,
  except a gameplay binding that depends on a pad-identity fact, which is
  **enforced** so that it is written once bring-up records the fact, for the
  reason set out below with the pad-identity rule. That costs a player on the
  box nothing. The emulators whose bindings need a pad identity - Azahar, and
  Dolphin wherever the determination finds its device selector needs one -
  rebind only through Qt dialogs, which need a mouse or a keyboard, so no pad
  can reach them; a rebind made there with a keyboard lasts until the
  frontend's next start, like a rebind of the route back.
- The settings that connect a further player's controller slot are owned in
  the tier of the bindings they make usable: **seeded** like gameplay
  bindings, so a household that turns a slot off keeps that choice, and
  **enforced** with bindings that depend on a pad-identity fact.
- Every setting a binding depends on to reach a pad is owned in the same tier
  as the binding it serves: **enforced** for the route back and for a gameplay
  binding that depends on a pad-identity fact, **seeded** for every other
  gameplay binding. An enforced binding whose device selector is left unowned
  can survive while no pad can fire it. The slot settings above are one case
  of this rule, and Dolphin's `Device` lines are another: Dolphin reads each
  controller section's `Device` line as that section's default device, and the
  section's bindings resolve against it (Dolphin 2603a,
  `Source/Core/InputCommon/ControllerEmu/ControllerEmu.cpp`,
  `EmulatedController::LoadConfig`). So `Hotkeys.ini` `[Hotkeys]` `Device` is
  enforced with the route-back hotkey, and the `Device` lines of the gameplay
  profiles are owned with their bindings: seeded, or enforced where the
  determination finds a line must name the pad itself, which makes the
  bindings resolving against it identity-dependent too. Azahar's profile-array
  keys, the array's count and the active-profile index, are a third case: they
  select which stored bindings Azahar reads, so they are settings its bindings
  depend on and sit in their tier, as set out below. These are instances
  rather than the list: the determination records every such setting per
  emulator. Azahar's `<key>\default` companions are not settings of this kind
  - each decides whether the one value beside it is read at all, whoever set
  it - and are enforced in every tier for the reason set out below.

Enforced means asserted at the anchor the editor already has - before the
frontend starts, each relaunch included - and this change does not move that
anchor. The consequence is stated in the requirement rather than papered over:
a player who unbinds the route back mid-session stays unbound for the rest of
that frontend session, and the binding returns when the frontend next starts.
Narrowing the anchor to each game launch would mean writing emulator
configuration on the path between the frontend handing off and the emulator
starting - a path nothing else writes on, with no existing assertion covering
it - to close a window that ends the next time the family returns to the
frontend, which is the same act that gets them out of the game in the first
place.

**Azahar needs a companion key for every controller key owned in it.** Its
configuration is written by QSettings, which emits a sibling `<key>\default`
flag beside each value and consults that flag first: a value whose flag says
`true` is discarded in favour of the built-in default, so an owned binding
with no owned flag beside it reverts the moment Azahar writes its own
configuration once. `modules/emulators/default.nix:1299-1305` already carries
this treatment for `fullscreen` and `firstStart`, spelled with the backslash
QSettings' INI writer emits rather than the slash of the in-memory key path,
the first instance of the spelling rule set out below.
Every Azahar controller key this change owns therefore carries an owned
`<key>\default = false` in the same section wherever Azahar's writer emits that
flag beside it, which the on-disk confirmation the spelling rule requires
records per key, and the assertions that check the bindings check the
companions with them - so a binding written without its flag fails a check
here rather than reverting silently on the box.

The companion is **enforced** whatever tier its binding sits in. Azahar's own
bindings are enforced as well, under the pad-identity rule below, but the
flag's tier does not rest on theirs. The two keys do not say the same kind of
thing: the binding
expresses a preference a player may change, while the flag decides whether the
value is read at all. A flag left saying `true` does not preserve a player's
choice, it discards whatever value is in the file - the player's own included
- so seeding the flag would leave the very case seeding exists to protect
broken. It costs the player nothing, because rebinding inside Azahar's menus
rewrites the binding and its flag together, so enforcement finds the flag
already at `false` and corrects nothing. Binding and flag are distinct keys,
so one being enforced while the other is seeded is not the both-tiers overlap
the editor refuses.

**Every owned key and every owned value is spelled as the emulator's own
writer spells it.** The configuration editor compares key text literally and
writes values verbatim, so a key spelled otherwise than the emulator's writer
would spell it is a different key to the editor, and a value spelled otherwise
is a different value to the emulator. A pinned value cannot catch that: pinned
against the flake's own spelling, it agrees with the flake whatever the
emulator reads. So every key and every value this change owns is declared
exactly as that emulator's own writer would write it, confirmed by a
round-trip through that writer, or by reading a file the emulator itself
wrote, and recorded beside the key table, and the pinned expectations
hand-type that spelling. This is not a new idea. The tree learned it for
Azahar's `<key>\default` backslash, found empirically with a QSettings
round-trip (the comment on the Azahar table in `modules/emulators/default.nix`),
and the same writer supplies a further instance this change meets in Azahar's
gameplay bindings, beside a rule of that writer's that holds for any key owned
in its files:

- Values: a string value containing a comma is wrapped in double quotes, and
  an unquoted comma-separated Azahar binding is read back as a list rather
  than a string.
- Key names: QSettings percent-encodes characters outside its plain key set,
  so a space is written as `%20`, and any owned key the determination finds
  carrying such a character is declared in that encoded form.

These are instances, not an exhaustive list: the determination records the
on-disk spelling of every key and value owned in every emulator.

**A binding value names no particular pad wherever the emulator allows it.**
Some owned values name the pad itself rather than an input on it: a section's
device selector naming the backend's own name for the device, or a binding
value carrying an SDL joystick GUID, which encodes the pad's bus, vendor,
product and version. Such a value is right only for the pad and the backend
it was taken from, and the spelling rule above cannot catch a wrong one: a
round-trip through the emulator's writer on the development machine, which is
macOS, produces a value spelled exactly as the writer spells it and naming a
device the box does not have. Nor would the status report notice, since its
accepted modes key on vendor and product alone, so a pad could be reported
accepted while an emulator's owned bindings named a different device. So the
determination prefers, per emulator, a binding form that names no particular
device, such as a device index, wherever the emulator offers one. Where the
emulator requires the pad's identity in a value, that value is a bring-up fact
like the port paths: recorded from the real pad under Linux, held beside the
port paths in the box's facts under `emubox.facts.controllerIdentities`, and
empty until bring-up.

It is read at bring-up from a command on the box that prints it in the form the
consuming emulator's input library reports it: the SDL joystick GUID, for
Azahar, and the SDL device name, which Dolphin's SDL backend uses, wherever the
determination finds a Dolphin `Device` line must name the pad. The command
comes from nixpkgs and is installed on the box, where the administrator works
at bring-up: `sdl-jstest`, "Simple SDL joystick test application for the
console", which lists joysticks with SDL's names and GUIDs, or an equivalent
nixpkgs tool that prints them, whichever the determination confirms. For each
identity-bearing key, the determination confirms that the tool's output
matches the form the emulator stores, which is the spelling rule above applied
to the tool's output. The value is read rather than derived because nothing
downstream catches a plausible but wrong one: the only capture method the tree
documents, `udevadm info -q property`, prints neither form, and a GUID or
device name assembled by hand from its output passes the editor, the pins, the
VM checks and the status report, which keys on vendor and product. A GUID also
includes the pad's USB device revision, which can differ between units of one
model, so it is taken from the real pad rather than from the model's
identifiers. The per-emulator bring-up check that the pad plays stays the
end-to-end check of each recorded value.

An owned key whose value needs an identity fact that is still empty is not
declared at all, in either tier, until the fact is recorded, and nothing is
declared in its place - the treatment Decision 1 gives the enumeration hint
while no ports are recorded, for the same reason. A value naming no device, or
the development machine's, would be written as if it were right: the editor,
the pins and the VM checks would all hold it as the owned value, while on the
box it names a device that is not there, so the binding it serves looks owned
and correct and no pad fires it.

Declaring the key late settles what is written, but not whether it is written.
A gameplay binding that depends on such a fact is therefore **enforced**,
together with every setting it depends on to reach a pad, which is declared
with it, so it is written at the first editor run after the fact is recorded,
whatever the emulator wrote into those keys in the meantime. Until then the
emulator's own value stands. Seeding would not do: a seeded key is written
only while the file has no assignment for it, and an emulator that writes its
own values into those keys would block a seeded binding for good. Azahar is
that emulator. It writes its whole `[Controls]` profile, keyboard defaults
included, every time it saves its configuration, so if it runs before bring-up
records the pad identity, its own values already fill the keys by the time the
flake declares its bindings, and a seed tier would never write them. On the
real box that puts those keys, and whatever depends on them to reach a pad, in
the inert state the slot names are already in until bring-up. The VM node
records a fixture value for each such fact beside its fixture ports, so the
keys are proven there, and a node whose facts leave them empty proves them
undeclared.

**Azahar's bindings are read through a profile array.** Azahar 2125.1.2 keeps
its controls as a QSettings array: `QtConfig::ReadControlValues` reads the
array whose length is `profiles\size`, and reads the flat legacy keys only
when that count is 0, and `SaveControlValues` writes the array back on every
save. Its bindings, which carry the pad's SDL joystick GUID and so fall under
the rule above, are therefore owned under the array's per-profile key prefix,
`profiles\1\`, and the array's count key `profiles\size` and its
active-profile index `profile` are owned beside them as settings the bindings
depend on to reach a pad: in the same enforced tier, declared with them, and
not read-gating flags, since they choose which stored bindings are read rather
than whether one stored value is. Their spellings, like every other owned
Azahar key's, are confirmed on disk through Azahar's own writer, as the
spelling rule requires, and so is whether the writer gives each of them a
`\default` companion.

### 3. Gameplay bindings follow whether a default can survive an owned file

The question is not whether an emulator's default binds the box's controller.
It is whether that default still reaches the emulator once the flake owns the
file the default lives in. Restating a default that cannot be lost costs a
large hand-derived table across every binding syntax the owned files use and
buys nothing;
omitting one that can be lost ships an unplayable system, and the file being
owned is what decides which of the two an emulator is.

Two shapes, and the determination establishes per emulator which one applies:

- **Compiled-in fallbacks.** The emulator holds its defaults in its own code
  and applies them for bindings the configuration file does not carry. The
  flake can own that file, write only the route back into it, and the pad
  still plays: the omitted bindings are supplied by the emulator, launch after
  launch.
- **Generated into the file.** The emulator writes its defaults into the
  configuration file on first run and afterwards reads only the file. When the
  flake owns that file, those defaults are ordinary file content with no owner
  - and the editor recreates a missing or unreadable owned file carrying the
  owned keys and nothing else, so a recreate erases every binding the flake
  did not write. Here the flake owns the complete gameplay binding set, for
  each system whose bindings live in that file, for every player that system
  supports up to player four, whatever a pristine install would have produced
  for those players, so a file the editor creates or recreates carries all of
  it. Where a pristine install's binding names an input the pad never sends,
  the control it serves does nothing even there, and the flake binds that
  control to the input the pad does report for it instead. PPSSPP's shoulders
  are the case: at v1.20.4 its pristine pad map binds PSP L and R to
  `NKCODE_BUTTON_7` and `NKCODE_BUTTON_8` (`Core/KeyMapDefaults.cpp:274-275`),
  codes its SDL layer never emits, since `SDL/SDLJoystick.cpp:127-142` maps
  the left shoulder to `NKCODE_BUTTON_6` (193) and the right to
  `NKCODE_BUTTON_5` (192), which are what the flake binds. In a file that
  already exists each binding is written in its tier, and a seeded one the
  emulator had already filled with its own value keeps that value, as the
  Migration Plan records.

PPSSPP is the confirmed second case, on two pieces of evidence taken together:
the editor's recreate branch creates a missing owned file containing only the
enforced and seeded keys, and PPSSPP's loader erases every default mapping
whose key the file omits. A `controls.ini` the flake owns and half-fills is a
pad with half its buttons dead, and the half that works is the half somebody
happened to list. PCSX2 and DuckStation are re-examined under that same
question - what the flake owning the file does to defaults written into it -
rather than under the disabled setup wizard, which an earlier reading named as
the cause and which is not the mechanism that decides this.

The determination is a task in this change, reading each emulator's
configuration handling at the version the flake locks, the method already used
to justify the existing key tables, and its evidence is recorded per emulator
beside that emulator's key table. Its unit is the emulator together with every
system the frontend assigns it, not the emulator alone: an emulator serving
more than one system may keep a separate controller profile per system, and a
system whose profile is left unowned launches with nothing bound. The table
below is therefore that determination's expected output rather than a closed
list. The general rules this design states are the authority - the tiers of
Decision 2, with the settings a binding depends on to reach a pad, the
writer's spelling and the preference for binding forms that name no particular
pad, and the rules below on slots, the route back and a
prepared file's acceptance - and the table records the instances they are
expected to produce at the pinned versions, each to be confirmed by the
determination rather than assumed. A fact the determination finds that the
table lacks is governed by the same rules. Current expectations:

| Emulator | File | What must be established |
|---|---|---|
| Dolphin | `GCPadNew.ini`, `WiimoteNew.ini`, `Hotkeys.ini`; slot settings in `Dolphin.ini` `[Core]` and `WiimoteNew.ini`; a `Device` line in each controller section of those three profiles | No pad bound by default; bindings and route back both needed. The frontend launches both the GameCube and the Wii systems through Dolphin, so the Wii profile is owned on the same rule as the GameCube one - Wii is half the systems Dolphin serves, and a Wii game launched with nothing bound is the failure this change exists to prevent. Confirm whether these profile files are read as the only source of bindings. Slot settings, to confirm: `Dolphin.ini` `[Core]` `SIDevice1`-`SIDevice3` and `WiimoteNew.ini` `[Wiimote2]`-`[Wiimote4]` `Source`, read as defaulting to no device, each connected for the further player it serves. `Device` lines, to confirm: each controller section's `Device` line, read as the default device that section's bindings resolve against, owned in the tier of the bindings it serves - `Hotkeys.ini` `[Hotkeys]` `Device` enforced with the route back, the gameplay profiles' `Device` lines seeded with their bindings, or, where the determination finds such a line must name the pad itself, enforced together with the bindings resolving against it and the slot settings those bindings depend on |
| Azahar | `qt-config.ini` `[Controls]` | Citra lineage defaults to keyboard; bindings needed, and **enforced**, since their SDL values carry the pad's joystick GUID, each with its enforced `<key>\default = false` companion in the same section wherever the writer emits one. The bindings sit under the QSettings `profiles` array's per-profile prefix `profiles\1\`, with the array's count `profiles\size` and the active-profile index `profile` owned beside them as settings they depend on, in the same enforced tier; spellings confirmed on disk through Azahar's own writer. Route back: none at the pinned version, deferred to a later change - Azahar persists a hotkey as a key sequence and a context only, so no pad input can reach "Exit Azahar", and nothing is owned for its route back |
| PCSX2 | `PCSX2.ini` `[Pad1]`, `[Hotkeys]`; the second pad's type in `PCSX2.ini` | Whether its pad defaults are compiled-in fallbacks or written into the file on first run, and so whether the complete set must be owned. Slot setting, to confirm: the second pad's type, read as defaulting to not connected, connected for player two; no multitap, so two players |
| DuckStation | `settings.ini` `[Pad1]`, `[Hotkeys]`; the second controller port's type in `settings.ini` | Same question. Slot setting, to confirm: the second controller port's type, read as defaulting to none, connected for player two where player two is bound; multitap left disabled, so two players |
| PPSSPP | `controls.ini`; `--pause-menu-exit` on the frontend's PSP launch command | Confirmed generated into the file, and the loader drops every mapping the file omits, so the flake owns the complete set for every player its system supports up to the fourth. Route back, to confirm: the exit action is pause then the pause menu's Exit, and whether that Exit confirms; the launch option that makes it reach the frontend is `--pause-menu-exit`, carried by the launch command because the settings it sets are never saved to a file |
| ScummVM | `scummvm.ini` keymapper | Whether its joystick keymap is compiled in or written into the file, and whether the flake owns the file it lands in |

How many players each emulator gets bindings for is part of the same
determination rather than a separate guess. Players are counted by a system's
native controller ports, without a multiplayer accessory such as a multitap,
so PlayStation and PlayStation 2 get two players each; why no accessory is
enabled is set out below with the slot settings. The task above produces the full
emulator-by-system-by-player matrix, and every emulator that needs bindings at
all gets them for each further player its system supports, up to player four
and no further: a two-player system gets a player two and no player three or
player four, and a system supporting more than four stops at the fourth. That
per-system bound governs both shapes above rather than only one of them. For
compiled-in fallbacks it bounds which unbound players the flake fills in; for
defaults generated into an owned file it bounds the complete set the flake
declares, which is every player that system supports up to the fourth rather
than only the players a pad is expected on.

Four is the ceiling everywhere, and it is the box's rather than any emulator's.
The configuration records four controller ports, so a fifth player's binding
names a pad that has nowhere to plug in; an emulator whose system supports more
players than that gets bindings through player four and no further. Writing the
rest would be a table nobody can exercise, kept in step with every binding
syntax the owned files use for the life of the box. The per-system count and
this ceiling bound the bindings the flake declares, not the existing content
of a readable file: a binding beyond them that a player or an emulator wrote
is unowned and stays, as the emulators capability's ownership rules require,
and only a file the editor recreates from nothing is bounded by them outright.
Dolphin and PCSX2 are the
expected answer - Dolphin through its fourth native port, PCSX2 with a second
player rather than four - not a fixed scope: if the
investigation finds another local-multiplayer standalone that binds no pad by
default, or binds one only in a file the flake owns, it is in scope by the
same rule, and a hard-coded pair would have made that finding unusable.

Those additional players' bindings are declared unconditionally - on a box with
no ports recorded exactly as on one with four. The binding names a controller
index the emulator assigns from its own enumeration; it does not name a port
this configuration records. Tying it to `controllerPorts`, whose list is empty
until bring-up, would ship a one-player Dolphin for no reason and would make
the requirement mean two different things on the test node and the real box.
The recorded port list stays the authority for player order alone.

**A further player's bindings need a connected slot.** At the versions the
flake pins, several emulators leave every controller slot after the first
disconnected by default, so a further player's bindings alone give a pad that
plays nothing. Read from upstream source at the pinned tags:

- Dolphin 2603a (`Source/Core/Core/Config/MainSettings.cpp`,
  `WiimoteSettings.cpp`): the GameCube ports `SIDevice1` to `SIDevice3` in
  `Dolphin.ini` `[Core]` default to no device, and `Source` for `Wiimote2` to
  `Wiimote4` in `WiimoteNew.ini` defaults to none.
- PCSX2 v2.6.3 (`pcsx2/SIO/Pad/Pad.cpp`): the second pad's type defaults to
  not connected, and pads beyond the second need a multitap port, which is off
  by default.
- DuckStation v0.1-11752 (`src/core/settings.h`): the second controller port's
  type defaults to none, and the multitap mode defaults to disabled.

So for every further player it declares bindings for, the flake also owns the
setting that connects that player's slot where the emulator leaves it
disconnected, and like those bindings it is declared whether or not any port is
recorded. It sits in the same tier as the bindings it makes usable, as
Decision 2's rule for a setting a binding depends on requires, and that is
**seeded** wherever those bindings are: whether a slot is connected is a
household's choice in the way a binding is, and a household that turns a slot
off in an emulator's own menus keeps that choice rather than having it
switched back on at the next frontend start. Where those bindings depend on a
pad-identity fact, it is enforced with them, under Decision 2's rule for such
bindings.
Several of these settings live in files the emulators capability already
owns - `Dolphin.ini`, `PCSX2.ini` and DuckStation's `settings.ini` - and the
controllers capability contributes them into those files' owned entries, at
paths built from `emubox.emulators.configDirs`, as it does for its other keys,
so a controller key stays the controllers capability's wherever it lands. The
table above lists these settings to be confirmed by the determination with the
rest of it.

An emulator whose first start rejects a configuration file this system
prepared - resetting it, prompting about it, or rewriting it for lack of some
key - has the key that start checks enforced, so the prepared file is read as
its own. The determination asks every emulator that question, and this rule is
where each answer goes; PCSX2 is the case read so far, and its slot setting
needs that key before it can last. The
configuration editor creates `PCSX2.ini` before PCSX2 ever runs, carrying only
the owned keys, and PCSX2 v2.6.3 accepts its settings file only when `[UI]
SettingsVersion` equals 1 (`pcsx2/VMManager.cpp`, `CheckSettingsVersion`).
When an existing file fails that check, PCSX2 raises a modal question -
"Settings failed to load, or are the incorrect version. Clicking Yes will reset
all settings to defaults" (`pcsx2-qt/QtHost.cpp`). With only a pad at the box,
No leaves PCSX2 refusing to start, and Yes resets every setting to PCSX2's
defaults, the seeded ones included, which the seed tier never restores because
it leaves an existing assignment alone. PCSX2 treats a prepared file without
its settings version as one to reset, so the emulators module owns
`UI.SettingsVersion = 1` in PCSX2's file, enforced. It owns no settings version
for PCSX2 today, so this affects the box as it already ships, and the seeded
PCSX2 slot setting above depends on it. DuckStation v0.1-11752 is the
counter-example: it writes defaults only when its file is absent and loads an
existing file as-is (`src/core/core.cpp`), so it needs no such key. This reading is from upstream source; an
executable run of PCSX2 could not be completed on the development machine, so
the determination records it with the other findings and the bring-up
checklist confirms it on real hardware. The key is one enforced setting and
harmless if the reading is wrong.

A system's supported players are its native controller ports, without a
multiplayer accessory. A multitap changes how some games detect controllers
and can break one- and two-player play, so enabling one to reach a third or
fourth player would trade the common case for a rare one. No multitap is
enabled, and PlayStation and PlayStation 2 get two players each: the slot
settings stop at the second pad for PCSX2 and DuckStation, while Dolphin's,
whose systems have four native ports, reach the fourth.

An emulator whose determination answers with a native input backend of its own
rather than the system's game controller library is outside the enumeration
order the session declares: the hint reaches that library and nothing else, so
which pad such an emulator calls player one is its own business. Two outcomes
are allowed and the determination picks per emulator. Either its gameplay
bindings are written against something the recorded ports do control - a device
node the port names resolve to, which the naming rule supplies whatever
enumerates it - and the order holds for it after all; or they are not, and then
the port-order guarantee does not hold for that emulator, and that limit is
recorded beside its key table with the evidence, and stated in the README,
rather than left as a promise the box does not keep. The requirement is already
scoped to emulators that read controllers through the system's game controller
library, so recording the limit is what keeps the specs and the built box
saying the same thing.

RetroArch, the frontend's core-based emulator, is asked the same question, and
its joypad driver is left as it is. Only the second outcome is open to it,
since this change owns none of its bindings: if the determination finds it
enumerating controllers through a backend of its own, as upstream's default
`udev` joypad driver would, the recorded port order is not promised for
RetroArch, the limit is recorded beside the controllers module's key tables,
RetroArch having no table of its own, and in the README, and the bring-up
check that a pad is presented once covers RetroArch's backend, with its order
clause waived.

Several of these emulators express a hotkey binding as an alternative of
inputs rather than a simultaneous combination, so a Start-plus-Select chord
matching RetroArch's may not be expressible everywhere. Where it is not, the
route back is a single unlikely binding chosen per emulator and recorded with
its reason, which is why the spec requires the binding to exist rather than
requiring one uniform combination.

What may not vary is where the route back lands. It is bound to the action
that ends the emulator's process under the command the frontend launches it
with, so the player is back in the frontend with no prompt in between that a
pad cannot answer; a binding that is present but stops at the emulator's own
menu, or at a confirmation dialog, has returned nobody. At the versions the
flake pins, one emulator shows that the binding's presence is not enough on
its own, and one has no binding a pad can reach at all. Read from upstream
source at the pinned tags:

- Azahar 2125.1.2 offers no route back a pad can take. It declares an "Exit
  Azahar" hotkey beside "Stop Emulation"
  (`src/citra_qt/configuration/config.cpp`), but it persists a hotkey as a key
  sequence and a context and nothing else (`src/citra_qt/uisettings.h`,
  `ContextualShortcut`; `src/citra_qt/configuration/config.cpp`,
  `ReadShortcutValues` and `SaveShortcutValues`, which read and write only the
  key sequence). Its in-memory hotkey structure has a `controller_keyseq`
  member (`src/citra_qt/hotkeys.h`), but `hotkeys.cpp` never sets it and
  nothing saves it, and the hotkeys dialog shows it only as a column that
  cannot be edited. So no pad input can reach "Exit Azahar", and the box has
  no keyboard. Azahar is therefore the one standalone without a pad route back
  at the pinned version: this change owns no route-back binding for it and no
  `confirmClose` either, since a confirmation matters only to a route back
  that exists, and defers its route back to a change of its own, recorded as a
  known limit under Risks. Moving 3DS to another emulator was declined, since
  it would need a `saves` delta and a save-data migration: Azahar stays the 3DS
  emulator, and its gameplay bindings and every other setting it owns stay as
  this design sets them out.
- PPSSPP 1.20.4: leaving a game goes to PPSSPP's own menu. Its
  `PauseExitsEmulator` and `PauseMenuExitsEmulator` settings default to false
  and are not saved in its configuration file (`Core/Config.cpp`); only the
  launch options `--escape-exit` and `--pause-menu-exit` set them
  (`UI/NativeApp.cpp`). `--pause-menu-exit` turns the pause menu's "Exit to
  menu" into "Exit", so pause then Exit is a way out of the program a pad can
  reach. PPSSPP's owned route back is that: pause, bound to the pad, then
  Exit. It needs `--pause-menu-exit` on the frontend's PSP launch command,
  which carries no such option today and which the emulators module owns
  (`modules/emulators/default.nix`, `pspOverride`), so that module gains the
  option in this change; no owned file could carry it instead, because the
  settings it sets are never saved.

The frontend launches Dolphin with `-b`, PCSX2 and DuckStation with `-batch`,
and ScummVM relies on its own owned settings, so those four already exit to
the frontend when emulation stops. The determination confirms each, together
with whether stopping raises a confirmation of its own first, since a
confirmation there is suppressed by an owned setting, enforced like the
binding it serves.

### 4. `emubox-status` becomes an aggregator over registered reporters

A new `pkgs/emubox-status` runs reporters registered through a module option
(`emubox.status.reporters`, a list of name and command) rendered to
`/etc/emubox/status-reporters`, which the aggregator reads. The `environment.etc`
indirection is the shape already used for `emubox/bios-inventory.json`, and for
the same reason: an administrator never has to look up a store hash.

That option has an owner of its own: `modules/status/default.nix`, one
directory per concern as every other capability in `modules/` has. It declares
`emubox.status.reporters`, renders the registered list to that stable path and
puts the aggregator on the system path, so the capability's central new command
is somebody's rather than nobody's. Like every other module directory it is
added to the imports list in `modules/default.nix`, because a directory that
list does not name is never evaluated: the option would then not exist, and
every module registering a reporter against it would fail host evaluation on an
undefined option - a failure whose cause is nowhere near where it surfaces.

The aggregator is a program this project writes, so it joins the package set in
`pkgs/default.nix` with the rest of them. That single entry is what puts it on
the overlay, offers it as a standalone `x86_64-linux` output and gathers it into
the store paths pushed to the public cache, so no consumer rebuilds it and its
licence posture is settled where the package is defined.

`modules/backups` registers `emubox-restic-backup --status`, whose program
keeps its status output and its exit statuses - only the `makeWrapper` alias
and the `argv[0]` dispatch are removed.

The registration sits **outside** the `lib.mkIf cfg.enable` branch that
installs the helper (`modules/backups/default.nix:149`), because the three
layers that program reports do not share one enable. `btrbk-local` is declared
unconditionally in `modules/saves`, so every box takes local snapshots, while
the off-site backup and maintenance units exist only under that guard - and
off-site backup is off by default, which is the current host setting and the
documented rollback path. A reporter inside the guard would leave the one
layer every box has reported by nobody. A reporter outside it that still
reported all three would warn forever about two units that were never meant to
exist on that box, which is the same thing as no status at all once an
administrator learns to ignore it.

So the reporter is registered on every box and told which layers to report:
the local layer alone where off-site backup is off, all three where it is on.
That is one added option on a program this change otherwise leaves alone - the
default `--status` invocation, which is what the helper's own unit tests
exercise, reports the same three layers with the same exit statuses it does
today. The registration names the helper by store path, as `modules/saves`
already does for the local marker, so it does not depend on the guard's
`environment.systemPackages`.

Naming it by store path is also what makes the execution contract above bite
here: the aggregator runs that argv with the environment untouched, so the
helper reaches `systemctl` and `journalctl` only through its own wrapper. It
does not today - the wrapper prefixes btrfs, restic and util-linux - so systemd
joins that wrapper's runtime path in this change. It is one line in the
package, and it is the difference between a backups section that reports the
box's layers and one that reports a file-not-found as a finding about them.

The status capability's "a capability contributes no report" case is
unaffected and still occurs: it belongs to a capability that registers no
reporter at all, of which this box has several, rather than to backups on a
box with off-site backup off.

`emubox-check-bios`, the emulators capability's BIOS check, is one of those:
it stays a separate command and registers no reporter in this change.
Registering it as it stands would have a box missing BIOS files for systems
the household never plays warn for the life of that box - the same standing
warning this change already refuses for empty controller ports and for the
off-site layers on a box without off-site backup. Deciding which missing BIOS
file is a finding belongs to a later change, and a BIOS reporter waits for
it. Until then `emubox-status` aggregates the reports registered with it and
makes no claim about the health of the whole box.

`modules/controllers` registers a reporter that lists which `emubox-pN`
symlinks resolve and warns for a controller identifying as none of the modes
the box accepts. A controller, for that warning, is an input event device udev
marks `ID_INPUT_JOYSTICK=1`, the property the port rule of Decision 1 already
matches, and its identity is the vendor and product the input device itself
reports, read from the input device rather than from udev's USB-derived
`ID_VENDOR_ID` and `ID_MODEL_ID`, which the reporter does not use. Both halves
carry weight. A reporter that enumerated every event device, or every device
with a vendor and product pair, would name the power button, a keyboard or a
receiver, and since that warning is the one condition that makes this report
unhealthy, a healthy box's `emubox-status` would exit unsuccessfully. And the
identity has to come from the input device, because the VM fixture is a
`uinput` device with no USB parent, so the USB-derived properties are absent
on it, while the input device's own identity is where the wired pad presents
`045e:028e`. The accepted set is a declared list rather than one constant,
so that a second mode can be added later without reworking the reporter, but on
the box this change ships it holds one entry: the wired pad, which presents
`045e:028e` in its default mode under the in-kernel `xpad` driver - the same
identity the RetroArch autoconfig profile keys on. Every mode in that list is
one a fixture can present and the VM node can assert, which is what keeps the
reporter's warning meaningful rather than resting on an identity nobody has
seen.

An empty slot is information rather than a finding, and that is the same
question the backups registration above answers for its layers, answered the
same way. A recorded port resolving to no pad is listed as unoccupied, a box
that records no ports is reported as recording none, and neither warns; a
controller identifying as none of the accepted modes stays the only thing this
reporter warns about. The box ships with no ports recorded, and a household
that plays two-player games leaves two of its four ports empty, so any other
policy would have `emubox-status` exit unsuccessfully on a perfectly healthy
box for the life of that box. That is the same forever-warning the backups
registration is shaped to avoid, and it ends the same way: an administrator
learns to ignore the warning, which is no status at all.

Rejected: teaching the backup program about controllers, which is the smallest
diff and the wrong shape - the backup program would grow knowledge of input
devices, and the next capability would grow another. Rejected: a second
`emubox-pads` command, which is cheapest now but fragments the operator surface
and makes `README.md:378` untrue.

Doing this now rather than later is deliberate: the remote-administration and
update capabilities will each want to report state, and each would otherwise
face this decision with more shipped code in the way.

### 5. The fixture proves the mapping this project owns

A test-only udev rule, ordered ahead of ours, sets `ENV{ID_PATH}` to a fixture
string and `ENV{ID_INPUT_JOYSTICK}="1"` on a device created through `uinput`.
The test node's `emubox.facts.controllerPorts` holds those same fixture
strings. The assertion is that the player names resolve, in order.

The node is registered in the flake's host-only check set, beside `kiosk`,
`session` and `retroarch-settings`, not among the per-system checks. It is a
NixOS VM test, so offering it per-system would have it evaluated for a system
it cannot be built for - precisely the split that set exists to keep, and
which the flake's own comment records. The new aggregator's unit tests are a
different matter and go in the per-system set beside the other helper
packages, so the admin's Mac runs them natively without a builder.

Membership of that set is not by itself enough to be caught before a push. A
host-only check is evaluated on a machine that cannot build it only through the
justfile's hand-maintained enumeration of derivation paths, which is the whole
of the local gate for those checks, so the one host-only check this change adds
- the controllers node - is added to that enumeration. Left out, it would be a
check whose evaluation errors are first seen in CI, which is exactly the gap
the local gate exists to close.

This narrows the claim deliberately. What the flake owns is the mapping from a
recorded device path to a player name, and that is what gets proven. The device
path itself is computed by systemd's `path_id` builtin, which is not this
project's code and is covered by systemd's own tests, and the values it will
produce on the real box are a bring-up fact no VM can supply. A fixture built
on the virtual machine's bus topology would couple the suite to QEMU's port
numbering while proving no more - and, as Context records, would not fire the
rule at all.

The presence and ordering of the session hint is asserted on the same node
against `/etc/set-environment`, where `environment.sessionVariables` lands by
way of `environment.variables`
(`nixos/modules/config/shells-environment.nix:231,248`), so that node needs no
graphical session. It is made to have none rather than merely spared one: the
boot adaptations below leave the display manager and its autologin on, and the
kiosk session runs `emubox-prepare` on every loop before starting the
frontend, so the node sets `services.displayManager.sddm.enable =
lib.mkForce false` on itself, as the install node does, rather than in the
module it shares with the kiosk node, which needs its session - left on, the
editor would run alongside, and between, the test's own runs. Without one, nothing on the node runs the configuration
editor, whose only caller on the box is the kiosk session script, so the test
runs the node's own `emubox-prepare` as `player` against the node's rendered
owned-values file, taken from the node's configuration rather than rebuilt by
the test, as `tests/kiosk.nix` already does, for the first run and every
re-run and recreate the owned-key checks need. The absence case belongs to the kiosk node instead, which
imports the real `hosts/emubox/facts.nix` (`tests/kiosk.nix:485`) and therefore
has no recorded ports.

Being a plain node built from the box's modules, the controllers node carries
the boot adaptations the kiosk node already makes for the same reason - the
initrd units that roll the root back and bind `/persist` suppressed, tmpfs
stand-ins for `/persist` and `/data` needed for boot, sops pointed at the
committed test secrets, and sshd off - preferably from one test module both
nodes import, so the two cannot drift.

The controllers node is a plain one without the box's btrfs snapshot layer, so
its backups section reports the local layer as not yet run and warns, and the
proof is divided accordingly: the controllers node proves the controllers
report and the aggregation's sections, and the install node, which has the
real btrfs layout, runs the local snapshot job and records no ports, proves a
healthy aggregate.

## Risks / Trade-offs

- **A misread emulator default** → either a redundant assertion, which is
  cheap, or an emulator that is unplayable until bring-up, which is not. The
  sharper version of the same risk is misreading where a default lives: a
  default generated into a file the flake owns, mistaken for a compiled-in
  fallback, is erased the first time that file is recreated, and the emulator
  is playable in the VM and dead on the box. The determination task records
  its evidence per emulator, naming which of the two shapes it found and where
  it read that, and the bring-up checklist gains a per-emulator "the pad plays,
  the route back returns to the frontend with no prompt in between" line -
  for Azahar, the pad plays and its deferred route back is recorded - and
  for each emulator whose first start rejects a prepared file, PCSX2 among
  them, a check that its first start on a freshly prepared box raises no
  settings prompt.
- **The slot mechanism is inert on the real box until bring-up** → intended,
  and it matches every other hardware fact, but its first real exercise is at
  bring-up. The VM fixture is what stands in for it, and the "no ports
  recorded" scenario exists so that the inert state is itself asserted rather
  than merely assumed to be harmless.
- **The status split touches shipped code the backups capability owns** → the
  blast radius is one `makeWrapper` line and one `argv[0]` branch, and the
  reporter keeps the identical `--status` interface, so the backup program's
  behaviour is unchanged and only its second name moves. The three
  `emubox-status` call sites in the install VM test - the one that expects
  success and the two fault-injection ones that match on a substring - are
  updated to say which of the two they mean. `tests/backups.nix` is
  evaluation-only and names no command, so it is untouched.
- **Enforcing the route back overrides a player who rebinds it** → deliberate,
  and the same trade already made for the two RetroArch combos: one lost
  rebinding costs less than a family stuck inside a game.
- **Azahar cannot be left with a pad at the pinned version** → accepted as a
  deferred gap and recorded rather than papered over. Azahar persists each
  hotkey as a keyboard sequence and nothing else, so none of its actions can be
  bound to a pad, and the box has no keyboard: a family member in a 3DS game
  plays with the pad but leaves Azahar no better off than before this change.
  A later change closes the gap, by one of an upstream Azahar that persists
  controller hotkeys, a layer that turns pad input into the key sequence
  Azahar already listens for, or a different 3DS emulator together with a
  migration of its save data.
- **Wireless pads stay unusable on the box until a later change** → accepted,
  and it is the point of the scope decision rather than a side effect. A family
  that owns a wireless pad has to reach for a cable until the change that
  brings a surface capable of pairing one lands. What that buys is a change
  whose every requirement is reachable and asserted on the box as it ships,
  instead of one whose central feature could not be invoked at all.

## Migration Plan

No state migration. Two transitions matter on an already-running box:

- `emubox-status` keeps its name and its argument-free invocation, so an
  administrator's habit and `README.md` stay correct; only what it prints
  grows.
- The new owned input keys reach existing emulator configuration files by
  tier, and a file a player has customised keeps every unowned key. An
  enforced key is written at the next launch whatever the file holds: the
  route back, the bindings that depend on a pad-identity fact and the settings
  they depend on, the acceptance keys, and the read-gating flags. A seeded key
  is written only where the file has no assignment for it, so on a box where
  an emulator had already written its own value into a seeded key, that value
  stands. The only machines that have run these emulators under the flake
  before this change are the VM test nodes, which start from fresh
  configuration.

Rollback is a generation rollback; nothing here writes state that a previous
generation cannot read.
