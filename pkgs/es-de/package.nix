# ES-DE, the frontend, built from source at a pinned release with the in-app
# updater compiled out so the box's frontend only ever changes through the
# flake. Derived from nixpkgs revision 7c7c704523
# (pkgs/by-name/em/emulationstation-de/package.nix, 3.2.0), the last
# revision carrying it: the parent of PR #454867 (2025-10-23), which
# removed it along with freeimage. Changes from that derivation: renamed
# to es-de, bumped to 3.4.1, the nixpkgs patch that added
# /run/current-system/sw/lib/retroarch/cores to es_find_rules.xml dropped
# because upstream's file carries that path (the postInstall guard below
# re-checks that claim on every bump), a version check added, the nixpkgs
# maintainer dropped, and the description shortened to nixpkgs' noun-phrase
# form. FreeImage resolves to the vendored pkgs/freeimage through the
# overlay; ES-DE has no other image backend.
#
# kiosk-quit-menu.patch is this project's own, not nixpkgs'. Since upstream
# commit defb16b6 (2020-12-17) GuiMenu.cpp adds the QUIT entry only when
# neither ForceKiosk nor UIMode == "kiosk" is in effect, so kiosk mode has no
# quit menu at all and the box would have no way to power off from the
# frontend. The patch adds the entry in every UI mode and, in openQuitMenu(),
# routes kiosk mode to the submenu and drops its "quit ES-DE" row (the
# session would only relaunch the frontend) and its "suspend" row (the box
# refuses to suspend), leaving reboot and power off with their confirmations.
# Being in `patches`, a bump to a source the hunks no longer apply to fails
# in the patch phase rather than producing a frontend without the menu.
# `--fuzz=0` alongside the default `-p1` makes that a tripwire on any drift
# in the hunks' context, not only on drift in the lines they change: GNU
# patch's default fuzz of 2 would apply them through a nearby edit, and the
# guard is meant to put a person in front of the patch on such a bump. It
# costs nothing today - the hunks apply to the pinned source with fuzz
# forbidden.
#
# The kiosk restriction inside openQuitMenu() is Linux-only by construction:
# on __APPLE__ and __ANDROID__ upstream takes an `if (true)` branch to the
# bare "really quit?" box, so the guarded submenu is unreachable there. This
# package is `platforms = lib.platforms.linux`, so that path is never built.
#
# Bumping: edit `version`, set `hash = lib.fakeHash`, rebuild, and record
# the hash the failed fetch reports; the guard and the version check re-run.
{
  lib,
  stdenv,
  fetchzip,
  cmake,
  pkg-config,
  alsa-lib,
  bluez,
  curl,
  ffmpeg,
  freeimage,
  freetype,
  gettext,
  harfbuzz,
  icu,
  libgit2,
  poppler,
  pugixml,
  SDL2,
  libGL,
  versionCheckHook,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "es-de";
  version = "3.4.1";

  src = fetchzip {
    url = "https://gitlab.com/es-de/emulationstation-de/-/archive/v${finalAttrs.version}/emulationstation-de-v${finalAttrs.version}.tar.gz";
    hash = "sha256-MVmJIdxwEG3wgvwbhuIEYCxKaYss/3hq9xszGLjZ1Xw=";
  };

  patches = [ ./kiosk-quit-menu.patch ];
  # `-p1` is the stdenv default, restated because setting patchFlags
  # replaces it rather than adding to it.
  patchFlags = [
    "-p1"
    "--fuzz=0"
  ];

  postPatch = ''
    # ldd-based detection fails for cross builds
    substituteInPlace CMake/Packages/FindPoppler.cmake \
      --replace-fail 'GET_PREREQUISITES("''${POPPLER_LIBRARY}" POPPLER_PREREQS 1 0 "" "")' ""
  '';

  nativeBuildInputs = [
    cmake
    gettext # msgfmt
    pkg-config
  ];

  buildInputs = [
    alsa-lib
    bluez
    curl
    ffmpeg
    freeimage
    freetype
    harfbuzz
    icu
    libgit2
    poppler
    pugixml
    SDL2
    libGL
  ];

  cmakeFlags = [ (lib.cmakeBool "APPLICATION_UPDATER" false) ];

  # The find rules ES-DE installs must name the NixOS RetroArch core
  # directory, or the frontend cannot find its cores. Upstream's file has
  # carried it since before 3.2.0; this fails the build if a bump drops it.
  postInstall = ''
    rules=$out/share/es-de/resources/systems/linux/es_find_rules.xml
    if [ ! -f "$rules" ]; then
      echo "es-de: $rules is not installed; the resources moved" >&2
      exit 1
    fi
    if ! grep -qF /run/current-system/sw/lib/retroarch/cores "$rules"; then
      echo "es-de: $rules does not list /run/current-system/sw/lib/retroarch/cores" >&2
      exit 1
    fi
  '';

  # `es-de --version` prints and returns before SDL initialises, so it runs
  # headless in the sandbox.
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";
  doInstallCheck = true;

  meta = {
    description = "Frontend for browsing and launching games from a multi-platform collection";
    homepage = "https://es-de.org";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "es-de";
  };
})
