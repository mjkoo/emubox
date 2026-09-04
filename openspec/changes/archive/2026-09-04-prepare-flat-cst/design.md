# prepare-flat-cst design

## Context

See proposal.md - Why. The flat-file layer currently reads both formats
through configupdater behind an impedance layer whose every rule answers
a hazard of the borrowed parser, not of the files: a synthetic wrapper
section, an indiscriminate per-line `lstrip`, a grammar reconciliation
against `Parser.SECTCRE`, a post-construction `optionxform` under a
checker suppression, and a four-exception catch tuple. The editors
themselves (`sweep`, `write`, survivor reduction, flash-wear comparison,
recreate policy) are sound and carry over; only the document model
underneath them changes.

Constraints that shape the design:

- The parity baseline is the `prepare-configupdater` branch and its
  test suite. Every observable behavior - which files are refused,
  what the journal is told, what bytes are written - is defined by that
  implementation, not re-derived from scratch.
- The program stays a single stdlib-plus-cryptography script installed
  by `patchShebangs`; no new runtime dependency may replace the one
  being removed.
- The emulators' own parsers define the grammar: RetroArch rejects any
  line without `=` and has no sections; the Qt-family INI writers emit
  canonical `[Name]` headers, `#`/`;` comments and `key = value` lines.

## Goals / Non-Goals

Goals:

- One document model for both flat formats, typed, lossless, stdlib
  only, with the grammar stated in a single per-line classifier.
- Zero index arithmetic and zero defence against a foreign parser's
  semantics.
- A refusal set provably equal to the baseline's, except two declared
  wrapper artifacts.

Non-Goals:

- No behavior change beyond the declared refusal-set and presentation
  diffs below. In particular the PPSSPP BOM stays unreadable.
- No change to the ES-DE XML editor, the RetroAchievements flow, or
  any caller of the two editors.
- No general INI library. The model supports exactly what these two
  formats and these editors need; unsupported shapes take the recreate
  path exactly as they do today.

## The document model

Vocabulary, defined once; the code names match:

| Node | Holds | Meaning |
|---|---|---|
| `Blank` | `raw` | a line that is empty or whitespace only |
| `Comment` | `raw` | a line whose stripped text starts with a comment prefix |
| `Assignment` | `raw`, `key`, `value` | a `key = value` line; `raw` is the line verbatim |
| `SectionNode` | `raw_header` (None for the preamble), `name`, `children` | a header line plus every line below it until the next header |
| `Document` | `sections: list[SectionNode]` | the whole file; `sections[0]` is always the preamble |

Rules of the model:

- Every node keeps its source line verbatim in `raw`. Rendering a
  document is concatenation of `raw` values with `\n`; a document
  nobody edited renders byte-identical to what was read (plus a final
  newline when the source lacked one, matching the baseline's written
  bytes). There is no index anywhere: an edit mutates or removes a
  node, and sections own their children, so deletion invalidates
  nothing.
- Editing an assignment replaces the node with one whose `raw` is
  re-rendered as `key = value`. Only the edited line is normalised;
  every untouched line keeps its bytes. This matches the baseline,
  which re-renders exactly the lines it assigns.
- The preamble is a first-class `SectionNode` with `raw_header` None.
  This is the honest version of the wrapper section: the region above
  the first header exists in the model instead of being smuggled in as
  a fake header and stripped back off. For RetroArch the whole file is
  the preamble and a `SectionNode` with a real header is a refusal.
- A rendered `Assignment` must be one line. `_writable` keeps dropping
  values carrying `\n` or `\r` at both editors' doors, and the
  renderer asserts the invariant.

## The classifier

One function turns one line into one node kind, trying in order:
blank, comment, header (INI only), the two ranked junk rules below,
assignment, junk. Junk is not a node: any junk line refuses the whole
file into the recreate path, which is the baseline's `ParsingError`
behavior with a plain reason.

Per-format differences are data, not code paths: comment prefixes
(`#` and `;` for INI, `#` alone for RetroArch), and whether headers
are legal (INI) or a refusal (RetroArch).

Classification runs on the line stripped of all leading and trailing
whitespace; the node keeps the raw line. This preserves the baseline's
readability decisions (an indented assignment or header is still that
line, under any Unicode whitespace) while no longer destroying the
indentation on write - there is no continuation concept for
indentation to trigger, because no parser with one is involved.

Lines are split on `\n` alone, never `str.splitlines()`, so a value
carrying U+2028 or another exotic separator stays one line, as today.

Header names are non-empty: `[]` is not a header, has no `=`, and is
junk - the baseline refuses it too.

Two junk rules outrank the assignment rule, because the baseline
refuses these shapes even though they carry `=`:

- A line the library's header grammar reads - `[`, then a closing `]`
  with at least one character of any kind between them - that fails
  the full header grammar is junk in both formats, `=` or not.
  `[Name] = v`, `[Name]x = y` and `[]] = v` are all headers to the
  library's greedy `\[.+\]`, and unreadable to this program's, so the
  baseline recreates the file rather than let keys land under a
  section the emulator reads differently. The shape is the library's,
  not "non-`]` characters then `]`": the greedy grammar happily puts
  `]` inside a name, so the rule keys on a `]` anywhere past the
  second column. A line with no such `]` never matches, so
  `[foo bar = baz` stays an assignment named `[foo bar` and `[] = y`
  (its only `]` closes an empty name the library rejects) stays an
  assignment named `[]`, exactly as the baseline reads both.
- An assignment's key must be non-empty after stripping: `= v` is
  junk, matching the baseline's `ParsingError`. `[] = y` carries the
  non-empty key `[]` and stays an assignment, as it is today.

## Refusal-set parity

The boundary between "edited in place" and "recreated, unowned keys
lost" is the riskiest thing this change touches, so it is enumerated.
Every row is pinned by a test.

| File shape | Baseline | CST | Same? |
|---|---|---|---|
| unreadable bytes / OSError | recreate | recreate | yes |
| empty or whitespace-only INI file | recreate, note deferred to the editor | same | yes |
| line that is no comment, header or assignment (INI or RetroArch) | recreate | recreate (junk) | yes |
| `[]` | recreate | recreate (junk) | yes |
| `[Name] trailing junk` | recreate ("cannot read") | recreate (junk) | yes, different journal wording |
| `[Name] = v`, `[Name]x = y`, `[]] = v` (library header shape, this grammar fails) | recreate ("cannot read") | recreate (junk) | yes, different journal wording |
| `= v` (empty key) | recreate | recreate (junk) | yes |
| header in a RetroArch file | recreate | recreate | yes |
| `;`-prefixed line without `=` in a RetroArch file | recreate | recreate (junk) | yes |
| value spanning lines | impossible at parse; guarded at write | impossible by construction; same write guard | yes |
| section named `emubox-flat-file-wrapper` | recreate (wrapper collision) | ordinary editable file | no - declared |
| owned values naming that section | refused as reserved, noted | ordinary section | no - declared |

The two declared rows are wrapper artifacts: no emulator writes that
header, the shape arises only from a hand edit, and the spec mandates
recreation only for files that cannot be read as the emulator's format
- which these can. Both diffs strictly reduce data loss.

Presentation diffs, declared up front and within the spec's stated
tolerance ("spacing, indentation, a line's position - not guaranteed"):

- Unowned lines keep their indentation through a write; the baseline
  strips every line when any write happens.
- A section header keeps a trailing comment; the baseline normalises
  the header and drops it.
- Everything else the baseline preserves stays byte-preserved.

## Decisions

**D1: stdlib dataclasses and `match`, no parsing library.**
Alternatives rejected:
- *Keep configupdater (status quo)*: measured wash; couples the
  refusal boundary to library internals (`Parser.SECTCRE`, the
  exception surface, continuation handling) that a version bump can
  move silently.
- *lark with `keep_all_tokens`*: the only credible lossless library
  route, but its tree is generic `Tree`/`Token` objects with stringly
  node names; the typed layer would be written anyway, leaving lark
  supplying only a line classifier that five regexes already are.
- *tree-sitter*: lossless but text-first editing - mutating means byte
  span arithmetic plus reparse, the bookkeeping this layer already
  paid to remove once; needs a compiled grammar per format.
- *pyparsing / parsy combinators*: earn their keep on nested grammars;
  this one is line-regular with zero nesting.

**D2: a two-level tree, not a flat line list with section ranges.**
Sections own their children. Ranges over a flat list are exactly how
the pre-configupdater editor accumulated bounds arithmetic
(`_ini_section_bounds`, `protect` ranges, recompute-after-delete); a
child list makes deletion local and order-safe by construction.

**D3: refusal parity is enforced differentially, then kept by tests.**
While both implementations exist in the tree, a one-time harness in
`.scratch/` feeds a corpus - every fixture in the test suite plus
generated edge shapes - through both implementations and compares the
readable-or-refused verdict and, where both edit, the written bytes
modulo the declared presentation diffs. The gate runs in two halves,
because the swap replaces the public editors in place: the loader half
runs before the swap, old loader against new parser; the editor half
runs after the swap, the new public editors against the old layer
driven directly through its still-present helpers, before the
deletion group removes them. Any undeclared difference is a defect in
the new code. The harness cannot outlive the change (its other half
is deleted with the dependency), so the durable protection is the
behavior suite: every parity-table row and every declared diff lands
as a named test.

**D4: edited lines are re-rendered as `key = value`; unedited lines
are verbatim.** The baseline does the same on the lines it assigns,
and the flash-wear rule (compare stripped values, skip the write when
equal; write the file only when something changed) carries over
unchanged, so a settled file is still untouched on every launch.

**D5: the editors' semantics move, not change.** Write target is the
first instance of a repeated section; removal sweeps every instance
plus the preamble; a written key is reduced to one surviving
assignment, keeping the last copy in the target section; recreate
branches build a fresh document holding only the owned values. Each is
already pinned by the suite and stays pinned.

## Risks / Trade-offs

- [The program owns a parser again] -> The grammar is one classifier
  function with one regex per line kind; D3's differential gate proves
  the boundary equal at the moment of the swap; the 298-test behavior
  suite and per-rule discrimination tests (each classifier rule has a
  test that fails when the rule is broken) keep it equal afterward.
- [Parity is defined against an implementation, not a document] -> The
  parity table above is the document, it is exhaustive over the
  baseline's refusal reasons, and every row is executable.
- [The differential harness dies with the change] -> Accepted; it is a
  gate, not a regression net. Its corpus and verdict summary are
  recorded in tasks.md before the old implementation is deleted.
- [`prepare-configupdater` is still open] -> This change builds on its
  branch. If that branch gains further commits before this one starts,
  the baseline is re-measured (suite run, corpus regenerated) before
  the swap.

## Migration Plan

Branch off the `prepare-configupdater` branch (or main, once that
change has landed there). Implement the model and classifier alongside
the existing layer, run the differential gate, swap the editors over,
delete the old layer and the dependency, then the standard evidence:
full suite, `just check-all`, the derivation's check phase on both
platforms, `just kiosk-test` in CI. Rollback is reverting the branch;
nothing outside `pkgs/emubox-prepare` and the two nix files changes.

## Open Questions

None.
