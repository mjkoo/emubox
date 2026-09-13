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
  # its keys and nothing stands in their place.
  dolphinSdlDeviceName = identity.sdlGamepadName;
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
    # No key of its own from this module: the route back lives entirely in
    # `Hotkeys.ini`.
    "${dolphinWiimoteFile}" = {
      format = "ini";
    };

    # New to the editor, registered for the same reason `WiimoteNew.ini`
    # above is: Dolphin's `GCPad<N>` sections hold no route-back key of
    # their own either, only gameplay bindings.
    "${dolphinGCPadFile}" = {
      format = "ini";
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
