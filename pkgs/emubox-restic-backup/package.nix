{
  lib,
  stdenvNoCC,
  btrfs-progs,
  makeWrapper,
  python3,
  restic,
  ruff,
  ty,
  util-linux,
}:
let
  python = python3.withPackages (ps: [ ps.pytest ]);
  runtimePath = lib.makeBinPath [
    btrfs-progs
    restic
    util-linux
  ];
in
stdenvNoCC.mkDerivation {
  pname = "emubox-restic-backup";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      (lib.fileset.fileFilter (f: f.hasExt "py") ./.)
      (lib.fileset.fileFilter (f: f.hasExt "toml") ./.)
    ];
  };
  buildInputs = [ python ];
  nativeBuildInputs = [ makeWrapper ];
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
    install -Dm755 emubox_restic_backup.py $out/bin/emubox-restic-backup
    ${lib.optionalString stdenvNoCC.hostPlatform.isLinux ''
      wrapProgram $out/bin/emubox-restic-backup --prefix PATH : ${runtimePath}
    ''}
    # The operator's restic entry point is `restic-emubox`, which
    # `services.restic`'s `createWrapper` installs with this repository's
    # environment already set.
    makeWrapper $out/bin/emubox-restic-backup $out/bin/emubox-status \
      --add-flags --status
  '';
  meta = {
    description = "Snapshot-consistent restic backup helper for EmuBox";
    license = lib.licenses.mit;
    # The installed helper invokes Linux btrfs tools, but its pure path and
    # cleanup tests intentionally run on the administrator's Mac as well.
    platforms = lib.platforms.all;
    mainProgram = "emubox-restic-backup";
  };
}
