{
  lib,
  stdenvNoCC,
  btrfs-progs,
  makeWrapper,
  python3,
  restic,
  ruff,
  runtimeShell,
  shellcheck,
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
      (lib.fileset.fileFilter (f: f.hasExt "sh") ./.)
      (lib.fileset.fileFilter (f: f.hasExt "toml") ./.)
    ];
  };
  buildInputs = [ python ];
  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [
    ruff
    shellcheck
    ty
    python.pkgs.pytest
  ];
  doCheck = true;
  # The wrapper install check creates fake `id` and `restic` executables. Its
  # fixture shebangs must work in the Nix sandbox, where `/usr/bin/env` is not
  # available.
  postPatch = ''
    substituteInPlace test_emubox_restic_wrapper.sh \
      --replace-fail "/usr/bin/env bash" "${runtimeShell}"
  '';
  checkPhase = ''
    ruff check .
    ruff format --check .
    ty check
    pytest -q
    shellcheck emubox_restic_wrapper.sh test_emubox_restic_wrapper.sh
  '';
  doInstallCheck = true;
  installPhase = ''
    install -Dm755 emubox_restic_backup.py $out/bin/emubox-restic-backup
    install -Dm755 emubox_restic_wrapper.sh $out/bin/emubox-restic
    ln -s emubox-restic-backup $out/bin/emubox-status
    ${lib.optionalString stdenvNoCC.hostPlatform.isLinux ''
      wrapProgram $out/bin/emubox-restic-backup --prefix PATH : ${runtimePath}
    ''}
  '';
  installCheckPhase = ''
    bash test_emubox_restic_wrapper.sh "$out/bin/emubox-restic"
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
