# Design section 10: USB-A slot 1..4 = player 1..4, SDL device order, BT pairing.
{ config, lib, ... }:
let
  ports = config.emubox.facts.controllerPorts;
in
{
  # /dev/input/emubox-pN from each port's ID_PATH; rules apply on hotplug.
  services.udev.extraRules = lib.concatImapStringsSep "\n" (
    i: path:
    ''SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_JOYSTICK}=="1", ENV{ID_PATH}=="${path}", SYMLINK+="input/emubox-p${toString i}"''
  ) ports;

  # TODO(design 10): export SDL_JOYSTICK_DEVICE in the session, hotkeys,
  # the "Pair a controller" discoverable window.
  hardware.xpadneo.enable = true;
  hardware.bluetooth.settings.General = {
    ClassicBondedOnly = false;
  };
}
