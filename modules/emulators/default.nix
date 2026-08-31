# Design section 6: RetroArch cores for everything through the disc
# generations, standalone only where the core is weak or absent.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.emubox.retroachievements;

  # `players`'s home, read from the same option modules/kiosk sets rather
  # than repeated here, so a future change to it cannot silently desync one
  # module's config paths from the other's.
  playerHome = config.users.users.player.home;

  # Config file paths, verified against each emulator's own source at the
  # pinned nixpkgs revision this flake locks (and, for DuckStation, the
  # pinned upstream AppImage source - see pkgs/duckstation) on 2026-08-30.
  # Every one of them takes the XDG basedir branch on a fresh kiosk home
  # with no `XDG_*` override and no legacy dotfile/dotdir already present -
  # true on this appliance, whose home is created empty by `createHome`
  # every time the disk is laid down (modules/kiosk). None of these programs
  # is run in portable mode: that would need a marker file
  # (`portable.txt`/`portable.ini`) sitting beside the binary in the Nix
  # store, which none of these derivations puts there.
  retroarchConfigFile = "${playerHome}/.config/retroarch/retroarch.cfg";
  dolphinConfigFile = "${playerHome}/.config/dolphin-emu/Dolphin.ini";
  # Dolphin keeps its RetroAchievements settings in a *second* ini beside
  # Dolphin.ini, not inside it (Core/Config/AchievementSettings.cpp reads
  # and writes a config layer scoped to this file's own name) - both files
  # need their own `format` entry in ownedFiles below.
  dolphinAchievementsFile = "${playerHome}/.config/dolphin-emu/RetroAchievements.ini";
  pcsx2ConfigFile = "${playerHome}/.config/PCSX2/inis/PCSX2.ini";
  # PCSX2 keeps the RA token only here, in a second file, never in
  # PCSX2.ini itself (Achievements.cpp's SetSecretsSettingsLayer) - both
  # files share the literal section name `Achievements`.
  pcsx2SecretsFile = "${playerHome}/.config/PCSX2/inis/secrets.ini";
  ppssppConfigFile = "${playerHome}/.config/ppsspp/PSP/SYSTEM/ppsspp.ini";
  # Not in `ownedFiles`: this holds the RA token as raw bytes with no
  # `key=value` framing at all, so none of prepare's file-format editors
  # can touch it. See the `ppsspp` entry in `raEmulators` below.
  ppssppTokenFile = "${playerHome}/.config/ppsspp/PSP/SYSTEM/ppsspp_retroachievements.dat";
  azaharConfigFile = "${playerHome}/.config/azahar-emu/qt-config.ini";
  # DuckStation is the one emulator here whose data root is NOT under
  # `.config`: `Core::SetDataRoot` falls back to a *hardcoded*
  # `$HOME/.local/share/duckstation` on Linux when `XDG_CONFIG_HOME` is
  # unset - it never consults `XDG_DATA_HOME` at all, a genuine quirk of
  # this emulator's own source (src/core/core.cpp), not a typo here.
  #
  # Portable-mode verdict, checked against the actual built extraction of
  # this flake's pinned AppImage (pkgs/duckstation), not just the source
  # logic: `appimageTools.wrapType2`'s FHS wrapper execs `AppRun` directly
  # and never sets `APPIMAGE` on that path, so DuckStation's own
  # `IsRunningInPortableMode()` check (`AppRoot == DataRoot`) sees its
  # read-only Nix store extraction as `AppRoot` and this home-relative path
  # as `DataRoot` - they differ, so portable mode is off and the machine-id
  # key stays in the token derivation, exactly as design D3 assumes. A
  # future DuckStation bump could change this wrapper's behaviour; if it
  # ever starts setting `APPIMAGE`, or nixpkgs switches this package off
  # `wrapType2`, this verdict needs rechecking before the bump lands.
  duckstationConfigFile = "${playerHome}/.local/share/duckstation/settings.ini";
  scummvmConfigFile = "${playerHome}/.config/scummvm/scummvm.ini";

  # DuckStation's token encryption keys off the raw bytes of this file
  # (design D3); it is not under the appdata root because E1 already keeps
  # it stable across the root wipe on its own, so a second copy here would
  # just be another place for the same fact to drift.
  machineIdFile = "/etc/machine-id";

  # The flake's own cores bundle - the one source `libretro_directory`
  # below is allowed to name (spec: "the flake's packaged cores and no
  # other source"). Every `libretro-*` core derivation installs its .so
  # into `$out/lib/retroarch/cores` by default (mkLibretroCore.nix); with
  # no cores of its own, `symlinkJoin` folds every core named here plus
  # retroarch-bare into one `$out`, so this literal subpath is where all of
  # them land together - not a path this module invents.
  retroarchWithCores = pkgs.retroarch.withCores (
    cores: with cores; [
      stella
      prosystem
      handy
      mesen
      snes9x
      mupen64plus
      gambatte
      mgba
      beetle-vb
      beetle-wswan
      beetle-ngp
      genesis-plus-gx
      picodrive
      beetle-saturn
      flycast
      beetle-psx-hw
      beetle-pce-fast
      beetle-supergrafx
      fbneo
      melonds
      dosbox-pure
      puae
      vice-x64
      bluemsx
      vecx
      freeintv
    ]
  );
  coresDirectory = "${retroarchWithCores}/lib/retroarch/cores";

  # RetroAchievements' per-emulator tables (design D1-D4). One attrset per
  # supporting emulator, each shaped exactly as `emubox-prepare`'s
  # `retroachievements.targets[]` entries (design D1) minus the `name`
  # field, which `retroachievementsNamespace` below adds when it renders
  # the enabled JSON. The same attrset also drives the disabled fallback in
  # `raDisabledFiles`, which is what keeps every key spelling here typed
  # exactly once rather than twice and liable to drift apart. Azahar and
  # ScummVM have no entry: exhaustive source greps for every RA-related
  # identifier (`achievement`, `cheevos`, `rc_client`, `retroachiev`, ...)
  # across both trees, vendored dependencies included, found nothing.
  raEmulators = {
    # RetroArch logs in with a plaintext token straight from retroarch.cfg
    # (configuration.c:1596-1598) and never needs the password once one is
    # set; the same three keys are also called out together as a group
    # configuration.c excludes from per-game overrides (:5878-5883), a
    # second, independent confirmation of their exact spelling.
    retroarch = {
      encoding = "plain";
      booleans = {
        "true" = "true";
        "false" = "false";
      };
      keys = {
        enabled = {
          file = retroarchConfigFile;
          key = "cheevos_enable";
        };
        hardcore = {
          file = retroarchConfigFile;
          key = "cheevos_hardcore_mode_enable";
        };
        username = {
          file = retroarchConfigFile;
          key = "cheevos_username";
        };
        token = {
          file = retroarchConfigFile;
          key = "cheevos_token";
        };
      };
    };

    # Dolphin's token is plaintext at rest too - no encryption wraps the
    # write at AchievementManager.cpp:961 - and Dolphin never persists a
    # password at all, only ever the token a successful login yields
    # (AchievementSettings.cpp has no `Password` key).
    dolphin = {
      encoding = "plain";
      booleans = {
        "true" = "True";
        "false" = "False";
      };
      keys = {
        enabled = {
          file = dolphinAchievementsFile;
          section = "Achievements";
          key = "Enabled";
        };
        hardcore = {
          file = dolphinAchievementsFile;
          section = "Achievements";
          key = "HardcoreEnabled";
        };
        username = {
          file = dolphinAchievementsFile;
          section = "Achievements";
          key = "Username";
        };
        token = {
          file = dolphinAchievementsFile;
          section = "Achievements";
          key = "ApiToken";
        };
      };
    };

    # `ChallengeMode`, not `HardcoreMode`, is the on-disk key even though
    # the C++ field is named `HardcoreMode`
    # (`SettingsWrapBitBoolEx(HardcoreMode, "ChallengeMode")`,
    # Pcsx2Config.cpp:1879) - the field name is not the ini spelling here.
    pcsx2 = {
      encoding = "plain";
      booleans = {
        "true" = "true";
        "false" = "false";
      };
      keys = {
        enabled = {
          file = pcsx2ConfigFile;
          section = "Achievements";
          key = "Enabled";
        };
        hardcore = {
          file = pcsx2ConfigFile;
          section = "Achievements";
          key = "ChallengeMode";
        };
        username = {
          file = pcsx2ConfigFile;
          section = "Achievements";
          key = "Username";
        };
        token = {
          file = pcsx2SecretsFile;
          section = "Achievements";
          key = "Token";
        };
      };
    };

    # PPSSPP's ini has an `AchievementsToken` key, but it is a decoy for
    # login purposes: Core/Config.h documents it as unused by the real path,
    # and `TryLoginByToken` (Core/RetroAchievements.cpp) reads a *separate*
    # raw secret file instead (`NativeLoadSecret("retroachievements")`,
    # UI/NativeApp.cpp) holding the token's bare bytes with no `key=value`
    # framing at all. `encoding = "secret-file"` is what routes the token
    # through `token_file` below instead of an ini key; prepare's own
    # validation forbids a `token` entry under `keys` for this encoding, so
    # there is none here on purpose. Enabled/hardcore/username are ordinary
    # ini keys - only the token needs the raw file.
    ppsspp = {
      encoding = "secret-file";
      booleans = {
        "true" = "True";
        "false" = "False";
      };
      token_file = ppssppTokenFile;
      keys = {
        enabled = {
          file = ppssppConfigFile;
          section = "Achievements";
          key = "AchievementsEnable";
        };
        hardcore = {
          file = ppssppConfigFile;
          section = "Achievements";
          key = "AchievementsChallengeMode";
        };
        username = {
          file = ppssppConfigFile;
          section = "Achievements";
          key = "AchievementsUserName";
        };
      };
    };

    # The one target `emubox-prepare` cannot write as a plain string:
    # DuckStation's `Cheevos.Token` holds the login2 token AES-128-CBC
    # encrypted with a key and IV both derived from `/etc/machine-id` and
    # the account name (src/core/achievements.cpp, design D3), which is
    # what `encoding = "duckstation"` and `machine_id_file` exist for.
    # `ChallengeMode`, not `HardcoreMode`, mirrors PCSX2's same
    # field-vs-ini-key split (settings.cpp:530,881).
    duckstation = {
      encoding = "duckstation";
      booleans = {
        "true" = "true";
        "false" = "false";
      };
      machine_id_file = machineIdFile;
      keys = {
        enabled = {
          file = duckstationConfigFile;
          section = "Cheevos";
          key = "Enabled";
        };
        hardcore = {
          file = duckstationConfigFile;
          section = "Cheevos";
          key = "ChallengeMode";
        };
        username = {
          file = duckstationConfigFile;
          section = "Cheevos";
          key = "Username";
        };
        token = {
          file = duckstationConfigFile;
          section = "Cheevos";
          key = "Token";
        };
        login_timestamp = {
          file = duckstationConfigFile;
          section = "Cheevos";
          key = "LoginTimestamp";
        };
      };
    };
  };

  # The retroachievements spec's Disabled scenario ("each supporting
  # emulator's configuration has achievements disabled") with no dynamic
  # write ever happening, since a null `retroachievements` namespace means
  # `emubox-prepare` skips `apply_retroachievements` entirely: this module
  # has to put the off values there itself, statically, as ordinary owned
  # keys. Built from `raEmulators` above rather than a second copy of the
  # same key spellings - only `enabled` and `hardcore` are forced off; a
  # stale `username`/`token` is left alone, same as prepare's own behaviour
  # when a login simply does not resolve one.
  raDisabledFiles =
    let
      off =
        ra: keyDef:
        if keyDef ? section then
          { ${keyDef.file}.keys.${keyDef.section}.${keyDef.key} = ra.booleans."false"; }
        else
          { ${keyDef.file}.keys.${keyDef.key} = ra.booleans."false"; };
    in
    lib.foldl' (
      acc: ra:
      lib.recursiveUpdate (lib.recursiveUpdate acc (off ra ra.keys.enabled)) (off ra ra.keys.hardcore)
    ) { } (lib.attrValues raEmulators);
in
{
  options.emubox.retroachievements = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the box logs in to RetroAchievements and writes the
        session token into every supporting emulator's configuration
        before each launch of the frontend. Default true: the
        retroachievements spec's fresh-box scenario is that credentials in
        the secrets store and a working network unlock achievements with
        nobody touching a menu, which only holds if the feature does not
        also need to be switched on first.
      '';
    };

    hardcore = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        The single hardcore switch every supporting emulator's
        configuration follows (retroachievements spec, "Hardcore mode is
        one switch"). Off, the default, keeps save states, rewind and
        cheats available in every supporting emulator.
      '';
    };

    apiUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://retroachievements.org/dorequest.php";
      description = ''
        The RetroAchievements API endpoint `emubox-prepare` posts its
        `login2` request to. An option rather than a literal buried in
        this module, because design D2 has the VM test point prepare at a
        mock server here instead of patching the module to do it.
      '';
    };
  };

  config = {
    environment.systemPackages = [
      retroarchWithCores
      pkgs.ppsspp
      pkgs.dolphin-emu
      pkgs.pcsx2
      pkgs.azahar
      pkgs.scummvm
      pkgs.duckstation
    ];

    # The performance and hotkey tables (design D4) always apply; the
    # RetroAchievements keys only get folded in statically when the
    # feature is off (`raDisabledFiles`) - when it is on, prepare's own
    # `apply_retroachievements` writes them at runtime from
    # `retroachievementsNamespace` below, and this module never touches
    # them directly.
    emubox.kiosk.ownedFiles = lib.recursiveUpdate {
      "${retroarchConfigFile}" = {
        format = "retroarch";
        keys = {
          video_fullscreen = "true";
          libretro_directory = coresDirectory;
          # The literal "default" is magic in RetroArch's own parser and
          # gets cleared back to empty (configuration.c:4346-4347) - never
          # spell the BIOS directory that way.
          system_directory = "/data/bios";
          autosave_interval = "30";
          menu_driver = "ozone";
          # Both entries a family could otherwise use to pull unvetted
          # cores or content onto the box over the network - the "Online
          # Updater" submenu and the separate top-level "Core Downloader"
          # shortcut.
          menu_show_online_updater = "false";
          menu_show_core_updater = "false";
          # The uniform hotkey set (design's open question, settled here).
          # These are *keyboard* key-name strings - RetroArch's separate
          # per-pad `_btn` keys are written by autoconfig per controller,
          # which is epic E6's territory, not this change's, so none
          # appears here on purpose.
          input_menu_toggle = "f1";
          input_save_state = "f2";
          input_load_state = "f4";
          # The toggle variant, not `input_hold_fast_forward`: a
          # press-once switch is the right semantics for a couch box, and
          # RetroArch has no single key that means both.
          input_toggle_fast_forward = "space";
          input_screenshot = "f8";
          # The gamepad-combo counterparts, device-independent (no `_btn`
          # binding needed): RetroArch's `enum input_combo_type`
          # (input_defines.h) numbers `INPUT_COMBO_START_SELECT` as 4 -
          # `NONE`=0, `DOWN_Y_L_R`=1, `L3_R3`=2,
          # `L1_R1_START_SELECT`=3, `START_SELECT`=4, and on; both keys
          # are plain `SETTING_UINT`s against this same enum
          # (configuration.c). The desktop build's own default for both is
          # `INPUT_COMBO_NONE` (config.def.h:939,942) - with nothing
          # pinned here a player who entered a core would have no
          # controller-only way back to the frontend, which is exactly
          # the gap a quit combo exists to close.
          input_menu_toggle_gamepad_combo = "4";
          input_quit_gamepad_combo = "4";
        };
      };

      "${dolphinConfigFile}" = {
        format = "ini";
        keys = {
          Display.Fullscreen = "True";
          # "Wii dual core off": Dolphin's own writer emits `True`/`False`
          # capitalized (StringUtil.cpp:290-293); `CPUThread = False` is
          # dual core *off* - the UI's "Enable Dual Core" checkbox is this
          # same key inverted (DolphinQt/Settings/GeneralPane.cpp:144).
          Core.CPUThread = "False";
        };
      };
      # No performance keys of its own - see the comment on
      # `dolphinAchievementsFile` above for why this file exists at all.
      "${dolphinAchievementsFile}" = {
        format = "ini";
        keys = { };
      };

      "${pcsx2ConfigFile}" = {
        format = "ini";
        keys = {
          UI.StartFullscreen = "true";
          # Native internal resolution. PCSX2 serializes this float with
          # plain `ostringstream` formatting - the shortest decimal, `1`,
          # never `1.000000` - so this exact literal is what has to be
          # asserted, or every launch would see a spurious diff and rewrite
          # the file (Pcsx2Config.cpp:908,1021; INISettingsInterface.cpp).
          "EmuCore/GS".upscale_multiplier = "1";
        };
      };
      # No performance keys of its own - see the comment on
      # `pcsx2SecretsFile` above; only the RA token, when enabled, ever
      # lands here.
      "${pcsx2SecretsFile}" = {
        format = "ini";
        keys = { };
      };

      "${ppssppConfigFile}" = {
        format = "ini";
        keys = {
          Graphics.FullScreen = "True";
          # No suppressible splash or first-run dialog exists in PPSSPP's
          # source to own a "quiet-start" key for - `FirstRun` only gates a
          # one-line OSD toast, not a blocking dialog.
        };
      };

      "${azaharConfigFile}" = {
        format = "ini";
        # Every Azahar-initiated save also writes a sibling `<key>/default`
        # bool (config.cpp:189-212); on read, `<key>/default = true` makes
        # Azahar *ignore* the literal `key = ...` value and use its
        # compiled default instead (config.cpp:128-134). Forcing
        # `/default = false` alongside every key this module owns is what
        # keeps a value from silently reverting the first time Azahar
        # itself saves the file.
        keys = {
          UI = {
            fullscreen = "true";
            "fullscreen/default" = "false";
            # Suppresses the first-run welcome/setup flow.
            firstStart = "false";
            "firstStart/default" = "false";
          };
          Miscellaneous = {
            # A kiosk box should not have an emulator quietly phoning home
            # for its own updates at every launch.
            check_for_update_on_start = "false";
            "check_for_update_on_start/default" = "false";
          };
        };
      };

      "${duckstationConfigFile}" = {
        format = "ini";
        keys = {
          Main.StartFullscreen = "true";
          GPU = {
            # "PGXP geometry correction": `PGXPEnable` is the one setting
            # that key names in the design - `PGXPCulling` etc. are
            # distinct add-ons layered on top of it, not part of it.
            PGXPEnable = "true";
            # A 1080p-appropriate upscale: PS1 renders natively around
            # 320x240 (up to 512x480 in hi-res modes), and 4x lands around
            # 1280x960-2048x1920 - close to 1080p without wildly
            # overshooting it. Config data, not a source-verified fact;
            # revisit at the E12 hardware checklist if it disappoints.
            ResolutionScale = "4";
          };
        };
      };

      "${scummvmConfigFile}" = {
        format = "ini";
        keys = {
          scummvm = {
            fullscreen = "true";
            # Suppresses the "really quit?" confirmation dialog.
            confirm_exit = "false";
            # false is what makes quitting a game exit the process (and so
            # return control to the frontend) instead of bouncing back to
            # ScummVM's own launcher UI - the kiosk has no use for that
            # second launcher ever appearing.
            gui_return_to_launcher_at_exit = "false";
          };
        };
      };
    } (lib.optionalAttrs (!cfg.enable) raDisabledFiles);

    emubox.kiosk.retroachievementsNamespace =
      if cfg.enable then
        {
          api_url = cfg.apiUrl;
          username_file = config.sops.secrets.retroachievements_username.path;
          password_file = config.sops.secrets.retroachievements_password.path;
          # Relative, so it resolves under the appdata root (design D2: the
          # root wipe must not be able to eat it) rather than under `/data`
          # generally, which E5's backup design has not yet settled the
          # inclusion of.
          cache_file = "retroachievements/token-cache";
          inherit (cfg) hardcore;
          targets = lib.mapAttrsToList (name: ra: ra // { inherit name; }) raEmulators;
        }
      else
        null;
  };
}
