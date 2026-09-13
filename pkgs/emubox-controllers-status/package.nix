# emubox-controllers-status: the controllers capability's own status
# reporter, registered through emubox.status.reporters from
# modules/controllers. It shells out to udevadm to find which input event
# devices udev marks a joystick, so udevadm has to resolve through this
# package's own wrapper rather than whatever PATH the status aggregator
# happens to run it with - the same contract emubox-restic-backup follows
# for systemctl and journalctl.
#
# Packaged the way pkgs/emubox-check-bios/package.nix packages its own
# report-only tool, plus the wrapper pkgs/emubox-restic-backup/package.nix
# uses for its own runtime dependency: a handful of Python files and their
# tests under stdenvNoCC.mkDerivation, with the unit tests, lint and type
# check running in checkPhase so checks.<system>.emubox-controllers-status
# is one build on every system the flake is checked on, the admin's Mac
# included.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  ruff,
  systemd,
  ty,
}:

stdenvNoCC.mkDerivation {
  pname = "emubox-controllers-status";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      (lib.fileset.fileFilter (f: f.hasExt "py") ./.)
      (lib.fileset.fileFilter (f: f.hasExt "toml") ./.)
    ];
  };

  buildInputs = [ python3 ];
  nativeBuildInputs = [ makeWrapper ];

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
    install -Dm755 emubox_controllers_status.py $out/bin/emubox-controllers-status
    ${lib.optionalString stdenvNoCC.hostPlatform.isLinux ''
      wrapProgram $out/bin/emubox-controllers-status --prefix PATH : ${lib.makeBinPath [ systemd ]}
    ''}
    runHook postInstall
  '';

  meta = {
    description = "Reports connected controller ports and unaccepted pad modes";
    license = lib.licenses.mit;
    # The installed program invokes Linux's udevadm, but its pure
    # classification tests intentionally run on the administrator's Mac too.
    platforms = lib.platforms.all;
    mainProgram = "emubox-controllers-status";
  };
}
