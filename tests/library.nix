# Nonvisual integration checks for the real local scraper.
{ self }:
let
  pkgs = self.nixosConfigurations.emubox.pkgs;
  lib = pkgs.lib;
  importImage = "${pkgs.skyscraper.src}/resources/boxfront.png";
  testCage = pkgs.writeShellScriptBin "cage" ''
    if [ "$1" != -s ] || [ "$2" != -- ]; then
      exit 90
    fi
    shift 2
    if [ "$1" = es-de ]; then
      printf 'frontend %s\n' "$$" >> /run/emubox-library-test/events
      exec "$@"
    fi
    printf 'window %s\n' "$*" >> /run/emubox-library-test/events
    exec "$@"
  '';
  testFoot = pkgs.writeShellScriptBin "foot" ''
    if [ "$1" != -e ]; then
      exit 90
    fi
    shift
    mode=$(cat /run/emubox-library-test/window-mode 2>/dev/null || true)
    case "$mode" in
      fail) exit 42 ;;
      hang)
        printf '%s\n' "$$" > /run/emubox-library-test/window-pid
        exec ${pkgs.coreutils}/bin/sleep 3600
        ;;
      fail-handshake)
        touch /run/emubox-library-test/before-fail
        while [ ! -e /run/emubox-library-test/allow-fail ]; do
          ${pkgs.coreutils}/bin/sleep 0.05
        done
        exit 42
        ;;
      handshake)
        touch /run/emubox-library-test/before-child
        while [ ! -e /run/emubox-library-test/allow-child ]; do
          ${pkgs.coreutils}/bin/sleep 0.05
        done
        "$@"
        result=$?
        printf '%s\n' "$result" > /run/emubox-library-test/child-status
        while [ ! -e /run/emubox-library-test/allow-return ]; do
          ${pkgs.coreutils}/bin/sleep 0.05
        done
        exit "$result"
        ;;
    esac
    printf 'generation %s\n' "$*" >> /run/emubox-library-test/events
    exec "$@"
  '';
  testEsde = pkgs.runCommand "emubox-test-es-de" { nativeBuildInputs = [ pkgs.stdenv.cc ]; } ''
    mkdir -p "$out/bin"
    cat > frontend.c <<'C'
    #include <unistd.h>
    int main(void) {
      for (;;) pause();
    }
    C
    $CC -Wall -Wextra -Werror frontend.c -o "$out/bin/es-de"
    ln -s ${pkgs.es-de}/share "$out/share"
  '';
  testSkyscraper = pkgs.writeShellScriptBin "Skyscraper" ''
    mode=$(cat /run/emubox-library-test/scraper-mode 2>/dev/null || true)
    if [ "$mode" = hang-psx ]; then
      seen_format=0
      seen_psx=0
      for arg in "$@"; do
        [ "$arg" = esde ] && seen_format=1
        [ "$arg" = psx ] && seen_psx=1
      done
      if [ "$seen_format" -eq 1 ] && [ "$seen_psx" -eq 1 ]; then
        touch /run/emubox-library-test/psx-hung
        exec ${pkgs.coreutils}/bin/sleep 3600
      fi
    fi
    for arg in "$@"; do
      if [ "$arg" = screenscraper ]; then
        printf '%s\n' "$*" >> /run/emubox-library-test/fetches
        printf '%s\n' "$HOME" >> /run/emubox-library-test/fetch-homes
        exit 0
      fi
    done
    exec ${pkgs.skyscraper}/bin/Skyscraper "$@"
  '';
  testLibrary = pkgs.runCommand "emubox-test-library-commands" { } ''
    mkdir -p "$out/bin"
    ln -s ${pkgs.emubox-library}/bin/emubox-scrape "$out/bin/emubox-scrape"
    ln -s ${pkgs.emubox-library}/bin/emubox-library-report "$out/bin/emubox-library-report"
    cat > "$out/bin/emubox-library-generate" <<'SH'
    #!${pkgs.runtimeShell}
    printf 'library %s\n' "$*" >> /run/emubox-library-test/events
    mode=$(cat /run/emubox-library-test/command-mode 2>/dev/null || true)
    case "$mode:$1" in
      capture-hang:capture | cleanup-hang:cleanup)
        exec ${pkgs.coreutils}/bin/sleep 3600
        ;;
      cleanup-fail:cleanup)
        exit 66
        ;;
    esac
    exec ${pkgs.emubox-library}/bin/emubox-library-generate "$@"
    SH
    chmod +x "$out/bin/emubox-library-generate"
  '';
  testProcps = pkgs.symlinkJoin {
    name = "emubox-test-procps";
    paths = [ pkgs.procps ];
    postBuild = ''
      rm "$out/bin/pgrep"
      cat > "$out/bin/pgrep" <<'SH'
      #!${pkgs.runtimeShell}
      ids=$(${pkgs.procps}/bin/pgrep "$@") || exit $?
      mode=$(cat /run/emubox-library-test/pgrep-mode 2>/dev/null || true)
      if [ "$mode" = lose-target ]; then
        ${pkgs.coreutils}/bin/true &
        ids=$!
        wait "$ids"
      fi
      printf '%s\n' "$ids"
      SH
      chmod +x "$out/bin/pgrep"
    '';
  };
  testTimeout = pkgs.writeShellScriptBin "timeout" ''
    window_mode=$(cat /run/emubox-library-test/window-mode 2>/dev/null || true)
    command_mode=$(cat /run/emubox-library-test/command-mode 2>/dev/null || true)
    scraper_mode=$(cat /run/emubox-library-test/scraper-mode 2>/dev/null || true)
    if [ "$1" = --kill-after=30 ] && [ "$2" = 2100 ] && [ "$window_mode" = hang ]; then
      shift 2
      exec ${pkgs.coreutils}/bin/timeout --kill-after=1 2 "$@"
    fi
    if [ "$1" = --kill-after=30 ] && [ "$2" = 2100 ] && [ "$scraper_mode" = hang-psx ]; then
      shift 2
      ${pkgs.coreutils}/bin/timeout --kill-after=1 2100 "$@" &
      child=$!
      for _ in $(${pkgs.coreutils}/bin/seq 1 600); do
        if [ -e /run/emubox-library-test/psx-hung ]; then
          kill -TERM "$child"
          wait "$child"
          exit $?
        fi
        ${pkgs.coreutils}/bin/sleep 0.1
      done
      kill -TERM "$child"
      wait "$child"
      exit 98
    fi
    if [ "$1" = --signal=KILL ] && [ "$2" = 5 ]; then
      case "$command_mode" in
        capture-hang | cleanup-hang)
          shift 2
          exec ${pkgs.coreutils}/bin/timeout --signal=KILL 2 "$@"
          ;;
      esac
    fi
    exec ${pkgs.coreutils}/bin/timeout "$@"
  '';
  testPkgs = pkgs // {
    cage = testCage;
    foot = testFoot;
    es-de = testEsde;
    skyscraper = testSkyscraper;
    emubox-library = testLibrary;
    procps = testProcps;
  };
  productionStep = self.nixosConfigurations.emubox.config.emubox.kiosk.preFrontendStep;
  testStep =
    assert lib.hasInfix "--kill-after=30 2100" productionStep;
    assert lib.hasInfix (builtins.unsafeDiscardStringContext "${pkgs.foot}/bin/foot") productionStep;
    lib.replaceStrings
      [
        (builtins.unsafeDiscardStringContext "${pkgs.coreutils}/bin/timeout")
        (builtins.unsafeDiscardStringContext "${pkgs.foot}/bin/foot")
      ]
      [
        "${testTimeout}/bin/timeout"
        "${testFoot}/bin/foot"
      ]
      productionStep;
  preservedGamelist = pkgs.writeText "emubox-library-preservation.xml" ''
    <?xml version="1.0"?>
    <gameList>
      <game>
        <path>./fixture.nes</path>
        <favorite>true</favorite>
        <hidden>true</hidden>
        <kidgame>true</kidgame>
        <completed>true</completed>
        <playcount>7</playcount>
        <lastplayed>20250924T113000</lastplayed>
        <sortname>Fixture sort</sortname>
        <altemulator>Fixture emulator</altemulator>
      </game>
      <game>
        <path>./uncached.nes</path>
        <favorite>true</favorite>
        <hidden>true</hidden>
        <kidgame>true</kidgame>
        <completed>true</completed>
        <playcount>9</playcount>
        <lastplayed>20250925T114500</lastplayed>
        <sortname>Uncached sort</sortname>
        <altemulator>Uncached emulator</altemulator>
      </game>
    </gameList>
  '';
  sessionProgram =
    config:
    let
      desktop = lib.head (
        lib.filter (
          package: (package.providedSessions or [ ]) == [ "emubox" ]
        ) config.services.displayManager.sessionPackages
      );
    in
    pkgs.runCommand "emubox-library-session-program" { } ''
      program=$(sed -n 's/^Exec=//p' ${desktop}/share/wayland-sessions/emubox.desktop)
      test -x "$program"
      mkdir -p "$out/bin"
      ln -s "$program" "$out/bin/emubox-session"
    '';
in
{
  name = "emubox-library";

  nodes.machine =
    { config, lib, ... }:
    {
      nixpkgs.pkgs = lib.mkForce testPkgs;
      imports = [
        self.nixosModules.emubox
        ../hosts/emubox/facts.nix
        ./boot-adaptations.nix
      ];
      system.stateVersion = "26.05";
      virtualisation.memorySize = 2048;
      services.displayManager.sddm.enable = lib.mkForce false;
      services.displayManager.autoLogin.enable = lib.mkForce false;
      services.btrbk.instances.local.onCalendar = lib.mkForce null;
      emubox.facts.controllerPorts = lib.mkForce [ ];
      emubox.facts.controllerIdentities.sdlGamepadName = lib.mkForce null;
      emubox.facts.controllerIdentities.sdlJoystickGuid = lib.mkForce null;
      emubox.kiosk.preFrontendStep = lib.mkForce testStep;
      systemd.tmpfiles.rules = [
        "d /run/emubox-library-test 0777 root root -"
      ];
      systemd.services.emubox-library-test-session = {
        description = "Library integration session fixture";
        path = [ config.system.path ];
        environment = {
          HOME = "/data/home/player";
          XDG_RUNTIME_DIR = "/run/emubox-library-test";
          EMUBOX_CRASH_WINDOW = "30";
        };
        serviceConfig = {
          User = "player";
          ExecStart = "${sessionProgram config}/bin/emubox-session";
          Restart = "no";
        };
      };
    };

  nodes.baseline =
    { lib, ... }:
    {
      disabledModules = [ "${self}/modules/library" ];
      imports = [
        self.nixosModules.emubox
        ../hosts/emubox/facts.nix
        ./boot-adaptations.nix
      ];
      system.stateVersion = "26.05";
      virtualisation.memorySize = 1024;
      services.displayManager.sddm.enable = lib.mkForce false;
      services.displayManager.autoLogin.enable = lib.mkForce false;
      services.btrbk.instances.local.onCalendar = lib.mkForce null;
      emubox.facts.controllerPorts = lib.mkForce [ ];
      emubox.facts.controllerIdentities.sdlGamepadName = lib.mkForce null;
      emubox.facts.controllerIdentities.sdlJoystickGuid = lib.mkForce null;
    };

  testScript =
    { nodes }:
    let
      session = sessionProgram nodes.machine;
    in
    ''
      import copy
      import json
      import shlex
      import xml.etree.ElementTree as ET

      def player(command):
          return "su player -s /bin/sh -c " + shlex.quote(command)

      def wait_frontend_count(count):
          try:
              machine.wait_until_succeeds(
                  f"test $(grep -c '^frontend ' /run/emubox-library-test/events) -ge {count}",
                  timeout=180,
              )
          except Exception:
              print(machine.execute("journalctl -u emubox-library-test-session --no-pager")[1])
              raise

      def direct_generation_count():
          return machine.succeed("cat /run/emubox-library-test/events").splitlines().count("library ")

      def requested_restart():
          machine.succeed("touch /run/emubox-library-test/emubox-frontend-restart")
          machine.succeed("pkill -TERM -x es-de")

      def library_journal():
          return machine.succeed("journalctl -t emubox-library --no-pager -o cat")

      def new_library_journal(before):
          after = library_journal()
          assert after.startswith(before), "the library journal was rewritten"
          return after[len(before):].lower()

      def gamelist_games(folder):
          root = ET.fromstring(machine.succeed(
              f"cat /data/es-de/gamelists/{folder}/gamelist.xml"
          ))
          return {game.findtext("path") or "": game for game in root.findall("game")}

      def write_library_config(settings):
          machine.succeed("rm -f /etc/emubox/library.json")
          machine.succeed(
              "printf %s " + shlex.quote(json.dumps(settings))
              + " > /etc/emubox/library.json"
          )

      machine.start()
      machine.wait_for_unit("multi-user.target")
      machine.wait_until_succeeds("test -d /data/home/player")

      with subtest("Library capability adds no player sudo privilege"):
          baseline.start()
          baseline.wait_for_unit("multi-user.target")
          granted = machine.succeed("runuser -u player -- sudo -n -l")
          original = baseline.succeed("runuser -u player -- sudo -n -l")
          granted = granted.replace("machine", "NODE")
          original = original.replace("baseline", "NODE")
          assert granted == original, (granted, original)

      with subtest("The production session gives generation and frontend the console-switch flag"):
          script = machine.succeed("cat ${session}/bin/emubox-session")
          assert "cage -s -- es-de" in script
          assert "cage -s -- ${testFoot}/bin/foot -e emubox-library-generate" in script
          assert "--kill-after=30 2100 cage -s --" in script

      with subtest("Ingest permissions work for admin and for a player-created folder"):
          machine.succeed("runuser -u admin -- mkdir /data/roms/psx")
          directory_mode = machine.succeed("stat -c '%G:%a' /data/roms/psx").strip()
          assert directory_mode == "player:2775", directory_mode
          machine.succeed("runuser -u admin -- sh -c 'printf ownership > /data/roms/psx/owned.cue'")
          file_mode = machine.succeed("stat -c '%G:%a' /data/roms/psx/owned.cue").strip()
          assert file_mode == "player:664", file_mode
          assert machine.succeed(player("cat /data/roms/psx/owned.cue")) == "ownership"
          machine.succeed(player("mkdir /data/roms/genesis"))
          assert machine.succeed("stat -c '%G' /data/roms/genesis").strip() == "player"
          machine.succeed("runuser -u admin -- sh -c 'printf inherited > /data/roms/genesis/admin.md'")
          assert machine.succeed(player("cat /data/roms/genesis/admin.md")) == "inherited"

      with subtest("A first local import deploys resources and populates cache"):
          machine.succeed("test ! -e /data/home/player/.skyscraper")
          machine.succeed("install -d -o player -g player /data/roms/nes")
          machine.succeed("install -d -o player -g player /data/cache/skyscraper")
          machine.succeed("install -d -o player -g player /data/cache/skyscraper/probe-import/covers")
          machine.succeed("install -d -o player -g player /data/cache/skyscraper/probe-import/wheels")
          machine.succeed("install -d -o player -g player /data/cache/skyscraper/probe-import/textual")
          machine.succeed("printf 'fixture rom' > /data/roms/nes/fixture.nes")
          machine.succeed("chown player:player /data/roms/nes/fixture.nes")
          machine.succeed("printf 'uncached rom' > /data/roms/nes/uncached.nes")
          machine.succeed("chown player:player /data/roms/nes/uncached.nes")
          machine.succeed("install -o player -g player ${importImage} /data/cache/skyscraper/probe-import/covers/fixture.png")
          machine.succeed("install -o player -g player ${importImage} /data/cache/skyscraper/probe-import/wheels/fixture.png")
          machine.succeed("printf 'Description: ###DESCRIPTION###\\n' > /data/cache/skyscraper/probe-import/definitions.dat")
          machine.succeed("printf 'Description: Imported fixture description\\n' > /data/cache/skyscraper/probe-import/textual/fixture.txt")
          machine.succeed("chown -R player:player /data/cache/skyscraper/probe-import")
          machine.succeed("printf '[main]\\nimportFolder=/data/cache/skyscraper/probe-import\\n' > /data/cache/skyscraper/probe.ini")
          machine.succeed("chown player:player /data/cache/skyscraper/probe.ini")
          command = (
              "Skyscraper -p nes -s import -c /data/cache/skyscraper/probe.ini "
              "-i /data/roms/nes -d /data/cache/skyscraper/nes --flags unattend"
          )
          output = machine.succeed(player(command), timeout=180)
          print(output)
          machine.succeed("test -f /data/home/player/.skyscraper/resources/boxfront.png")
          quick_ids = ET.fromstring(machine.succeed(
              "cat /data/cache/skyscraper/nes/quickid.xml"
          ))
          fixture_ids = [
              entry.get("id") for entry in quick_ids.findall("quickid")
              if entry.get("filepath") == "/data/roms/nes/fixture.nes"
          ]
          assert len(fixture_ids) == 1, ET.tostring(quick_ids)
          cache = ET.fromstring(machine.succeed(
              "cat /data/cache/skyscraper/nes/db.xml"
          ))
          assert any(
              entry.get("id") == fixture_ids[0] and entry.get("source") == "import"
              for entry in cache.findall("resource")
          ), ET.tostring(cache)

      with subtest("The session generates the first gamelist before its frontend"):
          machine.succeed("test ! -e /data/es-de/gamelists/nes")
          machine.succeed("printf 'nes\\n' > /data/cache/skyscraper/pending")
          machine.succeed("printf '{\"nes\":\"import-one\"}\\n' > /data/cache/skyscraper/revisions.json")
          machine.succeed("chown player:player /data/cache/skyscraper/{pending,revisions.json}")
          machine.succeed("systemctl start emubox-library-test-session")
          wait_frontend_count(1)
          events = machine.succeed("cat /run/emubox-library-test/events").splitlines()
          capture_index = events.index("library capture")
          window_index = next(i for i, event in enumerate(events) if event.startswith("window "))
          generation_index = events.index("generation emubox-library-generate")
          frontend_index = next(i for i, event in enumerate(events) if event.startswith("frontend "))
          assert capture_index < window_index < generation_index < frontend_index, events
          assert "foot -e emubox-library-generate" in events[window_index], events
          assert machine.succeed("cat /data/cache/skyscraper/pending") == ""
          gamelist = ET.fromstring(machine.succeed("cat /data/es-de/gamelists/nes/gamelist.xml"))
          games = {game.findtext("path") or "": game for game in gamelist.findall("game")}
          fixture = next(game for path, game in games.items() if path.endswith("fixture.nes"))
          assert fixture.findtext("desc") == "Imported fixture description"
          machine.succeed("test -n \"$(find /data/media/nes/covers -type f -name '*fixture*' -print -quit)\"")
          machine.succeed("test -n \"$(find /data/media/nes/marquees -type f -name '*fixture*' -print -quit)\"")
          machine.succeed("test ! -e /data/media/nes/textures")
          machine.succeed("test ! -e /data/media/nes/wheels")
          machine.succeed("pgrep -x es-de")

      with subtest("Regeneration preserves every family field on cached and uncached games"):
          machine.succeed("install -o player -g player ${preservedGamelist} /data/es-de/gamelists/nes/gamelist.xml")
          machine.succeed("printf 'nes\\n' > /data/cache/skyscraper/pending")
          machine.succeed("printf '{\"nes\":\"preservation-two\"}\\n' > /data/cache/skyscraper/revisions.json")
          machine.succeed("chown player:player /data/cache/skyscraper/{pending,revisions.json}")
          requested_restart()
          wait_frontend_count(2)
          expected = {
              "fixture.nes": {
                  "favorite": "true", "hidden": "true", "kidgame": "true",
                  "completed": "true", "playcount": "7",
                  "lastplayed": "20250924T113000", "sortname": "Fixture sort",
                  "altemulator": "Fixture emulator",
              },
              "uncached.nes": {
                  "favorite": "true", "hidden": "true", "kidgame": "true",
                  "completed": "true", "playcount": "9",
                  "lastplayed": "20250925T114500", "sortname": "Uncached sort",
                  "altemulator": "Uncached emulator",
              },
          }

          def check_preservation(games):
              for name, fields in expected.items():
                  entry = next(
                      (game for path, game in games.items() if path.endswith(name)), None
                  )
                  assert entry is not None, (name, list(games))
                  for field, value in fields.items():
                      assert entry.findtext(field) == value, (name, field, value)
              uncached = next(
                  game for path, game in games.items() if path.endswith("uncached.nes")
              )
              assert not uncached.findtext("desc"), ET.tostring(uncached)

          games = gamelist_games("nes")
          check_preservation(games)
          for name, fields in expected.items():
              key = next(path for path in games if path.endswith(name))
              for field in fields:
                  broken = copy.deepcopy(games)
                  broken[key].remove(broken[key].find(field))
                  try:
                      check_preservation(broken)
                  except AssertionError:
                      pass
                  else:
                      raise AssertionError(f"removing {field} from {name} was not detected")
          broken = copy.deepcopy(games)
          del broken[next(path for path in broken if path.endswith("uncached.nes"))]
          try:
              check_preservation(broken)
          except AssertionError:
              pass
          else:
              raise AssertionError("dropping the uncached game was not detected")

      with subtest("The documented admin command succeeds with an admin HOME"):
          library_config = json.loads(machine.succeed("cat /etc/emubox/library.json"))
          machine.succeed(
              "printf '[main]\\n[screenscraper]\\nuserCreds=fixture:secret\\n' "
              "> /run/emubox-library-test/credentials.ini"
          )
          good_config = dict(library_config)
          good_config["scraper_config"] = "/run/emubox-library-test/credentials.ini"
          write_library_config(good_config)
          machine.succeed("runuser -u admin -- env HOME=/home/admin sudo -u player emubox-scrape")
          successful = json.loads(machine.succeed("cat /data/cache/skyscraper/last-run.json"))
          assert successful["result"] == "complete", successful
          assert successful["folders"]["nes"] == "fetched", successful
          assert "screenscraper" in machine.succeed("cat /run/emubox-library-test/fetches")
          assert set(machine.succeed("cat /run/emubox-library-test/fetch-homes").splitlines()) == {"/data/home/player"}
          machine.succeed("test -f /data/home/player/.skyscraper/resources/boxfront.png")

      with subtest("Account, placeholder and held-claim refusals preserve the right state"):
          before = machine.succeed("cat /data/cache/skyscraper/last-run.json")
          for command in ("emubox-scrape", "runuser -u admin -- emubox-scrape"):
              status, output = machine.execute(command + " 2>&1")
              assert status != 0, (command, output)
              assert "sudo -u player emubox-scrape" in output, output
              assert machine.succeed("cat /data/cache/skyscraper/last-run.json") == before

          machine.succeed("systemd-run --unit=emubox-library-lock-holder --property=User=player "
                          "${pkgs.bash}/bin/bash -c "
                          + shlex.quote("exec 9>/data/cache/skyscraper/lock; "
                                        "${pkgs.util-linux}/bin/flock -x 9; "
                                        "${pkgs.coreutils}/bin/touch /run/emubox-library-test/held; "
                                        "exec ${pkgs.coreutils}/bin/sleep 3600"))
          machine.wait_until_succeeds("test -e /run/emubox-library-test/held", timeout=30)
          status, output = machine.execute(player("emubox-scrape") + " 2>&1")
          assert status != 0 and "in progress" in output.lower(), output
          assert machine.succeed("cat /data/cache/skyscraper/last-run.json") == before
          machine.succeed("systemctl stop emubox-library-lock-holder")

          pending_before = machine.succeed("cat /data/cache/skyscraper/pending")
          write_library_config(library_config)
          status, output = machine.execute(player("emubox-scrape") + " 2>&1")
          assert status != 0 and "placeholder" in output.lower(), output
          refused = json.loads(machine.succeed("cat /data/cache/skyscraper/last-run.json"))
          assert refused["result"] == "refused", refused
          assert "placeholder" in refused["cause"].lower(), refused
          assert refused["folders"] == json.loads(before)["folders"], (refused, before)
          assert machine.succeed("cat /data/cache/skyscraper/pending") == pending_before
          write_library_config(good_config)

      with subtest("Unreadable cache fails one folder and the frontend still starts"):
          machine.succeed("install -d -o root -g root -m 000 /data/cache/skyscraper/psx")
          machine.succeed("printf 'psx\\n' > /data/cache/skyscraper/pending")
          machine.succeed("printf '{\"psx\":\"unreadable-cache\"}\\n' > /data/cache/skyscraper/revisions.json")
          machine.succeed("chown player:player /data/cache/skyscraper/{pending,revisions.json}")
          journal_before = library_journal()
          requested_restart()
          wait_frontend_count(3)
          failed = json.loads(machine.succeed("cat /data/cache/skyscraper/last-run.json"))
          assert failed["folders"]["psx"] == "generation-failed", failed
          assert machine.succeed("cat /data/cache/skyscraper/pending") == ""
          journal = new_library_journal(journal_before)
          assert "generation failed for psx" in journal, journal
          machine.succeed("pgrep -x es-de")

      with subtest("Status is equally readable as root and admin"):
          # Other reporters warn on this node's temporary filesystems.
          _, root_status = machine.execute("emubox-status")
          _, admin_status = machine.execute("runuser -u admin -- emubox-status")
          for output in (root_status, admin_status):
              assert "library: ok" in output, output
              assert "nes: 2 ROMs, 2 gamelist entries, 1 unscraped" in output, output
              assert "Last run: refused" in output, output
              assert "Failed folders: psx" in output, output
              assert "Generation pending: none" in output, output
          assert root_status.split("library:", 1)[1].split("\n\n", 1)[0] == admin_status.split("library:", 1)[1].split("\n\n", 1)[0]
          for name in ("last-run.json", "last-run.log", "pending"):
              mode = machine.succeed("stat -c '%a' /data/cache/skyscraper/" + name).strip()
              assert mode == "644", (name, mode)

      with subtest("A failed progress window records failure without changing the gamelist"):
          previous = machine.succeed("cat /data/es-de/gamelists/nes/gamelist.xml")
          machine.succeed("printf 'nes\\n' > /data/cache/skyscraper/pending")
          machine.succeed("printf '{\"nes\":\"failed-window\"}\\n' > /data/cache/skyscraper/revisions.json")
          machine.succeed("chown player:player /data/cache/skyscraper/{pending,revisions.json}")
          machine.succeed("printf 'fail\\n' > /run/emubox-library-test/window-mode")
          generation_count = machine.succeed("grep -c '^generation ' /run/emubox-library-test/events").strip()
          direct_count = direct_generation_count()
          journal_before = library_journal()
          requested_restart()
          wait_frontend_count(4)
          assert machine.succeed("cat /data/es-de/gamelists/nes/gamelist.xml") == previous
          assert machine.succeed("cat /data/cache/skyscraper/pending") == ""
          assert machine.succeed("grep -c '^generation ' /run/emubox-library-test/events").strip() == generation_count
          assert direct_generation_count() == direct_count
          failed = json.loads(machine.succeed("cat /data/cache/skyscraper/last-run.json"))
          assert failed["folders"]["nes"] == "generation-failed", failed
          journal = new_library_journal(journal_before)
          assert "generation window exited with 42" in journal, journal
          assert "progress window" in journal, journal
          machine.succeed("rm /run/emubox-library-test/window-mode")

      with subtest("A hung progress window reaches the shortened external deadline"):
          previous = machine.succeed("cat /data/es-de/gamelists/nes/gamelist.xml")
          machine.succeed("printf 'nes\\n' > /data/cache/skyscraper/pending")
          machine.succeed("printf '{\"nes\":\"hung-window\"}\\n' > /data/cache/skyscraper/revisions.json")
          machine.succeed("chown player:player /data/cache/skyscraper/{pending,revisions.json}")
          machine.succeed("printf 'hang\\n' > /run/emubox-library-test/window-mode")
          generation_count = machine.succeed("grep -c '^generation ' /run/emubox-library-test/events").strip()
          direct_count = direct_generation_count()
          journal_before = library_journal()
          requested_restart()
          wait_frontend_count(5)
          assert machine.succeed("cat /data/es-de/gamelists/nes/gamelist.xml") == previous
          assert machine.succeed("cat /data/cache/skyscraper/pending") == ""
          assert machine.succeed("grep -c '^generation ' /run/emubox-library-test/events").strip() == generation_count
          assert direct_generation_count() == direct_count
          machine.succeed("! kill -0 $(cat /run/emubox-library-test/window-pid) 2>/dev/null")
          failed = json.loads(machine.succeed("cat /data/cache/skyscraper/last-run.json"))
          assert failed["folders"]["nes"] == "generation-failed", failed
          journal = new_library_journal(journal_before)
          assert "generation window exited with 124" in journal, journal
          assert "progress window" in journal, journal
          machine.succeed("rm /run/emubox-library-test/window-mode")

      with subtest("A fetch claim held at capture leaves pending unchanged"):
          machine.succeed("printf 'nes\\n' > /data/cache/skyscraper/pending")
          machine.succeed("printf '{\"nes\":\"held-at-capture\"}\\n' > /data/cache/skyscraper/revisions.json")
          machine.succeed("chown player:player /data/cache/skyscraper/{pending,revisions.json}")
          pending_before = machine.succeed("cat /data/cache/skyscraper/pending")
          window_before = machine.succeed("grep -c '^window ' /run/emubox-library-test/events").strip()
          machine.succeed("rm -f /run/emubox-library-test/held")
          machine.succeed("systemd-run --unit=emubox-library-lock-at-capture --property=User=player "
                          "${pkgs.bash}/bin/bash -c "
                          + shlex.quote("exec 9>/data/cache/skyscraper/lock; "
                                        "${pkgs.util-linux}/bin/flock -x 9; "
                                        "${pkgs.coreutils}/bin/touch /run/emubox-library-test/held; "
                                        "exec ${pkgs.coreutils}/bin/sleep 3600"))
          machine.wait_until_succeeds("test -e /run/emubox-library-test/held", timeout=30)
          journal_before = library_journal()
          requested_restart()
          wait_frontend_count(6)
          assert machine.succeed("cat /data/cache/skyscraper/pending") == pending_before
          assert machine.succeed("grep -c '^window ' /run/emubox-library-test/events").strip() == window_before
          journal = new_library_journal(journal_before)
          assert "fetch was running" in journal, journal
          machine.succeed("systemctl stop emubox-library-lock-at-capture")
          requested_restart()
          wait_frontend_count(7)
          assert machine.succeed("cat /data/cache/skyscraper/pending") == ""

      with subtest("Exit 75 from the test window skips cleanup after a lock handshake"):
          machine.succeed("printf 'nes\\n' > /data/cache/skyscraper/pending")
          machine.succeed("printf '{\"nes\":\"held-in-window\"}\\n' > /data/cache/skyscraper/revisions.json")
          machine.succeed("chown player:player /data/cache/skyscraper/{pending,revisions.json}")
          pending_before = machine.succeed("cat /data/cache/skyscraper/pending")
          before = machine.succeed("cat /run/emubox-library-test/events")
          machine.succeed("rm -f /run/emubox-library-test/{before-child,allow-child,child-status,allow-return,held}")
          machine.succeed("printf 'handshake\\n' > /run/emubox-library-test/window-mode")
          journal_before = library_journal()
          requested_restart()
          machine.wait_until_succeeds("test -e /run/emubox-library-test/before-child")
          machine.succeed("systemd-run --unit=emubox-library-lock-in-window --property=User=player "
                          "${pkgs.bash}/bin/bash -c "
                          + shlex.quote("exec 9>/data/cache/skyscraper/lock; "
                                        "${pkgs.util-linux}/bin/flock -x 9; "
                                        "${pkgs.coreutils}/bin/touch /run/emubox-library-test/held; "
                                        "exec ${pkgs.coreutils}/bin/sleep 3600"))
          machine.wait_until_succeeds("test -e /run/emubox-library-test/held", timeout=30)
          machine.succeed("touch /run/emubox-library-test/allow-child")
          machine.wait_until_succeeds("test -e /run/emubox-library-test/child-status")
          assert machine.succeed("cat /run/emubox-library-test/child-status").strip() == "75"
          machine.succeed("systemctl stop emubox-library-lock-in-window")
          machine.succeed("touch /run/emubox-library-test/allow-return")
          wait_frontend_count(8)
          after = machine.succeed("cat /run/emubox-library-test/events")
          new_events = after[len(before):].splitlines()
          assert not any(event.startswith("library cleanup") for event in new_events), new_events
          assert machine.succeed("cat /data/cache/skyscraper/pending") == pending_before
          journal = new_library_journal(journal_before)
          assert "generation window exited with 75" in journal, journal
          assert "cleanup deferred" not in journal, journal
          machine.succeed("rm /run/emubox-library-test/window-mode")

          # The negative control runs cleanup against a copy of the same
          # pending batch. If the session had taken that path, the pending
          # assertion above would have failed even after the claim ended.
          machine.succeed("install -d -o player -g player /data/cache/skyscraper/negative-control")
          machine.succeed("install -o player -g player /data/cache/skyscraper/pending /data/cache/skyscraper/negative-control/pending")
          machine.succeed("install -o player -g player /data/cache/skyscraper/revisions.json /data/cache/skyscraper/negative-control/revisions.json")
          negative = dict(good_config)
          negative["cache_root"] = "/data/cache/skyscraper/negative-control"
          machine.succeed("printf %s " + shlex.quote(json.dumps(negative)) + " > /run/emubox-library-test/negative.json")
          machine.succeed(player("emubox-library-generate cleanup --config /run/emubox-library-test/negative.json --batch '{\"nes\":\"held-in-window\"}'"))
          assert machine.succeed("cat /data/cache/skyscraper/negative-control/pending") != pending_before

      with subtest("A stalled capture is bounded and leaves pending intact"):
          machine.succeed("printf 'capture-hang\\n' > /run/emubox-library-test/command-mode")
          before = machine.succeed("cat /data/cache/skyscraper/pending")
          windows = machine.succeed("grep -c '^window ' /run/emubox-library-test/events").strip()
          journal_before = library_journal()
          requested_restart()
          wait_frontend_count(9)
          assert machine.succeed("cat /data/cache/skyscraper/pending") == before
          assert machine.succeed("grep -c '^window ' /run/emubox-library-test/events").strip() == windows
          journal = new_library_journal(journal_before)
          assert "batch capture skipped" in journal, journal
          machine.succeed("rm /run/emubox-library-test/command-mode")

      with subtest("A stalled cleanup is bounded and leaves pending intact"):
          before = machine.succeed("cat /data/cache/skyscraper/pending")
          live = machine.succeed("cat /data/es-de/gamelists/nes/gamelist.xml")
          machine.succeed("printf 'fail\\n' > /run/emubox-library-test/window-mode")
          machine.succeed("printf 'cleanup-hang\\n' > /run/emubox-library-test/command-mode")
          journal_before = library_journal()
          requested_restart()
          wait_frontend_count(10)
          assert machine.succeed("cat /data/cache/skyscraper/pending") == before
          assert machine.succeed("cat /data/es-de/gamelists/nes/gamelist.xml") == live
          journal = new_library_journal(journal_before)
          assert "cleanup deferred" in journal, journal
          machine.succeed("rm /run/emubox-library-test/{window-mode,command-mode}")

      with subtest("Cleanup contention cannot consume a newer pending batch"):
          before = machine.succeed("cat /data/cache/skyscraper/pending")
          machine.succeed("rm -f /run/emubox-library-test/{before-fail,allow-fail,held}")
          machine.succeed("printf 'fail-handshake\\n' > /run/emubox-library-test/window-mode")
          journal_before = library_journal()
          requested_restart()
          machine.wait_until_succeeds("test -e /run/emubox-library-test/before-fail")
          machine.succeed("systemd-run --unit=emubox-library-lock-at-cleanup --property=User=player "
                          "${pkgs.bash}/bin/bash -c "
                          + shlex.quote("exec 9>/data/cache/skyscraper/lock; "
                                        "${pkgs.util-linux}/bin/flock -x 9; "
                                        "${pkgs.coreutils}/bin/touch /run/emubox-library-test/held; "
                                        "exec ${pkgs.coreutils}/bin/sleep 3600"))
          machine.wait_until_succeeds("test -e /run/emubox-library-test/held", timeout=30)
          machine.succeed("touch /run/emubox-library-test/allow-fail")
          wait_frontend_count(11)
          assert machine.succeed("cat /data/cache/skyscraper/pending") == before
          journal = new_library_journal(journal_before)
          assert "cleanup deferred" in journal, journal
          machine.succeed("systemctl stop emubox-library-lock-at-cleanup")
          machine.succeed("rm /run/emubox-library-test/window-mode")

      with subtest("A newer fetch of the same folder survives old-batch cleanup"):
          previous_revision = json.loads(machine.succeed("cat /data/cache/skyscraper/revisions.json"))["nes"]
          machine.succeed("rm -f /run/emubox-library-test/{before-fail,allow-fail}")
          machine.succeed("printf 'fail-handshake\\n' > /run/emubox-library-test/window-mode")
          requested_restart()
          machine.wait_until_succeeds("test -e /run/emubox-library-test/before-fail")
          machine.succeed(player("emubox-scrape"))
          fetched_revision = json.loads(machine.succeed("cat /data/cache/skyscraper/revisions.json"))["nes"]
          assert fetched_revision != previous_revision
          pending_after_fetch = machine.succeed("cat /data/cache/skyscraper/pending")
          assert "nes\n" in pending_after_fetch
          machine.succeed("touch /run/emubox-library-test/allow-fail")
          wait_frontend_count(12)
          assert machine.succeed("cat /data/cache/skyscraper/pending") == pending_after_fetch
          assert json.loads(machine.succeed("cat /data/cache/skyscraper/revisions.json"))["nes"] == fetched_revision
          machine.succeed("rm /run/emubox-library-test/window-mode")

      with subtest("A cleanup write failure cannot block frontend launch"):
          before = machine.succeed("cat /data/cache/skyscraper/pending")
          machine.succeed("rm -f /run/emubox-library-test/{before-fail,allow-fail}")
          machine.succeed("printf 'fail-handshake\\n' > /run/emubox-library-test/window-mode")
          journal_before = library_journal()
          requested_restart()
          machine.wait_until_succeeds("test -e /run/emubox-library-test/before-fail")
          machine.succeed("chmod 0555 /data/cache/skyscraper")
          machine.succeed("touch /run/emubox-library-test/allow-fail")
          wait_frontend_count(13)
          machine.succeed("chmod 0755 /data/cache/skyscraper")
          assert machine.succeed("cat /data/cache/skyscraper/pending") == before
          journal = new_library_journal(journal_before)
          assert "cleanup deferred" in journal, journal
          machine.succeed("rm /run/emubox-library-test/window-mode")

      with subtest("A completed folder keeps its replacement when later generation is interrupted"):
          machine.succeed("printf 'nes\\npsx\\n' > /data/cache/skyscraper/pending")
          machine.succeed("printf '{\"nes\":\"completed-first\",\"psx\":\"interrupted-second\"}\\n' > /data/cache/skyscraper/revisions.json")
          machine.succeed("chown player:player /data/cache/skyscraper/{pending,revisions.json}")
          machine.succeed("printf '<gameList><game><path>./fixture.nes</path><name>old sentinel</name></game></gameList>' > /data/es-de/gamelists/nes/gamelist.xml")
          machine.succeed("chown player:player /data/es-de/gamelists/nes/gamelist.xml")
          machine.succeed("rm -f /run/emubox-library-test/psx-hung")
          machine.succeed("printf 'hang-psx\\n' > /run/emubox-library-test/scraper-mode")
          requested_restart()
          wait_frontend_count(14)
          machine.succeed("test -e /run/emubox-library-test/psx-hung")
          updated = machine.succeed("cat /data/es-de/gamelists/nes/gamelist.xml")
          assert "old sentinel" not in updated and "Imported fixture description" in updated
          result = json.loads(machine.succeed("cat /data/cache/skyscraper/last-run.json"))
          assert result["folders"]["nes"] == "generated", result
          assert result["folders"]["psx"] == "generation-failed", result
          assert machine.succeed("cat /data/cache/skyscraper/pending") == ""
          machine.succeed("rm /run/emubox-library-test/scraper-mode")

      with subtest("The Tools command requests one restart through its explicit interpreter"):
          systems = ET.fromstring(machine.succeed(
              "cat /data/es-de/custom_systems/es_systems.xml"
          ))
          tools = next(
              system for system in systems.findall("system")
              if system.findtext("name") == "emubox-tools"
          )
          command = tools.findtext("command")
          path = tools.findtext("path")
          assert command is not None and path is not None
          interpreter = command.split()[0]
          entry = path + "/Update game art.sh"
          machine.succeed("test -f " + shlex.quote(entry))

          def run_tools_entry():
              previous_pid = machine.succeed("pgrep -x es-de").strip()
              machine.succeed(player(
                  "env XDG_RUNTIME_DIR=/run/emubox-library-test "
                  + shlex.quote(interpreter) + " " + shlex.quote(entry)
              ))
              return previous_pid

          previous_pid = run_tools_entry()
          wait_frontend_count(15)
          assert machine.succeed("pgrep -x es-de").strip() != previous_pid
          machine.succeed("test ! -e /run/emubox-library-test/emubox-frontend-restart")
          for count in (16, 17):
              run_tools_entry()
              wait_frontend_count(count)
          machine.succeed("systemctl is-active emubox-library-test-session")

      with subtest("Three unrequested short exits after a requested restart end the session"):
          for count in (18, 19):
              machine.succeed("pkill -TERM -x es-de")
              wait_frontend_count(count)
          machine.succeed("pkill -TERM -x es-de")
          machine.wait_until_succeeds(
              "test $(systemctl show -P ActiveState emubox-library-test-session) = inactive"
          )
          journal = machine.succeed("journalctl -u emubox-library-test-session --no-pager")
          assert "three short runs in a row" in journal, journal
          assert machine.succeed("grep -c '^frontend ' /run/emubox-library-test/events").strip() == "19"

      with subtest("A requested restart resets two prior short exits"):
          machine.succeed("systemctl start emubox-library-test-session")
          wait_frontend_count(20)
          for count in (21, 22):
              machine.succeed("pkill -TERM -x es-de")
              wait_frontend_count(count)
          run_tools_entry()
          wait_frontend_count(23)
          machine.succeed("pkill -TERM -x es-de")
          wait_frontend_count(24)
          machine.succeed("systemctl is-active emubox-library-test-session")

      with subtest("A failed termination request clears its restart mark"):
          machine.succeed("printf 'lose-target\\n' > /run/emubox-library-test/pgrep-mode")
          status, output = machine.execute(player(
              "env XDG_RUNTIME_DIR=/run/emubox-library-test "
              + shlex.quote(interpreter) + " " + shlex.quote(entry)
          ))
          assert status != 0, output
          machine.succeed("test ! -e /run/emubox-library-test/emubox-frontend-restart")
          machine.succeed("rm /run/emubox-library-test/pgrep-mode")
          machine.succeed("pkill -TERM -x es-de")
          wait_frontend_count(25)
          journal = machine.succeed("journalctl -u emubox-library-test-session --no-pager")
          assert "crash 2 of 3" in journal, journal

      with subtest("Real generation keeps frontend-only formats and distinct nested paths"):
          machine.succeed("systemctl stop emubox-library-test-session")
          base = "/data/cache/library-preservation"
          machine.succeed(f"install -d -o player -g player {base}/roms/n3ds {base}/import/textual {base}/gamelists/n3ds")
          files = {
              "roms/n3ds/cached.3ds": "cached fixture ROM",
              "import/definitions.dat": "Description: ###DESCRIPTION###\n",
              "import/textual/cached.txt": "Description: Imported preservation description\n",
              "import.ini": f"[main]\nimportFolder={base}/import\n",
          }
          for name, content in files.items():
              machine.succeed("printf %s " + shlex.quote(content) + " > " + shlex.quote(base + "/" + name))
          machine.succeed(f"chown -R player:player {base}")
          machine.succeed(player(
              "${pkgs.skyscraper}/bin/Skyscraper -p 3ds -s import "
              f"-c {base}/import.ini -i {base}/roms/n3ds -d {base}/cache/n3ds --flags unattend"
          ))
          machine.succeed(f"install -d -o player -g player {base}/roms/n3ds/nested")
          for name in ("uncached.cxi", "nested/cached.3ds"):
              machine.succeed("printf %s " + shlex.quote("different ROM " + name) + " > " + shlex.quote(base + "/roms/n3ds/" + name))
          old = ET.Element("gameList")
          for name, count in (("cached.3ds", "7"), ("uncached.cxi", "8"), ("nested/cached.3ds", "9"), ("deleted.cxi", "10")):
              game = ET.SubElement(old, "game")
              for tag, value in {"path": "./" + name, "favorite": "true", "playcount": count, "altemulator": "custom-" + count}.items():
                  ET.SubElement(game, tag).text = value
          machine.succeed("printf %s " + shlex.quote(ET.tostring(old, encoding="unicode")) + f" > {base}/gamelists/n3ds/gamelist.xml")
          settings = json.loads(machine.succeed("cat /etc/emubox/library.json"))
          settings.update(rom_root=base + "/roms", cache_root=base + "/cache",
                          gamelist_root=base + "/gamelists", media_root=base + "/media",
                          skyscraper="${pkgs.skyscraper}/bin/Skyscraper")
          machine.succeed("printf %s " + shlex.quote(json.dumps(settings)) + f" > {base}/library.json")
          machine.succeed(f"printf 'n3ds\\n' > {base}/cache/pending")
          machine.succeed(f"chown -R player:player {base}")
          machine.succeed(player("${pkgs.emubox-library}/bin/emubox-library-generate " + f"--config {base}/library.json"))
          root = ET.fromstring(machine.succeed(f"cat {base}/gamelists/n3ds/gamelist.xml"))
          entries = {entry.findtext("path").removeprefix("./"): entry for entry in root.findall("game")}
          assert set(entries) == {"cached.3ds", "uncached.cxi", "nested/cached.3ds"}, entries
          for name, count in (("cached.3ds", "7"), ("uncached.cxi", "8"), ("nested/cached.3ds", "9")):
              assert entries[name].findtext("favorite") == "true"
              assert entries[name].findtext("playcount") == count
              assert entries[name].findtext("altemulator") == "custom-" + count
          assert entries["cached.3ds"].findtext("desc") == "Imported preservation description"
          assert not entries["uncached.cxi"].findtext("desc")
          record = json.loads(machine.succeed(f"cat {base}/cache/last-run.json"))
          assert record["folders"] == {"n3ds": "generated"}, record
          machine.succeed(f"test ! -s {base}/cache/pending")
    '';
}
