## Why

The kiosk boots to a frontend that can browse games but not faithfully run
them: the emulators are installed, yet nothing asserts their
configuration, so every launch depends on whatever defaults or hand-made
settings happen to sit in the player's home. Roadmap epics E4 and E7
close that gap together, because RetroAchievements writes into the same
five emulator config files the launch settings live in; settling each
file once avoids a second change that reopens all of them.

## What Changes

- The config editor's owned-values tables grow to cover RetroArch
  (`retroarch.cfg`: core and BIOS directories, autosave interval,
  fullscreen, menu driver, online-updater menus off, the uniform hotkey
  set) and the six standalone emulators (Dolphin, PCSX2, PPSSPP, Azahar,
  DuckStation, ScummVM), each asserted before every frontend launch.
- The frontend's custom systems definition gets its first payload:
  system entries whose chosen emulator differs from the frontend's
  default, PS1 on DuckStation with Beetle PSX HW as the alternate first
  among them.
- A BIOS layout under `/data/bios` and a report-only `emubox-check-bios`
  tool that compares it against a declared name and checksum list.
- RetroAchievements: the config editor logs in through the RA API,
  caches the token on the box as the offline fallback, and writes it
  into every supporting
  emulator's config - including DuckStation, whose token-at-rest
  encryption the editor reproduces so no manual login exists anywhere. Hardcore mode is
  one host option, off by default. Credentials come from the declared
  secrets store; a missing or unreachable RA endpoint never blocks the
  session.
- The VM test grows an assertion group: headless RetroArch runs a freely
  redistributable homebrew ROM per BIOS-free core family, each
  standalone gets a smoke launch, and a mocked RA endpoint proves every
  config carries the token and follows the hardcore option.

## Capabilities

### New Capabilities

- `emulators`: which emulator serves each system, the launch
  configuration the flake owns per emulator, the frontend's per-system
  overrides, and the BIOS directory layout with its checking tool.
- `retroachievements`: the single shared login, how the token reaches
  every supporting emulator (DuckStation's encrypted form included), the
  hardcore switch, and the offline behavior.

### Modified Capabilities

- `kiosk`: the custom-systems requirement stops claiming the shipped
  box has an empty definition, since `modules/emulators` now
  contributes entries; the mechanism itself is unchanged.
- `vm-test`: a new requirement that the VM proves emulator launches
  (headless RetroArch per BIOS-free core family, standalone smoke
  launches) and, against a mocked RA endpoint, the token in every
  supporting config and the hardcore option's effect.

## Impact

- `modules/emulators/`: gains the owned-values tables, the custom
  systems entries, the BIOS list and `emubox-check-bios`, and the
  RetroAchievements options (`emubox.retroachievements.enable`,
  `emubox.retroachievements.hardcore`).
- `pkgs/emubox-prepare/`: new RA login step (network call with timeout
  and on-disk token cache), the DuckStation token transform, and
  whatever table entries the new formats need; `python3Packages.cryptography`
  joins its dependencies.
- `modules/secrets/` and the host secrets file: RA username and password
  declared; no change to how secrets are provisioned.
- `tests/`: the kiosk VM test (or a sibling node) gains the emulator and
  RA assertion group with fetched homebrew fixtures and a mock RA
  endpoint.
- The DuckStation bump runbook in `pkgs/duckstation` gains "re-verify
  the token encoding against the new tag".
