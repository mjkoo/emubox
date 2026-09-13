# Evaluation-only guards for the controllers capability's owned-file
# contributions: every standalone emulator's owned file lies under one of
# `emubox.emulators.configDirs`'s directories, and the controllers module
# types none of those directories itself; the SDL identity-capture tool
# lands on the host's own system path; the frontend's PSP launch command
# carries its route-back flag; a malformed pad identity is refused when the
# facts are evaluated; and a configuration with no recorded pad identity
# declares none of the identity-bearing keys or the route-back binding that
# depends on them - proven against a configuration that does record one
# too, so the gate is shown working both ways rather than only vacuously.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  host = self.nixosConfigurations.emubox;
  configDirs = host.config.emubox.emulators.configDirs;
  ownedFiles = host.config.emubox.kiosk.ownedFiles;

  # The files `modules/controllers` registers with a `format` for the
  # first time - every file new to the editor this capability adds. Hand-
  # typed against each emulator's own file names rather than read back
  # from the module under test.
  newControllerFiles = [
    "${configDirs.dolphin}/Hotkeys.ini"
    "${configDirs.dolphin}/GCPadNew.ini"
    "${configDirs.dolphin}/WiimoteNew.ini"
    "${configDirs.ppsspp}/controls.ini"
  ];
  notRegistered = lib.filter (path: !(ownedFiles ? ${path})) newControllerFiles;

  # The owned files that are not a standalone emulator's own - the
  # frontend's settings and RetroArch's configuration - hand-typed rather
  # than read back from the modules that own them. Every other owned file,
  # whichever module contributes it, has to lie under one of `configDirs`'s
  # own directories.
  notStandaloneFiles = [
    "settings/es_settings.xml"
    "${host.config.users.users.player.home}/.config/retroarch/retroarch.cfg"
  ];
  standaloneFiles = lib.subtractLists notStandaloneFiles (lib.attrNames ownedFiles);
  outsideConfigDirs = lib.filter (
    path: !(lib.any (dir: lib.hasPrefix "${dir}/" path) (lib.attrValues configDirs))
  ) standaloneFiles;

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

  fixtureSdlGamepadName = "Xbox 360 Controller";
  fixtureSdlJoystickGuid = "030081b85e0400008e02000014010000";

  # A configuration whose identity facts are empty and one that records
  # both a pad's SDL device name and its SDL joystick GUID, checked against
  # the same files both ways: Dolphin's route back and its gameplay
  # profiles wait on the device name alone, Azahar's whole Controls section
  # on the GUID alone, so the identity variant below sets both at once
  # rather than repeating this pair of configurations for each. Both force
  # their facts rather than inherit the host's own, so the empty side still
  # means "nothing recorded" once bring-up records real values in
  # hosts/emubox/facts.nix, and the fixture side never conflicts with them.
  withIdentities =
    name: guid:
    host.extendModules {
      modules = [
        {
          emubox.facts.controllerIdentities.sdlGamepadName = lib.mkForce name;
          emubox.facts.controllerIdentities.sdlJoystickGuid = lib.mkForce guid;
        }
      ];
    };
  withoutIdentityHost = withIdentities null null;
  withIdentityHost = withIdentities fixtureSdlGamepadName fixtureSdlJoystickGuid;

  # A GUID one digit short, and a GUID in capitals where `sdl2-jstest`
  # prints lowercase, and an empty device name: each has to be refused when
  # the facts are evaluated rather than carried silently into a binding
  # that could never match the pad.
  refused =
    name: guid:
    let
      identities = (withIdentities name guid).config.emubox.facts.controllerIdentities;
    in
    !(builtins.tryEval (builtins.deepSeq identities identities)).success;
  malformedIdentitiesAccepted = lib.filter (candidate: !(refused candidate.name candidate.guid)) [
    {
      name = fixtureSdlGamepadName;
      guid = "030081b85e0400008e0200001401000";
    }
    {
      name = fixtureSdlGamepadName;
      guid = "030081B85E0400008E02000014010000";
    }
    {
      name = "";
      guid = fixtureSdlJoystickGuid;
    }
  ];

  hotkeysFile = "${configDirs.dolphin}/Hotkeys.ini";
  gcPadFile = "${configDirs.dolphin}/GCPadNew.ini";
  wiimoteFile = "${configDirs.dolphin}/WiimoteNew.ini";
  dolphinIniFile = "${configDirs.dolphin}/Dolphin.ini";
  azaharIniFile = "${configDirs.azahar}/qt-config.ini";

  enforceOf = h: file: h.config.emubox.kiosk.ownedFiles.${file}.enforce;

  withoutIdentityEnforce = enforceOf withoutIdentityHost hotkeysFile;
  withIdentityEnforce = enforceOf withIdentityHost hotkeysFile;

  withoutIdentityGCPad = enforceOf withoutIdentityHost gcPadFile;
  withIdentityGCPad = enforceOf withIdentityHost gcPadFile;
  withoutIdentityWiimote = enforceOf withoutIdentityHost wiimoteFile;
  withIdentityWiimote = enforceOf withIdentityHost wiimoteFile;

  withoutIdentityDolphinCore = (enforceOf withoutIdentityHost dolphinIniFile).Core or { };
  withIdentityDolphinCore = (enforceOf withIdentityHost dolphinIniFile).Core or { };

  withoutIdentityAzaharControls = (enforceOf withoutIdentityHost azaharIniFile).Controls or { };
  withIdentityAzaharControls = (enforceOf withIdentityHost azaharIniFile).Controls or { };

  players = [
    1
    2
    3
    4
  ];

  # The stick calibrations an earlier keyboard-default Dolphin run leaves
  # behind, owned empty so the pad's sticks use their full range: gated on
  # the pad's identity with the rest of each section.
  calibrationsWrong =
    lib.filter (entry: (entry.enforce.${entry.section}.${entry.key} or null) != "")
      (
        lib.concatMap (n: [
          {
            enforce = withIdentityGCPad;
            section = "GCPad${toString n}";
            key = "Main Stick/Calibration";
          }
          {
            enforce = withIdentityGCPad;
            section = "GCPad${toString n}";
            key = "C-Stick/Calibration";
          }
          {
            enforce = withIdentityWiimote;
            section = "Wiimote${toString n}";
            key = "Nunchuk/Stick/Calibration";
          }
        ]) players
      );

  # Every gameplay binding Azahar's profile carries, hand-typed rather than
  # read back from the module: each must name the recorded GUID, and each
  # has its own `\default` companion held at false.
  azaharBindingNames = [
    "button_a"
    "button_b"
    "button_x"
    "button_y"
    "button_up"
    "button_down"
    "button_left"
    "button_right"
    "button_l"
    "button_r"
    "button_start"
    "button_select"
    "button_zl"
    "button_zr"
    "button_home"
    "circle_pad"
    "c_stick"
  ];
  azaharBindingsWrong = lib.filter (
    name:
    !(
      lib.hasInfix fixtureSdlJoystickGuid (withIdentityAzaharControls."profiles\\1\\${name}" or "")
      && withIdentityAzaharControls."profiles\\1\\${name}\\default" or null == "false"
    )
  ) azaharBindingNames;

  pspStandaloneCommand = "%EMULATOR_PPSSPP% --pause-menu-exit %ROM%";
  customSystems = host.config.emubox.kiosk.customSystems;
in
assert lib.assertMsg (outsideConfigDirs == [ ]) ''
  tests/controllers-config.nix: a standalone emulator's owned file does not
  lie under any of emubox.emulators.configDirs's own directories
  (${lib.concatStringsSep ", " (lib.attrValues configDirs)}):
  ${lib.concatStringsSep "\n" outsideConfigDirs}
'';
assert lib.assertMsg (notRegistered == [ ]) ''
  tests/controllers-config.nix: a file modules/controllers is expected to
  register in emubox.kiosk.ownedFiles is missing from it entirely:
  ${lib.concatStringsSep "\n" notRegistered}
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
assert lib.assertMsg (malformedIdentitiesAccepted == [ ]) ''
  tests/controllers-config.nix: emubox.facts.controllerIdentities accepted
  a malformed value it must refuse - got ${builtins.toJSON malformedIdentitiesAccepted}.
'';
assert lib.assertMsg (withoutIdentityEnforce == { }) ''
  tests/controllers-config.nix: with emubox.facts.controllerIdentities
  empty, Dolphin's Hotkeys.ini must declare no enforced key at all - got
  ${builtins.toJSON withoutIdentityEnforce}.
'';
assert lib.assertMsg
  (
    withIdentityEnforce.Hotkeys.Device or null == "SDL/0/${fixtureSdlGamepadName}"
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
    lib.all (n: withIdentityGCPad ? "GCPad${toString n}") players
    && withIdentityGCPad.GCPad1.Device or null == "SDL/0/${fixtureSdlGamepadName}"
  )
  ''
    tests/controllers-config.nix: with
    emubox.facts.controllerIdentities.sdlGamepadName set, Dolphin's
    GCPadNew.ini must declare every player's gameplay profile - got
    ${builtins.toJSON withIdentityGCPad}.
  '';
assert lib.assertMsg
  (
    lib.all (n: withIdentityWiimote ? "Wiimote${toString n}") players
    && withIdentityWiimote.Wiimote1.Device or null == "SDL/0/${fixtureSdlGamepadName}"
    && withIdentityWiimote.Wiimote2.Source or null == "1"
  )
  ''
    tests/controllers-config.nix: with
    emubox.facts.controllerIdentities.sdlGamepadName set, Dolphin's
    WiimoteNew.ini must declare every player's gameplay profile and each
    further player's Source slot setting - got
    ${builtins.toJSON withIdentityWiimote}.
  '';
assert lib.assertMsg (calibrationsWrong == [ ]) ''
  tests/controllers-config.nix: with
  emubox.facts.controllerIdentities.sdlGamepadName set, every player's
  Main Stick, C-Stick and Nunchuk stick calibration must be enforced
  empty - wrong or missing: ${
    lib.concatMapStringsSep ", " (entry: "[${entry.section}] ${entry.key}") calibrationsWrong
  }.
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
    && azaharBindingsWrong == [ ]
  )
  ''
    tests/controllers-config.nix: with
    emubox.facts.controllerIdentities.sdlJoystickGuid set, Azahar's
    qt-config.ini must declare its profile array and every gameplay
    binding under profiles\1\, each carrying the recorded GUID beside a
    false \default companion - bindings wrong or missing:
    ${lib.concatStringsSep ", " azaharBindingsWrong}; got
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
