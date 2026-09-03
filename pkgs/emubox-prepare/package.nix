# emubox-prepare: the config editor the kiosk session runs before every
# launch of the frontend. It asserts the settings the flake owns and leaves
# every other key as the frontend last wrote it (design D3).
#
# Not a vendored package: this is a program of the project's own, built by
# the flake like any other package it provides. A handful of Python files
# and their tests, so `stdenvNoCC.mkDerivation` rather than
# `buildPythonApplication`, which would want a pyproject.toml of its own. If
# prepare outgrows this it becomes a uv project here and the derivation
# switches to nixpkgs' uv support.
#
# The unit tests, lint and type check run in `checkPhase` rather than as
# derivations of their own, so `checks.<system>.emubox-prepare` is a single
# build on every system the flake is checked on, the admin's Mac included.
# `python3.withPackages` is a `buildInputs` entry, not a native one: the
# script runs on the host platform, and the default fixup's
# `patchShebangs --host` resolves its `#!` against exactly that environment -
# the one carrying `cryptography` for the DuckStation token transform and
# `configupdater` for the settings files it edits.
{
  lib,
  stdenvNoCC,
  python3,
  ruff,
  ty,
}:

let
  # One python closure for both the installed script's shebang and the
  # check phase's pytest, so `import cryptography` works in both places
  # rather than only at runtime or only under test. `configupdater` is the
  # comment-preserving INI library both flat-file editors read and write
  # through; it is pure Python and pulls in nothing else.
  python = python3.withPackages (ps: [
    ps.cryptography
    ps.configupdater
  ]);
in
stdenvNoCC.mkDerivation {
  pname = "emubox-prepare";
  version = "0.1.0";

  # By extension rather than by name: `ty.toml` exists only if a ty release
  # needs per-rule downgrades (design Risks), and a fileset naming a file
  # that is not there fails evaluation.
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
    runHook preCheck
    ruff check .
    ruff format --check .
    ty check
    pytest -q
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 emubox_prepare.py $out/bin/emubox-prepare
    runHook postInstall
  '';

  meta = {
    description = "Seeds and asserts the emulation frontend settings the flake owns";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
    mainProgram = "emubox-prepare";
  };
}
