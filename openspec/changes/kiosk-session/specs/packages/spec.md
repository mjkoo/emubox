## ADDED Requirements

### Requirement: The flake's own programs are package outputs too
A program this project writes rather than vendors SHALL be built by the flake like any other package it provides: exposed to the host configuration through the same overlay, exposed as a standalone `x86_64-linux` package output, and included among the store paths pushed to the public binary cache, so that no consumer rebuilds it and its licence posture is the project's own.

#### Scenario: Standalone build
- **WHEN** `nix build .#emubox-prepare` runs on an `x86_64-linux` builder
- **THEN** it succeeds and produces the config editor the kiosk session runs

#### Scenario: On the host's program path
- **WHEN** the box has booted and a program the project wrote is part of a running feature, as the config editor is of the kiosk session
- **THEN** it is an executable file on the system's program path, reachable by anyone with a shell on the box and not only from inside the script that uses it

#### Scenario: On the cache
- **WHEN** the cache roots are pushed
- **THEN** the config editor's store path is among them, and it carries the project's own declared licence, which permits redistributing what is pushed

## MODIFIED Requirements

### Requirement: Nothing licence-restricted from redistribution reaches the public cache
Every store path the project publishes to its public binary cache SHALL be one whose licence permits the redistribution of the form being published, whatever kind of package it is; a modified build of a no-derivatives work MUST NOT be pushed. Each path's licence posture SHALL be recorded where that path is defined, so that a package added to the published set without a settled posture is visible rather than silent.

#### Scenario: Unfree emulator cores on the cache
- **WHEN** the cache roots are pushed
- **THEN** every unfree core among them carries a licence permitting redistribution of the built form, because the selection that gathers them admits only cores whose licence metadata records that permission

#### Scenario: DuckStation on the cache
- **WHEN** the cache roots are pushed
- **THEN** the DuckStation store path pushed holds the upstream AppImage's contents extracted unmodified, plus the wrapper that runs them and a desktop entry the project wrote; the licence permits redistributing that unmodified work non-commercially with attribution, and extraction changes its form, not its content

#### Scenario: ES-DE and FreeImage on the cache
- **WHEN** the cache roots are pushed
- **THEN** ES-DE (MIT) and FreeImage (FreeImage Public License or GPL, as the vendored derivation records it) are pushed with the rest


### Requirement: ES-DE is built from source at a pinned release
ES-DE SHALL be built from the upstream source archive of release 3.4.1 with the in-app application updater compiled out, so that the box's frontend only ever changes through the flake, and SHALL carry a project patch that makes its quit menu available in kiosk mode with power off and reboot as the only entries, with the patch's provenance and the upstream behaviour it changes recorded in the package.

#### Scenario: Version report
- **WHEN** the built `es-de` is asked for its version
- **THEN** it reports 3.4.1

#### Scenario: RetroArch cores are discoverable without a local patch
- **WHEN** ES-DE is built
- **THEN** the installed emulator find-rules file contains the NixOS RetroArch core directory `/run/current-system/sw/lib/retroarch/cores`, and a build in which that path is absent from the installed file fails rather than producing a frontend that cannot find its cores

#### Scenario: Kiosk quit menu patch applies
- **WHEN** ES-DE is built
- **THEN** the kiosk quit-menu patch applies to the pinned source, and a bump to a source the patch no longer applies to fails the build rather than producing a frontend without the menu

#### Scenario: Patch provenance recorded
- **WHEN** a reader opens the vendored ES-DE package
- **THEN** it names the upstream commit whose behaviour the patch changes and what the patch does
