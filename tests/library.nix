# Graphical probes for the terminal, frontend and local scraper contracts.
{ self }:
let
  pkgs = self.nixosConfigurations.emubox.pkgs;

  # Fixed pixel size and contrast make the visible fixture independent of
  # terminal defaults and the virtual monitor's reported DPI.
  terminalConfig = pkgs.writeTextFile {
    name = "emubox-probe-foot.ini";
    text = ''
      font=DejaVu Sans Mono:pixelsize=32
      pad=32x32
      initial-color-theme=light
      [colors-light]
      foreground=000000
      background=ffffff
    '';
    checkPhase = ''
      ${pkgs.foot}/bin/foot --check-config --config "$target"
    '';
  };
  terminalPresentation = {
    fonts.packages = [ pkgs.dejavu_fonts ];
    systemd.tmpfiles.rules = [
      "d /data/home/player/.config 0755 player player -"
      "d /data/home/player/.config/foot 0755 player player -"
      "L+ /data/home/player/.config/foot/foot.ini - - - - ${terminalConfig}"
    ];
  };

  terminalClient = pkgs.writeShellScript "emubox-terminal-client" ''
    case "$(cat /run/emubox-probe-mode 2>/dev/null || echo wait)" in
      wait)
        printf 'FOOT ALONE PROBE\n'
        touch /data/home/player/emubox-terminal-ready
        while [ ! -e /run/emubox-probe-release ]; do sleep 1; done
        ;;
      success) exit 0 ;;
      skip) exit 75 ;;
      *) exit 90 ;;
    esac
  '';
  cageProbe = pkgs.writeShellScript "emubox-cage-probe" ''
    client=${terminalClient}
    if [ "$(cat /run/emubox-probe-mode 2>/dev/null || echo wait)" = missing ]; then
      client=/run/emubox-probe-missing-executable
    fi
    exec ${pkgs.coreutils}/bin/timeout --kill-after=30 2100 \
      ${pkgs.cage}/bin/cage -s -- ${pkgs.foot}/bin/foot -e "$client"
  '';

  gameEntry = pkgs.writeTextDir "update.sh" ''
    if [ ! -e /data/home/player/emubox-probe-launched ]; then
      touch /data/home/player/emubox-probe-launched
      ${pkgs.cage}/bin/cage -s -- ${pkgs.foot}/bin/foot -e ${pkgs.bash}/bin/bash -c \
        'printf "FOOT CHILD PROBE\\n"; touch /data/home/player/emubox-child-terminal-ready; while [ ! -e /data/home/player/emubox-probe-release ]; do sleep 1; done'
      touch /data/home/player/emubox-probe-complete
    else
      frontend=$(pgrep -u player -x es-de | head -n 1)
      if [ -e /data/home/player/emubox-probe-signal-cage ]; then
        kill -TERM "$(ps -o ppid= -p "$frontend" | tr -d ' ')"
      else
        kill -TERM "$frontend"
      fi
    fi
  '';
  customSystems = ''
    <?xml version="1.0"?>
    <systemList>
      <system>
        <name>emuboxprobe</name>
        <fullname>Tools</fullname>
        <path>${gameEntry}</path>
        <extension>.sh</extension>
        <command>${pkgs.bash}/bin/bash %ROM%</command>
        <platform>ignore</platform>
        <theme>emuboxprobe</theme>
      </system>
    </systemList>
  '';
  importImage = "${pkgs.skyscraper.src}/resources/boxfront.png";
in
{
  name = "emubox-library";
  enableOCR = true;

  nodes.standalone =
    { lib, ... }:
    {
      imports = [
        self.nixosModules.emubox
        ../hosts/emubox/facts.nix
        ./boot-adaptations.nix
        terminalPresentation
      ];
      system.stateVersion = "26.05";
      virtualisation.memorySize = 2048;
      virtualisation.qemu.options = [ "-vga none -device virtio-gpu-pci" ];
      services.displayManager.sddm.enable = lib.mkForce false;
      services.displayManager.autoLogin.enable = lib.mkForce false;
      services.cage = {
        enable = true;
        user = "player";
        program = "${pkgs.foot}/bin/foot";
      };
      systemd.services.cage-tty1.serviceConfig.ExecStart = lib.mkForce "${cageProbe}";
      services.btrbk.instances.local.onCalendar = lib.mkForce null;
      emubox.facts.controllerPorts = lib.mkForce [ ];
      emubox.facts.controllerIdentities.sdlGamepadName = lib.mkForce null;
      emubox.facts.controllerIdentities.sdlJoystickGuid = lib.mkForce null;
    };

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        self.nixosModules.emubox
        ../hosts/emubox/facts.nix
        ./boot-adaptations.nix
        terminalPresentation
      ];
      system.stateVersion = "26.05";
      virtualisation.memorySize = 3072;
      virtualisation.qemu.options = [ "-vga none -device virtio-gpu-pci" ];
      services.btrbk.instances.local.onCalendar = lib.mkForce null;
      emubox.facts.controllerPorts = lib.mkForce [ ];
      emubox.facts.controllerIdentities.sdlGamepadName = lib.mkForce null;
      emubox.facts.controllerIdentities.sdlJoystickGuid = lib.mkForce null;
      emubox.kiosk.customSystems = lib.mkForce customSystems;
      emubox.kiosk.ownedFiles."settings/es_settings.xml".enforce.SaveGamelistsMode = {
        type = "string";
        value = "on exit";
      };
    };

  testScript = ''
    import shlex
    import xml.etree.ElementTree as ET

    ${builtins.readFile ./lib/test_helpers.py}

    def player(command):
        return "su player -s /bin/sh -c " + shlex.quote(command)

    def esde_pids():
        rc, output = machine.execute("pgrep -u player -x es-de")
        return [int(pid) for pid in output.split()] if rc == 0 else []

    def terminal_status(mode):
        standalone.succeed(f"printf '%s\\n' {shlex.quote(mode)} > /run/emubox-probe-mode")
        standalone.succeed("systemctl reset-failed cage-tty1.service")
        standalone.succeed("systemctl start cage-tty1.service")
        standalone.wait_until_succeeds(
            "! systemctl is-active --quiet cage-tty1.service", timeout=30
        )
        return int(standalone.succeed(
            "systemctl show cage-tty1.service -p ExecMainStatus --value"
        ).strip())

    with subtest("A standalone Cage session displays foot"):
        standalone.start()
        standalone.wait_until_succeeds(
            "test -e /data/home/player/emubox-terminal-ready", timeout=120
        )
        standalone.succeed("pgrep -u player -x foot")
        standalone.succeed(player("${pkgs.foot}/bin/foot --check-config"))
        try:
            standalone.wait_for_text(r"FOOT\s+ALONE\s+PROBE", timeout=60)
        finally:
            standalone.screenshot("foot-alone")
        standalone.succeed("touch /run/emubox-probe-release")
        standalone.wait_until_succeeds(
            "! systemctl is-active --quiet cage-tty1.service", timeout=30
        )
        assert int(standalone.succeed(
            "systemctl show cage-tty1.service -p ExecMainStatus --value"
        ).strip()) == 0

    with subtest("The terminal chain preserves its child exit status"):
        assert terminal_status("success") == 0
        assert terminal_status("skip") == 75
        missing_status = terminal_status("missing")
        assert missing_status not in (0, 75), missing_status
        print(f"foot launch failure exited {missing_status}")
        standalone.shutdown()

    with subtest("The frontend loads the read-only store system"):
        machine.start()
        machine.wait_until_succeeds("pgrep -u player -x es-de", timeout=120)
        frontend_log_path = "/data/es-de/logs/es_log.txt"
        machine.wait_until_succeeds(
            f"grep -F 'Found custom systems configuration file' {frontend_log_path}", timeout=60
        )
        machine.succeed(
            f"grep -E 'Parsed configuration for .* loaded 1 system ' {frontend_log_path}"
        )
        machine.succeed(f"grep -F 'Total game count: 1' {frontend_log_path}")
        definition = machine.succeed("cat /data/es-de/custom_systems/es_systems.xml")
        assert "<name>emuboxprobe</name>" in definition, definition
        assert "<path>${gameEntry}</path>" in definition, definition
        machine.succeed("test -f ${gameEntry}/update.sh")
        machine.succeed(player("test ! -w ${gameEntry}/update.sh"))
        assert not "${gameEntry}".startswith("/data/roms/")

    with subtest("A keyboard launch opens foot as an ES-DE child"):
        machine.wait_for_text("Tools", timeout=60)
        machine.send_key("ret")
        machine.wait_for_text("update", timeout=60)
        machine.send_key("ret")
        machine.wait_until_succeeds(
            "test -e /data/home/player/emubox-probe-launched", timeout=60
        )
        machine.wait_until_succeeds(
            "test -e /data/home/player/emubox-child-terminal-ready", timeout=60
        )
        machine.succeed("pgrep -u player -x foot")
        try:
            machine.wait_for_text(r"FOOT\s+CHILD\s+PROBE", timeout=60)
        finally:
            machine.screenshot("foot-from-frontend")
        launch_log = machine.succeed("cat /data/es-de/logs/es_log.txt")
        assert 'Launching game "update" from system "Tools (emuboxprobe)"' in launch_log, launch_log
        machine.succeed("touch /data/home/player/emubox-probe-release")
        machine.wait_until_succeeds(
            "test -e /data/home/player/emubox-probe-complete", timeout=60
        )
        machine.wait_for_text("update", timeout=60)

    with subtest("The child can end ES-DE as a normal quit and it relaunches"):
        gamelist_path = "/data/es-de/gamelists/emuboxprobe/gamelist.xml"

        def persisted_playcount():
            rc, text = machine.execute(f"cat {gamelist_path}")
            if rc != 0:
                return None
            games = ET.fromstring(text).findall("game")
            assert len(games) == 1, text
            return games[0].findtext("playcount")

        def signal_and_wait():
            assert persisted_playcount() is None, (
                "the VM's on-exit save setting did not keep playcount in memory"
            )
            before = esde_pids()[0]
            machine.send_key("ret")
            retry(lambda _: any(pid != before for pid in esde_pids()), timeout_seconds=120)

        signal_and_wait()
        if persisted_playcount() in ("1", "2"):
            print("ES-DE SIGTERM saved the first launch's playcount and the session relaunched")
        else:
            print("ES-DE SIGTERM did not persist playcount; probing its Cage parent")
            machine.succeed("rm /data/home/player/emubox-probe-launched")
            machine.succeed("rm /data/home/player/emubox-probe-complete")
            machine.succeed("touch /data/home/player/emubox-probe-signal-cage")
            machine.wait_for_text("Tools", timeout=60)
            machine.send_key("ret")
            machine.wait_for_text("update", timeout=60)
            machine.send_key("ret")
            machine.wait_until_succeeds(
                "test -e /data/home/player/emubox-probe-launched", timeout=60
            )
            machine.succeed("touch /data/home/player/emubox-probe-release")
            machine.wait_until_succeeds(
                "test -e /data/home/player/emubox-probe-complete", timeout=60
            )
            machine.wait_for_text("update", timeout=60)
            signal_and_wait()
            assert persisted_playcount() in ("1", "2"), (
                "neither ES-DE nor its Cage parent persisted the played game"
            )
            print("Cage SIGTERM saved the first launch's playcount and the session relaunched")

    with subtest("A first local import deploys resources and populates cache"):
        machine.succeed("test ! -e /data/home/player/.skyscraper")
        machine.succeed("install -d -o player -g player /data/roms/nes")
        machine.succeed("install -d -o player -g player /data/cache/skyscraper")
        machine.succeed("install -d -o player -g player /data/cache/skyscraper/probe-import/covers")
        machine.succeed("printf 'fixture rom' > /data/roms/nes/fixture.nes")
        machine.succeed("chown player:player /data/roms/nes/fixture.nes")
        machine.succeed("install -o player -g player ${importImage} /data/cache/skyscraper/probe-import/covers/fixture.png")
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
  '';
}
