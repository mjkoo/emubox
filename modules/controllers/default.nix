# USB-A port order becomes player order: each recorded port gets a stable
# /dev/input/emubox-pN name, and the session is told to enumerate those names
# first, in order. Beyond that hint, this module also gives every standalone
# emulator but Azahar its own owned route back to the frontend, at file paths
# built from `emubox.emulators.configDirs` rather than a config path typed a
# second time here.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  ports = config.emubox.facts.controllerPorts;
  configDirs = config.emubox.emulators.configDirs;
  identity = config.emubox.facts.controllerIdentities;

  # The one mode this change has evidence for: the wired pad in its default
  # mode under the in-kernel xpad driver, the identity the packaged
  # RetroArch autoconfig profile keys on. A list rather than a single
  # constant, so a further accepted mode can be added later without
  # reworking the status reporter.
  acceptedControllerModes = [
    {
      vendor = "045e";
      product = "028e";
    }
  ];

  controllersStatusCommand = [
    (lib.getExe pkgs.emubox-controllers-status)
    "--ports"
    (toString (lib.length ports))
  ]
  ++ lib.concatMap (mode: [
    "--accepted"
    "${mode.vendor}:${mode.product}"
  ]) acceptedControllerModes;

  # Every file this module owns or adds a key to, built from
  # `emubox.emulators.configDirs` alone - never a literal emulator
  # configuration path of this module's own.
  dolphinIniFile = "${configDirs.dolphin}/Dolphin.ini";
  dolphinHotkeysFile = "${configDirs.dolphin}/Hotkeys.ini";
  dolphinGCPadFile = "${configDirs.dolphin}/GCPadNew.ini";
  dolphinWiimoteFile = "${configDirs.dolphin}/WiimoteNew.ini";
  pcsx2IniFile = "${configDirs.pcsx2}/PCSX2.ini";
  duckstationIniFile = "${configDirs.duckstation}/settings.ini";
  ppssppIniFile = "${configDirs.ppsspp}/ppsspp.ini";
  ppssppControlsFile = "${configDirs.ppsspp}/controls.ini";
  scummvmIniFile = "${configDirs.scummvm}/scummvm.ini";

  # Dolphin's route back binds the pad through its SDL backend, and every
  # `Device` line it writes is `SDL/<index>/<SDL device name>`
  # (`InputCommon/ControllerInterface/CoreDevice.cpp:188-197`) - no form
  # free of the pad's own name exists, and an absent or empty `Device`
  # leaves Dolphin's non-pad default device in place
  # (`ControllerEmu.cpp:117-119`). So the route back is declared only once
  # this fact holds a value; while it is null, `Hotkeys.ini` carries none of
  # its keys and nothing stands in their place. Every gameplay `Device`
  # line below waits on the same fact for the same reason, and takes every
  # other key in its own section down with it: a section Dolphin reads
  # applies no defaults of its own (`InputCommon/InputConfig.cpp:68-116`),
  # so a profile written with every key but `Device` would still leave the
  # pad unbound.
  dolphinSdlDeviceName = identity.sdlGamepadName;

  # Azahar's own SDL binding grammar carries the pad's GUID directly
  # (`src/input_common/sdl/sdl_impl.cpp:345-358,754-757`); an unmatched GUID
  # gives Azahar a placeholder joystick that never delivers input, so its
  # whole `[Controls]` section - the profile array and every binding under
  # it - waits on this fact the same way Dolphin's gameplay profiles wait on
  # `dolphinSdlDeviceName`.
  azaharGuid = identity.sdlJoystickGuid;
  azaharIniFile = "${configDirs.azahar}/qt-config.ini";

  # Dolphin's GC pad layout, upstream's own `Data/Sys/Profiles/GCPad/SDL
  # Gamepad.ini`, mirrored per player by substituting only the SDL index
  # `<i>` (0-3) into the writer-confirmed player-one spellings - the same
  # substitution Dolphin's own `Device` line already carries. Alphabetic-
  # only names are written bare, every other input name backticked
  # (`InputCommon/ControllerInterface/MappingCommon.cpp:51-56`).
  gcPadBindings = i: {
    Device = "SDL/${toString i}/${dolphinSdlDeviceName}";
    "Buttons/A" = "`Button S`";
    "Buttons/B" = "`Button E`";
    "Buttons/X" = "`Button W`";
    "Buttons/Y" = "`Button N`";
    "Buttons/Z" = "`Shoulder R`";
    "Buttons/Start" = "Start";
    "Main Stick/Up" = "`Left Y+`";
    "Main Stick/Down" = "`Left Y-`";
    "Main Stick/Left" = "`Left X-`";
    "Main Stick/Right" = "`Left X+`";
    "C-Stick/Up" = "`Right Y+`";
    "C-Stick/Down" = "`Right Y-`";
    "C-Stick/Left" = "`Right X-`";
    "C-Stick/Right" = "`Right X+`";
    "Triggers/L" = "`Trigger L`";
    "Triggers/R" = "`Trigger R`";
    "Triggers/L-Analog" = "`Trigger L`";
    "Triggers/R-Analog" = "`Trigger R`";
    "D-Pad/Up" = "`Pad N`";
    "D-Pad/Down" = "`Pad S`";
    "D-Pad/Left" = "`Pad W`";
    "D-Pad/Right" = "`Pad E`";
  };

  # Dolphin's Wii profile, laid out the same way: player one's
  # writer-confirmed spellings, index-substituted per further player, with
  # `Source` added from player two on - the setting that connects that
  # Wiimote's slot, since only player one's is connected by default
  # (`Core/Config/WiimoteSettings.cpp:10-19`; `Core/HW/Wiimote.h:47-52`).
  # `Extension = Nunchuk` rides in the same section and so the same
  # identity gate as the bindings it serves.
  wiimoteBindings =
    i:
    {
      Device = "SDL/${toString i}/${dolphinSdlDeviceName}";
      "Buttons/A" = "`Button S`";
      "Buttons/B" = "`Trigger R`";
      "Buttons/1" = "`Button W`";
      "Buttons/2" = "`Button N`";
      "Buttons/-" = "Back";
      "Buttons/+" = "Start";
      "Buttons/Home" = "Guide";
      "D-Pad/Up" = "`Pad N`";
      "D-Pad/Down" = "`Pad S`";
      "D-Pad/Left" = "`Pad W`";
      "D-Pad/Right" = "`Pad E`";
      "IR/Up" = "`Right Y+`";
      "IR/Down" = "`Right Y-`";
      "IR/Left" = "`Right X-`";
      "IR/Right" = "`Right X+`";
      "Shake/X" = "`Button E`";
      "Shake/Y" = "`Button E`";
      "Shake/Z" = "`Button E`";
      Extension = "Nunchuk";
      "Nunchuk/Buttons/C" = "`Shoulder L`";
      "Nunchuk/Buttons/Z" = "`Trigger L`";
      "Nunchuk/Stick/Up" = "`Left Y+`";
      "Nunchuk/Stick/Down" = "`Left Y-`";
      "Nunchuk/Stick/Left" = "`Left X-`";
      "Nunchuk/Stick/Right" = "`Left X+`";
      "Nunchuk/Shake/X" = "`Thumb L`";
      "Nunchuk/Shake/Y" = "`Thumb L`";
      "Nunchuk/Shake/Z" = "`Thumb L`";
    }
    // lib.optionalAttrs (i != 0) {
      Source = "1";
    };

  # PCSX2's own Controller Port > Automatic Mapping > SDL-<i> action wrote
  # these bindings for a freshly connected pad (`pcsx2/Input/SDLInputSource.cpp`);
  # kept as the pristine default set so a player never has to redo it, with
  # only the SDL device index substituted per player
  # (`pcsx2/Input/InputManager.cpp`, the player id PCSX2's own SDL source
  # assigns first-free in add order).
  pcsx2PadBindings = i: {
    Up = "SDL-${toString i}/DPadUp";
    Right = "SDL-${toString i}/DPadRight";
    Down = "SDL-${toString i}/DPadDown";
    Left = "SDL-${toString i}/DPadLeft";
    Triangle = "SDL-${toString i}/FaceNorth";
    Circle = "SDL-${toString i}/FaceEast";
    Cross = "SDL-${toString i}/FaceSouth";
    Square = "SDL-${toString i}/FaceWest";
    Select = "SDL-${toString i}/Back";
    Start = "SDL-${toString i}/Start";
    L1 = "SDL-${toString i}/LeftShoulder";
    L2 = "SDL-${toString i}/+LeftTrigger";
    R1 = "SDL-${toString i}/RightShoulder";
    R2 = "SDL-${toString i}/+RightTrigger";
    L3 = "SDL-${toString i}/LeftStick";
    R3 = "SDL-${toString i}/RightStick";
    Analog = "SDL-${toString i}/Guide";
    LUp = "SDL-${toString i}/-LeftY";
    LRight = "SDL-${toString i}/+LeftX";
    LDown = "SDL-${toString i}/+LeftY";
    LLeft = "SDL-${toString i}/-LeftX";
    RUp = "SDL-${toString i}/-RightY";
    RRight = "SDL-${toString i}/+RightX";
    RDown = "SDL-${toString i}/+RightY";
    RLeft = "SDL-${toString i}/-RightX";
    LargeMotor = "SDL-${toString i}/LargeMotor";
    SmallMotor = "SDL-${toString i}/SmallMotor";
  };

  # DuckStation's own Controller Port > Automatic Mapping > SDL-<i> action,
  # the same shape as PCSX2's above but with DuckStation's own face-button
  # names (`src/util/input_manager.cpp`).
  duckstationPadBindings = i: {
    Up = "SDL-${toString i}/DPadUp";
    Right = "SDL-${toString i}/DPadRight";
    Down = "SDL-${toString i}/DPadDown";
    Left = "SDL-${toString i}/DPadLeft";
    Triangle = "SDL-${toString i}/Y";
    Circle = "SDL-${toString i}/B";
    Cross = "SDL-${toString i}/A";
    Square = "SDL-${toString i}/X";
    Select = "SDL-${toString i}/Back";
    Start = "SDL-${toString i}/Start";
    L1 = "SDL-${toString i}/LeftShoulder";
    L2 = "SDL-${toString i}/+LeftTrigger";
    R1 = "SDL-${toString i}/RightShoulder";
    R2 = "SDL-${toString i}/+RightTrigger";
    L3 = "SDL-${toString i}/LeftStick";
    R3 = "SDL-${toString i}/RightStick";
    Analog = "SDL-${toString i}/Guide";
    LUp = "SDL-${toString i}/-LeftY";
    LRight = "SDL-${toString i}/+LeftX";
    LDown = "SDL-${toString i}/+LeftY";
    LLeft = "SDL-${toString i}/-LeftX";
    RUp = "SDL-${toString i}/-RightY";
    RRight = "SDL-${toString i}/+RightX";
    RDown = "SDL-${toString i}/+RightY";
    RLeft = "SDL-${toString i}/-RightX";
    LargeMotor = "SDL-${toString i}/LargeMotor";
    SmallMotor = "SDL-${toString i}/SmallMotor";
  };

  # Azahar's SDL binding grammars, each carrying the pad's own GUID
  # (`src/input_common/sdl/sdl_impl.cpp`); keys are written sorted by
  # Azahar's own `ParamPackage` (`param_package.h:16`), reproduced here in
  # that order for the same reason the value spellings below are copied
  # verbatim rather than reformatted.
  azaharButtonValue = n: ''"button:${toString n},engine:sdl,guid:${azaharGuid},port:0"'';
  azaharHatValue = dir: ''"direction:${dir},engine:sdl,guid:${azaharGuid},hat:0,port:0"'';
  azaharAxisButtonValue =
    axis: ''"axis:${toString axis},direction:+,engine:sdl,guid:${azaharGuid},port:0,threshold:0.5"'';
  azaharAnalogValue =
    x: y:
    ''"axis_x:${toString x},axis_y:${toString y},deadzone:0.100000,engine:sdl,guid:${azaharGuid},port:0"'';

  # Azahar's own raw button, hat and axis indices, declared statically:
  # they follow from xpad's `XTYPE_XBOX360` capability set (`xpad.c:157`,
  # cited at Linux 6.18.47) and SDL's own Linux enumeration order
  # (`src/joystick/linux/SDL_sysjoystick.c:1244-1310`), not from the pad's
  # identity, so they need no bring-up capture - only the GUID above does.
  # `b1` A, `b0` B, `b3` X, `b2` Y, `b4` L, `b5` R, `b6` Select, `b7` Start,
  # `b8` Home, `a2` ZL, `a5` ZR, hat0 the D-pad, `a0`/`a1` the circle pad,
  # `a3`/`a4` the C-stick.
  azaharBindings = {
    button_a = azaharButtonValue 1;
    button_b = azaharButtonValue 0;
    button_x = azaharButtonValue 3;
    button_y = azaharButtonValue 2;
    button_up = azaharHatValue "up";
    button_down = azaharHatValue "down";
    button_left = azaharHatValue "left";
    button_right = azaharHatValue "right";
    button_l = azaharButtonValue 4;
    button_r = azaharButtonValue 5;
    button_start = azaharButtonValue 7;
    button_select = azaharButtonValue 6;
    button_zl = azaharAxisButtonValue 2;
    button_zr = azaharAxisButtonValue 5;
    button_home = azaharButtonValue 8;
    circle_pad = azaharAnalogValue 0 1;
    c_stick = azaharAnalogValue 3 4;
  };
in
{
  # /dev/input/emubox-pN from each port's ID_PATH; rules apply on hotplug.
  services.udev.extraRules = lib.concatImapStringsSep "\n" (
    i: path:
    ''SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_JOYSTICK}=="1", ENV{ID_PATH}=="${path}", SYMLINK+="input/emubox-p${toString i}"''
  ) ports;

  # Tells every emulator that enumerates controllers through the system's
  # game controller library to list the recorded ports first, in order,
  # before its own general scan (SDL3's SDL_HINT_JOYSTICK_DEVICE, read
  # through the session environment). Declared only when a port is
  # recorded: an empty hint is still a hint, and SDL would parse it, try to
  # open the empty path and discard it, which is not the same as declaring
  # no enumeration order at all.
  #
  # RetroArch reaches controllers through its own `udev` joypad driver
  # instead (`configuration.c:672-720,1240-1297`; `HAVE_UDEV=auto`,
  # `qb/config.params.sh:56`; udev linked at
  # `retroarch-bare/package.nix:99-113`; confirmed at the pinned build,
  # `[Input] Found joypad driver: "udev"`). That driver fills ports in
  # udev's own enumeration order, and on hotplug in arrival order
  # (`input/drivers_joypad/udev_joypad.c:347`), and never reads this hint at
  # all - so the recorded port order above is not promised for RetroArch,
  # the one input interface among every emulator this flake configures that
  # is not the system's own game controller library. This change gives
  # RetroArch no further controller configuration of its own.
  environment.sessionVariables = lib.mkIf (ports != [ ]) {
    SDL_JOYSTICK_DEVICE = lib.concatImapStringsSep ":" (i: _: "/dev/input/emubox-p${toString i}") ports;
  };

  # TODO: hotkeys, the "Pair a controller" discoverable window.
  hardware.xpadneo.enable = true;
  hardware.bluetooth.settings.General = {
    ClassicBondedOnly = false;
  };

  environment.systemPackages = [
    # `sdl2-jstest --list`, run over SSH at bring-up
    # (`sudo env SDL_VIDEODRIVER=dummy sdl2-jstest --list`), is what
    # captures the two `emubox.facts.controllerIdentities` values every
    # binding below depends on - the SDL device name and, for a later
    # change, the SDL joystick GUID.
    pkgs.sdl-jstest
  ];

  # Lists which recorded ports resolve to a connected pad and warns about
  # any controller identifying as none of the accepted modes above,
  # wherever it is attached. An empty slot, and a box with no ports
  # recorded at all, are both information rather than a finding: the
  # report is registered unconditionally, and stays healthy either way.
  emubox.status.reporters = [
    {
      name = "controllers";
      command = controllersStatusCommand;
    }
  ];

  # Every standalone emulator but Azahar gets an owned route back here: a
  # pad-bindable action that ends the emulator's process under the
  # frontend's own launch command, its exit-confirmation suppressed, and
  # every setting that binding depends on to reach a pad at all. Azahar has
  # no pad-bindable exit at the pinned version (it persists a hotkey as a
  # key sequence and a context alone, never a controller input), so it gets
  # no entry here and no `confirmClose` key.
  #
  # A leaf this module and `modules/emulators` both set would conflict and
  # fail evaluation, so every key added to a file that module already owns
  # (`Dolphin.ini`, `PCSX2.ini`, DuckStation's `settings.ini`, `ppsspp.ini`,
  # `scummvm.ini`) is one neither table already declares; the module
  # system's own attrset merge is what lets the two modules' contributions
  # to the same file coexist.
  emubox.kiosk.ownedFiles = {
    "${dolphinIniFile}" = {
      format = "ini";
      enforce = {
        # Interface.ConfirmStop: Dolphin-Emulator/dolphin
        # Core/HotkeyManager.cpp (`HK_STOP`) emits the hotkey
        # `MainWindow::RequestStop` handles; it asks for confirmation first
        # whenever this key is set, the default
        # (`Core/Config/MainSettings.cpp:436`;
        # `DolphinQt/MainWindow.cpp:930-1049,998-1000`). False is what
        # suppresses that question; it is the one Dolphin key this route
        # back needs that does not wait on the pad's identity.
        Interface.ConfirmStop = "False";
      }
      // lib.optionalAttrs (dolphinSdlDeviceName != null) {
        Core = {
          # Core.SIDevice1-3: Dolphin-Emulator/dolphin
          # Core/Config/MainSettings.cpp:168-178 and Core/HW/SI/SI_Device.h:87-105
          # - GameCube controller ports 2-4 default disconnected (`6`,
          # `SIDEVICE_NONE`); `6` is `SIDEVICE_GC_CONTROLLER`, the same
          # value port 1 already defaults to. Connects the slot each
          # further player's `GCPadNew.ini` profile below binds; withheld
          # with those profiles until the pad's identity is recorded, since
          # a connected but unbound port is no better than a disconnected
          # one.
          SIDevice1 = "6";
          SIDevice2 = "6";
          SIDevice3 = "6";
        };
      };
    };

    # New to the editor: Dolphin writes this file, and only this file,
    # through its Hotkey Settings dialog, and only once that dialog is
    # used to bind a hotkey - a fresh box otherwise never gets one at all
    # (`Core/HotkeyManager.cpp:395-476`).
    "${dolphinHotkeysFile}" = {
      format = "ini";
      enforce = lib.optionalAttrs (dolphinSdlDeviceName != null) {
        Hotkeys = {
          # [Hotkeys] Device: every Dolphin hotkey resolves against this
          # section's own default device
          # (`InputCommon/ControllerEmu/ControllerEmu.cpp:113-122`), so the
          # route back binds the pad only once this line names it. Bound
          # to `SDL/0` alone - the first-enumerated pad - since a second
          # uinput node cannot be probed on this project's own hardware
          # rig, and ordering between two physical pads is therefore left
          # to bring-up rather than assumed here.
          Device = "SDL/0/${dolphinSdlDeviceName}";
          # General/Stop = HK_STOP, bound by pressing the fixture's Back
          # and Start within Dolphin's own 50 ms chord window
          # (`InputCommon/ControllerInterface/MappingCommon.cpp:28,101-113`).
          # Alphabetic input names are written bare by Dolphin's own writer
          # (`MappingCommon.cpp:51-56`), so `Back&Start` - not
          # `` `Back` & `Start` `` - is this key's own spelling.
          "General/Stop" = "Back&Start";
        };
      };
    };

    # New to the editor, and owned on the same rule as `GCPadNew.ini`
    # below: the frontend launches the Wii system through Dolphin too, and
    # a file the editor creates holds only the keys it owns, so leaving
    # this file unregistered would leave Wii with no owned route back at
    # all even though `Hotkeys.ini` above is shared between both systems.
    # No route-back key of its own - that lives entirely in `Hotkeys.ini` -
    # but every Wii Remote's complete gameplay profile, one section per
    # player up to the system's native four, each withheld until the pad's
    # identity is recorded for the same reason `Hotkeys.ini` withholds its
    # own keys: an absent or empty `Device` leaves Dolphin's non-pad
    # default device in place rather than binding nothing
    # (`InputCommon/ControllerEmu/ControllerEmu.cpp:117-119`), and a
    # section without one still reads as bound to that non-pad default.
    "${dolphinWiimoteFile}" = {
      format = "ini";
      enforce = lib.optionalAttrs (dolphinSdlDeviceName != null) (
        lib.listToAttrs (
          map
            (n: {
              name = "Wiimote${toString n}";
              value = wiimoteBindings (n - 1);
            })
            [
              1
              2
              3
              4
            ]
        )
      );
    };

    # New to the editor, registered for the same reason `WiimoteNew.ini`
    # above is: Dolphin's `GCPad<N>` sections hold no route-back key of
    # their own either, only every GameCube pad's complete gameplay
    # profile, one section per player up to the system's native four, each
    # withheld with `WiimoteNew.ini`'s own profiles until the pad's
    # identity is recorded.
    "${dolphinGCPadFile}" = {
      format = "ini";
      enforce = lib.optionalAttrs (dolphinSdlDeviceName != null) (
        lib.listToAttrs (
          map
            (n: {
              name = "GCPad${toString n}";
              value = gcPadBindings (n - 1);
            })
            [
              1
              2
              3
              4
            ]
        )
      );
    };

    # New to the editor: Azahar's own `[Controls]` section - the profile
    # array's count and active index, and every gameplay binding under
    # `profiles\1\` - waits on the pad's GUID for the same reason Dolphin's
    # gameplay profiles wait on its own identity fact: every SDL binding
    # value carries the GUID directly, and an unmatched one gives a
    # placeholder joystick that never delivers input
    # (`src/input_common/sdl/sdl_impl.cpp:345-358,754-757`). Already owned
    # by `modules/emulators` for its own, identity-free `[UI]` keys; this
    # module's own `[Controls]` keys sit in the same file, merged by the
    # module system rather than declared twice.
    "${azaharIniFile}" = {
      format = "ini";
      enforce = lib.optionalAttrs (azaharGuid != null) {
        Controls = {
          # profiles\size: azahar-emu/azahar src/citra_qt/configuration/config.cpp,
          # `QtConfig::ReadControlValues` reads the profile array whose
          # length this key gives, and its writer emits no `\default`
          # companion for it (unlike every key below).
          "profiles\\size" = "1";
          # profile / profile\default: the active profile index, and the
          # backslashed QSettings companion every Azahar-initiated save
          # writes beside a key it owns (`config.cpp:189-212`,
          # `1442-1450`). Azahar's own writer sets `profile\default=true`
          # whenever the index is 0, on every save - harmless, since both
          # the literal and the compiled default read as index 0, and
          # corrected back to `false` the next time this editor runs.
          profile = "0";
          "profile\\default" = "false";
        }
        // lib.mapAttrs' (key: value: lib.nameValuePair "profiles\\1\\${key}" value) azaharBindings
        // lib.mapAttrs' (key: _: lib.nameValuePair "profiles\\1\\${key}\\default" "false") azaharBindings;
      };
    };

    "${pcsx2IniFile}" = {
      format = "ini";
      enforce = {
        # InputSources.SDL: PCSX2/pcsx2 pcsx2/Input/SDLInputSource.cpp -
        # every `SDL-<n>/...` binding, route back and gameplay alike, reads
        # nothing at all unless this input source is enabled. True is
        # PCSX2's own fresh-file default, pinned here so a route back never
        # depends on a player having left it alone.
        InputSources.SDL = "true";
        # UI.ConfirmShutdown: PCSX2/pcsx2 pcsx2-qt/MainWindow.cpp
        # (v2.6.3), the default true asks before `ShutdownVM` below takes
        # effect. False lets the bound chord return to the frontend with
        # no prompt in between, and `-batch` (the frontend's own launch
        # command) quits PCSX2 once the shutdown completes
        # (`MainWindow.cpp:2184-2189`).
        UI.ConfirmShutdown = "false";
        # Hotkeys.ShutdownVM: PCSX2/pcsx2 pcsx2/Hotkeys.cpp:233-237,
        # `Host::RequestVMShutdown`. Bound by pressing the fixture's Back
        # then Start; PCSX2's own binding widget commits each key as it
        # crosses its press threshold and joins them with `` & ``
        # (`pcsx2-qt/Settings/InputBindingWidget.cpp:338-389`;
        # `pcsx2/Input/InputManager.cpp:378-402`). Free of the pad's own
        # identity: PCSX2 names an SDL input by its enumeration index
        # alone.
        Hotkeys.ShutdownVM = "SDL-0/Back & SDL-0/Start";
      };
      # Seeded, not enforced: PCSX2 names an SDL input by its enumeration
      # index alone, so none of this depends on the pad's identity, and a
      # player who rebinds a control through PCSX2's own settings keeps
      # that choice across a reboot.
      seed = {
        # Pad1.Type: PCSX2/pcsx2 (v2.6.3) already falls back to
        # `DualShock2` for port one, so this pins the same value the
        # emulator's own fresh-file default already carries.
        Pad1 = pcsx2PadBindings 0 // {
          Type = "DualShock2";
        };
        # Pad2.Type: PCSX2's own fresh-file default is `None`, which reads
        # nothing at all through `[Pad2]`'s bindings below - the setting
        # that connects player two's slot.
        Pad2 = pcsx2PadBindings 1 // {
          Type = "DualShock2";
        };
      };
    };

    "${duckstationIniFile}" = {
      format = "ini";
      enforce = {
        # InputSources.SDL: stenzek/duckstation src/util/input_manager.cpp
        # - the same gate PCSX2's own `[InputSources] SDL` key is, for the
        # same reason: no `SDL-<n>/...` binding reads at all without it.
        InputSources.SDL = "true";
        # Main.ConfirmPowerOff: stenzek/duckstation
        # src/duckstation-qt/mainwindow.cpp:3133-3134 (default true from
        # `settings.cpp:277`) gates `PowerOff` below the same way PCSX2's
        # `ConfirmShutdown` gates `ShutdownVM`. `-batch` quits once the
        # shutdown completes (`mainwindow.cpp:3184-3189`).
        Main.ConfirmPowerOff = "false";
        # Hotkeys.PowerOff: stenzek/duckstation src/core/hotkeys.cpp:202-206,
        # `Host::RequestSystemShutdown`. Bound the same way PCSX2's
        # `ShutdownVM` was: Back then Start, joined with `` & `` by
        # DuckStation's own binding widget
        # (`duckstation-qt/inputbindingwidgets.cpp:407-461`;
        # `util/input_manager.cpp:481-493`), free of the pad's identity for
        # the same reason.
        Hotkeys.PowerOff = "SDL-0/Back & SDL-0/Start";
      };
      # Seeded, not enforced, for the same reason PCSX2's own gameplay
      # bindings are: free of the pad's identity, and left alone once a
      # player rebinds a control through DuckStation's own settings.
      seed = {
        Pad1 = duckstationPadBindings 0;
        # Pad2.Type: DuckStation's own fresh-file default is `None`, which
        # reads nothing at all through `[Pad2]`'s bindings below - the
        # setting that connects player two's slot.
        Pad2 = duckstationPadBindings 1 // {
          Type = "AnalogController";
        };
      };
    };

    # Already owned by `modules/emulators`; this module adds only the
    # setting its own route back depends on.
    "${ppssppIniFile}" = {
      format = "ini";
      enforce = {
        # General.AskForExitConfirmationAfterSeconds: hrydgard/ppsspp
        # UI/PauseScreen.cpp:825-858 asks before the pause menu's Exit
        # (below) takes effect, after this many seconds of unsaved play;
        # the default is 300. Zero suppresses it outright, so the route
        # back never depends on how long a session has run. The one
        # confirmation left unowned - the same source's networked-session
        # question - is a deliberate, settled exception: it protects a
        # multiplayer session's other participants from one pad's exit,
        # which this key's own five-minute grace period does not.
        General.AskForExitConfirmationAfterSeconds = "0";
      };
    };

    # New to the editor: `controls.ini` is PPSSPP's own control-mapping
    # file, generated fresh at every start and distinct from `ppsspp.ini`
    # above, whose defaults never bind the mappings this file's loader
    # drops when they are absent (hrydgard/ppsspp Core/KeyMap.cpp:818-852).
    "${ppssppControlsFile}" = {
      format = "ini";
      enforce = {
        # ControlMapping.Pause: hrydgard/ppsspp opens the pause menu, whose
        # last entry - once `pspOverride`'s `--pause-menu-exit` flag is
        # passed (`modules/emulators`) - is Exit, ending the process
        # (`UI/PauseScreen.cpp:687-693,861-884`; `UI/NativeApp.cpp:576-577`).
        # `Pause = 10-196:10-197` is a chord of PPSSPP's own device-10
        # (pad) key codes for Back and Start; `--escape-exit` was
        # considered and rejected, since it only matches a single mapping,
        # never a chord (`Core/KeyMap.cpp:601-614`).
        ControlMapping.Pause = "10-196:10-197";
      };
      # Seeded: PPSSPP's own loader drops every mapping this file omits
      # (`Core/KeyMap.cpp:818-852`), so this is the complete gameplay set a
      # pristine install would have produced for the PSP's single native
      # player, free of the pad's identity - PPSSPP names a pad input by a
      # fixed keycode, not by the device it came from. `L`, `R`'s and
      # `Pause`'s own device-10 key codes rest on PPSSPP's own fixed
      # keycode switch; `Pause` above is confirmed by round trip, and `L`,
      # `R` share its device-10 numbering.
      seed = {
        ControlMapping = {
          Up = "10-19";
          Down = "10-20";
          Left = "10-21";
          Right = "10-22";
          Cross = "10-189";
          Circle = "10-190";
          Square = "10-191";
          Triangle = "10-188";
          Start = "10-197";
          Select = "10-196";
          L = "10-193";
          R = "10-192";
          "An.Up" = "10-4003";
          "An.Down" = "10-4002";
          "An.Left" = "10-4001";
          "An.Right" = "10-4000";
        };
      };
    };

    # Already owned by `modules/emulators`; this module adds the joystick
    # index every binding opens through and the combined route back: Guide
    # quits directly, and Start plus the virtual mouse and GUI interact
    # action reach the Global Main Menu's own Quit.
    "${scummvmIniFile}" = {
      format = "ini";
      enforce = {
        # scummvm.joystick_num: scummvm/scummvm
        # backends/events/sdl/sdl2-events.cpp:75-102,932-944 opens this
        # index as a GameController; 0 is the first SDL-enumerated pad, and
        # ScummVM's own writer keeps this key rather than dropping it as an
        # unowned default.
        scummvm.joystick_num = "0";
        keymapper = {
          # keymap_global_QUIT: scummvm/scummvm
          # backends/keymapper/keymap.cpp (`Keymap::loadMappings`, around
          # line 282) composes a config key as `keymap_<keymap
          # id>_<action id>`; `global`/`QUIT` is the global keymap's own
          # quit action, which is otherwise bound only to `C+q` on POSIX
          # (`backends/events/default/default-events.cpp:357-378`) - no
          # gamepad input at all without this key. Guide ends the process
          # directly in every engine but four (made, hugo, freescape,
          # grim), whose own keymaps take Guide for a menu action instead;
          # in each of those four, Start still reaches the Global Main
          # Menu's Quit below, and no engine takes both, so a pad always
          # has one working route back. crab, tot and ultima/nuvie also
          # switch the whole keymapper off during certain input states
          # (a key-binding menu, or scripted/event input), in which neither
          # route works until the engine re-enables it.
          keymap_global_QUIT = "JOY_GUIDE";
          # keymap_global_MENU: the same composition, for the global
          # keymap's own `MENU` action, which opens the Global Main Menu
          # (`default-events.cpp:332-339`). Bound to Start alone, not the
          # upstream default `C+F5 JOY_START`: ScummVM's own writer erases
          # any mapping equal to that compiled default rather than
          # persisting it (confirmed against the writer-produced file), so
          # the compound spelling would not survive a save.
          keymap_global_MENU = "JOY_START";
          # A pad reaches the Global Main Menu's own Quit button through
          # the GUI's virtual mouse and its interact action, not by D-pad
          # focus - `gui/gui-manager.cpp:159-194` binds D-pad focus to
          # navigation, not activation. The virtual mouse's own default
          # bindings (`backends/keymapper/virtual-mouse.cpp:157-177`) and
          # the GUI keymap's own interact binding
          # (`gui-manager.cpp:164-194`) already cover this pad, so these
          # four keys and `keymap_gui_INTRCT` below hold ScummVM's own
          # compiled defaults, spelled out here only because its writer
          # erases a value equal to its default on every save - exactly as
          # `keymap_global_MENU` above does - and the editor would
          # otherwise rewrite them back in at the next frontend start
          # regardless, which is harmless but worth pinning explicitly
          # rather than leaving to that rewrite.
          keymap_global_VMOUSEUP = "JOY_LEFT_STICK_Y-";
          keymap_global_VMOUSEDOWN = "JOY_LEFT_STICK_Y+";
          keymap_global_VMOUSELEFT = "JOY_LEFT_STICK_X-";
          keymap_global_VMOUSERIGHT = "JOY_LEFT_STICK_X+";
          keymap_gui_INTRCT = "JOY_A";
        };
      };
    };
  };
}
