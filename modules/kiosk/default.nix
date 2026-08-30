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
  esdeString = value: {
    type = "string";
    inherit value;
  };
  ownedValues = {
    "settings/es_settings.xml" = {
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
  # emubox-prepare and es-de resolve from the system path (they are in
  # environment.systemPackages below), not from runtimeInputs, so that the
  # session and any outside caller reach one binary.
  emubox-session = pkgs.writeShellApplication {
    name = "emubox-session";
    runtimeInputs = [ pkgs.cage ];
    text = ''
      export ESDE_APPDATA_DIR=${cfg.appdataDir}

      # A run shorter than the window counts as a crash; three in a row and
      # the session ends. SDDM's autoLogin.relogin is false, so what follows
      # is the greeter rather than an endless relaunch. EMUBOX_CRASH_WINDOW
      # is a test hook (tests/kiosk.nix lowers it); the box's figure is the
      # 60 s the kiosk spec states, and nothing in the product varies it.
      window="''${EMUBOX_CRASH_WINDOW:-60}"
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
            exit 1
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
      type = lib.types.str;
      default = "uuddlrlrba";
      description = ''
        The sequence that unlocks the frontend's full menu from kiosk mode.
        The default is ES-DE's own, so the box behaves as the frontend's
        documentation describes until the admin chooses another.
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

    ownedValuesFile = lib.mkOption {
      type = lib.types.path;
      default = pkgs.writeText "emubox-owned-values.json" (builtins.toJSON ownedValues);
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
