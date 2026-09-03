## Why

`emubox-prepare` carries its own INI parser, its own RetroArch flat-file
parser, and the line-index arithmetic both need: eleven functions, about 159
lines, hand-maintained. All eleven go; the one constant they share stays. Parsing a settings file is a solved problem, and the
part of it this program actually needs - editing a key in place while every
setting the emulator reads keeps its key and its value - is solved too, by
`configupdater`, which is packaged in nixpkgs, pure Python and maintained.

What breaks if this is not done: nothing today, and that is the point of doing
it deliberately rather than under pressure. The cost is paid slowly. Every
defect in that arithmetic is one this project finds on its own, in a program
that runs before every launch of the frontend and whose failure ends the
family's evening at a greeter. It has already happened twice, in the same
week and in mirrored forms: writes were not duplicate-aware while removals
were, and the ES-DE editor kept the last repeat while the other two kept the
first. Both were silent, and both were invisible for as long as they existed
because the editors agreed with themselves on the next run.

The second reason is narrower and concrete. The invariant those fixes
established - that exactly one assignment of an owned key survives a write,
holding the flake's value - appears in no spec. The `kiosk` and `emulators`
capabilities both say an owned key "holds the flake's value", which the
duplicate defect violated without contradicting the wording, since the file
did hold that value while the emulator read a different one. Writing the
invariant down is what gives this refactor an acceptance criterion instead of
a hope, and it repairs a spec gap the preceding fix left behind.

## What Changes

- Replace both flat-file parsers with `configupdater`. The sectioned-INI
  editor and the RetroArch editor become one editing model over one library.
- Read every file, INI and RetroArch alike, through a synthetic section
  header that is stripped on write. It is what lets a headerless RetroArch
  file use a sectioned-INI library at all, and it preserves today's tolerance
  of an assignment sitting above an INI file's first section header, which
  the library rejects outright.
- Delete `_parse_ini`, `_render_ini`, `_ini_section_bounds`,
  `_ini_insert_point`, `_parse_retroarch`, `_render_retroarch`, `_lines`,
  `_split_ini_assignment`, `_sweep_key`, `_ini_key_index` and
  `_matching_space`. `_INI_SECTION_RE` is *retained*: design decision 7
  rule 3 makes it the INI header guard, because the library's own section
  grammar reads a header carrying a further `]` under a different name and
  would leave a `REMOVE`d bearer token on disk.
- State the preservation contract in one place (design decision 7)
  rather than leaving it implied, and state it in terms of what an
  emulator reads rather than what the bytes look like: every setting the
  flake does not own keeps its key and its value, and every one of its
  assignments when it repeats. Formatting no consumer can observe is
  outside the contract, so a spaceless `Key=old` whose owned value
  changes comes back as `Key = new`, a newly seeded key lands at the end
  of its section's block, and `_matching_space` goes with the other
  deleted helpers. What the contract does defend is the recreate path,
  which rewrites a file with only the owned keys in it and so costs every
  unowned setting: decision 7's rules stop the library widening that path
  on an indented comment, and stop it narrowing on a bracketed line it
  reads as a header under a name today's parser does not give it.
- Keep every policy the editors carry, because no library supplies it:
  recreate-not-fail, `REMOVE` semantics, the `_holds_something` guard against
  a removal that a parser cannot see into, the "no owned keys means do not
  touch the file" rule, and the journal notes.
- Add `configupdater` to the `emubox-prepare` derivation's Python closure,
  which today carries only `cryptography`.
- State the one-assignment invariant in the two capabilities that promise
  owned keys hold the flake's values.
- Leave the ES-DE editor on `xml.etree.ElementTree`. No INI library applies
  to a rootless XML forest, and it is already the conventional choice.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `kiosk`: sharpen "The flake owns some frontend settings and leaves the
  rest" so that an owned key that appears more than once in the settings file
  ends as exactly one entry holding the flake's value, rather than a file
  that holds the value somewhere while the frontend reads another.
- `emulators`: the same sharpening for "The flake owns each emulator's launch
  settings", which covers RetroArch's flat file and the standalones' INI
  files, including the RetroAchievements account keys where a stale survivor
  is a bearer token rather than a preference.

## Impact

`pkgs/emubox-prepare/emubox_prepare.py` and its test suite, which gains
tests and amends one; `pkgs/emubox-prepare/package.nix` gains one Python
dependency. No NixOS module behaviour changes, and no changes to the module-level
unit or VM tests: the program's invocation contract, its exit codes and
the files it writes are all unchanged. One prose note in
`modules/emulators/default.nix` explains a past Azahar key-spelling
accident partly by saying "prepare appends new keys after a section's
last assignment"; that clause becomes a stale account of current
behaviour, since a seeded key now lands at the end of its section's
block, but the conclusion it supports - that the backslash spelling is
what prepare must assert - is unaffected, and the module's declarations
do not change.

Inside that module the blast radius is wider than the two editors. The
migration also moves `_current_ini_value`, a third caller of the deleted
helpers: it calls four of the eleven, and it is the DuckStation
RetroAchievements probe that decides whether a `login_timestamp` needs
rewriting. Deleting the eleven without moving it strands it, on a path
that runs for every duckstation target declaring that key. Design
decision 6 covers what it needs from the shared load helper.

The risk is concentrated in one place worth naming. This program is the last
thing that runs before the frontend launches, and its credential-removal path
is what takes a RetroAchievements bearer token off the box. A regression
there is silent by nature. The 186 unit tests are what make the change safe
to attempt, and they run in 26 seconds on the administrator's Mac; three
library behaviours already found during evaluation - key case folding, partial
deletion of a repeated key, and a section header read under a name today's
parser does not give it - are each a way this could regress quietly and are
called out in the design.
