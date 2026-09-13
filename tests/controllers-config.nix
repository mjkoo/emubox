# Evaluation-only guards for the controllers capability's owned-file
# contributions: every path it owns is built from
# `emubox.emulators.configDirs` rather than a literal emulator
# configuration path of its own, the SDL identity-capture tool lands on the
# host's own system path, the frontend's PSP launch command carries its
# route-back flag, and a configuration with no recorded pad identity
# declares none of Dolphin's identity-bearing keys or the route-back
# binding that depends on them - proven against a configuration that does
# record one too, so the gate is shown working both ways rather than only
# vacuously.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  host = self.nixosConfigurations.emubox;
  configDirs = host.config.emubox.emulators.configDirs;

  # The files `modules/controllers` registers with a `format` for the
  # first time - what this task and 3.3 between them add that is new to
  # the editor. Hand-typed against the determination's own file names
  # rather than read back from the module under test.
  newControllerFiles = [
    {
      path = "${configDirs.dolphin}/Hotkeys.ini";
      dir = configDirs.dolphin;
    }
    {
      path = "${configDirs.dolphin}/GCPadNew.ini";
      dir = configDirs.dolphin;
    }
    {
      path = "${configDirs.dolphin}/WiimoteNew.ini";
      dir = configDirs.dolphin;
    }
    {
      path = "${configDirs.ppsspp}/controls.ini";
      dir = configDirs.ppsspp;
    }
  ];

  outsideConfigDirs = lib.filter (f: !(lib.hasPrefix (f.dir + "/") f.path)) newControllerFiles;
  notRegistered = lib.filter (f: !(host.config.emubox.kiosk.ownedFiles ? ${f.path})) newControllerFiles;

  # The literal directories `modules/emulators` binds once each and
  # exposes through `configDirs` above - a regression guard against a
  # future edit to `modules/controllers` typing one of them again instead
  # of building every path from that option.
  controllersSource = builtins.readFile ../modules/controllers/default.nix;
  forbiddenPathLiterals = [
    ".config/dolphin-emu"
    ".config/azahar-emu"
    ".config/PCSX2"
    ".local/share/duckstation"
    ".config/ppsspp"
    ".config/scummvm"
  ];
  foundLiterals = lib.filter (l: lib.hasInfix l controllersSource) forbiddenPathLiterals;

  sdlJstestInstalled = lib.any (p: lib.getName p == "sdl-jstest") host.config.environment.systemPackages;

  # A configuration whose identity facts are empty - the host's own
  # default - and one that records a pad's SDL device name, checked
  # against the same file both ways.
  hotkeysFile = "${configDirs.dolphin}/Hotkeys.ini";
  withoutIdentityEnforce = host.config.emubox.kiosk.ownedFiles.${hotkeysFile}.enforce;
  withIdentityEnforce =
    (host.extendModules {
      modules = [ { emubox.facts.controllerIdentities.sdlGamepadName = "Xbox 360 Controller"; } ];
    }).config.emubox.kiosk.ownedFiles.${hotkeysFile}.enforce;

  pspStandaloneCommand = "%EMULATOR_PPSSPP% --pause-menu-exit %ROM%";
in
assert lib.assertMsg (outsideConfigDirs == [ ]) ''
  tests/controllers-config.nix: a file modules/controllers contributes does
  not lie under one of emubox.emulators.configDirs's own directories:
  ${lib.concatMapStringsSep "\n" (f: "${f.path} (expected under ${f.dir})") outsideConfigDirs}
'';
assert lib.assertMsg (notRegistered == [ ]) ''
  tests/controllers-config.nix: a file modules/controllers is expected to
  register in emubox.kiosk.ownedFiles is missing from it entirely:
  ${lib.concatMapStringsSep "\n" (f: f.path) notRegistered}
'';
assert lib.assertMsg (foundLiterals == [ ]) ''
  tests/controllers-config.nix: modules/controllers/default.nix contains a
  literal emulator configuration path that should instead be built from
  emubox.emulators.configDirs: ${lib.concatStringsSep ", " foundLiterals}
'';
assert lib.assertMsg sdlJstestInstalled ''
  tests/controllers-config.nix: nixpkgs sdl-jstest (binary sdl2-jstest) is
  not among the host's environment.systemPackages.
'';
assert lib.assertMsg (withoutIdentityEnforce == { }) ''
  tests/controllers-config.nix: with emubox.facts.controllerIdentities
  empty, Dolphin's Hotkeys.ini must declare no enforced key at all - got
  ${builtins.toJSON withoutIdentityEnforce}.
'';
assert lib.assertMsg
  (
    withIdentityEnforce.Hotkeys.Device or null == "SDL/0/Xbox 360 Controller"
    && withIdentityEnforce.Hotkeys."General/Stop" or null == "Back&Start"
  )
  ''
    tests/controllers-config.nix: with
    emubox.facts.controllerIdentities.sdlGamepadName set, Dolphin's
    Hotkeys.ini must declare its route-back Device and General/Stop keys -
    got ${builtins.toJSON withIdentityEnforce}.
  '';
assert lib.assertMsg (lib.hasInfix pspStandaloneCommand customSystems) ''
  tests/controllers-config.nix: the frontend's PSP standalone launch
  command must carry --pause-menu-exit (expected to find
  "${pspStandaloneCommand}" in emubox.kiosk.customSystems).
'';
pkgs.runCommand "emubox-controllers-config" { } ''
  touch "$out"
''
