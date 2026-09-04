# prepare-flat-bom design

## Context

See proposal.md - Why. PPSSPP's writer emits a UTF-8 byte order mark
before every save; the flat-file reader decodes it to a U+FEFF that is
not whitespace, so the first line never classifies as anything readable
and the file is recreated on every launch, losing every unowned key.
The fix is one prefix rule at the flat-file boundary. What makes it a
change of its own rather than a patch is that it widens which files are
editable - the exact boundary the two preceding changes were built to
hold still - so the widening is specified, deliberate and tested.

## Goals / Non-Goals

Goals:

- A leading mark stops making a flat file unreadable, and survives a
  write byte-for-byte.
- The widening is exactly one file shape; every other refusal is
  untouched.

Non-Goals:

- No tolerance for any other encoding artifact (UTF-16, a mark
  mid-file, a doubled mark beyond the first).
- No change to the ES-DE XML editor; no emulator other than PPSSPP is
  expected to exercise this, though the rule is format-level and both
  flat formats get it.

## Decisions

**D1: preserve the mark on write, do not strip it.** The mark is a
byte the emulator wrote and the contract's whole posture is that such
bytes survive. Stripping would also work - PPSSPP demonstrably reads
markless files, because every recreated `ppsspp.ini` today is markless
and PPSSPP loads it and re-saves - but preserving needs no claim about
any emulator's reader at all, and keeps a settled file byte-stable
instead of alternating with the emulator's own saves.
Alternative rejected: decode with `utf-8-sig` and forget the mark;
simpler read path, but the write then silently drops a byte the
emulator put there.

**D2: the rule lives at the flat-file read and write boundary, not in
the shared text reader.** The shared reader also serves the ES-DE XML
path, whose parser has its own opinion about leading bytes; scoping
the rule to flat files keeps this change's footprint equal to its
spec delta. After `prepare-flat-cst` the natural home is the document:
the mark is set aside before classification, remembered on the
document, and re-emitted first at render. On the current layer the
same rule brackets the load and dump helpers - and it must also
govern the editor's two emptiness judgments, which consult the raw
disk content rather than the loaded document: the deferred
empty-file note probe in `set_ini_settings`, which has to see a
mark-only file as empty for the note to fire, and `_holds_something`,
whose question is whether the file holds anything a recreation would
drop - and a mark-only file holds nothing but the mark. Either host
satisfies the same tests.

**D3: leading means leading.** Exactly one U+FEFF, at index zero of
the decoded text, is set aside. After that single set-aside the
residual text simply takes the existing rules; no shape gets an added
refusal anywhere. What any further mark does therefore depends on the
shape of the line carrying it, never on how many marks the file held
or where one sits. A mark on a line without an assignment - alone on
its line, or before a section header - leaves a line the existing
rules cannot read, so the file fails to parse and recreates, as
today. A mark inside an assignment line is ordinary content, part of
the key or the value, and is preserved, as today. A doubled leading
mark splits along the same seam: after the set-aside the residual
leads with one mark, and its first line decides - a second mark
before a section header, or on any other line without an assignment,
still fails to parse and recreates as today, while a second mark
leading an assignment line glues to the key and parses as ordinary
content, today and after this change alike. A file whose residual
text is empty is an empty file, and the existing rules genuinely
differ by format there, so the reduction composes differently per
format. The sectioned INI format refuses to load an empty file: a
mark-only file whose owned keys carry values is recreated - markless,
since the recreate path writes only the owned values - with the
deferred "is empty; recreating it" journal note, and one whose owned
keys are all declared for removal is left unwritten, exactly as an
empty file is. The sectionless RetroArch format reads an empty file
as a readable empty document: a mark-only file loads, gains the owned
keys appended after the mark, keeps the mark leading afterward, and
is settled thereafter - no note, no recreation.

**D4: the regression test is the real shape.** The reproduction from
the survey - a `ppsspp.ini` as PPSSPP saves it, mark first - becomes a
test asserting the three observable facts: every unowned key survives
with the value PPSSPP wrote, only the owned values change, and the
mark still leads. A second test pins the loop this
kills: a settled marked file reports no write, twice in a row.

## Risks / Trade-offs

- [The widening admits a file that used to be refused for a second,
  unnoticed reason] -> The tolerance is one codepoint at one position;
  every other refusal check runs on the text after the mark is set
  aside, unchanged, and the refusal tests all still pass.
- [Sequencing: two open changes touch the same layer] -> Implemented
  after `prepare-flat-cst` if that change proceeds, and its delta is
  written against `prepare-configupdater`'s requirement text; if
  either predecessor moves, this change rebases its one rule rather
  than the other way around, and task 3.1 diffs the copied
  requirement text against the then-current text before validating,
  so a stale copy is caught rather than archived.

## Migration Plan

Branch from whichever predecessor branch is current when this is
applied. One launch after deploy, `ppsspp.ini` stops being recreated;
nothing needs migrating because the defect never let state accumulate.
Rollback is reverting the branch and returns to the known recreate
loop, losing PPSSPP preferences again but nothing else.

## Open Questions

None.
