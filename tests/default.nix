# The VM test: disko's `installTest` over the real host configuration.
#
# This is a NixOS module. `flake.nix` extends `nixosConfigurations.emubox`
# with it; the harness then formats the real disko layout in an installer
# VM, installs the extended host toplevel with `switch-to-configuration
# boot`, and boots it through OVMF, systemd-boot and the initrd, which is
# where the root rollback and the early mounts live. `extraChecks` below
# runs on that booted node; it reboots it once cleanly and once by cutting
# the power.
#
# Every test override lives at this module's top level, never under
# `disko.tests.extraConfig`: a top-level override reaches both the installed
# system and the extended toplevel that `closure-no-secrets` greps, whereas
# `extraConfig` reaches only the harness's internal toplevel.
#
# The harness boots the installed VM with a fixed 1 GB and a 600 s test
# timeout and exposes no memory knob, so nothing here sets one.
{ config, lib, ... }:
let
  values = import ./values.nix;

  # The /data layout as `modules/library` declares it, so the test asserts
  # what the configuration says rather than a second copy of it.
  dataLayout = map (
    rule:
    let
      f = lib.splitString " " rule;
    in
    {
      path = lib.elemAt f 1;
      mode = lib.elemAt f 2;
      user = lib.elemAt f 3;
      group = lib.elemAt f 4;
    }
  ) (lib.filter (r: lib.hasPrefix "d /data/" r) config.systemd.tmpfiles.rules);

  # Python literal from a Nix value (strings, lists and attrsets only).
  py = builtins.toJSON;

  # Where a declared secret lands and with what owner and mode, as
  # modules/secrets declares it.
  secretFacts =
    name:
    let
      s = config.sops.secrets.${name};
    in
    {
      inherit (s) path mode;
      owner = if s.owner != null then s.owner else "root";
    };
in
{
  # Test secrets (design D7): the committed test host key decrypts
  # secrets/test.yaml, which holds the values from values.nix. Both mkForce,
  # because modules/secrets defines the same options for the box and a plain
  # definition would conflict or merge the real key path back in.
  # sops.age.keyFile stays null.
  sops.defaultSopsFile = lib.mkForce ../secrets/test.yaml;
  sops.age.sshKeyPaths = lib.mkForce [ ./test_host_ed25519_key ];

  # No host key is injected in the VM, so /etc/ssh/ssh_host_ed25519_key is
  # a dangling link into /persist and sshd's key generation would fail on
  # every run. sshd is loopback-only and nothing here asserts on it.
  services.openssh.enable = lib.mkForce false;

  disko.tests.extraChecks = ''
    # The harness itself only waits for local-fs.target; every boot phase
    # starts by waiting for multi-user.target.
    machine.wait_for_unit("multi-user.target")

    # --- vm-test: the VM boots through the real boot path -------------------

    with subtest("Layout matches the box: btrfs subvolume per mountpoint"):
        for mountpoint, subvol in {
            "/": "@root",
            "/nix": "@nix",
            "/persist": "@persist",
            "/data": "@data",
            "/data/cache": "@cache",
        }.items():
            out = machine.succeed(
                f"findmnt --noheadings --mountpoint {mountpoint} -o FSTYPE,SOURCE"
            )
            fstype, source = out.split()
            assert fstype == "btrfs", f"{mountpoint}: {out!r}"
            assert source.endswith(f"[/{subvol}]"), f"{mountpoint}: {out!r}"

    with subtest("Booted through systemd-boot"):
        out = machine.succeed("bootctl status")
        assert "systemd-boot" in out, out

    # --- persistence: the /data layout exists from the first boot ------------

    with subtest("player exists with its home under /data"):
        machine.succeed("id player")
        machine.succeed("test -d /data/home/player")
        assert machine.succeed("stat -c %U /data/home/player").strip() == "player"

    with subtest("/data layout has the declared owner and mode"):
        for entry in ${py dataLayout}:
            out = machine.succeed(f"stat -c '%a %U %G' {entry['path']}").strip()
            mode, user, group = out.split()
            assert int(mode, 8) == int(entry["mode"], 8), f"{entry['path']}: {out}"
            assert (user, group) == (entry["user"], entry["group"]), f"{entry['path']}: {out}"

    # --- persistence: proven across a clean reboot ---------------------------

    machine_id = machine.succeed("cat /etc/machine-id").strip()
    assert len(machine_id) == 32, f"machine-id not initialised: {machine_id!r}"
    machine.succeed("touch /root/marker /etc/marker /data/marker /tmp/marker")
    machine.succeed("sync")
    machine.shutdown()

    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("Root, /etc and /tmp markers are gone; /data marker remains"):
        machine.fail("test -e /root/marker")
        machine.fail("test -e /etc/marker")
        machine.fail("test -e /tmp/marker")
        machine.succeed("test -e /data/marker")

    with subtest("machine-id is stable across boots"):
        assert machine.succeed("cat /etc/machine-id").strip() == machine_id

    with subtest("Journal lists both boots and the previous one is readable"):
        out = machine.succeed("journalctl --list-boots --no-pager")
        boots = [l for l in out.splitlines() if l.split() and l.split()[0].lstrip("-").isdigit()]
        assert len(boots) == 2, out
        machine.succeed("journalctl -b -1 --no-pager -q | grep -q .")

    with subtest("/var/log resolves to storage under /persist"):
        # On btrfs findmnt shows the subvolume path in brackets, never a
        # /persist/... path.
        out = machine.succeed("findmnt --noheadings --target /var/log -o SOURCE").strip()
        assert out.endswith("[/@persist/var/log]"), out

    # --- persistence and base-system: power cut ------------------------------

    machine.succeed("touch /root/marker")
    machine.succeed("sync")
    machine.crash()

    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("After a power cut the root is wiped and no repair prompt held the boot"):
        machine.fail("test -e /root/marker")

    # --- secrets: decrypt in the VM ------------------------------------------
    # Expected content is compared in Python, never through a guest-shell
    # grep: the yescrypt hash's `$` fragments would expand there and match
    # vacuously. The store is not grepped from inside the VM; that is the
    # builder-side closure-no-secrets check.

    with subtest("Secrets exist on the runtime path with the declared mode and content"):
        for secret, value in [
            (${py (secretFacts "admin_password_hash")}, ${py values.hash}),
            (${py (secretFacts "wifi_ssid")}, ${py values.ssid}),
            (${py (secretFacts "wifi_psk")}, ${py values.psk}),
        ]:
            path = secret["path"]
            assert path.startswith("/run/secrets"), path
            out = machine.succeed(f"stat -c '%a %U' {path}").strip()
            expected = f"{int(secret['mode'], 8):o} {secret['owner']}"
            assert out == expected, f"{path}: {out!r} != {expected!r}"
            assert machine.succeed(f"cat {path}").strip() == value, path

    with subtest("admin logs in on tty2 with the test password"):
        # tty1 is the SDDM autologin's Wayland compositor, so switching VTs
        # needs the ctrl-alt chord; a bare alt-f2 goes to the compositor.
        machine.send_key("ctrl-alt-f2")
        machine.wait_until_tty_matches("2", "login: ")
        machine.send_chars("admin\n")
        machine.wait_until_tty_matches("2", "Password: ")
        machine.send_chars(${py values.password} + "\n")
        machine.wait_until_tty_matches("2", r"admin@.*\$")
  '';
}
