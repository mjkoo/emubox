## 1. The dependency and the shared load/dump helpers

- [ ] 1.1 Add `configupdater` to the `python3.withPackages` closure in `pkgs/emubox-prepare/package.nix`, beside `cryptography`; `nix build .#checks.aarch64-darwin.emubox-prepare` builds and its 186 existing tests still pass.
- [ ] 1.2 Add the load helper (text to document, wrapping in the synthetic section header, `strict=False`, `optionxform = str`) and the dump helper (document to text, stripping that header). Tests prove a file already beginning with a section header round-trips byte-identically with no residual blank line, and that a file whose first assignment sits above every header round-trips byte-identically too.
- [ ] 1.3 Add tests pinning the three library behaviours design decisions 3, 4 and 5 name: a written key keeps its declared case, a file carrying both `Username` and `username` keeps them as two distinct keys, and deleting a key repeated twice in one section requires iterating to absence. Each fails against a helper built with the library's defaults.
- [ ] 1.4 Add a test asserting no file this program writes ever contains the synthetic header sentinel, parameterised over every format and every writing branch (fresh, edited, recreated, all-removals).

## 2. The sectioned-INI editor

- [ ] 2.1 Move `set_ini_settings` onto the load/dump helpers, keeping its signature, its `REMOVE` handling, the `_holds_something` guard, the "no owned keys means leave the file alone" rule and every journal note. Every existing INI test passes unedited; any test whose meaning changes is reported rather than amended.
- [ ] 2.2 Assign a value only when the parsed value differs from the flake's, so that a Qt-style `Key=value` file is not renormalised to `Key = value` on a launch that changes nothing. A test writes a spaceless file, runs the editor twice with the value it already holds, and asserts the file is byte-identical and unwritten (`freeze`/`unwritten`).
- [ ] 2.3 Reduce a repeated owned key to one assignment across every instance of its section and the headerless region, via `iter_sections()`. The four duplicate-write tests added with the preceding fix pass unedited, including the one covering a stray assignment above every section header.
- [ ] 2.4 Keep a key of the same name under a section the flake does not own untouched, and keep every assignment of an unowned key. `test_ini_write_leaves_no_stale_twin_in_a_duplicated_section` and `test_ini_removal_still_reports_no_write_when_only_other_sections_match` pass unedited.
- [ ] 2.5 Keep the recreate path exactly as wide as it is: a line that is not an assignment still triggers recreation, and a file that is merely awkward (duplicate section header, headerless preamble) still does not. A test asserts both directions.

## 3. The RetroArch editor

- [ ] 3.1 Move `set_retroarch_settings` onto the same helpers, reading its headerless file through the synthetic header and rendering values in RetroArch's `key = "value"` form. Every existing RetroArch test passes unedited.
- [ ] 3.2 Reduce a repeated owned key to one assignment in the flat file; `test_retroarch_write_leaves_no_stale_twin` and `test_retroarch_removal_sweeps_every_occurrence` pass unedited.
- [ ] 3.3 Assign only on a genuine value difference, matching task 2.2, proven by the same freeze/unwritten shape against a RetroArch fixture.

## 4. Removing what the library replaced

- [ ] 4.1 Delete `_parse_ini`, `_render_ini`, `_ini_section_bounds`, `_ini_insert_point`, `_parse_retroarch`, `_render_retroarch`, `_lines`, `_split_ini_assignment`, `_sweep_key`, `_ini_key_index` and `_matching_space`, along with any test that only exercised a deleted helper directly rather than behaviour reachable through an editor.
- [ ] 4.2 Prove nothing is left stranded: an AST pass over `emubox_prepare.py` reports no function that is unreferenced inside the module, the same check the audit used to establish there were none.
- [ ] 4.3 Record the resulting module size in the change's own history, and confirm the deletion actually landed the ~159 lines the proposal claims, so a later reader can see whether the trade paid.

## 5. Evidence

- [ ] 5.1 Leave `nix build .#checks.aarch64-darwin.emubox-prepare` green, with the test count at or above 186 plus the tasks above, and `ruff check`, `ruff format --check` and `ty check` clean under the S/ARG/RUF100 ruleset.
- [ ] 5.2 Leave `just check-all` and `nix fmt -- --ci` passing, and `just kiosk-test` passing in CI, which is the only place the editors run against a real ES-DE and real emulator configuration.
- [ ] 5.3 Update the module docstring's account of how the flat-file editors work, so the file's own explanation matches what it does; confirm no committed document cites `.scratch/`.
