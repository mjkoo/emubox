# emubox-check-bios: the report-only tool an admin runs over SSH to see
# whether /data/bios holds the firmware the flake's inventory declares
# (design D6). Deliberately not sharing code with emubox-prepare even
# though both are small Python programs this project ships beside each
# other: prepare's error policy is "recreate, never fail" because a family
# staring at a dead frontend is the worst outcome it can produce, while this
# tool's whole job is to report the truth about files nobody can ship
# faithfully - the two policies are opposites, and a shared helper would
# have to pick one or grow a mode flag that exists only to keep them apart.
#
# Packaged exactly the way pkgs/emubox-prepare/package.nix packages prepare,
# for the same reasons recorded there: a handful of Python files and their
# tests under `stdenvNoCC.mkDerivation` rather than `buildPythonApplication`,
# with the unit tests, lint and type check running in `checkPhase` so
# `checks.<system>.emubox-check-bios` is one build on every system the flake
# is checked on, the admin's Mac included.
{
  lib,
  stdenvNoCC,
  python3,
  ruff,
  ty,
}:

stdenvNoCC.mkDerivation {
  pname = "emubox-check-bios";
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
    install -Dm755 emubox_check_bios.py $out/bin/emubox-check-bios
    runHook postInstall
  '';

  meta = {
    description = "Reports whether /data/bios holds the firmware the flake declares";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
    mainProgram = "emubox-check-bios";
  };
}
