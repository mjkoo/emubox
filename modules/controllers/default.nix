# USB-A port order becomes player order: each recorded port gets a stable
# /dev/input/emubox-pN name, and the session is told to enumerate those names
# first, in order.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  ports = config.emubox.facts.controllerPorts;

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
  environment.sessionVariables = lib.mkIf (ports != [ ]) {
    SDL_JOYSTICK_DEVICE = lib.concatImapStringsSep ":" (i: _: "/dev/input/emubox-p${toString i}") ports;
  };

  # TODO: hotkeys, the "Pair a controller" discoverable window.
  hardware.xpadneo.enable = true;
  hardware.bluetooth.settings.General = {
    ClassicBondedOnly = false;
  };

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
}
