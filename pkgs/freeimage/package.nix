# Vendored from nixpkgs revision 7c7c704523 (pkgs/by-name/fr/freeimage/),
# the last revision carrying this derivation: the parent of PR #454867
# (2025-10-23), whose two commits removed emulationstation-de and then
# freeimage over the unpatched CVEs listed in knownVulnerabilities below.
# Kept because ES-DE (pkgs/es-de) has no other image backend.
#
# The diffs and patches are byte-exact copies of the nixpkgs files
# (patchFlags --binary: several carry CRLF line endings, which the
# repository's .gitattributes keeps from conversion); libtiff-4.4.0.diff
# sits in nixpkgs' directory without being in its patches list and is
# copied for completeness. This file differs from nixpkgs' by this header,
# nixfmt's whitespace (CI's format check requires it), the three fixes
# forward below, the removal of libjpeg.dev_private from buildInputs (that
# output is now a throw), and lib.licenses.freeimage inlined under meta
# (it left nixpkgs with the package). knownVulnerabilities is deliberately
# not edited: it is the record of what is unpatched. flake.nix permits the
# package by name and records the accepted risk beside that permission.
#
# The fixes forward are the design's expected vendoring cost, each a
# postPatch substitution:
# - nixpkgs 608422bd4 ("libjpeg: drop freeimage support", 2025-05-22)
#   removed the patches that compiled libjpeg-turbo's transupp.c into
#   libjpeg and installed transupp.h in a dev_private output. FreeImage's
#   unbundled JPEGTransform.cpp still includes <transupp.h> and calls
#   jtransform_*. The postPatch compiles libjpeg-turbo's own transupp.c
#   (from the same libjpeg the library links, so the versions match by
#   construction) into libfreeimage instead; FreeImage builds with
#   -fvisibility=hidden, so nothing new is exported. Overriding libjpeg
#   for FreeImage alone was rejected: ES-DE also loads libjpeg through
#   poppler, and the dynamic linker picks one libjpeg.so.8 by soname in
#   load order. To re-check on a libjpeg bump: transupp.c still needs
#   only jcopy_block_row and jdiv_round_up from the library, and jpegint.h
#   still has no configuration-dependent struct layout (the stub
#   jconfigint.h defines none). The fallback if that breaks is dropping
#   JPEGTransform.cpp from the source lists: ES-DE never calls
#   FreeImage_JPEGTransform*.
# - OpenEXR 3 moved half.h into Imath and its stream API takes uint64_t
#   (the lines Fedora's freeimage-openexr3.patch changes, applied to the
#   unbundled tree).
# - libtiff 4.7.2 (2026-04) moved tif_row into the tif_dir sub-struct,
#   which PluginG3's fax decoder reaches into.
{
  lib,
  stdenv,
  fetchsvn,
  cctools,
  libtiff,
  libpng,
  zlib,
  libwebp,
  libraw,
  openexr,
  openjpeg,
  libjpeg,
  jxrlib,
  pkg-config,
  fixDarwinDylibNames,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "freeimage";
  version = "3.18.0-unstable-2024-04-18";

  src = fetchsvn {
    url = "svn://svn.code.sf.net/p/freeimage/svn/";
    rev = "1911";
    hash = "sha256-JznVZUYAbsN4FplnuXxCd/ITBhH7bfGKWXep2A6mius=";
  };

  sourceRoot = "${finalAttrs.src.name}/FreeImage/trunk";

  # Ensure that the bundled libraries are not used at all
  prePatch = ''
    rm -rf Source/Lib* Source/OpenEXR Source/ZLib
  '';

  # Tell patch to work with trailing carriage returns
  patchFlags = [
    "-p1"
    "--binary"
  ];

  patches = [
    ./unbundle.diff
    ./CVE-2020-24292.patch
    ./CVE-2020-24293.patch
    ./CVE-2020-24295.patch
    ./CVE-2021-33367.patch
    ./CVE-2021-40263.patch
    ./CVE-2021-40266.patch
    ./CVE-2023-47995.patch
    ./CVE-2023-47997.patch
  ];

  postPatch = ''
    # To support cross compilation, use the correct `pkg-config`.
    substituteInPlace Makefile.fip \
      --replace "pkg-config" "$PKG_CONFIG"
    substituteInPlace Makefile.gnu \
      --replace "pkg-config" "$PKG_CONFIG"

    # transupp from libjpeg-turbo's source, compiled into libfreeimage
    # (see the header). jinclude.h wants a generated jconfigint.h; with
    # its getenv/setenv helpers compiled out (transupp.c never calls them,
    # and setenv is invisible under the Makefile's -std=c99) nothing the
    # copied files use is left in it, so the stub only names the macros
    # the headers mention.
    cp ${libjpeg.src}/src/{transupp.c,transupp.h,jinclude.h,jpegint.h,jpegapicomp.h} Source/FreeImageToolkit/
    cat > Source/FreeImageToolkit/jconfigint.h <<'HDR'
    #define INLINE inline
    #define THREAD_LOCAL
    #define HIDDEN
    #define FALLTHROUGH
    #define NO_GETENV
    #define NO_PUTENV
    HDR
    substituteInPlace Makefile.srcs fipMakefile.srcs \
      --replace-fail "./Source/FreeImageToolkit/JPEGTransform.cpp" \
        "./Source/FreeImageToolkit/JPEGTransform.cpp ./Source/FreeImageToolkit/transupp.c"

    # OpenEXR 3 and libtiff 4.7.2 (see the header).
    substituteInPlace Source/FreeImage/PluginEXR.cpp Source/FreeImage/PluginTIFF.cpp \
      --replace-fail "<OpenEXR/half.h>" "<Imath/half.h>"
    substituteInPlace Source/FreeImage/PluginEXR.cpp \
      --replace-fail "Imath::Int64" "uint64_t"
    substituteInPlace Source/FreeImage/PluginG3.cpp \
      --replace-fail "tifin->tif_row" "tifin->tif_dir.td_row"
  ''
  + lib.optionalString (stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isAarch64) ''
    # Upstream Makefile hardcodes i386 and x86_64 architectures only
    substituteInPlace Makefile.osx --replace "x86_64" "arm64"
  '';

  nativeBuildInputs = [
    pkg-config
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    cctools
    fixDarwinDylibNames
  ];

  buildInputs = [
    libtiff
    libtiff.dev_private
    libpng
    zlib
    libwebp
    libraw
    openexr
    openjpeg
    libjpeg
    jxrlib
  ];

  postBuild = lib.optionalString (!stdenv.hostPlatform.isDarwin) ''
    make -f Makefile.fip
  '';

  INCDIR = "${placeholder "out"}/include";
  INSTALLDIR = "${placeholder "out"}/lib";

  preInstall = ''
    mkdir -p $INCDIR $INSTALLDIR
  ''
  # Workaround for Makefiles.osx not using ?=
  + lib.optionalString stdenv.hostPlatform.isDarwin ''
    makeFlagsArray+=( "INCDIR=$INCDIR" "INSTALLDIR=$INSTALLDIR" )
  '';

  postInstall =
    lib.optionalString (!stdenv.hostPlatform.isDarwin) ''
      make -f Makefile.fip install
    ''
    + lib.optionalString stdenv.hostPlatform.isDarwin ''
      ln -s $out/lib/libfreeimage.3.dylib $out/lib/libfreeimage.dylib
    '';

  enableParallelBuilding = true;

  meta = {
    description = "Open Source library for accessing popular graphics image file formats";
    homepage = "http://freeimage.sourceforge.net/";
    license = with lib.licenses; [
      # lib.licenses.freeimage left nixpkgs with the package in the same
      # PR; this is that entry as mkLicense built it.
      {
        spdxId = "FreeImage";
        shortName = "freeimage";
        fullName = "FreeImage Public License v1.0";
        url = "https://spdx.org/licenses/FreeImage.html";
        free = true;
        redistributable = true;
        deprecated = false;
        licenseType = "simple";
      }
      gpl2Only
      gpl3Only
    ];
    knownVulnerabilities = [
      "CVE-2024-31570"
      "CVE-2024-28584"
      "CVE-2024-28583"
      "CVE-2024-28582"
      "CVE-2024-28581"
      "CVE-2024-28580"
      "CVE-2024-28579"
      "CVE-2024-28578"
      "CVE-2024-28577"
      "CVE-2024-28576"
      "CVE-2024-28575"
      "CVE-2024-28574"
      "CVE-2024-28573"
      "CVE-2024-28572"
      "CVE-2024-28571"
      "CVE-2024-28570"
      "CVE-2024-28569"
      "CVE-2024-28568"
      "CVE-2024-28567"
      "CVE-2024-28566"
      "CVE-2024-28565"
      "CVE-2024-28564"
      "CVE-2024-28563"
      "CVE-2024-28562"
      "CVE-2024-9029"
      # "CVE-2023-47997"
      "CVE-2023-47996"
      # "CVE-2023-47995"
      "CVE-2023-47994"
      "CVE-2023-47993"
      "CVE-2023-47992"
      # "CVE-2021-40266"
      "CVE-2021-40265"
      "CVE-2021-40264"
      # "CVE-2021-40263"
      "CVE-2021-40262"
      # "CVE-2021-33367"
      # "CVE-2020-24295"
      "CVE-2020-24294"
      # "CVE-2020-24293"
      # "CVE-2020-24292"
      "CVE-2020-21426"
      "CVE-2019-12214"
      "CVE-2019-12212"
    ];
    maintainers = [ ];
    platforms = with lib.platforms; unix;
  };
})
