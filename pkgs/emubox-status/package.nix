# emubox-status: the operator's one aggregate health command. It carries no
# knowledge of what any capability considers healthy - it reads the reporter
# list a module renders to a stable path, runs each registered command
# exactly as given and reports the worst state any of them returned.
# modules/status owns that option and the stable path; this package is only
# the program that reads it, and it takes the reporter-list path as its own
# argument so it can be pointed at a fixture in its unit tests as readily as
# at the real one.
#
# Packaged exactly the way pkgs/emubox-check-bios/package.nix packages its
# own report-only tool, for the same reasons recorded there: a handful of
# Python files and their tests under stdenvNoCC.mkDerivation, with the unit
# tests, lint and type check running in checkPhase so
# checks.<system>.emubox-status is one build on every system the flake is
# checked on, the admin's Mac included. No runtime dependency of its own:
# each reporter's own packaging is responsible for whatever it shells out
# to, never this aggregator, which is why it wraps nothing and prefixes no
# runtime path onto itself.
{
  lib,
  stdenvNoCC,
  python3,
  ruff,
  ty,
}:

stdenvNoCC.mkDerivation {
  pname = "emubox-status";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      (lib.fileset.fileFilter (f: f.hasExt "py") ./.)
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
    install -Dm755 emubox_status.py $out/bin/emubox-status
    runHook postInstall
  '';

  meta = {
    description = "Aggregates the health reports capabilities register with it";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
    mainProgram = "emubox-status";
  };
}
