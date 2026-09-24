# The library commands share discovery, durable records and a scraper process
# boundary. Their Python tests and static checks run in this derivation.
{
  lib,
  stdenvNoCC,
  python3,
  ruff,
  ty,
  util-linux,
}:

stdenvNoCC.mkDerivation {
  pname = "emubox-library";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      (lib.fileset.fileFilter (f: f.hasExt "py") ./.)
      (lib.fileset.fileFilter (f: f.hasExt "json") ./.)
      (lib.fileset.fileFilter (f: f.hasExt "toml") ./.)
    ];
  };

  buildInputs = [ python3 ];
  nativeCheckInputs = [
    ruff
    ty
    python3.pkgs.pytest
  ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ruff check .
    ruff format --check .
    ty check
    pytest -q
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 emubox_scrape.py $out/bin/emubox-scrape
    install -Dm755 emubox_library_generate.py $out/bin/emubox-library-generate
    install -Dm755 emubox_library_report.py $out/bin/emubox-library-report
    install -Dm644 library.py $out/lib/emubox-library/library.py
    install -Dm644 vectors.json $out/lib/emubox-library/vectors.json
    # The entry points import their common module from the installed package.
    substituteInPlace $out/bin/emubox-scrape --replace-fail '@LIBDIR@' "$out/lib/emubox-library"
    substituteInPlace $out/bin/emubox-library-generate --replace-fail '@LIBDIR@' "$out/lib/emubox-library"
    substituteInPlace $out/bin/emubox-library-report --replace-fail '@LIBDIR@' "$out/lib/emubox-library"
    substituteInPlace $out/lib/emubox-library/library.py --replace-fail '@IONICE@' '${
      if stdenvNoCC.isLinux then "${util-linux}/bin/ionice" else ""
    }'
    runHook postInstall
  '';

  meta = {
    description = "Fetches and generates the game library and reports its state";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
    mainProgram = "emubox-scrape";
  };
}
