# Facts about this host. Hardware placeholders are marked TODO(bring-up)
# and are filled in from the hardware bring-up checklist.
{
  emubox.facts = {
    # The emubox cache on app.cachix.org (see the flake's cache-roots).
    binaryCachePublicKey = "emubox.cachix.org-1:srT930MaM6CWp8n/CoYNOTLimZ8bFZBESyot6LawdSA=";
    # nixos-anywhere over the installer sees the one M.2 as diskseq 1.
    disk = "/dev/disk/by-diskseq/1";
    # TODO(bring-up): the four USB-A ID_PATH values in physical port order,
    #   udevadm info -q property /dev/input/eventN | grep ID_PATH
    # USB-C is deliberately not a slot.
    controllerPorts = [ ];
    # TODO(bring-up): the pad's SDL device name and SDL joystick GUID,
    #   sudo env SDL_VIDEODRIVER=dummy sdl2-jstest --list
    # sdlGamepadName is the text between the quotes on that output's
    # GameControllerConfig "Name:" line (or "Joystick Name:" if that
    # section says "missing"); sdlJoystickGuid is the "Joystick GUID:"
    # token, copied verbatim. Both null until then: a binding that
    # depends on either is declared nowhere in the meantime.
    controllerIdentities = { };
    # TODO(bring-up): confirm the connector the TV is on.
    hdmiOutput = "HDMI-A-1";
  };
}
