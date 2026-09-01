{
  lib,
  stdenvNoCC,
  python3,
  ruff,
  ty,
}:
let
  python = python3.withPackages (ps: [ ps.pytest ]);
in
stdenvNoCC.mkDerivation {
  pname = "emubox-save-migrate";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      (lib.fileset.fileFilter (f: f.hasExt "py") ./.)
      (lib.fileset.fileFilter (f: f.hasExt "toml") ./.)
    ];
  };
  buildInputs = [ python ];
  nativeCheckInputs = [
    ruff
    ty
    python.pkgs.pytest
  ];
  doCheck = true;
  checkPhase = ''
    ruff check .
    ruff format --check .
    ty check
    pytest -q
  '';
  installPhase = ''
    install -Dm755 emubox_save_migrate.py $out/bin/emubox-save-migrate
  '';
  meta = {
    description = "Conflict-safe migration for EmuBox save routes";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
    mainProgram = "emubox-save-migrate";
  };
}
