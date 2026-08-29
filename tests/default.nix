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
# The harness boots the installed VM with a fixed 1 GB and exposes no
# memory knob (its `meta.timeout = 600` is a Hydra hint; the driver's own
# bound is its 3600 s globalTimeout). The display manager is forced off
# here (the design's fallback, taken by decision rather than by
# measurement, since no KVM builder was available to measure the memory
# budget): the graphical stack is neither started nor waited on, the
# console login lands on tty1's getty instead of a VT the kiosk session
# picks at runtime, and the initrd, persistence, secrets and networking
# paths are unaffected. The graphical session is proven on hardware.
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

  # The persisted list as `modules/persistence` declares it.
  persisted = config.environment.persistence."/persist";
  persistedDirs = map (d: d.dirPath) persisted.directories;
  persistedFiles = map (f: f.filePath) persisted.files;

  # Python literal from a Nix value (strings, lists and attrsets only).
  py = builtins.toJSON;

  # Where a declared secret lands and with what owner and mode, as
  # modules/secrets declares it. sops-nix's `owner` defaults to null and
  # the file is then owned by uid 0.
  secretFacts =
    name:
    let
      s = config.sops.secrets.${name};
    in
    {
      inherit (s) path mode;
      owner = if s.owner != null then s.owner else "root";
    };

  # The search path WirePlumber's user service reads its config from; the
  # nixpkgs module passes config packages through XDG_DATA_DIRS.
  wireplumberDataDirs = lib.splitString ":" config.systemd.user.services.wireplumber.environment.XDG_DATA_DIRS;
in
{
  # Test secrets (design D7): the committed test host key decrypts
  # secrets/test.yaml, which holds the values from values.nix. Both mkForce,
  # because modules/secrets defines the same options for the box and a plain
  # definition would conflict or merge the real key path back in.
  # sops.age.keyFile stays null.
  sops = {
    defaultSopsFile = lib.mkForce ../secrets/test.yaml;
    age.sshKeyPaths = lib.mkForce [ ./test_host_ed25519_key ];
  };

  # No host key is injected in the VM, so /etc/ssh/ssh_host_ed25519_key is
  # a dangling link into /persist and sshd's key generation would fail on
  # every run. sshd is loopback-only and nothing here asserts on it.
  services.openssh.enable = lib.mkForce false;

  # The display-manager fallback (see the header).
  services.displayManager.sddm.enable = lib.mkForce false;

  # Eval-time checks of what the configuration declares. The firewall
  # invariant itself lives in modules/hardware so it guards the shipped
  # system; these guard the test's own inputs.
  assertions = [
    {
      assertion = dataLayout != [ ];
      message = "tests: no `d /data/...` tmpfiles rules found; the /data layout assertion would be vacuous";
    }
    {
      assertion =
        lib.all (k: k.type == "ed25519") config.services.openssh.hostKeys
        && lib.all (f: !lib.hasInfix "rsa" f) persistedFiles;
      message = "tests: the host key must be ed25519 only, in services.openssh.hostKeys and in the persisted list";
    }
  ];

  disko.tests.extraChecks = ''
    # The harness itself only waits for local-fs.target; every boot phase
    # starts by waiting for multi-user.target and asserts that nothing
    # failed on the way, since several paths here (persist units, secrets,
    # the WiFi profile) log and continue rather than stop the boot.
    def booted():
        machine.wait_for_unit("multi-user.target")
        failed = machine.succeed("systemctl --failed --no-legend --plain").strip()
        assert not failed, f"failed units:\n{failed}"

    booted()

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
        # Only the "Current Boot Loader" block proves the loader ran; the
        # "Available Boot Loaders" block lists it even after a direct
        # kernel load.
        out = machine.succeed("bootctl status")
        assert "Current Boot Loader:" in out, out
        current = out.split("Current Boot Loader:", 1)[1].split("\n\n", 1)[0]
        assert "systemd-boot" in current, out

    with subtest("/run is memory-backed"):
        assert machine.succeed("findmnt --noheadings -o FSTYPE /run").strip() == "tmpfs"

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

    # --- persistence: persisted paths are bound into the root ----------------

    with subtest("Every persisted directory resolves to storage under /persist"):
        # On btrfs findmnt shows the subvolume path in brackets, never a
        # /persist/... path.
        for d in ${py persistedDirs}:
            out = machine.succeed(f"findmnt --noheadings --target {d} -o SOURCE").strip()
            assert out.endswith(f"[/@persist{d}]"), f"{d}: {out}"

    with subtest("Every persisted file is a bind from /persist or a link into it"):
        for f in ${py persistedFiles}:
            rc, source = machine.execute(f"findmnt --noheadings -o SOURCE {f}")
            if rc == 0:
                # A bind of the persisted file, not a transient overmount
                # from /run.
                assert source.strip().endswith(f"[/@persist{f}]"), f"{f}: {source}"
            else:
                target = machine.succeed(f"readlink {f}").strip()
                assert target == f"/persist{f}", f"{f} -> {target}"

    # --- persistence: proven across a clean reboot ---------------------------

    machine_id = machine.succeed("cat /etc/machine-id").strip()
    assert len(machine_id) == 32, f"machine-id not initialised: {machine_id!r}"
    # A Persistent=true timer touches its stamp when first activated, so the
    # stamp's mtime is boot 1's; it must survive unchanged.
    machine.wait_for_file("/var/lib/systemd/timers/stamp-fstrim.timer", timeout=60)
    stamp_mtime = machine.succeed("stat -c %Y /var/lib/systemd/timers/stamp-fstrim.timer").strip()
    machine.succeed("touch /root/marker /etc/marker /data/marker /tmp/marker")
    machine.succeed("sync")
    machine.shutdown()

    machine.start()
    booted()

    with subtest("Root and /etc markers are gone; /data marker remains"):
        machine.fail("test -e /root/marker")
        machine.fail("test -e /etc/marker")
        machine.succeed("test -e /data/marker")

    with subtest("/tmp is clean at boot"):
        # Covered by boot.tmp.cleanOnBoot as well as the root wipe, so this
        # is the spec's /tmp scenario, not rollback evidence.
        machine.fail("test -e /tmp/marker")

    with subtest("machine-id is stable across boots and lives on /persist"):
        assert machine.succeed("cat /etc/machine-id").strip() == machine_id
        assert machine.succeed("cat /persist/etc/machine-id").strip() == machine_id
        machine.succeed("findmnt /etc/machine-id")

    with subtest("Persistent timer stamp survived the reboot"):
        assert machine.succeed("stat -c %Y /var/lib/systemd/timers/stamp-fstrim.timer").strip() == stamp_mtime

    with subtest("Journal lists both boots and the previous one is readable"):
        out = machine.succeed("journalctl --list-boots --no-pager")
        boots = [l for l in out.splitlines() if l.split() and l.split()[0].lstrip("-").isdigit()]
        assert len(boots) == 2, out
        # No pipe: the driver runs commands under pipefail, and a grep -q
        # that closes the pipe early would fail journalctl with SIGPIPE.
        assert machine.succeed("journalctl -b -1 --no-pager -q -n 5").strip(), "previous boot's journal is empty"

    # --- persistence and base-system: power cut ------------------------------

    machine.succeed("touch /root/marker /etc/marker /tmp/marker")
    machine.succeed("sync")
    machine.crash()

    machine.start()
    booted()

    with subtest("After a power cut the root is wiped, /data survived, no repair prompt held the boot"):
        machine.fail("test -e /root/marker")
        machine.fail("test -e /etc/marker")
        machine.fail("test -e /tmp/marker")
        machine.succeed("test -e /data/marker")
        assert machine.succeed("cat /etc/machine-id").strip() == machine_id

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
            assert path.startswith("/run/secrets"), f"secret off the runtime path: {path}"
            out = machine.succeed(f"stat -c '%a %U' {path}").strip()
            expected = f"{int(secret['mode'], 8):o} {secret['owner']}"
            assert out == expected, f"{path}: {out!r} != {expected!r}"
            assert machine.succeed(f"cat {path}").strip() == value, path

    with subtest("admin logs in on tty1 with the test password"):
        # No display manager in the test, so tty1 carries a getty.
        machine.wait_until_tty_matches("1", "login: ", timeout=120)
        machine.send_chars("admin\n")
        machine.wait_until_tty_matches("1", "Password: ", timeout=60)
        machine.send_chars(${py values.password} + "\n")
        machine.wait_until_tty_matches("1", r"admin@.*\$", timeout=120)

    # --- networking: the declaration is proven -------------------------------

    with subtest("family-wifi is listed, with the SSID and PSK from the test secret"):
        # The ensure-profiles unit is a oneshot without RemainAfterExit, so
        # it is inactive once done; wait for its artifact and check its
        # result rather than its active state.
        machine.wait_for_file("/run/NetworkManager/system-connections/family-wifi.nmconnection", timeout=120)
        # Meaningful only after the file exists: Result is also "success"
        # for a unit that never ran.
        result = machine.succeed("systemctl show -p Result --value NetworkManager-ensure-profiles.service").strip()
        assert result == "success", f"NetworkManager-ensure-profiles: {result}"
        machine.wait_until_succeeds("nmcli connection show family-wifi", timeout=60)
        conn = machine.succeed(
            "cat /run/NetworkManager/system-connections/family-wifi.nmconnection"
        ).replace(" ", "")
        assert ("ssid=" + ${py values.ssid}) in conn, conn
        assert ("psk=" + ${py values.psk}) in conn, conn

    with subtest("Nothing listens on the LAN"):
        def local_address(line):
            # ss -H columns: State Recv-Q Send-Q Local-Address:Port Peer ...
            # Wildcards print as 0.0.0.0:port, [::]:port or a bare *:port,
            # none of which is loopback.
            return line.split()[3]

        def is_loopback(addr):
            return addr.startswith("127.") or addr.startswith("[::1]:")

        for line in machine.succeed("ss -ltnH").splitlines():
            assert is_loopback(local_address(line)), f"TCP listener on the LAN: {line}"
        for line in machine.succeed("ss -lunH").splitlines():
            addr = local_address(line)
            # The DHCP clients (v4: 68, v6: 546) are the one allowed exception.
            if addr.rsplit(":", 1)[1] in ("68", "546"):
                continue
            assert is_loopback(addr), f"UDP listener on the LAN: {line}"

    # --- base-system ---------------------------------------------------------

    with subtest("WirePlumber HDMI-default fragment is on the daemon's config path"):
        fragment = "wireplumber/wireplumber.conf.d/51-emubox-hdmi-default.conf"
        found = [
            d for d in ${py wireplumberDataDirs}
            if machine.execute(f"test -e {d}/{fragment}")[0] == 0
        ]
        assert found, "fragment not found on XDG_DATA_DIRS"
        content = machine.succeed(f"cat {found[0]}/{fragment}")
        assert "priority.session" in content and "node.restore-default-targets" in content, content

    with subtest("Hygiene timers are active and swap is memory-backed"):
        machine.wait_until_succeeds(
            "systemctl is-active nix-gc.timer nix-optimise.timer fstrim.timer", timeout=60
        )
        swap = machine.wait_until_succeeds("swapon --show=NAME --noheadings | grep zram", timeout=60)
        assert "zram" in swap, swap

    with subtest("Runtime watchdog is declared at 30 s"):
        # The declaration, as the service manager reads it. The live
        # RuntimeWatchdogUSec value needs a watchdog device the VM does not
        # have; that is checked on hardware.
        conf = machine.succeed("systemd-analyze cat-config systemd/system.conf")
        assert "RuntimeWatchdogSec=30s" in conf, conf

    with subtest("Suspend is refused"):
        # The guest-side timeout bounds a refusal that hangs; a suspend that
        # actually happened would block the driver until its global timeout.
        machine.fail("systemctl suspend", timeout=30)

    with subtest("Time zone is America/New_York"):
        assert machine.succeed("timedatectl show -p Timezone --value").strip() == "America/New_York"

    with subtest("journald is size-capped and time-capped"):
        conf = machine.succeed("systemd-analyze cat-config systemd/journald.conf")
        assert "SystemMaxUse=256M" in conf, conf
        assert "MaxRetentionSec=1month" in conf, conf
  '';
}
