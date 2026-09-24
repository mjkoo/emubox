# Nonvisual integration checks for the real local scraper.
{ self }:
let
  pkgs = self.nixosConfigurations.emubox.pkgs;
  importImage = "${pkgs.skyscraper.src}/resources/boxfront.png";
in
{
  name = "emubox-library";

  nodes.machine =
    { lib, ... }:
    {
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
    };

  testScript = ''
    import shlex
    import xml.etree.ElementTree as ET

    def player(command):
        return "su player -s /bin/sh -c " + shlex.quote(command)

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("test -d /data/home/player")

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
