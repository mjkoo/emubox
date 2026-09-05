# Tasks

## 1. Seed tier in emubox-prepare

- [x] 1.1 Add failing unit tests for the seed contract, per format
      (ES-DE XML, ini, RetroArch flat): a seeded key absent from the
      file is written with the flake's default; a seeded key present
      with a different value is left alone and the file is not written;
      a seeded key present with an empty value is left alone; a seeded
      key repeated keeps every assignment even while an enforced key in
      the same file is corrected; recreation of an unreadable file
      writes seeded keys alongside enforced ones; a seeded name that
      does not read back as itself is dropped with a note through the
      same validation as enforced names. Add failing tests for the three
      rejections, each asserting a non-zero exit status, a diagnostic
      naming the file and the key, that no configuration file was
      written, that the mock login endpoint was never contacted, and
      that the token cache and PPSSPP's whole-file token are untouched
      (absent if absent before, byte-identical if present before): a
      rendered document naming one key under both `enforce` and `seed`
      of one file (one case per format: flat key name, sectioned
      section-and-key), run with RetroAchievements enabled so the test
      proves the refusal precedes the login; a RetroAchievements target
      key that the rendered document lists under its file's `seed`,
      refused by the target validation before the RetroAchievements
      login is attempted and while RetroAchievements is enabled; and,
      because a RetroAchievements
      merge with RetroAchievements disabled produces a `REMOVE`, that
      same seeded-target document with the feature switched off, so a
      `REMOVE` on a seeded key is refused before any editor runs. Add
      failing tests for the contract cutover and the per-file shape,
      each asserting a non-zero exit status, a diagnostic naming the
      file and the offending field (or, for the malformed entry, the
      file and the key), no configuration file written, no credential
      file written and the mock login endpoint never contacted: a
      rendered document whose per-file table carries the old single
      `keys` map instead of `enforce` and `seed`; a table missing
      `enforce`; a table missing `seed`; a table carrying both required
      maps and an unexpected extra field (for example `seedKeys`); and
      a table whose `seed` map holds a malformed entry for its format
      (an ini section that is not an object, or an ES-DE entry whose
      type or value is not a string). Verified by the new tests failing
      against the current editors for the reasons the contract states
      (missing seed support, missing validation, `keys` still accepted,
      extra fields and a malformed seed map not refused), recorded in
      the test run output.
- [x] 1.2 Teach prepare the two-map contract as a hard cutover: a
      per-file table carries exactly `format`, `enforce` and `seed`,
      both maps present, `{}` allowed, no alias for the old spelling.
      The per-file shape check of the rendered document refuses a table
      carrying `keys`, lacking either map, or carrying any field other
      than those three, as a broken call site (exit non-zero, diagnostic
      naming the file and the missing, obsolete or unexpected field, no
      RetroAchievements login attempted, no file written), and runs the
      per-format inner shape check that today covers the single map over
      both `enforce` and `seed` of every file, so a malformed seeded
      entry is a diagnostic naming the file and the key rather than a
      traceback. Add the seed
      branch to all three editors: append when no assignment exists
      among the places that belong to the key, otherwise do nothing;
      exclude seeded keys from duplicate sweeping. Add the validations:
      in `main`, immediately after the per-file shape check of the
      rendered document and before the RetroAchievements step, a static
      check that a file naming one key under both maps is a broken call
      site (exit non-zero, diagnostic naming file and key, no
      RetroAchievements login attempted, no file written, credential
      files included); in the target validation that already checks a
      RetroAchievements target key's file and format, a target key whose
      file lists it under `seed` is rejected the same way, before the
      RetroAchievements login is attempted. A re-check of the merged
      maps after the RetroAchievements merge and before any editor runs
      may stay as a defensive assertion but is not where either
      rejection lives. Keep an editor-level refusal of `REMOVE` on a
      seeded key as a defensive check. Migrate the unit suite to the
      contract: every rendered owned-values fixture and every editor
      call in the suite is re-rendered to the two-map contract (the
      former `keys` map becomes `enforce`, `seed` is added as `{}` where
      a test seeds nothing, and an editor call passes both maps), with
      the behaviour each existing test asserts left exactly as it is.
      Verified by every test from 1.1 passing and the existing suite,
      re-rendered to the two-map contract, passing with no behavioural
      edits, via the package's pytest run and `ruff`/`ty` clean.

## 2. Module schema and declarations

- [x] 2.1 Rename `keys` to `enforce` and add `seed` in the file-entry
      submodule, update the JSON contract rendering to carry both maps,
      add a module assertion that no file declares a key (a key name in
      a flat file, a section and key in a sectioned one) under both
      maps and that no RetroAchievements target key is listed under its
      file's `seed` map (every target's file, section and key from the
      retroachievements namespace's targets checked against that file's
      `seed`: the flat key for the RetroArch file, the section and key
      for an ini file; evaluation fails naming the target, the file and
      the key, with prepare's pre-login target validation staying as the
      runtime backstop), and re-tier the declarations: ES-DE `Theme` and
      `ApplicationLanguage`, RetroArch `menu_driver`,
      `input_menu_toggle`, `input_save_state`, `input_load_state`,
      `input_toggle_fast_forward` and `input_screenshot`, Dolphin
      `Core.CPUThread`, PCSX2 `EmuCore/GS.upscale_multiplier`,
      DuckStation `GPU.PGXPEnable` and `GPU.ResolutionScale` move to
      `seed`; every other declaration stays under `enforce` unchanged.
      Repoint the module-side readers of the `keys` map:
      `raDisabledFiles` in `modules/emulators/default.nix` writes
      `cheevos_enable` and `cheevos_hardcore_mode_enable` into
      `enforce`, `tests/retroachievements-disabled.nix` reads `enforce`,
      and `tests/saves.nix` reads `enforce` where it read `keys` in its
      three accesses (`savefile_directory` and `savestate_directory` on
      the RetroArch file, `scummvm.savepath` on the ScummVM file), with
      its route table, expected values and every other assertion
      unchanged. This task lands after 1.2 in the same branch: prepare
      refuses the rendered document on either side of the cutover alone
      (today's shape check demands `keys`; the new one refuses it), so
      renaming the module's rendered document is not behaviour-neutral
      by itself. Add a durable negative test for the assertion: a new
      `tests/*.nix` entry in `flake.nix`'s `perSystem` set (eval-only,
      like `tests/saves.nix`, which it follows: build a candidate with
      `host.extendModules { modules = [ ... ]; }` and assert
      `!(builtins.tryEval candidate.config.system.build.toplevel.drvPath).success`)
      that extends the host with three overlapping declarations, one
      candidate each - a flat-file key listed under both `enforce` and
      `seed` of the RetroArch file, a sectioned section-and-key listed
      under both maps of an ini file, and a RetroAchievements target key
      listed under its file's `seed` - and asserts that each candidate
      fails to evaluate. Module assertions fire only when
      `system.build.toplevel` is evaluated, so the check must force that
      attribute and not a shallower one; the target-key assertion must
      short-circuit on a null RetroAchievements namespace so the check
      still evaluates on a host with the feature off. Verified by
      `just check-all` passing, which evaluates the new check on every
      system; a Nix eval of the rendered contract showing exactly those
      twelve key names under `seed`, each in its file, and none of them
      under `enforce`; and the new check failing when the module
      assertion is temporarily commented out (recorded once, so the
      check is known to detect the assertion's absence).
- [x] 2.2 Update the kiosk VM test's owned-key subtests in
      `tests/kiosk.nix` for the two-map contract: split the ES-DE
      literal pin into an `enforce` literal (`UIMode`, `UIMode_passkey`,
      `ROMDirectory`, `MediaDirectory`, `ShowQuitMenu`) and a `seed`
      literal (`Theme`, `ApplicationLanguage`); split
      `PINNED_OWNED_KEYS` per tier, dropping the eight RetroArch keys
      task 3.1 moves to the append file (the flake check in 3.2 owns
      them, and the presence-only `UNPINNED_VALUE` sentinel that
      existed for `libretro_directory` goes with them) and keeping
      `savefile_directory` and `savestate_directory` under `enforce`;
      make both walks iterate `enforce` and `seed`, asserting enforced
      keys on disk by value and seeded keys by presence only. Verified
      by `just check-all` passing (the script is evaluated there; the
      run is CI-gated, group 5).

## 3. RetroArch launch-time delivery

- [x] 3.1 Move the RetroArch package call from
      `pkgs.retroarch.withCores` to
      `pkgs.wrapRetroArch { cores; settings; }` with the eight static
      enforced settings as the settings attrset: `video_fullscreen`,
      `libretro_directory` as the literal
      `/run/current-system/sw/lib/retroarch/cores`, `system_directory`,
      `autosave_interval`, `menu_show_online_updater`,
      `menu_show_core_updater`, `input_menu_toggle_gamepad_combo` and
      `input_quit_gamepad_combo` (every value a string, as the wrapper
      interpolates them). Drop exactly those eight keys from the
      RetroArch file's `enforce` map, leaving `savefile_directory`,
      `savestate_directory`, the seeds, the credentials and the two
      RetroAchievements policy switches in the parse path. Verified by
      `just check-all` passing (which includes `tests/saves.nix` still
      finding both save directories under the RetroArch file's
      `enforce`) and the RetroArch entry in the rendered contract
      carrying none of the eight keys.
- [x] 3.2 Add a flake check as an entry of `flake.nix`'s `hostOnly` set,
      built with `hostPkgs` for x86_64-linux only beside the `kiosk` and
      `session` checks (not `perSystem`: RetroArch is marked broken on
      Darwin, so a per-system placement would fail `nix flake check`
      and `just check-all` on the admin's Mac; `just check-all` on the
      Mac evaluates the new check only as it evaluates `hostOnly`
      entries today). The check selects the RetroArch package from the
      host configuration's `environment.systemPackages` by the same
      `p ? cores` filter the flake's `cache-roots` derivation uses,
      asserts exactly one such package, and inspects that derivation's
      `bin/retroarch`; it never calls `pkgs.wrapRetroArch` itself, since
      a package built inside the check would prove a second package
      agrees with itself. From that binary it recovers the append file's
      path by the distinct-path rule: split the binary on NUL and
      newline, extract every `--appendconfig=/nix/store/...` occurrence
      with a terminator that excludes whitespace and quotes (for example
      `tr '\0' '\n' < bin/retroarch | grep -a -o -- '--appendconfig=/nix/store/[^[:space:]'"'"'"]*' | sort -u`),
      and assert exactly one distinct path. A raw occurrence count is
      at least two on a correctly built wrapper, because the
      `makeBinaryWrapper` docstring repeats the flag beside the argv
      literal; repeats of one path are expected and two different paths
      are the failure. The check reads the file at that path - the path
      is taken from the wrapper's flag, never by re-rendering the
      settings, since a re-rendered copy would prove the settings render
      and not that the wrapper passes that file. The check asserts that
      the file carries all eight static enforced settings with the
      flake's values pinned literally (`libretro_directory` as
      `/run/current-system/sw/lib/retroarch/cores`, `video_fullscreen`
      as `true`, `system_directory` as `/data/bios`,
      `autosave_interval` as `30`, both updater entries as `false`, the
      two combos as their distinct enum values), that it carries the
      wrapper's three default keys by name (`assets_directory`,
      `joypad_autoconfig_dir`, `libretro_info_path`), that it carries no
      credential, that it carries none of the six seeded RetroArch keys
      (`menu_driver`, `input_menu_toggle`, `input_save_state`,
      `input_load_state`, `input_toggle_fast_forward`,
      `input_screenshot`), that it carries neither save-directory key
      (`savefile_directory`, `savestate_directory`), each absence
      mirroring the no-credential assertion, and that the selected
      package exposes a non-empty `passthru.cores` equal to a literal
      list of core names hand-typed in the check (the independent-literal
      rule `tests/kiosk.nix` applies to `PINNED_OWNED_KEYS`), never a
      list obtained from the module - the guards against the failure
      mode that exists today, a file carrying the wrapper's defaults and
      none of the flake's settings, against a seeded or save-directory
      key accidentally delivered ahead of `retroarch.cfg`, and against a
      wrapper that silently drops the passthru `cache-roots` filters on.
      The eight-key assertion is the regression baseline: a non-empty
      check cannot fail against the `withCores` wrapper, whose file
      already carries the three defaults. Verified by the eight-key
      assertion failing when the check is run against the pre-change
      `withCores` wrapper (recorded once as the regression baseline) and
      the whole check passing on the new one, under `nix flake check` on
      the x86_64-linux builder.

## 4. Kiosk VM test

- [x] 4.1 Add the seeded-survival assertion to the kiosk VM test, with
      the frontend stopped: after the crash-loop subtest, when the
      session is at the greeter and no `es-de` process exists, and
      before the `machine.shutdown()` of the reboot subtest, change
      `ApplicationLanguage` in `/data/es-de/settings/es_settings.xml`
      from `en_US` to a locale ES-DE bundles (for example `en_GB`; the
      implementer verifies the locale against the pinned ES-DE's bundled
      list, since a value the frontend does not accept is replaced on
      start), writing the edit as `player` or restoring the file's
      ownership afterwards. After the reboot, once the frontend is up
      (the existing `pgrep -x es-de` wait), assert the file carries the
      changed value. Verified by the assertion being present in the
      test script the flake evaluates (`just check-all` passes; the run
      itself is CI-gated, group 5).
- [x] 4.2 Prove the append file at runtime in the kiosk VM test. Change
      the headless RetroArch launches to pass the flake's append file
      and the test override in one `--appendconfig` flag joined by `|`,
      since a second flag replaces the first. The test recovers the
      flake's store path on the node from
      `/run/current-system/sw/bin/retroarch` (or the store path
      `environment.systemPackages` resolves) before composing the joined
      flag, by the same distinct-path rule as the flake check: split
      the binary on NUL and newline, extract every
      `--appendconfig=/nix/store/...` occurrence with a terminator that
      excludes whitespace and quotes, take the distinct paths and assert
      exactly one (a raw match count is at least two, since the wrapper's
      docstring repeats the flag). Use `grep -a -o`, which is on the
      node; `strings` is binutils and is not asserted present there. The
      test never re-renders the settings to derive the path, so the
      override joins onto the file the node's wrapper actually passes.
      Before one headless launch, bake a stale value for one
      launch-delivered key into `retroarch.cfg` (for example
      `video_fullscreen = "false"`); the key must be one of the seven
      launch-delivered keys other than `libretro_directory`, which the
      wrapper's `-L` flag overrides at runtime so its write-back shows
      the wrapper's store path, not the append file's literal. Perform
      the bake as `player` (for example `su player -s /bin/sh -c` with a
      `printf >>` append or an in-place edit run as player) or restore
      `player` ownership afterwards, and assert the file is player-owned
      before the launch: the driver runs `machine.succeed` as root, and
      a root-owned `retroarch.cfg` makes RetroArch's exit write-back as
      `player` fail silently, so the assertion would fail for a reason
      unrelated to precedence and prepare's later enforced writes would
      fail for the rest of the run. After the launch exits assert that
      `retroarch.cfg` - which RetroArch rewrites from its effective
      settings on exit - carries the flake's value for the baked key; do
      not use the `[Config] Appending config` log line, which is not
      emitted on first load. Verified by the assertions being present
      in the test script the flake evaluates (`just check-all` passes;
      the run itself is CI-gated, group 5).

## 5. Evidence

- [x] 5.1 Record the full local gate at the final revision:
      `just check-all` exit 0 and the emubox-prepare check-phase
      derivation building on aarch64-darwin and x86_64-linux, with the
      commands and store paths recorded next to this box.

      Recorded at revision d5278c9, clean tree:

      - `just check-all` -> exit 0 (fmt-check, flake check, the five
        evals, actionlint, zizmor, install-guard test).
      - `nix build .#checks.aarch64-darwin.emubox-prepare` ->
        `/nix/store/vy5dh99kjciiw75ra229jv9pmrpgzwmi-emubox-prepare-0.1.0`
      - `nix build .#checks.x86_64-linux.emubox-prepare` ->
        `/nix/store/xbd4zs02d05dbfswrsnkyxk9c16ki1ik-emubox-prepare-0.1.0`

      The check phase of that derivation is what runs `ruff check`,
      `ruff format --check`, `ty check` and `pytest`, so building it on
      both systems is the unit gate on both.

      Two checks that need the x86_64-linux builder were also built green
      at this revision, neither needing KVM:

      - `nix build .#checks.x86_64-linux.retroarch-settings` -> exit 0,
        `retroarch append-config settings verified at
        /nix/store/vnrrm15vbgxb0hll3fy9yqxxfhxm8wy1-declarative-retroarch.cfg`
      - `nix build .#checks.aarch64-darwin.owned-key-tiers` -> exit 0.
- [x] 5.2 Record a green CI run including the kiosk VM test at the
      final revision, with the run URL recorded next to this box.
      Blocked on a push, which only the user may perform.

      https://github.com/mjkoo/emubox/actions/runs/33945898682 -
      conclusion success, at revision e44cb2a, the last revision of
      this branch that touches anything outside `openspec/`. An earlier
      run, https://github.com/mjkoo/emubox/actions/runs/33942814847 at
      576acdd, was green on the same code and is the run 5.1's builder
      evidence sits beside; the run between them, 33943406950 at
      b62dfec, failed on runner disk exhaustion (`/dev/root` at 100%)
      with nothing of this change's own reached.

      That run's `nix flake check -L` step covers the whole
      x86_64-linux check set on a runner with `/dev/kvm` opened, so it
      is the first execution of the kiosk VM test anywhere - no local
      builder exposes KVM. Its three relevant subtests all ran and
      passed:

      - "A seeded setting edited while the frontend is stopped survives
        the next boot"
      - "A reboot from the greeter restores the kiosk"
      - "Every BIOS-free core family with a licensed ROM runs headless",
        which carries the append-config precedence proof

      The same step also built `owned-key-tiers` and
      `retroarch-settings`, the latter reporting
      `retroarch append-config settings verified at
      /nix/store/vnrrm15vbgxb0hll3fy9yqxxfhxm8wy1-declarative-retroarch.cfg`.
