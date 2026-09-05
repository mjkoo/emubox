## Context

See proposal.md - Why for motivation. Current state, verified against the
tree at the branch point:

- `emubox-prepare` runs before every launch of the frontend and asserts the
  keys the flake owns in ten configuration files. The file-entry submodule
  is `format` plus `keys` (`modules/kiosk/default.nix:229-248`), the JSON
  contract carries one key map per file, and each editor writes a missing
  key and corrects a drifted one (`set_esde_settings` at
  `pkgs/emubox-prepare/emubox_prepare.py:557`, `set_ini_settings` at
  `:1071`, `set_retroarch_settings` at `:1190`; the flat editors drive a
  lossless syntax tree through `_write_key` at `:992` and `_sweep_key` at
  `:979`). The only conditional write in the program is DuckStation's
  `login_timestamp`, which is change-gating, not deference to a player.
- Prepare already divides its outcomes in two: a malformed owned-values
  document is a broken call site and `main` returns 1, so the session ends
  at the greeter; a failure while editing a file degrades and continues.
  The only producer of `REMOVE` is the RetroAchievements merge, which folds
  target keys into a file's key map after `_target_validation_error` has
  checked each target key's file and format.
- The kiosk module's own header comment promises that a preference changed
  in the frontend's menus survives a reboot, while ES-DE's `Theme` and
  `ApplicationLanguage` are enforced on every launch - a shipped
  contradiction.
- The flake's RetroArch package is `pkgs.retroarch.withCores`
  (`modules/emulators/default.nix:124`). At the pinned nixpkgs,
  `wrapRetroArch` accepts `{ cores, settings }`, renders the settings as
  `name = "value"` lines (every value interpolated as a string) to a
  `declarative-retroarch.cfg` in the store, and wraps the binary with
  `--appendconfig=<that file>` placed before any launch-time argument and
  with `-L <its own output>/lib/retroarch/cores`. `pkgs.wrapRetroArch` is
  `retroarch-bare.wrapper`, which merges three defaults of its own
  (`assets_directory`, `joypad_autoconfig_dir` and `libretro_info_path`,
  each a store path) under the caller's settings before rendering. The
  output exposes `passthru.cores`, `passthru.unwrapped` and
  `passthru.withCores` - but `passthru.withCores` forwards only `cores`
  through that same function, so today the file the flag points at
  carries those three nixpkgs defaults and none of the flake's own
  settings.
- Owned key and section names are validated to read back as themselves; a
  name that would classify differently on the next read is dropped with a
  note instead of written.
- The `saves` capability's authoritative route table names
  `savefile_directory` and `savestate_directory` as owned `retroarch.cfg`
  keys, orders migration before each key is written, and requires parsed
  owned-key evidence; `tests/saves.nix` asserts both keys in the RetroArch
  file's owned map at evaluation.
- The kiosk VM test's owned-key subtests read each file's `keys` map,
  pin the ES-DE and RetroArch keys literally in `tests/kiosk.nix`, and
  walk them against the file on disk; its headless RetroArch launches
  pass their own `--appendconfig` flag.

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

- Removing `emubox-prepare`'s parse-and-merge editors. Three of the ten
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
- Changing the `saves` capability's route table, its expected values or
  the `saves` spec. The attribute path `tests/saves.nix` reads follows the
  schema rename (`enforce` where it read `keys`); nothing else in that
  check changes.

## Decisions

### 1. Two tiers: enforced and seeded

The ownership vocabulary, used by the `kiosk` and `emulators` delta specs
and by every artifact in this change:

| Tier | Written when | Corrected on drift | Repeats swept | Removable |
|---|---|---|---|---|
| enforced | missing at any launch | yes | yes, to one assignment | yes |
| seeded | no assignment exists | never | never | never |
| unowned | never | never | never | never |

A setting belongs to exactly one tier. Decision 6 states what happens when
a declaration says otherwise.

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
otherwise. A third constraint: a key another capability's contract names
as an owned `retroarch.cfg` key stays in the parse path even though it is
static, because moving it would change that contract (decision 4, the two
save directories).

| | Enforced | Seeded |
|---|---|---|
| RetroArch, statically known and not named by another capability | flake-owned append file | parse-and-merge into `retroarch.cfg` |
| RetroArch, runtime-determined or named by the `saves` route table | parse-and-merge into `retroarch.cfg` | not applicable |
| Every other file | parse-and-merge | parse-and-merge |

### 4. RetroArch moves to `--appendconfig`; nothing else moves

Verified against RetroArch 1.22.2, the pinned revision:
`--appendconfig=FILE` merges into the same `config_file_t` before settings
extraction and wins over the main config. Moving the module from
`pkgs.retroarch.withCores` to `pkgs.wrapRetroArch { cores; settings; }`
gives a flake-owned whole file with no patch and no wrapper of our own,
and fixes the latent defect (Context): `withCores` forwards only the core
list, so the flake's own settings never reach the file while nixpkgs'
three defaults do. One shape difference at the
call site: `withCores` takes a function over `libretro`, while
`wrapRetroArch` takes the core list directly. The wrapped output keeps
`passthru.cores`, which `flake.nix`'s `cache-roots` filters
`environment.systemPackages` on; a wrapper that dropped it would shrink
the binary-cache closure silently, so the flake check pins the passthru
as well as the file.

Three corrections to RetroArch's published documentation, all read from
the pinned source:

- The appendconfig path list is `|`-delimited, not comma-delimited as
  `docs/retroarch.6` and docs.libretro.com state (`configuration.c:3871`).
- A second `--appendconfig` flag on one command line replaces the first
  rather than adding to it (`retroarch.c:7152-7155`, a plain copy into the
  append path). The nixpkgs wrapper places its own `--appendconfig=<store
  path>` before any launch-time argument, so a launch that passes its own
  `--appendconfig` discards the flake's file for that launch. Anything
  that launches RetroArch with an extra append file - today only the kiosk
  VM test's headless launches - must join it onto the flake's file inside
  one flag: `--appendconfig '<store file>|<extra file>'`, with the store
  path recovered from the node's wrapped RetroArch binary as described
  below.
- Appended values *are* written back into `retroarch.cfg` by
  `config_save_file()`, which rebuilds the file from the in-memory
  settings struct (`configuration.c:5449-5678`). `config_save_on_exit`
  defaults true and `--appendconfig` alone does not set the
  overrides-active flag, so the exit write still happens. That write is
  RetroArch's own, outside this system's guarantees: the specs say this
  system does not edit `retroarch.cfg` for the appended keys, and they say
  nothing about what RetroArch writes there itself.

Two consequences for evidence. The write-back means a stale value baked
into `retroarch.cfg` before a launch is replaced by the effective value
when RetroArch exits, so the file after exit is an observable of the
effective settings and the VM test can prove precedence by baking a stale
enforced value, launching headless, and reading the file back. The
`[Config] Appending config: ...` log line is emitted only when `first_load`
is false (`configuration.c:3877-3879`), so it is not evidence for the
initial load and the test must not rely on it.

Both pieces of evidence need the settings file's store path, and that
path is not an attribute of the wrapped package. At the pin the wrapper
binds the rendered file as a private `let`, exposes only `cores`,
`unwrapped` and `withCores` in `passthru`, and the path exists only as
the `--appendconfig=/nix/store/...-declarative-retroarch.cfg` argument
that `makeBinaryWrapper` compiles into `bin/retroarch`. The binary
wrapper embeds its flags as plain strings, so the argument is recoverable
from the binary with `grep -a -o`. It embeds each flag at least twice,
though: once as the NUL-terminated argv literal and once inside the
generator docstring `makeBinaryWrapper` compiles into every wrapper (the
`--add-flags '--appendconfig=...'` text of the command that produced it,
single-quoted). A raw occurrence count is therefore two or more against
a correctly built wrapper and must not be tightened back to one. The
rule both checks apply is exactly one distinct path: split the binary on
NUL and newline, extract every `--appendconfig=/nix/store/...`
occurrence with a terminator that excludes whitespace and quotes (so the
docstring's closing quote is not captured into the path), take the set
of distinct paths, assert its size is one, and use that path. Textual
repeats of the same path are expected; two different paths are the
failure. The VM test uses `grep -a -o`, which is on the node, rather
than `strings`, which is binutils and is not asserted present there;
the derivation check may use either. Neither check ever re-renders the
settings. A re-rendered `writeText` copy with the same content would
land on the same store path whenever the rendering matches, which makes
it the module agreeing with itself: it proves the settings render, not
that the wrapper the node runs passes that file, and a wrapper that
passed some other file would still satisfy it. Reading the path out of
the binary is what ties both checks to the file RetroArch actually
loads.

The same rule binds which package the flake check reads. The wrapped
package is a private `let` binding in the emulators module, reachable
from outside only through `environment.systemPackages`, so the check
selects the RetroArch package from the host configuration's
`environment.systemPackages` by the same `p ? cores` filter the flake's
`cache-roots` derivation uses, asserts exactly one such package, and
inspects that derivation's `bin/retroarch`. A check that called
`pkgs.wrapRetroArch` itself would prove a second package agrees with
itself and stay green if the module's own call site drifted. For the
same reason `passthru.cores` is compared against a literal list of core
names hand-typed in the check - the independent-literal rule the kiosk
VM test applies to its pins - never against a list obtained from the
module.

That write-back is the second reason credentials stay in the parse path,
on top of the store-path constraint. Removal means absence, and a blank
value will not do - RetroArch treats any `cheevos_token` it finds as a
token to log in with. An appended credential would be baked into
`retroarch.cfg` and survive its own removal, so the credentials continue
to be written and swept in `retroarch.cfg` directly.

What moves to the append file is eight keys: `video_fullscreen`,
`libretro_directory`, `system_directory`, `autosave_interval`,
`menu_show_online_updater`, `menu_show_core_updater`,
`input_menu_toggle_gamepad_combo` and `input_quit_gamepad_combo`. What
stays in `retroarch.cfg` is the seeds, the credentials, the two
RetroAchievements policy switches, and the two save directories.

The delivered file carries more than the eight. At the pinned nixpkgs,
`pkgs.wrapRetroArch` is `retroarch-bare.wrapper` (`all-packages.nix:1295`),
and that function merges its own three defaults - `assets_directory`,
`joypad_autoconfig_dir` and `libretro_info_path`, each a store path -
under the settings the caller passes, so a key the caller does not name
keeps the wrapper's value. The flake overrides none of the three, so the
delivered file carries eleven keys: the flake's eight and the wrapper's
three. The three are nixpkgs' choice at the pin, not the flake's, and
they are what today's file already delivers. The flake check pins the
eight by value and asserts the three present by name, so a nixpkgs bump
that drops or renames a wrapper default is visible in the check rather
than silently changing what reaches RetroArch ahead of `retroarch.cfg`;
the eight-key assertion is the one that fails against the `withCores`
wrapper, since that file has never carried the flake's keys. The check
also asserts what the file must not carry: no credential, none of the
six seeded RetroArch keys (`menu_driver`, `input_menu_toggle`,
`input_save_state`, `input_load_state`, `input_toggle_fast_forward`,
`input_screenshot`), and neither save-directory key
(`savefile_directory`, `savestate_directory`). A seeded key that slipped
into the settings attrset would be delivered ahead of `retroarch.cfg` on
every launch and override the player's tuning, which is the one outcome
the seed tier exists to prevent; a save-directory key that slipped in
would be delivered ahead of the parsed, migration-ordered write the
`saves` route table requires; and presence and value checks on the
intended keys cannot detect either.

`savefile_directory` and `savestate_directory` stay in the parse path even
though they are static and enforced. The `saves` capability's authoritative
route table names each as an owned `retroarch.cfg` key, orders migration
before the key is written, and requires parsed owned-key evidence;
`tests/saves.nix` asserts exactly that at evaluation. Moving them would
change another capability's contract for no gain this change is after, so
the `saves` route table, its expected values and the `saves` spec are
unchanged and the two keys stay where that table puts them. The one edit
`tests/saves.nix` takes is mechanical: the attribute path it reads follows
the schema rename, `enforce` where it read `keys`, with its assertions and
expected values as they are.

`libretro_directory`'s value in the append file is the literal
`/run/current-system/sw/lib/retroarch/cores`, not the wrapper's store path.
The settings file is a build input of the wrapper derivation, so a value
naming the wrapper's own output would make the derivation depend on its
own output and evaluation would fail with infinite recursion; the
wrapper's cores directory cannot appear in the wrapper's own settings. The
literal resolves only through `environment.systemPackages`, so it is still
the flake's packaged cores and no other source; it is the same path
ES-DE's find rules resolve `%CORE_RETROARCH%` against; and the wrapper
itself passes `-L <its own output>/lib/retroarch/cores` on every launch,
which RetroArch treats as setting `libretro_directory` with an override
marker (`retroarch.c:6788-6800`), so both spellings name the same cores.
Being a literal, the value is pinnable by value in the flake check, where
today's `libretro_directory` is asserted by presence only; it is not
pinnable through the VM test's write-back observable, because the
wrapper's `-L` flag overrides it at runtime and `retroarch.cfg` after
exit carries the wrapper's store path rather than the append file's
literal, which is why the VM test's stale bake uses one of the other
seven launch-delivered keys.

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

Twelve keys move (seven settings, the five keyboard hotkeys counted one by
one); everything else stays enforced.

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
and return-to-launcher; RetroArch's two save directories; and every
credential and RetroAchievements policy switch.

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
all ten file declarations, purely as data, and every reader of the
per-file `keys` map: `raDisabledFiles` in `modules/emulators/default.nix`
writes its two switches into `enforce`, `tests/retroachievements-disabled.nix`
reads `enforce`, `tests/saves.nix` reads `enforce` where it read `keys`
(its route table, expected values and assertions unchanged), and the
kiosk VM test's pins and walks split by tier (enforced keys asserted by
value, seeded keys by presence). The JSON
contract to prepare gains the same split; the editors gain a seed branch:
append when absent, otherwise do nothing. Seeded keys are excluded from
duplicate sweeping.

The contract change is a hard cutover. The JSON contract carries exactly
two maps per file, `enforce` and `seed`, both present and either allowed
to be `{}`; the old `keys` spelling is refused, and there is no transition
alias. A per-file table carries exactly `format`, `enforce` and `seed`.
A table that carries `keys`, that lacks either map, or that carries any
other field is a broken call site like any other malformed document:
prepare exits non-zero with a diagnostic naming the file and the missing,
obsolete or unexpected field, no RetroAchievements login is attempted,
and no file is written. The extra-field refusal is what makes a
misspelled map visible: without it, a table carrying `enforced` or
`seedKeys` beside both required maps would pass the shape check and its
keys would be silently ignored. Both maps are validated with the same
per-format inner shape check the single map gets today (an ini section
is an object; an ES-DE entry carries a string type and a string value),
so a malformed seeded entry is also a diagnostic naming the file and the
key rather than a traceback from the editor that first subscripts it.
The rejected alternative - accepting `keys` as an alias for `enforce`
during a transition - would let a stale pre-change document pass the
shape check and be enforced silently, which is the failure this change
exists to make visible; the only producer of the document is the module
in the same tree, so there is no external caller to transition. The
cutover reaches prepare's unit suite: every rendered owned-values fixture
and every editor call in it spells the old single map today and is
re-rendered to the two-map contract, with the behaviour each test asserts
left as it is, and rejection tests cover a document carrying `keys`, one
missing `enforce`, one missing `seed`, one carrying an unexpected extra
field, and one with a malformed seeded entry.

A key in both maps of one file is a configuration error, guarded at
evaluation and, at runtime, by two checks placed before anything with a
side effect:

- At evaluation, a module assertion that no file declares a key (a key
  name in a flat file, a section and key in a sectioned one) under both
  `enforce` and `seed`, and that no RetroAchievements target key is
  listed under its file's `seed` map. The RetroAchievements namespace's
  targets name each target key's file, section and key, and every file's
  `seed` map is declared beside them, so the overlap a target introduces
  is fully visible at evaluation: the assertion checks every target key
  against its file's `seed` map - the flat key for the RetroArch file,
  the section and key for an ini file - and fails evaluation naming the
  target, the file and the key. Without it a host that seeds, say, a
  supporting emulator's hardcore switch would pass `nix flake check` and
  the rebuild, and then every session would end at the greeter when
  prepare's runtime target validation refused the document at boot. This
  is a guard, not a one-off check of the shipped contract, and it has a
  durable negative test: a per-system eval-only flake check extends the
  host configuration with three deliberately overlapping declarations
  (a flat-file key under both maps, a sectioned section-and-key under
  both maps, a RetroAchievements target key under its file's `seed`)
  and asserts that each fails to evaluate, in the shape
  `tests/saves.nix` already uses for its invalid-exclusion case
  (`host.extendModules` and `builtins.tryEval` on
  `system.build.toplevel`). Module assertions fire only when
  `system.build.toplevel` is evaluated, so the check must evaluate that
  attribute and nothing shallower, and the target-key assertion must
  short-circuit when the RetroAchievements namespace is null.
- At runtime, a static overlap check on the rendered owned-values
  document, run in `main` immediately after the per-file shape check and
  before the RetroAchievements step: a file naming one key under both
  maps is a broken call site. The check is static because the overlap is
  visible in the document as parsed; nothing has to be merged to find
  it. It runs when the rendered declaration is validated, before the
  RetroAchievements login is attempted and before any file is touched,
  credential files included - the RetroAchievements step, which performs
  that login and writes the token cache and PPSSPP's whole-file token,
  has not started. Prepare exits non-zero with a diagnostic naming the
  file and the key, and the session ends at the greeter like every other
  broken call site.
- At runtime, the only overlap the RetroAchievements merge can introduce
  is a target key landing on a key its file seeds, since the merge folds
  a target key's value or removal into the file's enforced map. That case
  is rejected by the target validation before the RetroAchievements login
  is attempted, stated below; that runtime rejection is the backstop
  behind the evaluation-time assertion above, not the primary guard.

A re-check of the merged maps after the RetroAchievements merge and
before any editor runs may remain as a defensive assertion; it is not the
policy, and no rejection depends on it.

`REMOVE` on a seeded key is refused the same way, statically and before
the RetroAchievements login is attempted. The only producer of `REMOVE`
is the RetroAchievements merge, and every RetroAchievements target key
already passes through the target validation that checks the key's file
and format; that validation additionally rejects a target key whose file
lists it under `seed`. Prepare exits non-zero with a diagnostic naming
the file and the key, no RetroAchievements login is attempted, no file is
written, and the session ends at the greeter. With both rejections in place, a `REMOVE` reaching an editor on
a seeded key is unreachable by construction; the editors still refuse it
as a defensive check, but the policy lives in the validation. The
rejected alternative - refusing inside the editor as a note-and-skip that
lets the launch continue - would land on the degrade-and-continue side of
prepare's existing policy for what is a shape error in the flake's own
document, and would leave a partially applied file behind.

## Risks / Trade-offs

- [A seeded key a player never touches drifts from the flake's intent as
  upstream defaults change] -> Accepted. Seeding is a statement that the
  flake has no continuing opinion; a key that needs one belongs in
  `enforce`.
- [Recreation silently resets seeded settings] -> Accepted and stated in
  the specs. Recreation already loses every unowned setting, so seeds are
  not a new class of loss; they are a smaller one.
- [The append file goes missing or loses the flake's settings and
  `retroarch.cfg`'s stale baked copies quietly take over] -> This is
  today's latent `withCores` defect, in which the file carries the
  wrapper's three defaults and none of the flake's settings, so it is a
  real failure mode with precedent. Guarded by a derivation check that
  the wrapped `bin/retroarch` the host's `environment.systemPackages`
  carries embeds exactly one distinct `--appendconfig=` path (a raw
  occurrence count is at least two, since the wrapper's docstring
  repeats the flag) and that the file at that path (never a re-rendered
  copy) carries the eight enforced keys with the flake's values,
  including the `libretro_directory` literal, the wrapper's three
  default paths by name, no credential, none of the six seeded RetroArch
  keys, and neither save-directory key; the eight-key assertion, not
  non-emptiness, is what fails against the `withCores` wrapper.
- [A launch that supplies its own `--appendconfig` silently drops the
  flake's file, since a second flag replaces the first] -> The kiosk VM
  test's headless launches are the one such caller today; they join the
  test override onto the flake's file inside one `|`-delimited flag, and
  the test proves precedence at runtime by baking one stale enforced value
  into `retroarch.cfg` before a headless launch and reading the effective
  value back from the file RetroArch rewrites on exit. A derivation check
  alone would prove the file exists, not that RetroArch reads it or that
  it wins.
- [The wrapped package drops `passthru.cores` and the binary-cache
  closure shrinks to nothing without a failure] -> Guarded by the same
  flake check asserting a non-empty `passthru.cores` equal to a literal
  core list hand-typed in the check, on the package selected from the
  host's `environment.systemPackages` by the `cores` filter
  `cache-roots` uses.
- [The evaluation-time overlap assertion is weakened or dropped by a
  later refactor and the greeter-at-boot refusal becomes the first
  detector again] -> Guarded by the per-system eval-only check that
  extends the host with the three overlapping declarations and asserts
  each fails to evaluate; a regression of the assertion fails
  `nix flake check` rather than a boot.
- [`retroarch.cfg` accumulates stale copies of enforced keys that nothing
  manages] -> Accepted. They are permanently overridden at load, and
  RetroArch's own exit write-back replaces them with the effective values
  anyway. Sweeping them would mean writing `retroarch.cfg` on every
  launch, which is the churn this design exists to reduce.
- [Two ownership tiers is more contract for a reviewer and an implementer
  to hold] -> Accepted. The alternative is the current single tier, which
  is what produced a shipped contradiction with the module's own
  documentation.

## Migration Plan

Steps 1 and 2 are one revision on one branch, in this order: neither side
is behaviour-neutral alone. Today's prepare refuses a per-file table
without `keys`, so a module that rendered `enforce` and `seed` against it
would end every session at the greeter; and the new prepare refuses a
table carrying `keys`, so it cannot ship against today's module either.

1. Teach prepare the two-map contract: a per-file table carries exactly
   `format`, `enforce` and `seed`, both maps present, `{}` allowed; a
   table carrying `keys`, lacking either map, or carrying any other field
   is a broken call site (exit non-zero, diagnostic naming the file and
   the field, no RetroAchievements login attempted, no file written), and
   both maps pass the per-format inner shape check the single map gets
   today. Add the seed branch to all three editors: append when
   absent, and otherwise do nothing. Exclude seeded keys from duplicate
   sweeping. Reject, as broken call sites before the RetroAchievements
   login is attempted and before any file, credential files included, is
   written, a key in both maps of one file (a static check on the
   rendered document, placed right after the per-file shape check and
   before the RetroAchievements step) and a RetroAchievements target key
   its file seeds (checked in target validation, before the
   RetroAchievements login is attempted). Re-render every owned-values
   fixture and every editor call in prepare's unit suite to the two-map
   contract with no behavioural edits, and add the rejection tests for a
   document carrying `keys`, one missing `enforce`, one missing `seed`,
   one carrying an unexpected extra field, and one with a malformed
   seeded entry.
2. Split the module schema into `enforce` and `seed`, moving the twelve
   seeded keys (ES-DE `Theme`, `ApplicationLanguage`; RetroArch
   `menu_driver`, `input_menu_toggle`, `input_save_state`,
   `input_load_state`, `input_toggle_fast_forward`, `input_screenshot`;
   Dolphin `Core.CPUThread`; PCSX2 `EmuCore/GS.upscale_multiplier`;
   DuckStation `GPU.PGXPEnable`, `GPU.ResolutionScale`) and leaving every
   other declaration where it is, with the module assertion that no file
   declares a key in both maps and that no RetroAchievements target key
   is listed under its file's `seed` map, the per-system eval-only check
   that proves the assertion fires on the three overlapping
   declarations, and render both maps into the JSON contract. Repoint
   every reader of the `keys` map: `raDisabledFiles`,
   `tests/retroachievements-disabled.nix`, `tests/saves.nix` (attribute
   path only), and the kiosk VM test's pins and walks.
3. Update the capability specs as the delta specs state: the ownership
   requirement in `kiosk` and `emulators` splits into tiers, four items
   leave the emulators pin list for the seeded tier (the uniform hotkey
   set, Wii dual core off, native internal resolution, geometry correction
   and upscaling), and the kiosk VM test gains the seeded-survival
   assertion and the runtime precedence assertion.
4. Move `modules/emulators/default.nix` from `pkgs.retroarch.withCores` to
   `pkgs.wrapRetroArch { cores; settings; }`, with the eight static
   enforced settings as the settings attrset (`libretro_directory` as the
   literal `/run/current-system/sw/lib/retroarch/cores`, the core list
   passed directly rather than as a function), and drop exactly those
   eight keys from that file's `enforce` map. Seeds, credentials, the two
   RetroAchievements policy switches and the two save directories stay in
   the parse path. Join the kiosk VM test's headless override onto the
   flake's append file in one flag and add the runtime precedence
   assertion.

Rollback is `git revert`: the schema change is data, the editor change is
one branch per editor, and the derivation swap is one call site.
