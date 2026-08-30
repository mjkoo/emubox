## 1. Flake wiring (red first: the three attributes must exist before anything builds)

- [ ] 1.1 In `flake.nix`, extend `nixpkgsConfig` with `permittedInsecurePackages = [ "freeimage-3.18.0-unstable-2024-04-18" ]` and the risk comment from design D3 (only admin-supplied images are decoded; CI rebuilds on every push; ES-DE's AppImage is the fallback)
- [ ] 1.2 In `flake.nix`, define `hostPkgs = import nixpkgs { system = hostSystem; config = nixpkgsConfig; overlays = [ self.overlays.default ]; }` and replace the `forAllSystems` `packages` with `packages.${hostSystem} = import ./pkgs { pkgs = hostPkgs; } // { cache-roots = ...; }` per design D3; `devShells` and `formatter` stay `forAllSystems`; confirm `nix flake check` on the Mac still evaluates (`just check-all`)
- [ ] 1.3 Rewrite `pkgs/default.nix` as the three `callPackage`s (design D2) with the TODO comment removed; `overlays/default.nix` is unchanged

## 2. FreeImage

- [ ] 2.1 Copy `package.nix`, `unbundle.diff`, `libtiff-4.4.0.diff` and the eight `CVE-*.patch` files from nixpkgs revision `8451347` `pkgs/by-name/fr/freeimage/` into `pkgs/freeimage/` unchanged (fetch each from `https://raw.githubusercontent.com/NixOS/nixpkgs/8451347/pkgs/by-name/fr/freeimage/<file>`; `patchFlags = [ "-p1" "--binary" ]` means the diffs carry CRLF and must be copied byte-exact, not through an editor), then add the provenance header (revision, removal PR #454867, why it is kept) to `package.nix`
- [ ] 2.2 `nix build .#freeimage` on the Linux builder succeeds; `nix build .#freeimage` with the permission removed from 1.1 refuses with the `knownVulnerabilities` message (proves the permission is what admits it), then restore 1.1

## 3. ES-DE

- [ ] 3.1 Create `pkgs/es-de/package.nix` from the `8451347` `emulationstation-de` derivation per design D2: `pname = "es-de"`, `version = "3.4.1"`, `patches` removed, `postPatch` for `FindPoppler.cmake` kept, `APPLICATION_UPDATER` off, provenance header; obtain the `fetchzip` hash with a first build (`lib.fakeHash`) and record it
- [ ] 3.2 Add the find-rules guard in `postInstall`: locate the installed `es_find_rules.xml` under `$out/share/es-de/resources/systems/linux/` (confirm the path from the 3.4.1 install step; design D2), grep for `/run/current-system/sw/lib/retroarch/cores`, fail the build if absent; prove the guard by temporarily grepping for a string that is not there and watching the build fail, then restore
- [ ] 3.3 Add `versionCheckHook` (`nativeInstallCheckInputs`, `versionCheckProgramArg = "--version"`, `doInstallCheck = true`); `nix build .#es-de` succeeds on the Linux builder and `result/bin/es-de --version` prints `ES-DE 3.4.1`. A compile or link failure against `sdl2-compat`, ffmpeg 8 or poppler 26.06 is fixed forward with a `postPatch` or cmake flag recorded in the package's header; if that fails, stop and update these artifacts to the AppImage fallback (design Risks) before continuing

## 4. DuckStation

- [ ] 4.1 Create `pkgs/duckstation/package.nix` per design D1: `appimageTools.wrapType2` on `DuckStation-x64.AppImage` from release `v0.1-11752` (hash via `nix store prefetch-file` or a `lib.fakeHash` build), `extraInstallCommands` installing the `.desktop` file and icon from `appimageTools.extract`, `meta` with `license = lib.licenses.cc-by-nc-nd-40`, `mainProgram = "duckstation"`, `platforms = [ "x86_64-linux" ]`, `homepage`, and the licence-reasoning header
- [ ] 4.2 `nix build .#duckstation` succeeds on the Linux builder; `result/bin/duckstation` exists and `result/share/applications/` holds the desktop file; `nix-update --flake duckstation --version 0.1-11752` (or the equivalent dry run) shows the bump path works without touching anything else

## 5. Host closure, cache roots, VM test

- [ ] 5.1 `modules/kiosk`: add `pkgs.es-de` to `environment.systemPackages`, remove the `TODO(pkgs/es-de)` comment; `modules/emulators`: append `duckstation`, remove its TODO
- [ ] 5.2 `just build` (host toplevel on the Linux builder) succeeds and `nix build .#packages.x86_64-linux.cache-roots --print-out-paths` lists `es-de`, `freeimage` and `duckstation` among the roots; `nix build .#es-de --print-out-paths` equals the `es-de` path inside `cache-roots` (the standalone and host package sets agree; design D3), likewise for the other two
- [ ] 5.3 `tests/default.nix`: add the `packages` subtest group per design D4 (`test -x` on both programs under `/run/current-system/sw/bin`; `es-de --version` output contains `ES-DE 3.4.1`); `nix build .#checks.x86_64-linux.vm.driver` renders the script on the local builder
- [ ] 5.4 With the author's go-ahead, open the pull request from this branch so CI runs the VM test (KVM is CI-only); the first run compiles ES-DE and FreeImage cold; the new subtests are green and `just check-all` passes locally; record the run in this task

## 6. Docs

- [ ] 6.1 README "Vendored packages" subsection per design D5 (why each exists, FreeImage acknowledgment pointing at `flake.nix`, DuckStation licence posture and bump procedure)
