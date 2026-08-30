# DuckStation, the PS1 emulator, as the upstream x86_64 AppImage of a pinned
# release, extracted and run unmodified inside an FHS wrapper.
#
# Why a binary and not a source build: nixpkgs removed its duckstation
# derivation at upstream's request after the licence changed to
# CC-BY-NC-ND 4.0 ("removed following upstream request. Please use the
# appimage instead"). This repository and the emubox Cachix cache are
# public. CC-BY-NC-ND permits redistributing unmodified copies
# non-commercially with attribution and forbids distributing derivatives;
# the nixpkgs source derivation patched the source, so its build could not
# be pushed to the cache. The AppImage is unmodified and is the channel
# upstream asks distributions to use. wrapType2 extracts the AppImage and
# installs its contents plus an FHS wrapper that runs them, so what
# reaches the store and the cache is the extracted form, byte-identical in
# content: the posture rests on the contents being unmodified, not on the
# file being one blob. The desktop entry installed below is written here
# (the wrapper's name with upstream's icon name and categories), not a
# rewritten copy of upstream's file; the icon is copied verbatim.
#
# Bumping: edit `version` to the new release tag (without the leading v),
# set `hash = lib.fakeHash`, rebuild, and record the hash the failed fetch
# reports. The URL derives from `version`, so nothing else changes.
#
# Attribution: DuckStation by Connor McLaughlin (stenzek) and contributors,
# https://github.com/stenzek/duckstation, CC-BY-NC-ND 4.0.
{
  lib,
  appimageTools,
  fetchurl,
  makeDesktopItem,
}:

let
  pname = "duckstation";
  version = "0.1-11752";

  src = fetchurl {
    url = "https://github.com/stenzek/duckstation/releases/download/v${version}/DuckStation-x64.AppImage";
    hash = "sha256-Fpp90sN3MXgOs3KcvhbwSP/z47bvnJ9JmGncEXSJmlQ=";
  };

  # The unpacked AppImage; wrapType2 runs the same extraction for the
  # wrapper, so this is one more reference to the same store path.
  contents = appimageTools.extract { inherit pname version src; };

  desktopItem = makeDesktopItem {
    name = "org.duckstation.DuckStation";
    desktopName = "DuckStation";
    genericName = "PlayStation 1 Emulator";
    comment = "Fast PlayStation 1 emulator";
    exec = "duckstation %f";
    icon = "org.duckstation.DuckStation";
    categories = [
      "Game"
      "Emulator"
      "Qt"
    ];
  };
in
appimageTools.wrapType2 {
  inherit pname version src;

  # The project's desktop entry (see the header) and upstream's icon.
  extraInstallCommands = ''
    install -Dm444 ${desktopItem}/share/applications/org.duckstation.DuckStation.desktop \
      -t $out/share/applications
    install -Dm444 ${contents}/usr/share/icons/hicolor/512x512/apps/org.duckstation.DuckStation.png \
      -t $out/share/icons/hicolor/512x512/apps
  '';

  meta = {
    description = "Fast PlayStation 1 emulator";
    homepage = "https://github.com/stenzek/duckstation";
    license = lib.licenses.cc-by-nc-nd-40;
    platforms = [ "x86_64-linux" ];
    mainProgram = "duckstation";
  };
}
