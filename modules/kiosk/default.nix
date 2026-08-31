# Design section 5: SDDM autologin -> session loop -> cage -> ES-DE.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.emubox.kiosk;

  # The settings the flake owns, in the shape emubox-prepare reads: a file,
  # the format of that file, and the keys owned in it. A relative path
  # resolves under ESDE_APPDATA_DIR. Everything ES-DE writes that is not
  # named here is left exactly as the frontend last wrote it, which is what
  # lets a preference changed in its own menus survive a reboot.
  #
  # This module contributes only its own file, `settings/es_settings.xml`,
  # to `emubox.kiosk.ownedFiles` below; `modules/emulators` contributes every
  # emulator's config file to the same option (design D4,
  # emulators-retroachievements). The two merge through the module system's
  # ordinary attrset merging, which is why the option's type has to be one
  # that merges rather than a plain let-bound value.
  esdeString = value: {
    type = "string";
    inherit value;
  };

  # The empty string, not a store path to an empty file: the empty value is
  # what selects prepare's removal branch, so a path here would leave that
  # branch unreachable on the box as shipped (design D6).
  customSystemsPath =
    if cfg.customSystems == "" then "" else pkgs.writeText "emubox-es_systems.xml" cfg.customSystems;

  # The session loop. Runs as `player`; relaunches ES-DE if it exits, and
  # gives up at the greeter if it cannot keep it up (design D1).
  #
  # ESDE_APPDATA_DIR is exported once, above the loop, rather than prefixed
  # onto any single command: prepare and the frontend must read the same
  # value, and a per-command prefix is exactly the shape in which prepare
  # would assert settings into a directory the frontend never reads.
  #
  # cage is the one runtimeInput, so the compositor is pinned to the exact
  # store path this module was built against. emubox-prepare and es-de are
  # deliberately not: they resolve from the system path (they are in
  # environment.systemPackages below), so that the session and any outside
  # caller - the test driver, an admin who reached the greeter - reach one
  # binary rather than two that happen to agree.
  emubox-session = pkgs.writeShellApplication {
    name = "emubox-session";
    runtimeInputs = [ pkgs.cage ];
    text = ''
      export ESDE_APPDATA_DIR=${cfg.appdataDir}

      # Every way out of this script must exit 0, because SDDM shows a
      # greeter only for a session that ended cleanly - it reads exit 1 as
      # HELPER_AUTH_ERROR and then never starts one at all (the threshold
      # comment below carries the mechanism). That applies to the deliberate
      # give-up *and* to an unexpected failure under `set -e`: a bug here, or
      # the non-zero `emubox-prepare` that design D1 says should "stop at a
      # greeter the admin can log into", would otherwise leave the box on a
      # black screen with no way in - the opposite of what it promises. The
      # real status is logged before it is swallowed, so the journal keeps it.
      # A named function rather than the assignment inline in the trap
      # string, which shellcheck rejects as SC2154 (it cannot see a variable
      # assigned inside single quotes).
      report_clean_exit() {
        if [ "$1" -ne 0 ]; then
          echo "emubox-session: exiting $1; reporting a clean exit so SDDM shows the greeter" >&2
        fi
        exit 0
      }
      trap 'report_clean_exit $?' EXIT

      # A run shorter than the window counts as a crash; three in a row and
      # the session ends. SDDM's autoLogin.relogin is false, so what follows
      # is the greeter rather than an endless relaunch. EMUBOX_CRASH_WINDOW
      # is a test hook (tests/kiosk.nix lowers it); the box's figure is the
      # 60 s the kiosk spec states, and nothing in the product varies it.
      #
      # "Crash" is really "short run". ES-DE's own power-off exits the
      # frontend first and runs `shutdown` only afterwards, so choosing power
      # off from the menu increments this counter too. Harmless, since the
      # box is going down either way, but it is why the threshold is about
      # short runs rather than about crashes as such.
      window="''${EMUBOX_CRASH_WINDOW:-60}"
      # A non-numeric value would make `[ "$ran" -lt "$window" ]` fail, and
      # because that is an `if` condition `set -e` does not fire: every run
      # would silently count as long and the counter would never reach three.
      # Falling back loudly is the safe reading - the box stays up and the
      # journal says why the hook was ignored.
      case "$window" in
        "" | *[!0-9]*)
          echo "emubox-session: EMUBOX_CRASH_WINDOW=$window is not a number; using 60" >&2
          window=60
          ;;
      esac
      crashes=0

      while true; do
        mode=$(cat /run/emubox/mode 2>/dev/null || echo kiosk)
        # TODO(design 11, open question 1): desktop mode hands over to Plasma.
        if [ "$mode" = desktop ]; then
          exec startplasma-wayland
        fi

        # Not guarded: prepare's recreate policy already absorbs every
        # failure the box can produce, so a non-zero exit here is a bug in
        # prepare or an unwritable /data, and both should stop at a greeter
        # the admin can log into rather than loop invisibly (design D1).
        emubox-prepare ${cfg.ownedValuesFile} "${customSystemsPath}"

        # The loop needs the run's length, not its status, but the status is
        # captured rather than discarded with `|| true` so that `set -e` does
        # not end the session and the recovery epics still have it.
        started=$SECONDS
        rc=0
        cage -- es-de || rc=$?
        ran=$(( SECONDS - started ))
        # TODO(design 9): emubox-leakcheck

        if [ "$ran" -lt "$window" ]; then
          crashes=$(( crashes + 1 ))
          echo "emubox-session: es-de exited with $rc after ''${ran}s (crash $crashes of 3)" >&2
          if [ "$crashes" -ge 3 ]; then
            echo "emubox-session: three short runs in a row; ending the session" >&2
            # Exit 0, not 1, and this is load-bearing. SDDM casts the
            # helper's exit code straight to its HelperExitStatus enum
            # (src/auth/Auth.cpp), whose value 1 is HELPER_AUTH_ERROR - and
            # Display::slotHelperFinished is `if (status != HELPER_AUTH_ERROR)
            # stop()`, because SDDM refuses to restart the display after an
            # authentication failure so a bad password cannot loop the
            # greeter. A session exiting 1 therefore leaves the daemon alive
            # with no display and no greeter at all: a black screen, which is
            # the failure state this whole design exists to avoid. Exiting 0
            # is read as a session that ended normally, so the display is
            # stopped and recreated, and the new one shows the greeter
            # because `daemonApp->first` is already false. Proved in CI: with
            # `exit 1` the journal stops dead at "Auth: sddm-helper exited
            # with 1" and no greeter ever appears.
            exit 0
          fi
        else
          crashes=0
        fi
        sleep 2
      done
    '';
  };
  session = pkgs.writeTextDir "share/wayland-sessions/emubox.desktop" ''
    [Desktop Entry]
    Name=emubox
    Comment=Controller-driven game library
    Exec=${emubox-session}/bin/emubox-session
    Type=Application
  '';
in
{
  options.emubox.kiosk = {
    passkey = lib.mkOption {
      # ES-DE matches the sequence against `{up, down, left, right, a, b, x,
      # y}` on each entry's first character (UIModeController's mInputVals),
      # so these eight are the whole alphabet. Constrained rather than a bare
      # string because any other character silently yields a box whose full
      # menu cannot be unlocked by anything at all - a failure that would
      # surface only when the admin tried it, on hardware.
      type = lib.types.strMatching "[udlrabxy]+";
      default = "uuddlrlrba";
      description = ''
        The sequence that unlocks the frontend's full menu from kiosk mode,
        written with `u`, `d`, `l`, `r` for the directions and `a`, `b`, `x`,
        `y` for the face buttons. The default is ES-DE's own, so the box
        behaves as the frontend's documentation describes until the admin
        chooses another.
      '';
    };

    customSystems = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        The complete contents of an ES-DE custom `es_systems.xml`, the
        `<systemList>` wrapper included: it is written verbatim and no
        wrapper is added. Empty means no custom systems file exists, and a
        stale one left by an earlier configuration is removed before the
        frontend launches.
      '';
    };

    appdataDir = lib.mkOption {
      type = lib.types.path;
      default = "/data/es-de";
      readOnly = true;
      internal = true;
      description = ''
        Where the frontend keeps its application data, which is also what
        the session exports as ESDE_APPDATA_DIR. `modules/library`'s
        tmpfiles rules spell this same path; the two must agree, and
        `readOnly` is what keeps this end of it from drifting.
      '';
    };

    ownedFiles = lib.mkOption {
      # A submodule per file, not the looser `attrsOf (attrsOf anything)`:
      # a module that forgets `format` or misspells it as `"ini "` gets a
      # named-option eval error at the file and line that set it, rather
      # than a value that only fails once `emubox-prepare` reads the
      # rendered JSON on the box. The `keys` shape still varies by format
      # (esde-xml's `{name: {type, value}}`, ini's `{section: {key:
      # value}}`, retroarch's flat `{key: value}}`) and prepare, not this
      # module, is what enforces that shape - `anything` here is honest
      # about the limit of what Nix can usefully check.
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            format = lib.mkOption {
              type = lib.types.enum [
                "esde-xml"
                "ini"
                "retroarch"
              ];
              description = "The emubox-prepare editor this file's keys are written through.";
            };
            keys = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
              description = "The keys this file owns, shaped per `format` (see emubox-prepare).";
            };
          };
        }
      );
      default = { };
      internal = true;
      description = ''
        Every config file the flake owns a value in, keyed by that file's
        path (a relative path resolves under `appdataDir`, an absolute one
        is used as written - the same convention `emubox-prepare` uses
        throughout). `modules/kiosk` and `modules/emulators` each add their
        own entries here; the attrset merge across modules is the whole
        mechanism (design D4, emulators-retroachievements) - no module
        reads another's entries, they just both write into this one option.
      '';
    };

    retroachievementsNamespace = lib.mkOption {
      # A submodule, not the looser `attrsOf anything` this option used to
      # carry: that shape is exactly the failure mode `ownedFiles` above
      # was redesigned to prevent, and it was live here, not theoretical -
      # a deliberately malformed override applied through `extendModules`
      # did not conflict with this module's own definition, it silently
      # MERGED into it (an artifact of `types.anything`'s recursive merge),
      # and a namespace missing every required field still sailed through
      # `nix eval`. The only place it was ever caught was
      # `emubox-prepare` at boot, ending the session at a greeter - the
      # same class of failure `ownedFiles`'s own comment gives as the
      # reason for its submodule. `keys` inside each target stays
      # `attrsOf anything`, mirroring `ownedFiles.keys` for the same
      # reason that option gives: the shape already varies by encoding
      # (retroarch's flat keys carry no `section`; every ini-backed
      # emulator's do; duckstation's carries an extra `login_timestamp`
      # the others don't), and `emubox-prepare`, not this module, is what
      # enforces it (`_target_validation_error`).
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            api_url = lib.mkOption {
              type = lib.types.str;
              description = "The RetroAchievements API endpoint prepare posts its `login2` request to (design D2).";
            };
            username_file = lib.mkOption {
              type = lib.types.str;
              description = "Store path to the RetroAchievements account username secret.";
            };
            password_file = lib.mkOption {
              type = lib.types.str;
              description = "Store path to the RetroAchievements account password secret.";
            };
            cache_file = lib.mkOption {
              type = lib.types.str;
              description = "Where prepare caches the last resolved login token (design D2), relative to the appdata root.";
            };
            hardcore = lib.mkOption {
              type = lib.types.bool;
              description = "The single hardcore switch every target's own hardcore key follows (design D4).";
            };
            targets = lib.mkOption {
              type = lib.types.listOf (
                lib.types.submodule {
                  options = {
                    name = lib.mkOption {
                      type = lib.types.str;
                      description = "The supporting emulator this target writes into (design D1).";
                    };
                    encoding = lib.mkOption {
                      type = lib.types.enum [
                        "plain"
                        "duckstation"
                        "secret-file"
                      ];
                      description = "Which at-rest form this target's token takes - design D4's three encodings.";
                    };
                    booleans = lib.mkOption {
                      type = lib.types.submodule {
                        options = {
                          "true" = lib.mkOption {
                            type = lib.types.str;
                            description = "The literal this emulator's own config file spells its boolean true as.";
                          };
                          "false" = lib.mkOption {
                            type = lib.types.str;
                            description = "The literal this emulator's own config file spells its boolean false as.";
                          };
                        };
                      };
                      description = "This target's own true/false spelling - not every supporting emulator agrees (design D4).";
                    };
                    keys = lib.mkOption {
                      type = lib.types.attrsOf lib.types.anything;
                      default = { };
                      description = "The enabled/hardcore/username/[token] key entries this target writes, shaped per its file's format (see emubox-prepare).";
                    };
                    token_file = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      description = "The secret-file encoding's whole-file token path (PPSSPP only); unset for every other encoding.";
                    };
                    machine_id_file = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      description = "The duckstation encoding's machine-id source path (design D3); unset for every other encoding.";
                    };
                  };
                }
              );
              description = "One entry per RetroAchievements-supporting emulator (design D1).";
            };
          };
        }
      );
      default = null;
      internal = true;
      description = ''
        The owned-values document's `retroachievements` namespace (design
        D1, emulators-retroachievements), or null when the feature is off.
        This module never sets it; `modules/emulators` does, from
        `emubox.retroachievements.enable`. It lives here rather than in
        `modules/emulators` because `ownedValuesFile` below is what has to
        render it, and an internal option is how one module hands a value
        to another without either reading the other's private state.
      '';
    };

    ownedValuesFile = lib.mkOption {
      type = lib.types.path;
      default = pkgs.writeText "emubox-owned-values.json" (
        builtins.toJSON {
          files = cfg.ownedFiles;
          retroachievements =
            if cfg.retroachievementsNamespace == null then
              null
            else
              cfg.retroachievementsNamespace
              // {
                # `token_file` and `machine_id_file` are declared as
                # `nullOr str, default = null` on the target submodule
                # above so every target can share one type regardless of
                # its encoding; the module system fills the unset one in
                # with a literal `null` rather than omitting it, which
                # would change this document's shape from before the
                # namespace had a type at all (`raEmulators` in
                # `modules/emulators` never gave a target a key it didn't
                # need). Stripped back to "key absent" here so the
                # rendered JSON stays byte-identical either way - the only
                # two fields on a target that can ever be null; every
                # other field is required by the submodule itself.
                targets = map (
                  target: lib.filterAttrs (_: value: value != null) target
                ) cfg.retroachievementsNamespace.targets;
              };
        }
      );
      readOnly = true;
      internal = true;
      description = ''
        The rendered owned-values file the session passes to
        `emubox-prepare`. Exposed so that a test interpolates one source of
        truth rather than scraping the session script or re-rendering the
        JSON and agreeing with itself.
      '';
    };
  };

  config = {
    emubox.kiosk.ownedFiles."settings/es_settings.xml" = {
      format = "esde-xml";
      keys = {
        # The restriction itself, reasserted before every launch: an admin
        # who unlocked the full menu last time gets kiosk mode this time.
        UIMode = esdeString "kiosk";
        UIMode_passkey = esdeString cfg.passkey;
        ROMDirectory = esdeString "/data/roms";
        MediaDirectory = esdeString "/data/media";
        Theme = esdeString "linear-es-de";
        ApplicationLanguage = esdeString "en_US";
        # Makes the QUIT entry open the patched menu (pkgs/es-de) rather
        # than a bare "really quit?" box.
        ShowQuitMenu = {
          type = "bool";
          value = "true";
        };
      };
    };

    # A real `player` group: the /data layout (modules/library) is owned
    # `player player` with setgid on roms/ and bios/, so that admin's ingest
    # over the admin link lands group-owned (design 8). isNormalUser alone
    # would put the user in `users` and leave the tmpfiles rules unresolvable
    # (the first booted CI run: "Failed to resolve group 'player'").
    users.groups.player = { };
    users.users.player = {
      isNormalUser = true;
      group = "player";
      home = "/data/home/player";
      createHome = true;
      extraGroups = [
        "video"
        "input"
        "audio"
      ];
    };

    services.displayManager = {
      sddm = {
        enable = true;
        wayland.enable = true;
        # Explicit, and load-bearing rather than a restatement of the
        # nixpkgs default: SDDM autologins only when `daemonApp->first ||
        # Relogin`, so with this false the first display of the daemon's
        # life logs `player` in and every later one shows the greeter. When
        # the session gives up after three crashes, "the script exits" and
        # "the greeter appears" are then the same event. With relogin = true
        # SDDM would log `player` straight back in and the greeter could
        # never be reached from a crash loop (design D1). A reboot restores
        # automatic login. The option is SDDM's own, not the generic
        # displayManager.autoLogin, which has no relogin.
        autoLogin.relogin = false;
      };
      autoLogin = {
        enable = true;
        user = "player";
      };
      defaultSession = "emubox";
      sessionPackages = [ (session // { providedSessions = [ "emubox" ]; }) ];
    };

    # ES-DE powers off and reboots through logind.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (subject.user == "player" &&
            (action.id == "org.freedesktop.login1.power-off" ||
             action.id == "org.freedesktop.login1.power-off-multiple-sessions" ||
             action.id == "org.freedesktop.login1.reboot" ||
             action.id == "org.freedesktop.login1.reboot-multiple-sessions")) {
          return polkit.Result.YES;
        }
      });
    '';

    environment.systemPackages = [
      pkgs.cage
      pkgs.es-de
      # On the system path, not only inside the session script, so that the
      # test driver and an admin who reached the greeter can run it too
      # (design D3's invocation contract).
      pkgs.emubox-prepare
    ];
  };
}
