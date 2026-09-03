## Context

See `proposal.md` - Why. `emubox-prepare` edits three formats: ES-DE's
rootless XML forest, sectioned INI, and RetroArch's headerless
`key = "value"` flat file. Both flat-file editors are hand-written and
share five helpers between them. The program runs before every launch of
the frontend, as `player`, and its failure ends the session at a greeter,
which is why every editor recreates rather than raises.

The INI editor is pointed at eight files, declared `format = "ini"` in
`modules/emulators/default.nix`, and they do not share one writer:

| File | Written by |
|---|---|
| `Dolphin.ini` | Dolphin's own ini writer; spaced assignments |
| `RetroAchievements.ini` | the same Dolphin writer; spaced |
| `PCSX2.ini` | PCSX2's own ini writer; spaced |
| `secrets.ini` | the same PCSX2 writer; spaced |
| `ppsspp.ini` | PPSSPP's own ini writer; spaced |
| `qt-config.ini` | Azahar, through Qt's `QSettings` IniFormat; spaceless |
| `settings.ini` | DuckStation's own ini writer; spaced |
| `scummvm.ini` | ScummVM's own config writer; spaceless |

Two of the eight write spaceless assignments, and they are the two files
where decision 4's respacing is observable at all: Azahar's `qt-config.ini`,
through QSettings, and ScummVM's `scummvm.ini`, whose own writer emits
the key, a bare `=`, and the value with no spaces around it. ScummVM's
reader trims key and value, so a respaced line is still read correctly,
and decision 4's compare-before-assign guard stops the oscillation for
that file exactly as it does for Azahar's. The other six already write
the spaced form the library would render anyway. Note that the spacing
verdicts for `ppsspp.ini` and `scummvm.ini` come from reading those two
emulators' writers rather than from a file either emulator produced on
this box; decision 1 records what that leaves unsettled and task 2.5
carries the survey.

Exactly one of the eight is a QSettings file: Azahar's `qt-config.ini`.
QSettings escapes a `/` inside a key name to `\` when
it flattens a key to a line, which is why the owned keys for that file
are spelled `fullscreen\default` in the module rather than
`fullscreen/default`. The module's own notes at that declaration record
both facts.

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
- Semantic equivalence for the emulator that reads the file: every
  setting it reads keeps its key and its value, except the keys the flake
  owns. Formatting no consumer can observe is outside the contract.
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

The two awkward shapes in that table are the ones this program is known
to handle, and they came from the files it has actually met. Two of the
eight ini targets were not part of that survey: ScummVM's `scummvm.ini`
and PPSSPP's `ppsspp.ini`. Both are ordinary sectioned INI as far as the
module's notes and these emulators' documented formats go, and the
Context's spacing verdicts for both come from reading their writers -
PPSSPP reconstructs a line as key, ` = `, value; ScummVM writes key, a
bare `=`, value - but neither was read from a file the emulator itself
wrote, so neither is confirmed free of a third awkward shape. The spacing
verdicts no longer matter, since decision 7 puts delimiter spacing outside
the contract; the shape question does, because an unhandled shape falls into
the recreate path and costs every unowned setting in the file. Task 2.5
carries the survey for ScummVM, whose package builds on the administrator's
machine. It cannot carry it for PPSSPP: `nixpkgs#ppsspp.meta.platforms` is
Linux-only, so no `aarch64-darwin` run can produce a file PPSSPP wrote, and
the CI VM test is the only place the emulator runs at all. The ruling is to
settle the PPSSPP half by reading `IniFile::Save` at the locked revision and
to record here that the question stays open for that one file, bounded by
the recreate path, rather than to gate the change on evidence the project
has no way to obtain.

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
lowercases keys. None of the eight ini writers folds case - the owned
keys are spelled `Username`, `Token`, `Cheevos_enable`, and Azahar's are
spelled `firstStart` and `fullscreen\default`. Left at its default the
library reports the key of `Username = x` as `username`, and a file
carrying both `Username` and `username` collapses to two entries under
one name.

That is a silent data-corruption path directly into the credential keys,
so `optionxform` is set to `str` on every instance this program creates.
The test that pins it asserts *lookup*, not rendering: `"Username" in
section` is True for a file spelling the key `Username`, and
`section["Username"]` and `section["username"]` resolve to distinct
options. A written key's declared case is preserved at either setting and
therefore pins nothing.

### 4. A value is compared before it is assigned

Assigning through the library rewrites the whole line, normalising
`Key=value` to `Key = value`. Azahar's `qt-config.ini` is written by
QSettings without spaces, and QSettings rewrites the file in full
whenever Azahar saves, so an unconditional assignment would mean:
emulator saves, prepare renormalises, emulator saves, prepare
renormalises - one extra write to flash before every launch, forever.
This is the failure `_write_credential` already guards against for its
own file.

So each editor compares the parsed value against the flake's and assigns
only on a genuine difference, which is what the current code does with
`current.strip() != value`. Spacing then changes only when a value
actually changes, and the file stabilises.

That leaves the changed-value path, and there the line is re-rendered in
the library's `key = value` form: a source line `Key=old` comes back as
`Key = new`, not `Key=new` as it does today. `_matching_space`, whose
entire job is to carry the file's own delimiter spacing through a
rewrite, is given up with the rest of the hand-written arithmetic.

That is outside the contract rather than a concession, because no emulator
reading the file can observe it: `Key=new` and `Key = new` are the same
setting to every one of the eight ini writers' own readers. It is worth
recording only because `configupdater` 3.2 does expose a constructor
option that would render the spaceless form directly -
`space_around_delimiters`, which `Option._get_delim` consults - so the
claim that preserving spacing would require hand-written line arithmetic
is not true. The option is per document rather than per line, so honouring
both the six spaced writers and the two spaceless ones would mean choosing
it per file from the source text. The ruling is not to: the property is
not worth the branch.

The visible consequence, so a reader can recognise it: the first launch
after an owned value changes in `qt-config.ini` rewrites that one line
with spaces around the `=`, and it stays that way until Azahar itself
rewrites the file. `scummvm.ini` behaves the same way, and those are the
two files among the eight where it is observable at all.

### 5. Deleting a repeated key needs a loop

`del section[key]` removes one assignment, not every one: on a section
carrying `k` twice it leaves the second. Both the `REMOVE` path and
"reduced to one" therefore iterate to absence rather than deleting once.
Called out because it reads as though it should be idempotent and is
not, and because the existing `_sweep_key` handled it in a single pass
with a test that must keep passing.

"Reduced to one" needs the same iteration on the write side, but not the
same loop, and the difference matters. Iterating to absence there would
delete the survivor too: executed against 3.2, `while key in section: del
section[key]` on a section carrying the key twice leaves neither. The
obvious repair - delete every copy, then assign - is worse than it looks,
because it makes the editor write unconditionally and so rewrites the file
before every launch, which is exactly the flash-wear failure decision 4
exists to prevent and which task 2.3's "a second run is unwritten" forbids.

So the two paths are stated separately:

- **`REMOVE`** iterates to absence, in every instance of the declared
  section and in the headerless region.
- **Reduced to one** iterates to absence in every instance of the section
  *except* the one being written, and in the headerless region; inside the
  written instance it deletes down to a single surviving assignment, then
  applies decision 4's compare-before-assign to that survivor.

The write side also needs to reach one level further in than the deleted
code did. Assigning `section[key] = value` on a section instance that
already carries `key` twice edits the first line and leaves the second,
exactly as a single `del` does. So a repeat has three shapes, not two:
across repeated instances of a section, between the headerless region and
a section, and twice inside one section instance. Only the first two are
handled today; the third is a live gap in the current editor, and task 2.3
closes it.

### 6. The load helper has a silent variant, for the read that is only a probe

`_current_ini_value` is not an editor. It reads one key out of a
DuckStation ini purely to decide whether a newly encrypted token differs
from the one on disk, so that an unchanged token does not rewrite
`login_timestamp` on every launch. It deliberately avoids `_parse_ini`
today, and its docstring says why: that parser's job is to decide
whether a file is healthy enough to edit in place, and it notes
"recreating it" whenever it is not, so a probe routed through it would
announce a recreation before this run had decided to write anything.

The shared load helper inherits that hazard, because it will make the
same judgement about a missing, unreadable or unparseable file. So it
needs a quiet variant - a mode that returns nothing instead of noting,
or a factoring where the note belongs to the caller - and
`_current_ini_value` moves onto that. It keeps all four of its answers
of `None` - file missing, file unreadable, section absent, key absent - and
gains a fifth, file unparseable, because the shared helper validates where
`_read_quietly` did not. That reads as "the token changed" and rewrites
`login_timestamp` once, which is correct on a file about to be recreated.

Which refusals speak, and which do not, has to be stated per rule, because
`_parse_ini` today is not uniform and its non-uniformity is deliberate. It
notes one reason - "has a line that is not a setting (...); recreating it" -
and stays *silent* for empty text, because `set_ini_settings` owns the "is
empty; recreating it" note and emits it only once a write is confirmed;
noting it in the parser "used to fire on every single launch for exactly
that file, every time, for a recreation that never happened". The contract is therefore stated over *refusals*, not over rule numbers,
because rules 1 and 2 are transformations that never refuse: the loud helper
notes exactly when it reports a file unparseable, which is rules 3, 4 and 6
and rule 2's backstop; it is silent for rule 5, so `set_ini_settings` keeps
its deferred "is empty; recreating it" note and emits it only once a write is
confirmed; rules 1 and 2's ordinary transformations note nothing, since
noting there would print a recreation notice before every launch for a file
that is edited in place; and the quiet variant is silent throughout.

This is recorded as a decision because `_current_ini_value` is the third
caller of the machinery being deleted, and the only one that is neither
`set_ini_settings` nor `set_retroarch_settings`. It calls four of the
eleven functions task 4.1 removes, on a path reached for every
duckstation target that declares a `login_timestamp` key. Migrating the
two editors and deleting the eleven, without moving it, leaves a
dangling reference rather than an orphan - which is why task 4.2 checks
both directions.

### 7. What the editors promise about a file they did not write

The contract is semantic equivalence for the program that reads the file:
every setting an emulator reads keeps its key and its value, except the keys
the flake owns. Formatting no consumer can observe - delimiter spacing, the
position of a line within its section, whether a comment survives an edit to
the assignment it trails - is outside the contract, and buying it back would
mean the line arithmetic this change exists to delete. Everything below was
checked against `configupdater` 3.2 rather than assumed.

**Guaranteed.** For a file the editor edits in place rather than recreates:

- Every assignment the flake does not own keeps its key and its value, and
  keeps *every* one of its assignments when the key is repeated.
- A key of the same name under a section the flake does not own is untouched,
  as the `emulators` capability requires.
- No setting is reattributed from one section to another.

**Outside the contract, deliberately.** Delimiter spacing on a changed owned
value, so a source line `Key=old` comes back as `Key = new`; the position of a
newly seeded owned key within its section; the position of the surviving
assignment when a repeat is reduced to one; and an inline comment sharing a
line with an owned assignment whose value changes. None is observable to an
emulator reading the file. `configupdater` 3.2 does expose
`space_around_delimiters`, which renders the spaceless form directly, but it is
per document rather than per line and the ruling is not to use it.

Line terminators are unchanged from today: `_read_text` and `_read_quietly` go
through `Path.read_text`, whose universal-newline translation folds CRLF to LF
before any parser sees it, both before this change and after. None of the eight
ini writers or RetroArch emits CRLF on this appliance.

**Excluded, and prevented rather than accepted.** Recreation is not formatting:
it rewrites the file with only the owned keys in it, so every unowned setting
the emulator was reading disappears. Each rule below either stops the library
losing a setting silently, or stops the recreate path narrowing below today's
and stranding a credential. None is closed by a constructor option.

1. *A final line with no terminating newline.* `configupdater` stores each
   block's raw text including its terminator, so an unterminated last option
   has none and appending a new option writes immediately after it:
   `[A]\nToken = x` plus a new key `New` renders `Token = xNew = y`, destroying
   an unowned assignment and the owned key together, silently and permanently,
   because the next run parses `Token` as holding `xNew = y`. An unterminated
   last line is what a power cut leaves. **Rule:** the load helper appends a
   newline to the source text if it lacks one. Append only - not
   strip-then-append.
2. *An indented line.* `configparser`-family parsers treat a line indented
   past its option as a value continuation, so `[A]\nkey = 1\n    x\n` parses
   with `key` holding `'1\nx'` and writing `key` renders the file without that
   line. Executed against 3.2, this silently destroys an indented comment, an
   indented assignment and an indented section header alike. **Rule:** the load
   helper strips leading whitespace from every line before wrapping. Nothing is
   ever swallowed, so no line an emulator wrote is lost, and no shape today's
   parser accepts is pushed into the recreate path. (An indented line that is
   not a setting at all, such as a bare `    x`, becomes a bare `x` and raises
   `ParsingError`, reaching rule 6 and recreating - which is exactly what
   `_parse_ini` does with it today, so parity holds.) Executed: with stripping, `  # note` survives as a comment
   line, `  ind = 9` survives as the setting `ind = 9`, and `  [B]` becomes a
   real section with the keys below it landing under `B` - which is what today's
   parser already does, since `_INI_SECTION_RE` is anchored `^\s*\[` and matches
   an indented header. The cost is the indentation itself, which is formatting
   no consumer reads. Keep a backstop assertion that no parsed option's value
   contains a newline; with stripping it should be unreachable, and if it fires
   the file is unparseable and takes the existing recreate path.
3. *A bracketed line the library names differently than today's parser
   does.* This is the credential path. `configupdater` inherits
   `configparser`'s `SECTCRE`, `\[(?P<header>.+)\](?P<raw_comment>.*)`, greedy
   to the last `]` and requiring at least one character inside the brackets;
   `_INI_SECTION_RE` is `^\s*\[(?P<name>[^]]*)\][ \t]*(?:[;#].*)?$` and
   deliberately accepts a trailing comment of any content. Where they disagree
   about a section's *name*, a `REMOVE` loop over the declared section finds
   nothing, the document parses cleanly so no recreation fires, and a live
   `Token` survives - permanently, since every later launch parses it cleanly
   too. **Rule, both formats**, a three-way decision on every line whose
   stripped form begins with `[`:

   - `SECTCRE` does not match it, so the library will not read a header
     there: **pass it to the parser unchanged.** `[foo bar = baz` is an
     ordinary option named `[foo bar` to both the library and
     `_split_ini_assignment`, and stays one. `[]` and its whitespace and
     comment variants reach the parser and raise `ParsingError`, so rule 6
     recreates - which is *better* than today, where `_INI_SECTION_RE`
     matches `[]` with an empty name that never equals the owned section and
     a token strands on disk.
   - `SECTCRE` matches and `_INI_SECTION_RE` does not: **refuse**, and the
     file takes the recreate path. `[Achievements] [was Cheevos]` and
     `[Achievements][x]` are recreated today for the same reason, so this is
     parity; `[foo] = bar` is not, and is recorded below as a shape that
     moves.
   - Both match but their names differ: **rewrite that line to `[<name>]`,
     where `<name>` is `_INI_SECTION_RE`'s group, before wrapping.** This is
     the case a legal trailing comment containing a `]` produces -
     `[Achievements] ; was [Cheevos]`, which today's parser reads as section
     `Achievements` and edits in place, removing the token and keeping every
     unowned setting. Refusing it would recreate a file the current program
     preserves, destroying every unowned setting to fix a naming
     disagreement; normalising the header makes both grammars agree and costs
     only the header's trailing comment, which this decision already places
     outside the contract.

   RetroArch additionally refuses any document containing a section other
   than the synthetic one, since `_parse_retroarch` rejects every line
   without an `=` and so has no headers at all; that also catches
   `[something] = "x"`. An exhaustive search over short bracketed lines found
   no remaining class where the guard accepts and the two grammars still name
   a section differently. Because `_INI_SECTION_RE` supplies the name the
   comparison and the rewrite are against, it is retained rather than deleted.
4. *A file already carrying the sentinel's header.* Wrapping is
   `[<sentinel>]\n` + the text, so a file containing its own `[<sentinel>]`
   line yields two same-named sections; lookup resolves to the wrapper, the
   file's real keys become invisible, and stripping only the leading line
   leaves the sentinel in the output. The sentinel cannot be made unspellable:
   every newline-free string is a legal header name, and a name containing a
   newline cannot serve as the wrapper. **Rule:** the sentinel is a fixed
   improbable literal, and the refusal check is the whole of the defence. The
   load helper refuses source text in which any line, after its leading
   whitespace is stripped, is matched by `SECTCRE` with a header group equal to
   the sentinel - with no restriction on what follows the closing bracket,
   since that group is `.*` and accepts any text. A naive substring test for
   `[<sentinel>]\n` is not sufficient. This rule is needed for *both* formats
   and is the sole defence against the collision: a canonical `[<sentinel>]`
   line is named identically by both grammars, so rule 3 accepts it and only
   this rule catches it. Rule 3 refuses only the suffixed spellings.
5. *An empty or whitespace-only file.* `_parse_ini` returns None for text that
   does not `strip()`, which drives `set_ini_settings`'s deferred "is empty;
   recreating it" note; through the synthetic header, `""`, `"\n"` and
   `"   \n"` all parse cleanly and the note would silently disappear.
   **Rule:** the load helper reports empty or whitespace-only text as
   unparseable. INI only, matching today: `_parse_retroarch` has no empty-file
   check.
6. *The library's own parse failures.* `configupdater` re-exports
   `configparser`'s `ParsingError` and `MissingSectionHeaderError`. `main`'s
   editor loop guards `except OSError` only, and the kiosk session runs
   `emubox-prepare` unguarded under `set -e` with an EXIT trap that ends at the
   greeter, so an escaping parse error would end the family's evening rather
   than recreate a file. **Rule:** the load helper catches
   `configparser.Error` and reports the file unparseable.

**Recreate width.** Which files are editable is set by the parser options *and*
by the guards above, and the defaults do not match today's parsers.
`configupdater` inherits `delimiters=("=", ":")`, so `Time: 12` would become an
option where `_split_ini_assignment` partitions on `=` alone and rejects it.
**Rule:** the load helper is constructed with `delimiters=("=",)`, and with
`comment_prefixes` matching each format's current parser - `("#", ";")` for
INI, `("#",)` for RetroArch, since `_parse_retroarch` does not treat `;` as a
comment.

Two shapes move relative to today and are accepted rather than prevented. A
bare `= value` line raises `ParsingError` and so recreates, where today it is
preserved as an assignment with an empty key; the library cannot parse the
file at all, so recreate or do nothing are the only options and recreate is
the existing policy for a file no parser can read. An empty key is not a
setting any consumer acts on, and the journal says the file was recreated. And
a line beginning with `[` that carries an `=` after the closing bracket, such
as `[foo] = bar`, is an ordinary preserved assignment today - `_INI_SECTION_RE`
rejects it while `_split_ini_assignment` accepts it with key `[foo]` - and is
refused by rule 3 after this change. Refusing is the better of the two
available outcomes, because the alternative is the library reading it as a
section header and reattributing every key below it to a section that does not
exist in the file the emulator reads.

Two shapes move in the preserving direction. `[]` strands a token today,
because the empty section name never equals the owned one; after this change
rule 3 passes it to the parser, which raises `ParsingError`, so rule 6
recreates and the token is removed. A trailing
blank-line run, which today's editors collapse by `rstrip`-and-rejoin,
survives an edit intact once that hand-written normalisation is deleted; the
load and dump helpers therefore do not reintroduce an `rstrip`.

## Risks / Trade-offs

- [A silent regression in the credential-removal path takes a
  RetroAchievements bearer token off the box less thoroughly than
  before, and nothing says so] → The 186 unit tests run in 26 s on the
  administrator's Mac and cover that path heavily, and decision 7 rule 3
  exists because this is the way the migration could have caused it. A
  test that changes meaning outside decision 7's contract is a finding to
  explain rather than a test to update; a test that changes meaning
  because formatting moved is expected, since formatting is outside the
  contract. Decisions 3 and 5 each get a test of their own; decision 4's
  is the editor-level pair in tasks 2.2 and 3.3.
- [The synthetic header leaks into a written file] → It is stripped in
  exactly one place, and a test asserts no written file contains the
  sentinel, for every format and every branch that writes. The stronger
  case, a file that already carries a header spelling the sentinel, is
  not covered by stripping at all and is handled by decision 7 rule 4.
  That rule rests entirely on the load helper's refusal check: the
  sentinel cannot be made unspellable, because the library's section
  regex accepts any newline-free name, and a newline-bearing name would
  break the wrapper itself.
- [Trading a large piece of cleverness for a small one] → Accepted, and
  named rather than hidden: wrapping a non-INI file in a fake section
  header to reuse an INI library is a trick. It is confined to the load
  and dump helpers, and the design records why it exists.
- [A new dependency in the appliance's closure] → `configupdater` is
  pure Python with no transitive dependencies, and `closure-check`
  already bounds the system closure.
- [The library's idea of an unparseable file differs from the current
  parser's, silently widening or narrowing the recreate path] → Confirmed
  real, not hypothetical, and it took four forms, each answered by a rule
  in decision 7 rather than by a constructor option. A `key: value` line
  parses where today it recreates, which `delimiters=("=",)` closes. An
  indented line is swallowed into the preceding value, which rule 2
  answers by stripping leading whitespace before the library reads any
  line, so a comment, an assignment and a section header all survive as
  themselves. A bracketed line the library *names* differently than
  today's parser does is the dangerous one, because it narrows the path
  and strands a live credential - and it reaches that state through a
  header carrying a legal trailing comment as readily as through a
  malformed one; rule 3 answers it in both formats by requiring the two
  grammars to agree on the name. The empty-file check is the fourth, lost with the parser
  that carried it, and rule 5 carries it forward. Task 2.5 asserts each
  shape's outcome against the mechanism that delivers it.

## Migration Plan

1. Add `configupdater` to the derivation's Python closure; confirm the
   check still builds on `aarch64-darwin`, which is where the suite runs
   fastest.
2. Introduce the load and dump helpers under their own tests, before any
   editor uses them: the synthetic header, `strict=False`,
   `delimiters=("=",)` and per-format `comment_prefixes` as construction
   arguments, `optionxform` assigned to `str` on the constructed
   instance, plus decision 7's six exclusion rules: append a newline to
   source text that lacks one; strip leading whitespace from every line so no
   line can be read as a value continuation; refuse a bracketed line the
   library would name differently than today's parser names it, in both
   formats; recreate rather
   than wrap a file carrying a header that spells the sentinel; report an
   empty or whitespace-only file unparseable so the INI editor keeps its
   own note; and catch `configparser.Error` so a parse failure reaches
   the recreate path rather than the greeter.
3. Move `set_ini_settings` onto them, keeping its policy code and its
   signature. Keep every existing INI test passing without edits.
4. Move `set_retroarch_settings` onto them, same rule.
5. Move `_current_ini_value` onto the quiet variant of the load helper
   (decision 6), so the last caller of the old machinery is off it.
6. Delete the eleven helper functions once nothing references them, keeping
   `_INI_SECTION_RE`, which decision 7 rule 3 turns into the INI header guard;
   confirm
   in both directions: no function left unreferenced inside the module,
   which is the AST reachability check the audit used, and no name
   loaded in the module that nothing binds, which is what catches a
   survivor still calling something deleted.

Rollback is `git revert`: the change is confined to one module, its
tests and one derivation input, and it alters no interface any caller or
NixOS module depends on.
