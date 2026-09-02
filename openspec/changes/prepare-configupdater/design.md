## Context

See `proposal.md` - Why. `emubox-prepare` edits three formats: ES-DE's
rootless XML forest, sectioned INI as Qt's QSettings writes it
(DuckStation, PCSX2, Dolphin), and RetroArch's headerless
`key = "value"` flat file. Both flat-file editors are hand-written and
share five helpers between them. The program runs before every launch of
the frontend, as `player`, and its failure ends the session at a greeter,
which is why every editor recreates rather than raises.

`configupdater` 3.2 is in nixpkgs, is pure Python, and pulls in no
transitive dependency. Everything asserted about its behaviour below was
checked against that version rather than read from its documentation.

## Shared vocabulary

Both modified capabilities describe the same three outcomes; they are
defined here once and referenced there rather than re-enumerated.

| Term | Meaning |
|---|---|
| Owned key | A key the flake declares a value for in the owned-values document, in the file that document names. |
| Assignment | One physical line (INI, RetroArch) or one element (ES-DE) that binds a key to a value. A key may have several. |
| Reduced to one | After a write, exactly one assignment of an owned key remains in the file and it holds the flake's value; the others are deleted. Applies only to owned keys, and only within the section the flake declared the key under, plus the headerless region that belongs to no section. |

## Goals / Non-Goals

**Goals:**

- One editing model for both flat formats, over a maintained library.
- Byte-identical preservation of everything the flake does not own,
  which is the property the whole program exists for.
- No change to the invocation contract, the exit codes, the recreate
  policy, or the set of files written.

**Non-Goals:**

- Moving the ES-DE editor off `xml.etree.ElementTree`. No INI library
  applies to a rootless XML forest, and ElementTree is already the
  conventional choice for it. Its duplicate handling is fixed already.
- Reducing the policy code. Roughly 189 lines of `set_ini_settings` and
  `set_retroarch_settings` are recreate-not-fail rules, `REMOVE`
  semantics, the `_holds_something` guard and journal notes. No library
  supplies those; this change replaces parsing, not judgement.
- Making `emubox-prepare` a uv project. Its derivation comment names
  that as the move if the program outgrows a single module; one added
  dependency is not that moment.

## Decisions

### 1. `configupdater`, not `configparser`, `configobj` or `iniparse`

`configparser` is out: it rewrites the whole document and drops comments
and ordering, which is exactly the promise this program makes.

The three comment-preserving candidates in nixpkgs were each tried
against the two awkward shapes this program already handles. None
handles both:

| | Duplicate section header | Headerless preamble |
|---|---|---|
| `configupdater` (`strict=False`) | reads it; writes the first | `MissingSectionHeaderError` |
| `iniparse` | reads it; writes the last | `MissingSectionHeaderError` |
| `configobj` | `DuplicateError` | reads it |

`configupdater` wins on the axis that matters: it exposes
`iter_sections()`, so every instance of a repeated section is reachable
and "reduced to one" is an ordinary loop rather than the index
arithmetic being deleted. Its preamble gap is closed by decision 2.
`configobj` was rejected because a duplicate section header is the shape
that produced a live defect in this program, and it cannot read one at
all. `iniparse`'s last-write-wins is no better founded than
`configupdater`'s first, and it is the less maintained of the two.

### 2. Every file is read through a synthetic section header

Both formats are loaded as `[<synthetic>]\n` + the file's text, and the
header line is stripped on write. One mechanism, two problems solved:

- RetroArch's file has no sections at all, so a sectioned-INI library
  cannot read it otherwise.
- An INI file with an assignment above its first section header is
  rejected by the library, but tolerated today - `_sweep_key` deliberately
  covers that region, because an assignment there belongs to no section
  and so no section's owner can claim it. Under the synthetic header
  those keys become ordinary members of a real section and stay
  reachable.

Verified against `configupdater` 3.2: a file that already begins with a
section header round-trips byte-identically through this wrapping, with
no stray blank line where the synthetic header stood, and a file with a
preamble round-trips byte-identically too.

The alternative was to accept the library's rejection and let those
files take the recreate path. Rejected: recreation rewrites a file with
only the owned keys in it, so one stray line above the first header
would cost the family every unowned preference in that file. Today only
a line that is not an assignment at all does that. Widening the
recreate trigger to buy nothing is the wrong trade in a program whose
central promise is preserving what it does not own.

A second alternative, keeping a hand-written pre-pass just for the
preamble, was rejected because it preserves the most intricate branch of
the parser this change exists to delete.

### 3. `optionxform = str`, always

`configupdater` inherits `configparser`'s option-name folding, which
lowercases keys. Qt's INI files are case-sensitive and the owned keys are
spelled `Username`, `Token`, `Cheevos_enable`. Left at its default the
library reports the key of `Username = x` as `username`, and a file
carrying both `Username` and `username` collapses to two entries under
one name.

That is a silent data-corruption path directly into the credential keys,
so `optionxform` is set to `str` on every instance this program creates,
and a test asserts the case of a written key rather than trusting it.

### 4. A value is compared before it is assigned

Assigning through the library rewrites the whole line, normalising
`Key=value` to `Key = value`. Qt writes its files without spaces and
rewrites them in full whenever the emulator saves, so an unconditional
assignment would mean: emulator saves, prepare renormalises, emulator
saves, prepare renormalises - one extra write to flash before every
launch, forever. This is the failure `_write_credential` already guards
against for its own file.

So each editor compares the parsed value against the flake's and assigns
only on a genuine difference, which is what the current code does with
`current.strip() != value`. Spacing then changes only when a value
actually changes, and the file stabilises.

### 5. Deleting a repeated key needs a loop

`del section[key]` removes one assignment, not every one: on a section
carrying `k` twice it leaves the second. Both the `REMOVE` path and
"reduced to one" therefore iterate to absence rather than deleting once.
Called out because it reads as though it should be idempotent and is
not, and because the existing `_sweep_key` handled it in a single pass
with a test that must keep passing.

## Risks / Trade-offs

- [A silent regression in the credential-removal path takes a
  RetroAchievements bearer token off the box less thoroughly than
  before, and nothing says so] → The 186 unit tests run in 26 s on the
  administrator's Mac and cover that path heavily; this change adds no
  behaviour, so any test that changes meaning is a finding to explain
  rather than a test to update. The three library behaviours in
  decisions 3, 4 and 5 each get a test of their own.
- [The synthetic header leaks into a written file] → It is stripped in
  exactly one place, and a test asserts no written file contains the
  sentinel, for every format and every branch that writes.
- [Trading a large piece of cleverness for a small one] → Accepted, and
  named rather than hidden: wrapping a non-INI file in a fake section
  header to reuse an INI library is a trick. It is about five lines
  against 159, it is confined to the load and dump helpers, and the
  design records why it exists.
- [A new dependency in the appliance's closure] → `configupdater` is
  pure Python with no transitive dependencies, and `closure-check`
  already bounds the system closure.
- [The library's idea of an unparseable file differs subtly from the
  current parser's, silently widening or narrowing the recreate path]
  → The recreate path is behaviour the specs pin, so the migration keeps
  the existing recreate tests unchanged and adds a case asserting that a
  line which is not an assignment still triggers recreation.

## Migration Plan

1. Add `configupdater` to the derivation's Python closure; confirm the
   check still builds on `aarch64-darwin`, which is where the suite runs
   fastest.
2. Introduce the load and dump helpers with the synthetic header,
   `strict=False` and `optionxform = str`, under their own tests, before
   any editor uses them.
3. Move `set_ini_settings` onto them, keeping its policy code and its
   signature. Keep every existing INI test passing without edits.
4. Move `set_retroarch_settings` onto them, same rule.
5. Delete the eleven helpers once nothing references them, and confirm
   with the same AST reachability check that found no orphans in the
   audit.

Rollback is `git revert`: the change is confined to one module, its
tests and one derivation input, and it alters no interface any caller or
NixOS module depends on.
