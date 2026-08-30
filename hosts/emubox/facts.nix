# Facts about this host. Hardware placeholders are marked TODO(bring-up)
# and are filled in from the hardware checklist (design 13).
{
  emubox.facts = {
    # TODO(cache): the public key shown on the emubox cache at
    # app.cachix.org once the cache exists; null leaves cache.nixos.org as
    # the only substituter.
    binaryCachePublicKey = null;
    # nixos-anywhere over the installer sees the one M.2 as diskseq 1.
    disk = "/dev/disk/by-diskseq/1";
    # TODO(bring-up): the four USB-A ID_PATH values in physical port order,
    #   udevadm info -q property /dev/input/eventN | grep ID_PATH
    # USB-C is deliberately not a slot.
    controllerPorts = [ ];
    # TODO(bring-up): confirm the connector the TV is on.
    hdmiOutput = "HDMI-A-1";
  };
}
