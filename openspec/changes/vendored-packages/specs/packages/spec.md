## Purpose

The programs this project builds or wraps itself because the pinned nixpkgs no longer carries them: the ES-DE frontend, its FreeImage dependency and the DuckStation emulator. The capability fixes what each is, where it comes from, what security and licence posture it carries, and that the box and the public binary cache receive them.

## ADDED Requirements

### Requirement: The removed packages are provided by the flake
The flake SHALL provide `es-de`, `freeimage` and `duckstation` as packages of its own, built against the flake's single pinned nixpkgs rather than a second, older nixpkgs, and SHALL expose each both to the host configuration and as a standalone `x86_64-linux` package output.

#### Scenario: Standalone builds
- **WHEN** `nix build .#es-de`, `nix build .#freeimage` and `nix build .#duckstation` run on an `x86_64-linux` builder
- **THEN** each succeeds and produces the program or library named

#### Scenario: Present in the host closure
- **WHEN** the host configuration is built
- **THEN** its closure contains `es-de` and `duckstation`, and both are on the system's program path

#### Scenario: Evaluation on macOS
- **WHEN** `nix flake check` runs on the admin's macOS machine
- **THEN** the Linux-only packages do not fail evaluation there; they are offered only for `x86_64-linux`

### Requirement: ES-DE is built from source at a pinned release
ES-DE SHALL be built from the upstream source archive of release 3.4.1 with the in-app application updater compiled out, so that the box's frontend only ever changes through the flake.

#### Scenario: Version and updater
- **WHEN** the built `es-de` is asked for its version
- **THEN** it reports 3.4.1, and the build carries no application-updater code path

#### Scenario: RetroArch cores are discoverable without a local patch
- **WHEN** ES-DE is built
- **THEN** the installed emulator find-rules file contains the NixOS RetroArch core directory `/run/current-system/sw/lib/retroarch/cores`, and a build in which that path is absent from the installed file fails rather than producing a frontend that cannot find its cores

### Requirement: FreeImage is vendored with its vulnerability record intact
FreeImage SHALL be the last derivation nixpkgs carried before removal, with its unbundling of system libraries, its CVE patches and its `knownVulnerabilities` list preserved unchanged, and the flake SHALL permit it explicitly by name with the accepted risk recorded next to that permission.

#### Scenario: Insecure package is permitted deliberately
- **WHEN** the host configuration or the standalone package is evaluated
- **THEN** FreeImage builds only because the flake's nixpkgs configuration lists that exact package name as permitted, and the reason (only admin-supplied images are decoded; CI rebuilds it on every push) is recorded where the permission is granted

#### Scenario: Provenance is recorded
- **WHEN** a reader opens the vendored FreeImage or ES-DE package
- **THEN** it names the nixpkgs revision it was taken from and the removal it works around

### Requirement: DuckStation is the unmodified upstream binary
DuckStation SHALL be provided by wrapping the upstream `x86_64` AppImage of a pinned release, unmodified, with the upstream licence (CC-BY-NC-ND 4.0) and attribution recorded, and SHALL NOT be built from patched source.

#### Scenario: Pinned release
- **WHEN** `duckstation` is built
- **THEN** it is the upstream AppImage of release `v0.1-11752`, verified by hash, and the program runs as `duckstation`

#### Scenario: Bumping is mechanical
- **WHEN** the admin moves DuckStation to a newer upstream release
- **THEN** only the release identifier and the archive hash change in the package

### Requirement: Nothing licence-restricted from redistribution reaches the public cache
The set of store paths the project publishes to its public binary cache SHALL contain no package whose licence forbids the redistribution of the form being published; a modified build of a no-derivatives work MUST NOT be pushed.

#### Scenario: DuckStation on the cache
- **WHEN** the cache roots are pushed
- **THEN** the DuckStation store path pushed is the wrap of the unmodified upstream binary, which the licence permits to redistribute non-commercially with attribution

#### Scenario: ES-DE and FreeImage on the cache
- **WHEN** the cache roots are pushed
- **THEN** ES-DE (MIT) and FreeImage (GPL, as the vendored derivation records it) are pushed with the rest
