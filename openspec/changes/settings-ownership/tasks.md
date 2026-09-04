# Tasks

## 1. Seed tier in emubox-prepare

- [ ] 1.1 Add failing unit tests for the seed contract, per format
      (ES-DE XML, ini, RetroArch flat): a seeded key absent from the
      file is written with the flake's default; a seeded key present
      with a different value is left alone and the file is not written;
      a seeded key present with an empty value is left alone; a seeded
      key repeated keeps every assignment even while an enforced key in
      the same file is corrected; recreation of an unreadable file
      writes seeded keys alongside enforced ones; `REMOVE` on a seeded
      key is refused with a diagnostic rather than acted on; a seeded
      name that does not read back as itself is dropped with a note
      through the same validation as enforced names. Verified by the
      new tests failing against the current editors for the reasons the
      contract states (missing seed support), recorded in the test run
      output.
- [ ] 1.2 Teach prepare the two-map contract (`enforce` and `seed` per
      file) and add the seed branch to all three editors: append when no
      assignment exists among the places that belong to the key,
      otherwise do nothing; exclude seeded keys from duplicate sweeping;
      refuse `REMOVE` on a seeded key. Verified by every test from 1.1
      passing and the existing enforced-key suite passing unedited,
      via the package's pytest run and `ruff`/`ty` clean.

## 2. Module schema and declarations

- [ ] 2.1 Rename `keys` to `enforce` and add `seed` in the file-entry
      submodule, update the JSON contract rendering to carry both maps,
      and re-tier the declarations: ES-DE `Theme` and
      `ApplicationLanguage`, RetroArch `menu_driver` and the five
      keyboard hotkeys, Dolphin `Core.CPUThread`, PCSX2
      `EmuCore/GS.upscale_multiplier`, DuckStation `GPU.PGXPEnable` and
      `GPU.ResolutionScale` move to `seed`; every other declaration
      stays under `enforce` unchanged. Verified by `just check-all`
      passing and a Nix eval of the rendered contract showing exactly
      those eight keys under `seed` and no key in both maps.

## 3. RetroArch launch-time delivery

- [ ] 3.1 Move the RetroArch package call from
      `pkgs.retroarch.withCores` to
      `pkgs.wrapRetroArch { cores; settings; }` with the ten static
      enforced settings (`video_fullscreen`, `libretro_directory`,
      `system_directory`, `savefile_directory`, `savestate_directory`,
      `autosave_interval`, `menu_show_online_updater`,
      `menu_show_core_updater`, `input_menu_toggle_gamepad_combo`,
      `input_quit_gamepad_combo`) as the settings attrset, and drop
      exactly those ten keys from the RetroArch file's `enforce` map,
      leaving the seeds, credentials and the two RetroAchievements
      policy switches in the parse path. Verified by `just check-all`
      passing and the RetroArch entry in the rendered contract carrying
      none of the ten keys.
- [ ] 3.2 Add a flake check asserting the wrapped RetroArch package
      passes `--appendconfig`, that the referenced file is non-empty,
      and that it carries all ten static enforced settings with the
      flake's values - the guard against the empty-file failure mode
      that exists today. Verified by the check failing when run against
      the pre-change `withCores` wrapper (recorded once as the
      regression baseline) and passing on the new one, under
      `nix flake check` on the x86_64-linux builder.

## 4. Kiosk VM test

- [ ] 4.1 Add the seeded-survival assertion to the kiosk VM test: change
      a seeded frontend setting's entry in the settings file between
      boots, reboot the node, and assert the changed value is still in
      the settings file once the frontend is up again. Verified by the
      assertion being present in the test script the flake evaluates
      (`just check-all` passes; the run itself is CI-gated, group 5).

## 5. Evidence

- [ ] 5.1 Record the full local gate at the final revision:
      `just check-all` exit 0 and the emubox-prepare check-phase
      derivation building on aarch64-darwin and x86_64-linux, with the
      commands and store paths recorded next to this box.
- [ ] 5.2 Record a green CI run including the kiosk VM test at the
      final revision, with the run URL recorded next to this box.
      Blocked on a push, which only the user may perform.
