# prepare-flat-cst tasks

## 1. The document model and classifier

- [x] 1.1 Add the node dataclasses and `Document` from design.md's
  vocabulary table alongside the existing layer, untouched by any
  caller yet, and verify `ruff check` and `ty check` pass with the new
  definitions referenced by their tests alone.
- [x] 1.2 Implement the per-line classifier with per-format data
  (comment prefixes, headers legal or refused) and a test per rule:
  blank, comment, header, assignment, junk, non-empty header names,
  non-empty assignment keys (`= v` is junk), library-header-shape
  junk outranking assignment (`[Name] = v`, `[Name]x = y` and
  `[]] = v` are junk in both formats; `[foo bar = baz` and `[] = y`
  stay assignments),
  split on `\n` alone, classification on the fully stripped line.
  Verify each rule's test fails when its rule is broken (run the
  broken variant once, record the failing test name in this file).
  Mutation evidence - each broken variant was run once and made
  exactly this test fail:
  - blanks read as comments -> test_classifier_reads_a_blank_line_as_blank
  - comment prefixes not per-format ->
    test_classifier_reads_comment_prefixes_per_format
  - headers junked in INI -> test_classifier_reads_a_header_in_an_ini_file
  - headers accepted in RetroArch ->
    test_classifier_refuses_a_header_in_a_retroarch_file
  - empty header names accepted ->
    test_classifier_does_not_read_an_empty_name_as_a_header
  - loose-header junk rule dropped ->
    test_classifier_junks_a_loose_header_shape_even_when_it_carries_an_equals
  - empty assignment keys accepted ->
    test_classifier_junks_an_assignment_with_an_empty_key
  - assignment halves left unstripped ->
    test_classifier_reads_an_assignment_and_strips_its_halves
  - junk lines kept as comments ->
    test_classifier_junks_a_line_with_no_equals
  - classification on the raw line ->
    test_classifier_classifies_the_fully_stripped_line
  - split via str.splitlines -> test_parse_splits_on_newlines_alone
- [x] 1.3 Implement parse and render, and verify the round-trip
  property test passes: for every readable fixture in the suite,
  parse-then-render is byte-identical except the appended final
  newline when the source lacked one.
- [x] 1.4 Implement the refusal path and verify a test per parity-table
  row from design.md - every "yes" row refuses in both formats it
  applies to, and each refusal reaches the journal with a reason
  except the empty INI file, which stays silent for the editor to
  announce.

## 2. The differential parity gate

- [x] 2.1 Build the harness in `.scratch/prepare-flat-cst/`: feed every
  flat-file fixture used by the suite plus generated edge shapes
  (indented lines under each Unicode whitespace, header trailing
  comments, `[]`, library-header-shape lines carrying `=` such as
  `[Name] = v`, `[Name]x = y` and `[]] = v`, empty-key lines such as
  `= v`,
  unterminated last lines, repeated sections and keys, wrapper-named
  sections, BOM-prefixed files) through both loaders, and verify it
  reports verdict agreement everywhere except the two declared
  wrapper rows. The editor half of the gate is task 3.7: it needs the
  new editors, which do not exist until group 3 swaps them in.
  Loader-half run (`.scratch/prepare-flat-cst/differential.py`): every
  string constant in the test suite plus the generated edge shapes,
  1720 distinct texts, 3440 verdict pairs, 3356 agreements, 84
  disagreements all matching the declared wrapper-header row (checked
  against the refusal message's full prefix, not a substring), 0
  undeclared.

## 3. Swapping the editors

- [x] 3.1 Move `set_ini_settings` onto the document model - sweep
  every instance plus the preamble, write into the first instance,
  reduce survivors keeping the last copy in the target, recreate
  branches building a fresh document - and verify every existing INI
  editor test passes unamended except those pinning stripped
  indentation or normalised headers.
- [x] 3.2 Amend the tests that pin the baseline's presentation
  (stripped indentation, header trailing comments dropped) to pin the
  preserved presentation instead, and verify each amended test fails
  against the baseline behavior and passes against the new.
  Verified red against the pre-swap editors, green after:
  test_ini_keeps_an_indented_comment_through_a_write,
  test_ini_keeps_an_indented_assignment_through_a_write,
  test_ini_keeps_an_indented_section_header_through_a_write,
  test_ini_keeps_a_line_indented_by_any_whitespace (6 params),
  test_ini_keeps_a_header_whose_trailing_comment_carries_a_bracket,
  test_ini_keeps_a_header_whose_hash_comment_carries_a_bracket.
- [x] 3.3 Move `set_retroarch_settings` onto the document model with
  the whole file as the preamble and headers refused, and verify every
  existing RetroArch editor test passes with the same amendment rule
  as 3.1.
- [x] 3.4 Move `_current_ini_value` onto the new quiet read path,
  first instance of its section only, and verify the probe's silent
  `None`-cause tests pass unamended.
- [x] 3.5 Keep `_writable` at both editors' doors and add the renderer
  assertion that an assignment renders to one line; verify the
  multi-line and `\r` regression tests pass unamended.
- [x] 3.6 Add tests for the two declared refusal-set diffs: a file
  carrying a section named `emubox-flat-file-wrapper` is edited in
  place with its unowned keys preserved, and an owned-values table
  naming any section is honored with no reservation note. Verify both
  fail against the baseline and pass against the new code.
  Verified red against the pre-swap editors, green after:
  test_ini_edits_a_file_carrying_a_wrapper_named_section_in_place
  (4 spellings),
  test_ini_honors_an_owned_table_naming_a_wrapper_like_section,
  test_ini_recreating_a_file_owning_only_a_wrapper_like_section_writes_it.
- [x] 3.7 Extend the differential harness through both editors: the
  new `set_ini_settings` and `set_retroarch_settings` against the old
  layer driven directly through its surviving helpers (`_read_flat`,
  `_sweep_flat_key`, `_write_flat_key`, `_dump_flat`), which group 4
  has not yet deleted, with the owned-key tables the program really
  uses, comparing written bytes modulo the two declared presentation
  diffs. Verify zero undeclared differences, and record the corpus
  size and verdict summary in this file before group 4 deletes the
  old implementation.
  Editor-half run (`.scratch/prepare-flat-cst/differential_editors.py`):
  instead of re-driving the surviving helpers through a hand-written
  loop, the old side is the genuine pre-swap module (the branch commit
  whose public editors still ran on those helpers), so the comparison
  is old public editor against new public editor with zero
  transcription. Tables came from the evaluated module configuration
  (every flat file's static keys, plus each RetroAchievements target's
  logged-in and logged-out merges) plus the declared wrapper-owning
  and all-removals tables. 1721 file states (the loader corpus plus
  the absent file) x 12 INI and 4 RetroArch tables, run twice per
  side for flash-wear parity: 34692 comparisons, 3148 declared
  wrapper divergences skipped, 0 undeclared differences in written
  bytes, write verdicts, or second-run bytes.

## 4. Deleting the old layer

- [x] 4.1 Delete the configupdater layer - `_flat_document`,
  `_flat_source`, `_load_flat`, `_read_flat`, `_read_flat_quietly`,
  `_empty_flat_document`, `_dump_flat`, `_flat_places`,
  `_flat_write_target`, `_sweep_flat_key`, `_write_flat_key`, the
  wrapper constants, `_FLAT_PARSE_ERRORS`, the configupdater imports -
  plus the tests that exist only to pin that library's behavior, and
  verify the whole-module orphan tests and the full suite pass.
- [x] 4.2 Remove `configupdater` from `package.nix` and from
  `flake.nix`'s prepare python, update both files' comments, and
  verify `nix build .#checks.aarch64-darwin.emubox-prepare` passes.
- [x] 4.3 Update the module docstring's editor overview and any prose
  in the repo naming configupdater as what the editors read through,
  and verify `grep -ri configupdater` over the repo (generated,
  `.scratch/` and `openspec/` paths aside - the planning artifacts
  name the library by design) reports nothing in code or durable
  docs.
- [x] 4.4 Record the measured before/after statement and branch counts
  of the flat-file layer in this file, and verify the numbers come
  from the same AST measurement run against both revisions.
  One instrument (`.scratch/prepare-flat-cst/measure.py`: statements
  are every AST statement node inside the layer's top-level
  definitions; branch points are if/elif, while, for, comprehension
  ifs, ternaries, except handlers, asserts, and each boolean operator
  beyond its first operand), run against both revisions:
  - before (the configupdater layer at the parity baseline, 18
    definitions from `_INI_SECTION_RE` through
    `set_retroarch_settings`): 187 statements, 73 branch points.
  - after (the document model, 21 definitions from `Blank` through
    `set_retroarch_settings`, `_delete_key` included): 204 statements,
    78 branch points. An earlier record here said 201/79, measured
    before a review-suggested helper extraction landed; this is the
    re-run at the commit that carries the record.
  The raw counts grew: the five node dataclasses and their field
  declarations are 5 of the 20 definitions and carry no logic, and
  the classifier states the whole grammar in one place where the old
  layer inherited most of it from the library. What the change buys
  is stated in the proposal - the refusal boundary no longer depends
  on a library's internals - not a smaller number here.

## 5. Evidence

- [x] 5.1 Run the full suite and `just check-all`, and verify both
  exit clean. 347 tests passed; check-all (fmt-check, flake check,
  eval, workflow lint) exit 0.
- [x] 5.2 Build the derivation's check phase for x86_64-linux on the
  remote builder, and verify it passes.
- [ ] 5.3 Verify `just kiosk-test` passes in CI once the branch is
  pushed; this box closes only against a CI run that exists.
