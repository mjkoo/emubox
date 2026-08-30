## Why

The frontend and the preferred PS1 emulator the design names are not in the pinned nixpkgs: `freeimage` and with it `emulationstation-de` were removed in nixpkgs PR #454867 (2025-10-23) over unpatched CVEs, and `duckstation` was removed at the author's request after its licence changed to CC-BY-NC-ND 4.0. The locked `nixos-26.05` (2026-08-27) throws "removed" for all three, `pkgs/default.nix` is an empty attrset, and both `modules/kiosk` and `modules/emulators` carry a TODO waiting on these packages. E3 (kiosk session) cannot launch a frontend that does not exist, so this is the next change after the base layer, and the source builds against a nixpkgs several library generations newer than the removed derivations are the project's largest remaining technical risk, best retired early.

## What Changes

- Three packages appear under `pkgs/`, exposed through the existing overlay and as `packages.x86_64-linux` outputs, so `nix build .#packages.x86_64-linux.{es-de,freeimage,duckstation}` succeeds from the Mac through its Linux builder and CI's host build compiles them:
  - `freeimage`: the pre-removal nixpkgs derivation (`3.18.0-unstable-2024-04-18`, revision `8451347`) unchanged apart from a provenance header, including its unbundling diff, its eight CVE patches and its `knownVulnerabilities` list of about thirty unpatched CVEs. The flake names it in `permittedInsecurePackages` with the risk acknowledged in place: FreeImage only ever decodes images the admin put on the box (scraped art, theme assets), no untrusted input reaches it, and CI rebuilds it on every push so a breaking library bump surfaces before the box.
  - `es-de`: ES-DE built from source at 3.4.1 (2026-04-10, the latest tag), the nixpkgs derivation bumped from 3.2.0, with the in-app updater compiled out. nixpkgs' patch that added the NixOS RetroArch core path to `es_find_rules.xml` is dropped because upstream's file carries that path; the build asserts that the installed file still does, so the claim is re-checked on every bump.
  - `duckstation`: a wrap of the upstream `DuckStation-x64.AppImage` at release `v0.1-11752`, not a source build, because the repository and the cache are public and DuckStation's CC-BY-NC-ND licence forbids publishing a modified build (design D1 carries the reasoning). Bumping it is a version and hash edit.
- `es-de` joins the kiosk module's packages and `duckstation` the emulators module's, resolving both TODOs; the host closure carries both, and the `cache-roots` push made in the base layer now uploads three real store paths. No CI workflow change.
- The VM test asserts both programs are installed in the booted system and that ES-DE reports its version.
- The README gains a short section on the vendored packages: why they exist, the FreeImage acknowledgment and the DuckStation licence posture.
- No behaviour is removed. ES-DE's configuration, the session under cage, `es_systems.xml` overrides and every emulator setting stay with E3 and E4; rendering under cage on the TV and the AppImage's window under Wayland are E12 bring-up lines.

## Capabilities

### New Capabilities
- `packages`: the packages this project builds itself because nixpkgs no longer carries them: which they are, their versions and provenance, how each is obtained (source or upstream binary), the insecure-package acknowledgment, the licence constraint on what may be published to the public cache, and their presence in the host closure.

### Modified Capabilities
- `vm-test`: a new requirement that the booted test node has the vendored programs installed and that ES-DE reports its version; no existing requirement changes.

## Impact

- `pkgs/default.nix` (three `callPackage`s), `pkgs/freeimage/` (new: `package.nix`, `unbundle.diff`, `libtiff-4.4.0.diff`, eight `CVE-*.patch`), `pkgs/es-de/package.nix` (new), `pkgs/duckstation/package.nix` (new), `overlays/default.nix` (unchanged in content), `flake.nix` (the insecure-package permission; `packages` restricted to `x86_64-linux`; design D3), `modules/kiosk` and `modules/emulators` (one package each), `tests/default.nix` (one subtest group), `README.md`. `.github/workflows/ci.yml` is untouched: the vendored paths are in the host closure CI already builds before the push step.
- No new flake inputs. First cold CI run compiles ES-DE and freeimage and unpacks the AppImage once; every run after that substitutes from the `emubox` Cachix cache.
- `ACCT`: none new. The Cachix cache and its token exist since the base layer.
- Depends on E0 only; independent of E1 in content but lands after it. E3 (kiosk session) and E4 (emulators) depend on this change.
