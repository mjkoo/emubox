# Design section 13: NixOS VM test. Scaffold level: the software stack boots
# and the kiosk user exists. Grows to: ES-DE running, mode switch and back,
# each emulator with a homebrew ROM, save-leak and backup-path checks.
{ pkgs, self }:
pkgs.testers.runNixOSTest {
  name = "emubox-boot";
  nodes.machine = {
    imports = [ self.nixosModules.emubox ];
    virtualisation.memorySize = 2048;
  };
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("id player")
    machine.succeed("test -d /data/roms")
  '';
}
