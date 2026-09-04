# prepare-flat-bom tasks

## 1. The prefix rule

- [x] 1.1 Teach the flat-file read path to set aside exactly one
  leading U+FEFF before any other rule runs, in both formats, and
  verify a marked but otherwise readable file loads as a document
  whose first line is the line after the mark.
- [x] 1.2 Remember the mark on the loaded document and re-emit it
  first on write, and verify an edit to a marked file writes the mark
  back byte-for-byte at position zero.
- [x] 1.3 Keep every other behavior untouched: verify tests that a
  mark before a section header - or on any other line without an
  assignment - still fails to parse and recreates as today, that a
  doubled leading mark before a header recreates as today, that a
  mark embedded inside an unowned assignment is preserved unchanged,
  and that a file containing only the mark takes its format's
  existing empty-file path: in the sectioned INI format, recreated
  with the deferred "is empty; recreating it" journal note when its
  owned keys carry values, and left unwritten, exactly as an empty
  file is, when its owned keys are all removals; in the sectionless
  RetroArch format, loaded as an empty document and written with the
  owned keys appended and the mark still leading, reporting no write
  on the following run.

## 2. The regression proof

- [x] 2.1 Add the real-shape regression test: a `ppsspp.ini` as
  PPSSPP's writer saves it - mark first, then its sections - with
  unowned keys present and an owned key drifted; verify every unowned
  key survives with the value PPSSPP wrote, only the owned values
  change, and the mark still leads.
- [x] 2.2 Add the settled-file test that pins the loop this change
  kills: the same marked file already carrying every owned value
  reports no write on two consecutive runs, and verify the same
  fixture reproduces the recreate-every-launch loop when run against
  the predecessor revision (recorded here, not committed as a test).

  Predecessor reproduction, recorded 2026-09-04: the settled marked
  fixture (the `ppsspp_file("True")` shape from the test file - mark
  first, then `[General]`/`[CPU]`/`[Graphics]`/`[Sound]` with unowned
  keys and `FullScreen = True`) was run through `set_ini_settings` from
  `pkgs/emubox-prepare/emubox_prepare.py` at revision `59b1b5f` (main
  before this change). One run: the file is recreated - stderr says
  ``has a line that is not a setting ('﻿[General]'); recreating
  it`` - every unowned key is dropped and the mark no longer leads.
  Three runs with the mark re-prefixed between them, simulating
  PPSSPP's own save on exit, recreate on every single run (`wrote=True`
  three times), which is the recreate-every-launch loop. The same
  driver against this branch's revision reports no write on every run
  with all unowned keys intact and the mark still leading.

## 3. Spec and prose

- [ ] 3.1 Diff the reproduced requirement text in this change's
  `specs/emulators/spec.md` against the then-current text of the
  modified requirement - `prepare-configupdater`'s delta while that
  change is open, the main emulators spec once it has archived -
  setting aside the mark paragraph and the two mark scenarios this
  change adds, and redo the copy from the current text if they
  differ; then confirm the delta matches the implemented behavior
  sentence by sentence, and verify
  `openspec validate prepare-flat-bom --strict` passes.
- [ ] 3.2 Update the module docstring's flat-file overview to state
  the mark tolerance and its bounds, and verify the docstring makes no
  claim the tests do not pin.

## 4. Evidence

- [ ] 4.1 Run the full suite and `just check-all`, and verify both
  exit clean.
- [ ] 4.2 Build the derivation's check phase for aarch64-darwin and
  x86_64-linux, and verify both pass.
- [ ] 4.3 Verify `just kiosk-test` passes in CI once the branch is
  pushed; this box closes only against a CI run that exists.
