## Why

Every key the flake owns in the nine emulator and frontend configuration
files is enforced before every launch: written if missing, corrected if it
drifted. That is the right guarantee for the settings that make the box a
console (fullscreen, directories, kiosk mode, credentials), but it is applied
today to settings that are pure preference - the ES-DE theme and language,
RetroArch's menu skin and keyboard hotkeys, per-title performance toggles -
so a choice a player makes in an emulator's own menus is silently reverted
at the next launch, forever. For ES-DE this contradicts the kiosk module's
own documented promise that a preference changed in its menus survives a
reboot. If this is not fixed, the box quietly fights its players on exactly
the settings it promised to leave alone, and the contradiction between the
shipped behaviour and the module's documentation stands.

A second, latent defect rides along: the flake's RetroArch wrapper already
passes `--appendconfig`, but `retroarch.withCores` drops the `settings`
argument, so the flag points at an empty file and delivers nothing.

## What Changes

- Owned keys split into two tiers. **Enforced** keeps today's behaviour:
  asserted before every launch, corrected on drift, reduced to one
  assignment, removable. **Seeded** is written only when the key is absent
  from the file; once present, whatever value it holds, the flake stops
  having an opinion - never corrected, never swept, never removed.
- Eight keys become seeded: ES-DE `Theme` and `ApplicationLanguage`,
  RetroArch `menu_driver` and the five keyboard hotkeys, Dolphin
  `Core.CPUThread`, PCSX2 `EmuCore/GS.upscale_multiplier`, DuckStation
  `GPU.PGXPEnable` and `GPU.ResolutionScale`. Everything else stays
  enforced.
- RetroArch's enforced, statically known settings (ten keys) move out of the
  parse-and-merge path into a flake-owned `--appendconfig` file built by
  nixpkgs' `wrapRetroArch`, fixing the latent empty-file bug. Runtime-
  determined values (credentials, the RetroAchievements switches) and seeded
  keys stay in `retroarch.cfg`.
- The module schema renames `keys` to `enforce` and adds `seed` on every
  file declaration; the JSON contract to `emubox-prepare` carries the same
  split, and the editors gain a seed branch: append when absent, otherwise
  do nothing.
- The kiosk VM test asserts the player-facing promise: a seeded frontend
  setting changed between boots survives the next boot.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `kiosk`: the "flake owns some frontend settings" requirement splits into
  enforced and seeded tiers - theme and language become seeded, the
  exactly-once and drift-correction guarantees narrow to enforced keys, and
  seeded scenarios are added.
- `emulators`: the "flake owns each emulator's launch settings" requirement
  splits the same way - the SHALL-pin list loses the uniform hotkey set and
  the three per-emulator performance choices to the seeded tier, and
  RetroArch's enforced static settings are delivered through a launch-time
  append file rather than edits to `retroarch.cfg`.
- `vm-test`: the kiosk VM test's assertion list gains the seeded-setting
  survival check.

## Impact

- `modules/kiosk/default.nix`: file-entry submodule schema (`enforce` +
  `seed`), ES-DE declaration, JSON contract rendering.
- `modules/emulators/default.nix`: every emulator file declaration re-tiered;
  the RetroArch package call moves from `pkgs.retroarch.withCores` to
  `pkgs.wrapRetroArch { cores; settings; }`.
- `pkgs/emubox-prepare/emubox_prepare.py` and its tests: two-map contract,
  seed branch in all three editors, `REMOVE` rejected on seeded keys,
  seeded keys excluded from duplicate sweeping.
- `tests/kiosk.nix`: seeded-survival assertion; a derivation check that the
  wrapper's append file is non-empty and carries the enforced keys.
- No new dependencies, no new secrets, no account-side work. Rollback is
  `git revert`.
