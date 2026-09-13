{
  lib,
  stdenvNoCC,
  btrfs-progs,
  makeWrapper,
  python3,
  restic,
  ruff,
  systemd,
  ty,
  util-linux,
}:
let
  python = python3.withPackages (ps: [ ps.pytest ]);
  # systemd: the helper's own `systemctl` and `journalctl` calls, so they
  # resolve when the status aggregator runs this wrapper as a subprocess
  # rather than from an administrator's shell, which passes on its own PATH
  # unmodified.
  runtimePath = lib.makeBinPath [
    btrfs-progs
    restic
    systemd
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
    # This package once carried a second name, emubox-status, as a
    # makeWrapper alias with --status forced on; the aggregator (pkgs/
    # emubox-status) replaced it, and no derivation may produce that name
    # again here.
    test ! -e $out/bin/emubox-status
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
