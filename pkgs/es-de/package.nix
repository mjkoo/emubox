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
