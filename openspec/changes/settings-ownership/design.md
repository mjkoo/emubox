## Context

See proposal.md - Why for motivation. Current state, verified against the
tree at the branch point:

- `emubox-prepare` runs before every launch of the frontend and asserts the
  keys the flake owns in nine configuration files. The file-entry submodule
  is `format` plus `keys` (`modules/kiosk/default.nix:229-248`), the JSON
  contract carries one key map per file, and each editor writes a missing
  key and corrects a drifted one (`set_esde_settings` at
  `pkgs/emubox-prepare/emubox_prepare.py:557`, `set_ini_settings` at
  `:1071`, `set_retroarch_settings` at `:1190`; the flat editors drive a
  lossless syntax tree through `_write_key` at `:992` and `_sweep_key` at
  `:979`). The only conditional write in the program is DuckStation's
  `login_timestamp`, which is change-gating, not deference to a player.
- The kiosk module's own header comment promises that a preference changed
  in the frontend's menus survives a reboot, while ES-DE's `Theme` and
  `ApplicationLanguage` are enforced on every launch - a shipped
  contradiction.
- The flake's RetroArch package is `pkgs.retroarch.withCores`
  (`modules/emulators/default.nix:124`). At the pinned nixpkgs,
  `wrapRetroArch` accepts `{ cores, settings }`, renders the settings to a
  `declarative-retroarch.cfg` in the store and wraps the binary with
  `--appendconfig` pointing at it - but `passthru.withCores` forwards only
  `cores`, so today the flag points at an empty file and delivers nothing.
- Owned key and section names are validated to read back as themselves; a
  name that would classify differently on the next read is dropped with a
  note instead of written.

## Goals / Non-Goals

**Goals:**

- A player's tuning in an emulator's own menus survives, for every setting
  the box does not actually depend on.
- The flake still guarantees every setting that makes the box a console
  rather than a desktop, and every credential.
- Fewer writes to configuration files on an established box.
- Where an emulator supports it, deliver enforced settings as a file the
  flake owns outright rather than by editing the emulator's own file.

**Non-Goals:**

- Removing `emubox-prepare`'s parse-and-merge editors. Three of the nine
  files cannot be delivered any other way (decision 3), so the machinery
  stays.
- Moving PPSSPP, Dolphin, ScummVM or PCSX2 to their override mechanisms.
  Each is command-line rather than file-discovery (PPSSPP and ScummVM take
  a config path on the command line, Dolphin takes repeatable
  `-C Section.Key=Value` pairs, PCSX2's `inis/secrets.ini` overrides
  everything except `Achievements.Username`), so moving them means editing
  every launch command in the frontend's system overrides - a permanent
  upstream-tracking surface for a handful of already change-gated writes.
  Deferred, not rejected.
- Changing the recreate-not-fail policy, the removal semantics, or the
  credential paths.

## Decisions

### 1. Two tiers: enforced and seeded

The ownership vocabulary, used by the `kiosk` and `emulators` delta specs
and by every artifact in this change:

| Tier | Written when | Corrected on drift | Repeats swept | Removable |
|---|---|---|---|---|
| enforced | missing at any launch | yes | yes, to one assignment | yes |
| seeded | no assignment exists | never | never | never |
| unowned | never | never | never | never |

Alternative rejected: a per-key "write policy" enum with more states
(write-once, write-if-file-new, enforce-unless-touched). Two tiers cover
every key actually shipped, and each extra state is a new class of
subtle behaviour to test and explain.

### 2. Seeded means write-if-key-absent

Not write-if-file-absent. A seeded key added by a later flake bump reaches
boxes that already exist, and a key a player deletes returns to the flake's
default rather than the emulator's. The rejected alternative - seeding only
when the file is created - would make a box's defaults depend on when it
was first booted.

"Absent" means no assignment of the key exists among the places that
belong to it. A key present with an empty value is present and is left
alone; anything else would need a second notion of "unset" per format.

Recreation writes both tiers, because a recreated file is missing every
key. Recreation therefore resets seeded settings to flake defaults. That
is the one case where a player loses a tuning choice, and it is the honest
consequence of recreate-not-fail.

Seeded keys are owned names, so the owned-name validation applies to both
maps identically: a seeded key or section name that does not read back as
itself is dropped with a note, exactly as an enforced one is.

### 3. Delivery follows from the tier

A key delivered through a launch-time override is applied on every load by
construction. Override delivery *is* enforcement and cannot express
seeding. A second constraint sits alongside: the append file is a store
path built at evaluation time, so only statically known values can go in
it. Anything prepare decides at runtime stays in the parse path even when
it is enforced - for RetroArch that is `cheevos_username` and
`cheevos_token`, and also `cheevos_enable` and
`cheevos_hardcore_mode_enable`, which are static only when
RetroAchievements is switched off and are written from the login result
otherwise.

| | Enforced | Seeded |
|---|---|---|
| RetroArch, statically known | flake-owned append file | parse-and-merge into `retroarch.cfg` |
| RetroArch, runtime-determined | parse-and-merge into `retroarch.cfg` | not applicable |
| Every other file | parse-and-merge | parse-and-merge |

### 4. RetroArch moves to `--appendconfig`; nothing else moves

Verified against RetroArch 1.22.2, the pinned revision:
`--appendconfig=FILE` merges into the same `config_file_t` before settings
extraction and wins over the main config. Moving the module from
`pkgs.retroarch.withCores` to `pkgs.wrapRetroArch { cores; settings; }`
gives a flake-owned whole file with no patch and no wrapper of our own,
and fixes the latent empty-file bug (Context). One shape difference at the
call site: `withCores` takes a function over `libretro`, while
`wrapRetroArch` takes the core list directly.

Two corrections to RetroArch's published documentation, both read from the
pinned source: the appendconfig path list is `|`-delimited, not
comma-delimited as `docs/retroarch.6` and docs.libretro.com state
(`configuration.c:3871`); and appended values *are* written back into
`retroarch.cfg` by `config_save_file()`, which rebuilds the file from the
in-memory settings struct (`configuration.c:5449-5678`).
`config_save_on_exit` defaults true and `--appendconfig` alone does not
set the overrides-active flag, so the exit write still happens.

That write-back is the second reason credentials stay in the parse path,
on top of the store-path constraint. Removal means absence, and a blank
value will not do - RetroArch treats any `cheevos_token` it finds as a
token to log in with. An appended credential would be baked into
`retroarch.cfg` and survive its own removal, so the credentials continue
to be written and swept in `retroarch.cfg` directly.

What moves to the append file is RetroArch's enforced, statically known
settings, ten keys: `video_fullscreen`, `libretro_directory`,
`system_directory`, `savefile_directory`, `savestate_directory`,
`autosave_interval`, `menu_show_online_updater`, `menu_show_core_updater`,
`input_menu_toggle_gamepad_combo` and `input_quit_gamepad_combo`. The two
save directories qualify under the same rule as the rest: statically
known, enforced, nothing reads their values back out of `retroarch.cfg`
(the save routes are declared in Nix), and the write-back bakes the same
correct values. What stays in `retroarch.cfg` is the seeds, the
credentials and the two RetroAchievements policy switches.

The other emulators stay on parse-and-merge. DuckStation, Azahar and ES-DE
cannot move at all: none has a drop-in, include or alternate-config
mechanism; all three regenerate their primary file wholesale (Azahar
rewrites at startup, ES-DE regenerates the document from its in-memory
map on save), so parse-and-merge is not fragility to engineer away but
the only correct approach. PPSSPP, Dolphin, ScummVM and PCSX2 could move
but will not, for now (Non-Goals). The DuckStation, PCSX2 and Dolphin
mechanisms were read at upstream master rather than at the flake's pins;
they are long-standing, and since this change does not depend on them,
nothing here rests on that. RetroArch and ES-DE were read at the exact
pinned revisions.

### 5. Which keys are seeded

Eight keys move; everything else stays enforced.

| File | Key | Reason |
|---|---|---|
| `es_settings.xml` | `Theme` | Appearance. Enforcing it contradicts the module's own promise. |
| `es_settings.xml` | `ApplicationLanguage` | Locale; no behaviour depends on it. |
| `retroarch.cfg` | `menu_driver` | Menu skin. |
| `retroarch.cfg` | `input_menu_toggle`, `input_save_state`, `input_load_state`, `input_toggle_fast_forward`, `input_screenshot` | Keyboard hotkeys; controller work has not landed, so these are near-inert today. |
| `Dolphin.ini` | `Core.CPUThread` | Compatibility-versus-speed judgement, reasonably flipped per title. |
| `PCSX2.ini` | `EmuCore/GS.upscale_multiplier` | Taste. The literal stays `1`, not `1.000000`, or a seed write becomes a drift rewrite. |
| DuckStation `settings.ini` | `GPU.PGXPEnable` | Taste. |
| DuckStation `settings.ini` | `GPU.ResolutionScale` | Taste, and its own comment calls it unverified config data to revisit at hardware bring-up. |

Enforced, and deliberately so: every `fullscreen`; every BIOS and core
directory; every first-run or setup-wizard suppression; Azahar's two
`\default` guards, without which Azahar ignores the value it is given;
both RetroArch gamepad combos, the only controller-only route back to the
menu and out of a game; the two updater menu entries, the routes to
pulling unvetted cores onto the box; ES-DE's UI mode, passkey, ROM and
media directories and quit menu; ScummVM's exit-confirmation suppression
and return-to-launcher; and every credential and RetroAchievements policy
switch.

Four calls worth recording rather than burying:

- `autosave_interval = 30` stays enforced. A player who sets it to 0 loses
  progress silently on a box where power is pulled at the wall. A
  durability floor is different in kind from a look.
- Dolphin `Analytics.Enabled = False` stays enforced. The flake suppresses
  the consent prompt, so it has to answer it; leaving the answer to
  upstream's default is worse than stating the declined answer.
- The RetroArch keyboard hotkeys are seeded, but arguably: hotkey
  uniformity across emulators is a family-facing property. Seeded because
  they are keyboard-only today, and a keyboard is not part of the box.
- ScummVM `confirm_exit = false` stays enforced. It reads like removing a
  safety net, but on a pad-only kiosk a modal that is awkward to dismiss
  is a trap.

### 6. Module schema: `enforce` and `seed`

The file-entry submodule gains a second key map. Rename `keys` to
`enforce` and add `seed`, rather than keeping `keys` and bolting on
`seedKeys` (rejected: asymmetric, and a reader of a declaration cannot see
the tier without knowing which attribute is the legacy one). It touches
all nine file declarations, purely as data. The JSON contract to prepare
gains the same split; the editors gain a seed branch: append when absent,
otherwise do nothing. `REMOVE` on a seeded key is refused, and seeded keys
are excluded from duplicate sweeping.

## Risks / Trade-offs

- [A seeded key a player never touches drifts from the flake's intent as
  upstream defaults change] -> Accepted. Seeding is a statement that the
  flake has no continuing opinion; a key that needs one belongs in
  `enforce`.
- [Recreation silently resets seeded settings] -> Accepted and stated in
  the specs. Recreation already loses every unowned setting, so seeds are
  not a new class of loss; they are a smaller one.
- [The append file goes missing or empty and `retroarch.cfg`'s stale baked
  copies quietly take over] -> This is exactly today's latent `withCores`
  bug, so it is a real failure mode with precedent. Guarded by a
  derivation check that the wrapper passes the flag and that the
  referenced file is non-empty and carries the enforced keys.
- [`retroarch.cfg` accumulates stale copies of enforced keys that nothing
  manages] -> Accepted. They are permanently overridden at load. Sweeping
  them would mean writing `retroarch.cfg` on every launch, which is the
  churn this design exists to reduce.
- [Two ownership tiers is more contract for a reviewer and an implementer
  to hold] -> Accepted. The alternative is the current single tier, which
  is what produced a shipped contradiction with the module's own
  documentation.

## Migration Plan

1. Split the module schema into `enforce` and `seed`, moving the eight
   seeded keys and leaving every other declaration where it is. No
   behaviour change yet, since prepare still enforces everything it is
   given.
2. Teach prepare the two-map contract and add the seed branch to all three
   editors: append when absent, and otherwise do nothing. Reject `REMOVE`
   on a seeded key, and exclude seeded keys from duplicate sweeping.
3. Update the capability specs as the delta specs state: the ownership
   requirement in `kiosk` and `emulators` splits into tiers, four items
   leave the emulators pin list for the seeded tier (the uniform hotkey
   set, Wii dual core off, native internal resolution, geometry correction
   and upscaling), and the kiosk VM test gains the seeded-survival
   assertion.
4. Move `modules/emulators/default.nix` from `pkgs.retroarch.withCores` to
   `pkgs.wrapRetroArch { cores; settings; }`, with the ten static enforced
   settings as the settings attrset (the core list passed directly rather
   than as a function), and drop exactly those ten keys from that file's
   `enforce` map. Seeds, credentials and the two RetroAchievements policy
   switches stay in the parse path.

Rollback is `git revert`: the schema change is data, the editor change is
one branch per editor, and the derivation swap is one call site.
