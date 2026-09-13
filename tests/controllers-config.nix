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
  # first time - every file new to the editor this capability adds. Hand-
  # typed against each emulator's own file names rather than read back
  # from the module under test.
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
  notRegistered = lib.filter (
    f: !(host.config.emubox.kiosk.ownedFiles ? ${f.path})
  ) newControllerFiles;

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

  sdlJstestInstalled = lib.any (
    p: lib.getName p == "sdl-jstest"
  ) host.config.environment.systemPackages;

  # A configuration whose identity facts are empty - the host's own
  # default - and one that records both a pad's SDL device name and its
  # SDL joystick GUID, checked against the same files both ways: Dolphin's
  # route back and its gameplay profiles wait on the device name alone,
  # Azahar's whole Controls section on the GUID alone, so the identity
  # variant below sets both at once rather than repeating this pair of
  # configurations for each.
  hotkeysFile = "${configDirs.dolphin}/Hotkeys.ini";
  gcPadFile = "${configDirs.dolphin}/GCPadNew.ini";
  wiimoteFile = "${configDirs.dolphin}/WiimoteNew.ini";
  dolphinIniFile = "${configDirs.dolphin}/Dolphin.ini";
  azaharIniFile = "${configDirs.azahar}/qt-config.ini";

  withIdentityHost = host.extendModules {
    modules = [
      {
        emubox.facts.controllerIdentities.sdlGamepadName = "Xbox 360 Controller";
        emubox.facts.controllerIdentities.sdlJoystickGuid = "030081b85e0400008e02000014010000";
      }
    ];
  };

  withoutIdentityEnforce = host.config.emubox.kiosk.ownedFiles.${hotkeysFile}.enforce;
  withIdentityEnforce = withIdentityHost.config.emubox.kiosk.ownedFiles.${hotkeysFile}.enforce;

  withoutIdentityGCPad = host.config.emubox.kiosk.ownedFiles.${gcPadFile}.enforce;
  withIdentityGCPad = withIdentityHost.config.emubox.kiosk.ownedFiles.${gcPadFile}.enforce;
  withoutIdentityWiimote = host.config.emubox.kiosk.ownedFiles.${wiimoteFile}.enforce;
  withIdentityWiimote = withIdentityHost.config.emubox.kiosk.ownedFiles.${wiimoteFile}.enforce;

  withoutIdentityDolphinCore =
    host.config.emubox.kiosk.ownedFiles.${dolphinIniFile}.enforce.Core or { };
  withIdentityDolphinCore =
    withIdentityHost.config.emubox.kiosk.ownedFiles.${dolphinIniFile}.enforce.Core or { };

  withoutIdentityAzaharControls =
    host.config.emubox.kiosk.ownedFiles.${azaharIniFile}.enforce.Controls or { };
  withIdentityAzaharControls =
    withIdentityHost.config.emubox.kiosk.ownedFiles.${azaharIniFile}.enforce.Controls or { };

  pspStandaloneCommand = "%EMULATOR_PPSSPP% --pause-menu-exit %ROM%";
  customSystems = host.config.emubox.kiosk.customSystems;
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
assert lib.assertMsg (withoutIdentityGCPad == { }) ''
  tests/controllers-config.nix: with emubox.facts.controllerIdentities
  empty, Dolphin's GCPadNew.ini must declare no enforced key at all - got
  ${builtins.toJSON withoutIdentityGCPad}.
'';
assert lib.assertMsg (withoutIdentityWiimote == { }) ''
  tests/controllers-config.nix: with emubox.facts.controllerIdentities
  empty, Dolphin's WiimoteNew.ini must declare no enforced key at all -
  got ${builtins.toJSON withoutIdentityWiimote}.
'';
assert lib.assertMsg (withoutIdentityDolphinCore == { }) ''
  tests/controllers-config.nix: with emubox.facts.controllerIdentities
  empty, Dolphin.ini must declare no enforced [Core] key at all - got
  ${builtins.toJSON withoutIdentityDolphinCore}.
'';
assert lib.assertMsg (withoutIdentityAzaharControls == { }) ''
  tests/controllers-config.nix: with emubox.facts.controllerIdentities
  empty, Azahar's qt-config.ini must declare no enforced [Controls] key at
  all - got ${builtins.toJSON withoutIdentityAzaharControls}.
'';
assert lib.assertMsg
  (
    withIdentityGCPad ? GCPad1
    && withIdentityGCPad ? GCPad2
    && withIdentityGCPad ? GCPad3
    && withIdentityGCPad ? GCPad4
    && withIdentityGCPad.GCPad1.Device or null == "SDL/0/Xbox 360 Controller"
  )
  ''
    tests/controllers-config.nix: with
    emubox.facts.controllerIdentities.sdlGamepadName set, Dolphin's
    GCPadNew.ini must declare every player's gameplay profile - got
    ${builtins.toJSON withIdentityGCPad}.
  '';
assert lib.assertMsg
  (
    withIdentityWiimote ? Wiimote1
    && withIdentityWiimote ? Wiimote2
    && withIdentityWiimote ? Wiimote3
    && withIdentityWiimote ? Wiimote4
    && withIdentityWiimote.Wiimote1.Device or null == "SDL/0/Xbox 360 Controller"
    && withIdentityWiimote.Wiimote2.Source or null == "1"
  )
  ''
    tests/controllers-config.nix: with
    emubox.facts.controllerIdentities.sdlGamepadName set, Dolphin's
    WiimoteNew.ini must declare every player's gameplay profile and each
    further player's Source slot setting - got
    ${builtins.toJSON withIdentityWiimote}.
  '';
assert lib.assertMsg
  (
    withIdentityDolphinCore.SIDevice1 or null == "6"
    && withIdentityDolphinCore.SIDevice2 or null == "6"
    && withIdentityDolphinCore.SIDevice3 or null == "6"
  )
  ''
    tests/controllers-config.nix: with
    emubox.facts.controllerIdentities.sdlGamepadName set, Dolphin.ini must
    declare its GameCube slot settings SIDevice1-3 - got
    ${builtins.toJSON withIdentityDolphinCore}.
  '';
assert lib.assertMsg
  (
    withIdentityAzaharControls."profiles\\size" or null == "1"
    && withIdentityAzaharControls.profile or null == "0"
    && withIdentityAzaharControls."profile\\default" or null == "false"
    && lib.hasInfix "030081b85e0400008e02000014010000" (
      withIdentityAzaharControls."profiles\\1\\button_a" or ""
    )
  )
  ''
    tests/controllers-config.nix: with
    emubox.facts.controllerIdentities.sdlJoystickGuid set, Azahar's
    qt-config.ini must declare its profile array and every gameplay
    binding under profiles\1\ - got
    ${builtins.toJSON withIdentityAzaharControls}.
  '';
assert lib.assertMsg (lib.hasInfix pspStandaloneCommand customSystems) ''
  tests/controllers-config.nix: the frontend's PSP standalone launch
  command must carry --pause-menu-exit (expected to find
  "${pspStandaloneCommand}" in emubox.kiosk.customSystems).
'';
pkgs.runCommand "emubox-controllers-config" { } ''
  touch "$out"
''
