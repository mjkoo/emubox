# Boot adaptations every plain node built from the box's own software
# modules needs, factored out of tests/kiosk.nix so a second such node
# (tests/controllers.nix) cannot drift from the first: a missing adaptation
# here surfaces only when a VM test actually runs, which for this project is
# in CI, so the two nodes share one copy rather than two that have to be
# kept in step by hand.
{ lib, ... }:
{
  # No disko layout and no boot loader on a plain node, so the initrd units
  # that roll the root subvolume back and bind /persist have nothing to act
  # on.
  #
  # `suppressedUnits`, emphatically not `services.<name>.enable = false`:
  # `enable = false` *masks* a unit (a symlink to /dev/null) but still
  # emits its `.requires` links, and `modules/persistence` declares
  # `requiredBy = [ "sysroot.mount" ]` and `requiredBy =
  # [ "initrd-nixos-activation.service" ]`. systemd refuses to enqueue a
  # job that Requires= a masked unit, so sysroot.mount would fail, the
  # initrd would drop to emergency, and the node would never boot.
  boot.initrd.systemd.suppressedUnits = [
    "rollback-root.service"
    "persist-dirs.service"
    "persist-machine-id.service"
  ];

  # Memory-backed stand-ins for the two subvolumes the layout would
  # provide. neededForBoot because impermanence binds directories under
  # /persist before the switch to the real root.
  fileSystems."/persist" = {
    device = "tmpfs";
    fsType = "tmpfs";
    neededForBoot = true;
  };
  fileSystems."/data" = {
    device = "tmpfs";
    fsType = "tmpfs";
    neededForBoot = true;
  };

  # The committed test host key decrypts secrets/test.yaml, as the
  # install test does. Both mkForce, because modules/secrets defines the
  # same options for the box.
  sops = {
    defaultSopsFile = lib.mkForce ../secrets/test.yaml;
    age.sshKeyPaths = lib.mkForce [ ./test_host_ed25519_key ];
  };

  # No host key is injected here, so sshd's key generation would fail on
  # every run. Nothing on a plain node asserts on it.
  services.openssh.enable = lib.mkForce false;
}
