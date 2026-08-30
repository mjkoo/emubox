## 1. Flake wiring (red first: the three attributes must exist before anything builds)

- [x] 1.1 In `flake.nix`, extend `nixpkgsConfig` with `permittedInsecurePackages = [ "freeimage-3.18.0-unstable-2024-04-18" ]` and the risk comment from design D3 (only admin-supplied images are decoded; CI rebuilds on every push; ES-DE's AppImage is the fallback)
- [x] 1.2 In `flake.nix`, define `hostPkgs = self.nixosConfigurations.emubox.pkgs` (the set `cache-roots` already reads) and replace the `forAllSystems` `packages` with `packages.${hostSystem} = import ./pkgs { pkgs = hostPkgs; } // { cache-roots = ...; }` per design D3; `devShells` and `formatter` stay `forAllSystems`; confirm `nix flake check` on the Mac still evaluates (`just check-all`)
- [x] 1.3 Rewrite `pkgs/default.nix` as the three `callPackage`s (design D2) with the TODO comment removed; `overlays/default.nix` is unchanged

## 2. FreeImage

- [x] 2.1 Copy `package.nix`, `unbundle.diff`, `libtiff-4.4.0.diff` and the eight `CVE-*.patch` files from nixpkgs revision `7c7c704523` `pkgs/by-name/fr/freeimage/` into `pkgs/freeimage/` unchanged (fetch each from `https://raw.githubusercontent.com/NixOS/nixpkgs/7c7c704523/pkgs/by-name/fr/freeimage/<file>`; `patchFlags = [ "-p1" "--binary" ]` means the diffs carry CRLF and must be copied byte-exact, not through an editor), then add the provenance header (revision, removal PR #454867, why it is kept) to `package.nix`
- [x] 2.2 `nix build .#packages.x86_64-linux.freeimage` succeeds (the full attribute: `packages` exists only for `x86_64-linux` after 1.2, so the short `.#freeimage` form resolves only in a shell on the Linux builder itself); the same build with the permission removed from 1.1 refuses with the `knownVulnerabilities` message (proves the permission is what admits it), then restore 1.1

## 3. ES-DE

- [x] 3.1 Create `pkgs/es-de/package.nix` from the `7c7c704523` `emulationstation-de` derivation per design D2: `pname = "es-de"`, `version = "3.4.1"`, `patches` removed, `postPatch` for `FindPoppler.cmake` kept, `APPLICATION_UPDATER` off, provenance header; obtain the `fetchzip` hash with a first build (`lib.fakeHash`) and record it
- [x] 3.2 Add the find-rules guard in `postInstall`: grep the installed `$out/share/es-de/resources/systems/linux/es_find_rules.xml` (design D2) for `/run/current-system/sw/lib/retroarch/cores`, fail the build if absent; prove the guard by temporarily grepping for a string that is not there and watching the build fail, then restore
- [x] 3.3 Add `versionCheckHook` (`nativeInstallCheckInputs`, `versionCheckProgramArg = "--version"`, `doInstallCheck = true`); `nix build .#packages.x86_64-linux.es-de` succeeds and `result/bin/es-de --version` output contains `ES-DE 3.4.1`. A compile or link failure against `sdl2-compat`, ffmpeg 8 or poppler 26.06 is fixed forward with a `postPatch` or cmake flag recorded in the package's header; if that fails, stop and update these artifacts to the AppImage fallback (design Risks) before continuing

## 4. DuckStation

- [x] 4.1 Create `pkgs/duckstation/package.nix` per design D1: `appimageTools.wrapType2` on `DuckStation-x64.AppImage` from release `v0.1-11752` (hash via `nix store prefetch-file` or a `lib.fakeHash` build), `extraInstallCommands` installing the `.desktop` file (its `Exec=` line rewritten to `duckstation`) and icon from `appimageTools.extract`, `meta` with `license = lib.licenses.cc-by-nc-nd-40`, `mainProgram = "duckstation"`, `platforms = [ "x86_64-linux" ]`, `homepage`, and the licence-reasoning header
- [x] 4.2 `nix build .#packages.x86_64-linux.duckstation` succeeds; `result/bin/duckstation` exists and `result/share/applications/` holds the desktop file; prove the bump path (design D1) by setting `hash = lib.fakeHash`, rebuilding, and confirming the reported hash is the recorded one with nothing else in the file touched, then restore

## 5. Host closure, cache roots, VM test

- [x] 5.1 `modules/kiosk`: add `pkgs.es-de` to `environment.systemPackages`, remove the `TODO(pkgs/es-de)` comment; `modules/emulators`: append `duckstation`, remove its TODO
- [x] 5.2 `just build` (host toplevel on the Linux builder) succeeds and `nix build .#packages.x86_64-linux.cache-roots --print-out-paths` lists `es-de`, `freeimage` and `duckstation` among the roots; `nix build .#packages.x86_64-linux.es-de --print-out-paths` equals the `es-de` path inside `cache-roots` (one package set serves both; design D3), likewise for the other two
- [x] 5.3 `tests/default.nix`: add the `packages` subtest group per design D4 (`test -x` on both programs under `/run/current-system/sw/bin`; `es-de --version` output contains `ES-DE 3.4.1`); `nix build .#checks.x86_64-linux.vm.driver` renders the script on the local builder
- [ ] 5.4 With the author's go-ahead, open the pull request from this branch so CI runs the VM test (KVM is CI-only); the first run compiles ES-DE and FreeImage cold; the new subtests are green and `just check-all` passes locally; record the run in this task

## 6. Docs

- [ ] 6.1 README "Vendored packages" subsection per design D5 (why each exists, FreeImage acknowledgment pointing at `flake.nix`, DuckStation licence posture and bump procedure)
