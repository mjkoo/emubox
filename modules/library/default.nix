# Manual scraping, cache-backed gamelists, ingest permissions and library status.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.emubox.library;
  platformMap = pkgs.writeText "emubox-library-platforms.json" (builtins.toJSON cfg.platformMap);
  toolsEntry = pkgs.writeShellApplication {
    name = "emubox-update-art";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.procps
    ];
    text = ''
      ${pkgs.foot}/bin/foot -e emubox-scrape || true
      mark="''${XDG_RUNTIME_DIR:?}/emubox-frontend-restart"
      frontend=$(pgrep -u "$(id -u)" -x es-de) || exit 1
      # A single frontend owns this session; refuse an ambiguous target.
      case "$frontend" in
        *$'\n'* | "") exit 1 ;;
      esac
      touch "$mark"
      if ! kill -TERM "$frontend"; then
        rm -f "$mark"
        exit 1
      fi
    '';
  };
  toolsDirectory = pkgs.runCommand "emubox-tools" { } ''
    mkdir -p "$out"
    ln -s ${toolsEntry}/bin/emubox-update-art "$out/Update game art.sh"
  '';
in
{
  options.emubox.library = {
    threads = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Concurrent scraper requests, limited by the service account's allowance.";
    };
    platformMap = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = builtins.fromJSON (builtins.readFile ../../pkgs/emubox-library/platform-map.json);
      description = "Frontend folder names mapped to accepted Skyscraper platform names.";
    };
  };

  config = {
    systemd.tmpfiles.rules = [
      "d /data/home 0755 root root -"
      "d /data/roms 2775 player player -"
      "a+ /data/roms - - - - d:g:player:rwx"
      "d /data/bios 2775 player player -"
      "d /data/saves 0755 player player -"
      "d /data/es-de 0755 player player -"
      "d /data/media 0755 player player -"
      "d /data/cache 0755 player player -"
      "d /data/cache/skyscraper 0755 player player -"
    ];

    environment.systemPackages = [
      pkgs.skyscraper
      pkgs.emubox-library
    ];
    environment.etc."emubox/library-platforms.json".source = platformMap;
    environment.etc."emubox/library.json".source = pkgs.writeText "emubox-library.json" (
      builtins.toJSON {
        rom_root = "/data/roms";
        cache_root = "/data/cache/skyscraper";
        gamelist_root = "${config.emubox.kiosk.appdataDir}/gamelists";
        media_root = "/data/media";
        scraper_config = config.sops.templates."skyscraper.ini".path;
        bundled_systems = "${pkgs.es-de}/share/es-de/resources/systems/linux/es_systems.xml";
        custom_systems = config.emubox.kiosk.customSystemsFile;
        platform_map = platformMap;
        session_user = "player";
        skyscraper = "${pkgs.skyscraper}/bin/Skyscraper";
        systemd_cat = "${config.systemd.package}/bin/systemd-cat";
      }
    );

    sops.templates."skyscraper.ini" = {
      owner = "player";
      mode = "0400";
      content = ''
        [main]
        threads=${toString cfg.threads}
        regionPrios="us,eu,jp"
        lang="en"
        [screenscraper]
        userCreds="${config.sops.placeholder.screenscraper_username}:${config.sops.placeholder.screenscraper_password}"
      '';
    };

    emubox.kiosk.customSystems = [
      ''
        <system>
          <name>emubox-tools</name>
          <fullname>Tools</fullname>
          <path>${toolsDirectory}</path>
          <extension>.sh</extension>
          <command>${pkgs.bash}/bin/bash %ROM%</command>
          <platform>ignore</platform>
          <theme>tools</theme>
        </system>
      ''
    ];

    emubox.kiosk.preFrontendStep = ''
      # emubox-library-generate resolves from the system path so a test can substitute it.
      batch=
      capture_rc=0
      batch=$(${pkgs.coreutils}/bin/timeout --signal=KILL 5 emubox-library-generate capture) || capture_rc=$?
      if [ "$capture_rc" -ne 0 ]; then
        printf 'library batch capture skipped or failed (%s); starting frontend\n' "$capture_rc" | systemd-cat -t emubox-library || true
      elif [ -n "$batch" ] && [ "$batch" != '{}' ]; then
        generation_rc=0
        ${pkgs.coreutils}/bin/timeout --kill-after=30 2100 cage -s -- ${pkgs.foot}/bin/foot -e emubox-library-generate || generation_rc=$?
        if [ "$generation_rc" -ne 0 ]; then
          printf 'library generation window exited with %s\n' "$generation_rc" | systemd-cat -t emubox-library || true
        fi
        if [ "$generation_rc" -ne 75 ]; then
          if ! ${pkgs.coreutils}/bin/timeout --signal=KILL 5 emubox-library-generate cleanup --batch "$batch"; then
            printf 'library failure cleanup deferred; starting frontend\n' | systemd-cat -t emubox-library || true
          fi
        fi
      fi
    '';

    emubox.status.reporters = [
      {
        name = "library";
        command = [ "${pkgs.emubox-library}/bin/emubox-library-report" ];
      }
    ];
  };
}
