## Why

Every key the flake owns in the ten emulator and frontend configuration
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
passes `--appendconfig`, but `retroarch.withCores` forwards only the core
list, so the file the flag points at carries nixpkgs' three wrapper
defaults (the asset, joypad autoconfig and core-info directories) and none
of the flake's own settings.

## What Changes

- Owned keys split into two tiers. **Enforced** keeps today's behaviour:
  asserted before every launch, corrected on drift, reduced to one
  assignment, removable. **Seeded** is written only when the key is absent
  from the file; once present, whatever value it holds, the flake stops
  having an opinion - never corrected, never swept, never removed.
- Twelve keys become seeded (seven settings, the five keyboard hotkeys
  counted one by one): ES-DE `Theme` and `ApplicationLanguage`; RetroArch
  `menu_driver`, `input_menu_toggle`, `input_save_state`,
  `input_load_state`, `input_toggle_fast_forward` and `input_screenshot`;
  Dolphin `Core.CPUThread`; PCSX2 `EmuCore/GS.upscale_multiplier`;
  DuckStation `GPU.PGXPEnable` and `GPU.ResolutionScale`. Everything else
  stays enforced.
- Eight of RetroArch's enforced, statically known settings
  (`video_fullscreen`, `libretro_directory`, `system_directory`,
  `autosave_interval`, `menu_show_online_updater`,
  `menu_show_core_updater`, `input_menu_toggle_gamepad_combo`,
  `input_quit_gamepad_combo`) move out of the parse-and-merge path into a
  flake-owned `--appendconfig` file built by nixpkgs' `wrapRetroArch`,
  fixing the latent defect: the file gains the flake's eight settings
  alongside the wrapper's three defaults, where today it carries only the
  three. The two save directories
  (`savefile_directory`, `savestate_directory`) stay enforced in
  `retroarch.cfg`: the `saves` capability's route table names them as owned
  `retroarch.cfg` keys with parsed owned-key evidence, and that table is not
  changed here. Runtime-determined values (credentials, the
  RetroAchievements switches) and seeded keys stay in `retroarch.cfg` too.
- The module schema renames `keys` to `enforce` and adds `seed` on every
  file declaration; the JSON contract to `emubox-prepare` carries the same
  split as a hard cutover - exactly `enforce` and `seed` per file, with a
  document still spelling `keys` refused as a broken call site and no
  transition alias - and the editors gain a seed branch: append when
  absent, otherwise do nothing. A setting belongs to exactly one tier: a
  declaration that places one key in both maps of one file is rejected at
  evaluation, as is one that lists a RetroAchievements target key under
  its file's `seed` map, and a rendered document that does so anyway
  (including
  through a RetroAchievements target key merged at runtime onto a seeded
  key) is refused by prepare when the rendered declaration is validated,
  before the RetroAchievements login is attempted and before any file,
  credential files included, is written, as is a removal declared on a
  seeded key.
- The kiosk VM test asserts the player-facing promise - a seeded frontend
  setting changed while the frontend is stopped survives the next boot -
  and proves the append file at runtime: its headless RetroArch launches
  carry the flake's file, and a stale enforced value baked into
  `retroarch.cfg` loses to it.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `kiosk`: the "flake owns some frontend settings" requirement splits into
  enforced and seeded tiers - theme and language become seeded, the
  exactly-once and drift-correction guarantees narrow to enforced keys,
  a setting belongs to exactly one tier, and seeded scenarios are added.
- `emulators`: the "flake owns each emulator's launch settings" requirement
  splits the same way - the SHALL-pin list loses the uniform hotkey set and
  the three per-emulator performance choices to the seeded tier, a setting
  belongs to exactly one tier, a removal declared on a seeded key is
  refused before any file is written, a RetroAchievements-managed setting
  placed under the seeded tier is refused before the system is built or,
  failing that, before any file is written, and eight of RetroArch's
  enforced static settings are delivered through a launch-time append
  file rather than edits to `retroarch.cfg`, with every file-level rule
  excluding them; that file carries the eight alongside the package
  wrapper's own directory paths, and no credential and no seeded setting.
  The save and state directories stay in `retroarch.cfg`; the `saves`
  capability is unchanged.
- `vm-test`: the kiosk VM test's assertion list gains the seeded-setting
  survival check and a runtime check that RetroArch's launch-delivered
  settings win over a stale copy in `retroarch.cfg`.

## Impact

- `modules/kiosk/default.nix`: file-entry submodule schema (`enforce` +
  `seed`), ES-DE declaration, JSON contract rendering, a module assertion
  that no file declares a key in both maps and that no RetroAchievements
  target key is listed under its file's `seed` map.
- `modules/emulators/default.nix`: every emulator file declaration re-tiered;
  the RetroArch package call moves from `pkgs.retroarch.withCores` to
  `pkgs.wrapRetroArch { cores; settings; }`; `raDisabledFiles` writes its
  two switches into `enforce` rather than `keys`.
- `pkgs/emubox-prepare/emubox_prepare.py` and its tests: two-map contract
  (a per-file table carries exactly `format`, `enforce` and `seed`; a
  table carrying `keys`, lacking either map, or carrying any other field
  is refused as a broken call site, and both maps get the per-format inner
  shape check the single map gets today), seed branch in
  all three editors, a key in both maps of one file and a
  RetroAchievements target key that its file seeds both refused as broken
  call sites before the RetroAchievements login is attempted and before
  any file, credential files included, is written, seeded keys excluded
  from duplicate sweeping. The unit suite's rendered owned-values fixtures
  and editor calls, which spell the old single `keys` map today, are
  re-rendered to the two-map contract with no behavioural edits, and
  rejection tests cover a document carrying `keys`, one missing `enforce`,
  one missing `seed`, one carrying an unexpected extra field, and one with
  a malformed seeded entry.
- `tests/retroachievements-disabled.nix`: reads each file's `enforce` map
  where it read `keys`.
- `tests/saves.nix`: its three reads of the RetroArch and ScummVM owned
  maps follow the schema rename from `keys` to `enforce`; the `saves`
  route table, the expected values and every other assertion in the file
  are unchanged.
- `tests/kiosk.nix`: the ES-DE literal pin splits into an `enforce` literal
  and a `seed` literal; the eight launch-delivered RetroArch keys leave
  `PINNED_OWNED_KEYS` (the flake check owns them); the owned-key walks
  assert enforced keys by value and seeded keys by presence; the headless
  RetroArch launches join the flake's append file and the test override in
  one `--appendconfig` flag; a runtime precedence assertion; the
  seeded-survival assertion.
- `flake.nix` checks: a derivation check in the `hostOnly` set
  (x86_64-linux only, beside `kiosk` and `session`, since RetroArch is
  marked broken on Darwin) that selects the RetroArch package from the
  host's `environment.systemPackages` by the `cores` filter `cache-roots`
  uses, that its wrapped binary embeds exactly one distinct
  `--appendconfig` path, that the file at that path carries the eight
  flake keys with the flake's values and the wrapper's three default
  paths by name, no credential, none of the six seeded RetroArch keys
  and neither save-directory key, and that the package exposes a
  non-empty `passthru.cores` equal to a core list hand-typed in the
  check; and a per-system eval-only check that the module's overlap
  assertion fires on a flat-file key in both maps, a sectioned key in
  both maps, and a RetroAchievements target key under its file's `seed`.
- No new dependencies, no new secrets, no account-side work. Rollback is
  `git revert`.
