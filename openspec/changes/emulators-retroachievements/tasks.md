## 1. Prepare: owned-values JSON namespace (design D1)

- [x] 1.1 Restructure the owned-values JSON to `{"files": ..., "retroachievements": ...}` in `emubox_prepare.py`, keeping every existing editor and error-policy behaviour, with tests updated to the new shape
- [x] 1.2 Update the kiosk module's owned-values rendering to emit the new shape with `retroachievements: null`, and confirm the kiosk VM test still passes unchanged

## 2. Prepare: RetroAchievements login and tokens (design D2, D3)

- [x] 2.1 Implement token resolution in prepare: `login2` POST on every run with 5 s timeout against the JSON's API URL, cache refresh 0600 on success, cache fallback on network failure, invalid-credentials cache drop, and the skip-tokens-and-continue path, with unit tests using a fake HTTP handler for each branch
- [x] 2.2 Implement the RA-derived table merge: username, token, enabled and hardcore keys folded into the owned tables for RetroArch, Dolphin, PCSX2, PPSSPP; enabled-off tables when `retroachievements` is null (null means disabled, per design D1); tests per emulator target
- [x] 2.3 Implement the DuckStation token transform (machine-id raw bytes + username through SHA-256 and 100 rounds, AES-128-CBC via `cryptography`, zero padding, base64) plus `Username` and change-gated `LoginTimestamp`, with a round-trip test against an independent decrypt implementation and a fixed-vector test
- [x] 2.4 Add `cryptography` to the prepare package and confirm ruff, ty and pytest pass under `nix flake check` on macOS

## 3. Emulator owned tables and options (design D4)

- [x] 3.1 Verify at source and record the config file path and key spellings for RetroArch and each standalone (Dolphin, PCSX2 + `secrets.ini`, PPSSPP, Azahar, DuckStation, ScummVM), including that the DuckStation wrapper is not portable-mode
- [x] 3.2 Add the RetroArch owned table to `modules/emulators`: core directory, `system_directory=/data/bios`, `autosave_interval=30`, fullscreen, menu driver, online-updater entries off, and the uniform hotkey set settled per the design's open question
- [x] 3.3 Add the six standalone owned tables with the settled performance values (Dolphin Wii dual core off, PCSX2 native res, DuckStation PGXP + upscale, fullscreen everywhere)
- [x] 3.4 Add `emubox.retroachievements.enable` and `.hardcore` options, declare the RA username and password secrets, and wire the `retroachievements` JSON namespace from them

## 4. Frontend overrides and BIOS (design D5, D6)

- [x] 4.1 Diff ES-DE 3.4.1's bundled `es_systems.xml` against the system table, and contribute custom-systems entries for every divergence, PS1 with DuckStation primary and Beetle PSX HW alternate first
- [x] 4.2 Declare the BIOS inventory attrset and render it to JSON in the store
- [x] 4.3 Implement and package `emubox-check-bios` (report-only, exit status per spec) and add it to the system packages, with unit tests beside prepare's

## 5. VM test (design D7)

- [x] 5.1 Add the mock RA endpoint and test credentials to the kiosk VM test and assert every supporting config carries the mock token (DuckStation's via independent decrypt), no config carries the password, and both hardcore positions
- [x] 5.2 Pin one freely redistributable homebrew ROM per BIOS-free core family as fetched fixtures and assert headless RetroArch exit 0 plus a core log line per family
- [x] 5.3 Add the standalone smoke launches and the offline-no-cache boot assertion (frontend up, journal records the failed login)

## 6. Docs and runbook

- [x] 6.1 Add the token-scheme re-verification step to the DuckStation bump runbook comment in `pkgs/duckstation`
- [x] 6.2 Document `/data/bios` layout, `emubox-check-bios` usage and the RA secrets in the README's admin sections
