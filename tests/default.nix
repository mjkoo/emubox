# The install VM test: disko's `installTest` over the real host
# configuration. The session the box shows is tests/kiosk.nix's subject.
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
# paths are unaffected. The graphical session is proven by tests/kiosk.nix,
# which boots the same modules as a plain node with a memory knob and a
# virtual GPU; what needs a screen and a person stays a bring-up item.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  values = import ./values.nix;
  # A deliberately minimal repository double. It sees only runtime sops
  # environment variables, records no credentials, and copies the source the
  # backup helper mounted. This lets the install VM prove the service graph
  # and source transaction without contacting B2.
  fakeRestic = pkgs.writeShellScriptBin "restic" ''
    set -euo pipefail
    repo=/data/cache/emubox-restic-test
    mkdir -p "$repo"

    # The double models restic's command line by hand, so every time the
    # helper's argv changes the double mis-parses it. Left to exit codes
    # alone that is indistinguishable from a repository error and surfaces
    # several assertions later, against a fixture that never got written.
    # Recording the argv turns it into a located failure with the arguments
    # that caused it; `assert_double_understood_its_arguments` reads this.
    misuse() {
      mkdir -p /run/emubox
      printf 'fake restic did not model: %s\n' "$*" >> /run/emubox/restic-test-misuse
      exit 2
    }

    case "$1" in
      cat)
        # 10 is the only code the helper initializes on; everything else must
        # fail closed, so one non-10 code models the whole class.
        test ! -e /run/emubox/restic-test-init-network-fail || exit 1
        test -f "$repo/config" || exit 10
        printf '%s\n' '{"id":"emubox-test-repository"}'
        ;;
      init)
        : > "$repo/config"
        ;;
      backup)
        test ! -e /run/emubox/restic-test-fail || exit 1
        if test -e /run/emubox/restic-test-pause; then
          test -r /run/emubox/restic-source/saves/snapshot-consistency-fixture
          findmnt -no OPTIONS --target /run/emubox/restic-source \
            | tr ',' '\n' \
            | grep -qx ro
          : > /run/emubox/restic-test-ready
          while test -e /run/emubox/restic-test-pause; do sleep 1; done
        fi
        rm -rf -- "$repo/snapshot"
        mkdir -p "$repo/snapshot"
        # `services.restic` passes every option in `--name=value` form and the
        # paths through `--files-from`, so there are no positional paths left.
        excludes="" includes=""
        shift
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --exclude-file=*) excludes="''${1#--exclude-file=}" ;;
            --files-from=*) includes="''${1#--files-from=}" ;;
            --retry-lock=*|--host=*|--tag=*) ;;
            *) misuse "backup $*" ;;
          esac
          shift
        done
        test -n "$includes" || misuse "backup without --files-from"
        while IFS= read -r path; do
          case "$path" in
            "") ;;
            /run/emubox/restic-source/*)
              relative="''${path#/run/emubox/restic-source/}"
              mkdir -p "$repo/snapshot/$relative"
              cp -a "$path/." "$repo/snapshot/$relative/"
              ;;
            # Anything outside the transient source would mean restic was
            # pointed at the live tree.
            *) misuse "backup path outside the source: $path" ;;
          esac
        done < "$includes"
        if [ -n "$excludes" ]; then
          while IFS= read -r path; do
            relative="''${path#/run/emubox/restic-source/}"
            rm -rf -- "$repo/snapshot/$relative"
          done < "$excludes"
        fi
        : > "$repo/backup-ran"
        ;;
      snapshots)
        printf '%s\n' '[{"short_id":"emubox-test-snapshot"}]'
        ;;
      forget|check|unlock)
        ;;
      *)
        misuse "$*"
        ;;
    esac
  '';

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
  saveRoutes = config.emubox.saves.saveRoutes;
  saveBindMappings = config.emubox.saves.bindMappings;
  saveRoutesJson = builtins.toJSON saveRoutes;
  saveBindMappingsJson = builtins.toJSON saveBindMappings;
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

  emubox.backups = {
    enable = true;
    package = fakeRestic;
    b2 = {
      endpoint = "https://s3.us-west-004.backblazeb2.com";
      bucket = "emubox-test-backups";
      prefix = "emubox";
    };
  };

  systemd.services = {
    "restic-backups-emubox".path = [ fakeRestic ];
    "restic-backups-emubox-maintenance".path = [ fakeRestic ];
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
      assertion = lib.getExe config.emubox.backups.package == lib.getExe fakeRestic;
      message = "tests: off-site backup commands must use the local restic double";
    }
    {
      assertion =
        lib.all (k: k.type == "ed25519") config.services.openssh.hostKeys
        && lib.all (f: !lib.hasInfix "rsa" f) persistedFiles;
      message = "tests: the host key must be ed25519 only, in services.openssh.hostKeys and in the persisted list";
    }
  ];

  disko.tests.extraChecks = ''
    import contextlib
    import json

    # The harness itself only waits for local-fs.target; every boot phase
    # starts by waiting for multi-user.target and asserts that nothing
    # failed on the way, since several paths here (persist units, secrets,
    # the WiFi profile) log and continue rather than stop the boot.
    def booted():
        machine.wait_for_unit("multi-user.target")
        failed = machine.succeed("systemctl --failed --no-legend --plain").strip()
        assert not failed, f"failed units:\n{failed}"

    booted()

    # --- harness ------------------------------------------------------------
    # Parsed once, at the top: these were read out of the configuration inside
    # a subtest, so a failure there left every later subtest raising NameError
    # instead of reporting its own result.
    save_routes = json.loads(${py saveRoutesJson})
    save_bind_mappings = json.loads(${py saveBindMappingsJson})
    rollback_mapping = save_bind_mappings[0]

    BACKUP = "restic-backups-emubox.service"
    RESTIC_UNITS = [
        BACKUP,
        "restic-backups-emubox-maintenance.service",
        "emubox-restic-reconcile.service",
    ]

    def unit_property(unit, name):
        return machine.succeed(f"systemctl show --value --property={name} {unit}").strip()

    def reset_restic_units():
        """Clear failed state, and the start rate limiter, for the whole family."""
        machine.succeed("systemctl reset-failed " + " ".join(RESTIC_UNITS))

    def start_backup(expect="success"):
        """Start the backup unit and assert it *ran*, then that it ended in `expect`.

        The invocation id is the discriminating evidence. `machine.fail` on a
        `systemctl start` is satisfied by a dependency failure, a start-limit
        refusal or a misspelled unit name just as readily as by the backup
        running and failing, which is the only thing the fault-injection
        subtests actually mean. A run that never happened leaves the id, and
        so `emubox-status`, pointing at the previous success.
        """
        reset_restic_units()
        before = unit_property(BACKUP, "InvocationID")
        machine.execute(f"systemctl start {BACKUP}")
        after = unit_property(BACKUP, "InvocationID")
        assert after and after != before, (
            f"{BACKUP} never activated (invocation still {before!r}); failed units:\n"
            + machine.succeed("systemctl --failed --no-legend --plain")
        )
        result = unit_property(BACKUP, "Result")
        assert result == expect, f"{BACKUP}: Result={result!r}, expected {expect!r}"

    @contextlib.contextmanager
    def restic_fault(marker):
        """Inject a fake-restic fault, and remove it even when the block fails.

        Removing the marker on the last line of a subtest skips the removal
        exactly when it matters most, leaving every later subtest talking to a
        restic that always fails.
        """
        machine.succeed(f"mkdir -p /run/emubox && touch /run/emubox/{marker}")
        try:
            yield
        finally:
            machine.succeed(f"rm -f /run/emubox/{marker}")

    @contextlib.contextmanager
    def unmounted(where):
        """Stop the bind mount unit covering `where`, and always restart it."""
        unit = machine.succeed(f"systemd-escape --path --suffix=mount {where}").strip()
        machine.succeed(f"systemctl stop {shlex.quote(unit)}")
        try:
            yield
        finally:
            machine.succeed(f"systemctl start {shlex.quote(unit)}")

    def assert_double_understood_its_arguments():
        rc, recorded = machine.execute("cat /run/emubox/restic-test-misuse")
        assert rc != 0, f"the restic double was called with arguments it does not model:\n{recorded}"

    subtest_failures = []

    @contextlib.contextmanager
    def checked(name):
        """Record a subtest failure and carry on to the next subtest.

        The driver's own `subtest` re-raises, so the first failed assertion
        ends the script and one CI build reports exactly one defect. With no
        KVM available locally that build is the only feedback channel, which
        is what turned a handful of harness defects into a run per defect.
        These checks restore the machine through `start_backup` and
        `restic_fault`, so collecting them is safe; `subtest_failures` is
        asserted once, at the end.
        """
        try:
            with subtest(name):
                yield
        except Exception as error:
            subtest_failures.append(f"{name}: {error}")

    # --- vm-test: the VM boots through the real boot path -------------------

    with subtest("Layout matches the box: btrfs subvolume per mountpoint"):
        for mountpoint, subvol in {
            "/": "@root",
            "/nix": "@nix",
            "/persist": "@persist",
            "/data": "@data",
            "/data/cache": "@cache",
            "/data/.snapshots": "@snapshots",
        }.items():
            out = machine.succeed(
                f"findmnt --noheadings --mountpoint {mountpoint} -o FSTYPE,SOURCE"
            )
            fstype, source = out.split()
            assert fstype == "btrfs", f"{mountpoint}: {out!r}"
            assert source.endswith(f"[/{subvol}]"), f"{mountpoint}: {out!r}"

    with subtest("Local snapshot history is root-only and never recursively captures cache"):
        snapshot_root = "/data/.snapshots"
        assert machine.succeed(f"stat -c '%a %U %G' {snapshot_root}").strip() == "700 root root"
        machine.fail(f"sudo -u player test -r {snapshot_root}")
        machine.succeed("systemctl stop btrbk-local.timer")
        machine.succeed("systemctl stop btrbk-local.service")
        machine.succeed("touch /data/local-snapshot-fixture /data/cache/cache-only-fixture")

        # The retention windows themselves are btrbk implementing
        # `snapshot_preserve`; the declared policy is pinned at evaluation in
        # tests/snapshots.nix, which is where a wrong constant should fail. What
        # runs here is ours: the subvolume layout that decides what a snapshot
        # can reach, and btrbk being able to act on it at all.
        machine.succeed("systemctl start btrbk-local.service")
        result = machine.succeed(
            "systemctl show -p Result --value btrbk-local.service"
        ).strip()
        assert result == "success", result

        retained = machine.succeed(
            f"find {snapshot_root} -mindepth 1 -maxdepth 1 -type d -printf '%f\\n'"
        ).splitlines()
        assert retained, "btrbk retained no snapshot of /data"

        # btrbk defines snapshots as read-only. The latest real snapshot has
        # the current fixture but neither sibling subvolume below @data.
        latest = sorted(retained)[-1]
        properties = machine.succeed(
            f"btrfs property get -ts {snapshot_root}/{latest} ro"
        ).strip()
        assert properties == "ro=true", properties
        machine.succeed(f"test -e {snapshot_root}/{latest}/local-snapshot-fixture")
        machine.fail(f"test -e {snapshot_root}/{latest}/cache/cache-only-fixture")
        # A btrfs snapshot preserves the nested subvolume's empty mountpoint,
        # but never recursively copies the sibling subvolume or its contents.
        machine.fail(
            f"find {snapshot_root}/{latest}/.snapshots -mindepth 1 -print -quit | grep -q ."
        )

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

    with checked("Every declared save route is writable and every bind route is mounted"):
        for route in save_routes:
            destination = route["destination"]
            machine.succeed(f"test -d {destination}")
            machine.succeed(f"sudo -u player touch {destination}/vm-route-write")
        for mapping in save_bind_mappings:
            machine.succeed(f"mountpoint -q {mapping['where']}")

    with checked("Migration accepts equal data and rejects conflicts without overwriting"):
        # A bind target is unmounted only for this isolated migration check;
        # `unmounted` restores it even when an assertion here fails, so a
        # failure cannot leave the save routes down for every later subtest.
        mapping = save_bind_mappings[0]
        with unmounted(mapping["where"]):
            machine.succeed(f"mkdir -p {mapping['where']} {mapping['what']}")
            machine.succeed(f"printf equal > {mapping['where']}/equal.sav")
            machine.succeed(f"printf equal > {mapping['what']}/equal.sav")
            machine.succeed("${pkgs.emubox-save-migrate}/bin/emubox-save-migrate /etc/emubox/save-routes.json")
            machine.succeed(f"test -f {mapping['what']}/equal.sav")
            machine.succeed(f"printf old > {mapping['where']}/conflict.sav")
            machine.succeed(f"printf new > {mapping['what']}/conflict.sav")
            machine.fail("${pkgs.emubox-save-migrate}/bin/emubox-save-migrate /etc/emubox/save-routes.json")
            assert machine.succeed(f"cat {mapping['where']}/conflict.sav").strip() == "old"
            assert machine.succeed(f"cat {mapping['what']}/conflict.sav").strip() == "new"
            machine.succeed(f"rm {mapping['where']}/conflict.sav")
        machine.succeed(f"mountpoint -q {mapping['where']}")

    # --- off-site backups: local fake repository, real service transaction --

    with checked("Restic uses one read-only source and backs up only typed roots"):
        machine.succeed("systemctl stop restic-backups-emubox.timer")
        machine.succeed("mkdir -p /data/es-de /data/bios /data/home/player/.cache /data/home/player/.local/cache")
        machine.succeed("printf original > /data/saves/snapshot-consistency-fixture")
        machine.succeed("printf esde > /data/es-de/esde-fixture")
        machine.succeed("printf bios > /data/bios/bios-fixture")
        machine.succeed("printf excluded > /data/home/player/.cache/cache-fixture")
        machine.succeed("printf excluded > /data/home/player/.local/cache/cache-fixture")
        machine.succeed("printf include-me > /data/home/player/unlisted-home-fixture")
        # Started with --no-block and held at the double's pause point, so the
        # live file can be changed while the source snapshot is open. A
        # blocking start would wait on a service that is waiting on this test.
        with restic_fault("restic-test-pause"):
            reset_restic_units()
            machine.succeed(f"systemctl start --no-block {BACKUP}")
            machine.wait_until_succeeds("test -e /run/emubox/restic-test-ready")
            machine.succeed("printf changed-after-snapshot > /data/saves/snapshot-consistency-fixture")
        machine.wait_until_succeeds("test -e /data/cache/emubox-restic-test/backup-ran")
        machine.wait_until_succeeds(
            f"test $(systemctl show -p ActiveState --value {BACKUP}) = inactive"
        )
        assert machine.succeed("cat /data/cache/emubox-restic-test/snapshot/saves/snapshot-consistency-fixture").strip() == "original"
        machine.succeed("test -e /data/cache/emubox-restic-test/snapshot/es-de/esde-fixture")
        machine.succeed("test -e /data/cache/emubox-restic-test/snapshot/bios/bios-fixture")
        machine.succeed("test -e /data/cache/emubox-restic-test/snapshot/home/player/unlisted-home-fixture")
        machine.fail("test -e /data/cache/emubox-restic-test/snapshot/home/player/.cache/cache-fixture")
        machine.fail("test -e /data/cache/emubox-restic-test/snapshot/home/player/.local/cache/cache-fixture")
        machine.fail("mountpoint -q /run/emubox/restic-source")
        machine.fail("find /data/.snapshots/restic -mindepth 1 -maxdepth 1 -name 'restic-*' | grep .")
        assert unit_property(BACKUP, "Result") == "success"
        # No restore round trip: the double copies a tree and would copy it
        # back, exercising the double rather than this project. The bytes
        # asserted above already prove the source snapshot, not the live file,
        # is what reached restic. Verified restore is proven where it is real,
        # against B2, in the E12 rollout checklist.

    with checked("Runtime symlink aliases fail before restic sees backup inputs"):
        for alias, target in [
            ("/data/home/player/.cache", "/data/saves"),
            ("/data/home/player/.local/cache", "../.cache"),
        ]:
            before = machine.succeed("stat -c %Y /data/cache/emubox-restic-test/backup-ran").strip()
            machine.succeed(f"rm -rf {alias}")
            machine.succeed(f"ln -s {target} {alias}")
            try:
                start_backup(expect="exit-code")
                assert machine.succeed(
                    "stat -c %Y /data/cache/emubox-restic-test/backup-ran"
                ).strip() == before, f"restic ran despite the {alias} alias"
            finally:
                machine.succeed(f"rm -f {alias} && mkdir -p {alias}")

    with checked("Maintenance and status use exact-invocation journal markers"):
        start_backup()
        machine.succeed("systemctl start restic-backups-emubox-maintenance.service")
        machine.succeed(
            "journalctl -u restic-backups-emubox-maintenance.service -o cat --no-pager | grep -F 'EMUBOX_MARKER='"
        )
        machine.succeed("emubox-status")
        # `start_backup` asserts the backup actually ran and failed. Status
        # reads the unit's current invocation, so a backup that never started
        # would leave the previous success standing and report healthy.
        with restic_fault("restic-test-fail"):
            start_backup(expect="exit-code")
            status = machine.fail("emubox-status")
            assert "restic-backups-emubox.service: latest invocation failed" in status, status

    with checked("Cloud failures do not disable local gameplay or future backup scheduling"):
        with restic_fault("restic-test-fail"):
            start_backup(expect="exit-code")
            machine.succeed("mountpoint -q " + save_bind_mappings[0]["where"])
            machine.succeed("systemctl is-enabled restic-backups-emubox.timer")
            machine.succeed("systemctl start btrbk-local.service")

    with checked("The repository initialization gate is fail-closed and visible"):
        # The gate is the backup's own first step, so a repository it cannot
        # open fails the backup's own invocation and reaches status. While the
        # gate was a separate required unit this failed by `dependency`: the
        # backup never reached an invocation, and status kept reporting the
        # previous success for the whole freshness window.
        #
        # One case, not a matrix. Which restic results initialize and which
        # fail closed is `initialize()`'s own logic, covered by its unit tests;
        # what only the VM can show is that a failed gate stops the job and
        # says so.
        with restic_fault("restic-test-init-network-fail"):
            before = machine.succeed("stat -c %Y /data/cache/emubox-restic-test/backup-ran").strip()
            start_backup(expect="exit-code")
            assert machine.succeed(
                "stat -c %Y /data/cache/emubox-restic-test/backup-ran"
            ).strip() == before, "restic backed up despite a failed init gate"
            status = machine.fail("emubox-status")
            assert "restic-backups-emubox.service: latest invocation failed" in status, status
        start_backup()

    with checked("Disabling cloud jobs keeps routed saves active without reverse migration"):
        # The declarative rollback configuration is evaluated separately in
        # tests/saves.nix. This runtime half proves that stopping the cloud
        # activation paths neither tears down save mounts nor moves data back
        # into the legacy directory that the mount covers.
        for unit in RESTIC_UNITS:
            machine.succeed(f"systemctl stop {unit}")
        for timer in [
            "restic-backups-emubox.timer",
            "restic-backups-emubox-maintenance.timer",
        ]:
            # Stopped, not disabled. `/etc/systemd/system` is read-only on this
            # box, so `systemctl disable` cannot work at runtime and rollback is
            # declarative by construction: `emubox.backups.enable = false` and a
            # rebuild, which tests/saves.nix evaluates. What is left for the VM
            # is the runtime half, that taking the cloud jobs away touches
            # neither the save mounts nor the data under them.
            machine.succeed(f"systemctl stop {timer}")
            machine.fail(f"systemctl is-active {timer}")
        machine.succeed(f"mountpoint -q {rollback_mapping['where']}")
        machine.succeed(
            f"printf rollback-routed > {rollback_mapping['where']}/rollback-routed-write"
        )
        assert machine.succeed(
            f"cat {rollback_mapping['what']}/rollback-routed-write"
        ).strip() == "rollback-routed"

    with checked("Reconciler removes interrupted sources both before backup and on boot"):
        machine.succeed("btrfs subvolume snapshot -r /data /data/.snapshots/restic/restic-same-boot")
        start_backup()
        machine.fail("test -e /data/.snapshots/restic/restic-same-boot")
        machine.succeed("btrfs subvolume snapshot -r /data /data/.snapshots/restic/restic-after-power-loss")
        # `crash` rather than an in-guest `systemctl reboot`: the driver's shell
        # dies with the guest and does not reconnect on its own, so a reboot
        # issued from inside leaves every later command raising `Broken pipe`.
        # It also models what the fixture is named for.
        machine.crash()
        machine.start()
        booted()
        machine.fail("test -e /data/.snapshots/restic/restic-after-power-loss")
        # The timers stopped above are running again: their enablement lives in
        # the declared configuration, not in runtime state the boot preserves.
        machine.succeed("systemctl is-enabled restic-backups-emubox.timer")

    with checked("A routed write survives reboot after cloud rollback"):
        assert machine.succeed(
            f"cat {rollback_mapping['what']}/rollback-routed-write"
        ).strip() == "rollback-routed"
        machine.succeed(f"mountpoint -q {rollback_mapping['where']}")

    assert_double_understood_its_arguments()

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

    def listed_boots():
        out = machine.succeed("journalctl --list-boots --no-pager")
        return [l for l in out.splitlines() if l.split() and l.split()[0].lstrip("-").isdigit()]

    machine_id = machine.succeed("cat /etc/machine-id").strip()
    assert len(machine_id) == 32, f"machine-id not initialised: {machine_id!r}"
    # Counted across this reboot rather than against a literal total: how many
    # times the whole test restarts the machine is a property of the test, and
    # it changed the moment the reconciler subtest began completing its own
    # restart. What the persistence spec asks is that a restart adds a boot the
    # journal still lists, and that the previous one can be read.
    boots_before = len(listed_boots())
    # A Persistent=true timer touches its stamp when first activated, so the
    # stamp's mtime is boot 1's; it must survive unchanged.
    machine.wait_for_file("/var/lib/systemd/timers/stamp-fstrim.timer", timeout=60)
    stamp_mtime = machine.succeed("stat -c %Y /var/lib/systemd/timers/stamp-fstrim.timer").strip()
    # The /data marker goes under player's home, the path the persistence
    # spec's "Data under /data survives a reboot" scenario names.
    machine.succeed("touch /root/marker /etc/marker /data/home/player/marker /tmp/marker")
    machine.succeed("sync")
    machine.shutdown()

    machine.start()
    booted()

    with subtest("Root and /etc markers are gone; /data marker remains"):
        machine.fail("test -e /root/marker")
        machine.fail("test -e /etc/marker")
        machine.succeed("test -e /data/home/player/marker")

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

    with subtest("The reboot adds a listed boot and the previous one is readable"):
        boots = listed_boots()
        assert len(boots) == boots_before + 1, (boots_before, boots)
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
        machine.succeed("test -e /data/home/player/marker")
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
            (${py (secretFacts "b2_key_id")}, ${py values.b2KeyId}),
            (${py (secretFacts "b2_application_key")}, ${py values.b2ApplicationKey}),
            (${py (secretFacts "restic_password")}, ${py values.resticPassword}),
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
        # No pipe (see the journal check above); the zram device appears
        # shortly after boot, so poll the listing and match it in Python.
        swap = machine.wait_until_succeeds("swapon --show=NAME --noheadings", timeout=60)
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

    # --- packages: the vendored programs are installed -----------------------
    # Nothing is launched beyond `--version`: the VM has no display, and
    # the AppImage's Qt would fail without one, proving nothing about the
    # package. `es-de --version` returns before SDL initialises.

    with subtest("es-de and duckstation are on the system's program path"):
        machine.succeed("test -x /run/current-system/sw/bin/es-de")
        machine.succeed("test -x /run/current-system/sw/bin/duckstation")

    with subtest("es-de reports the pinned version"):
        # LD_BIND_NOW resolves every function symbol at load, so an
        # unresolved symbol anywhere in ES-DE's library graph (FreeImage's
        # fixes forward included) fails here instead of on first use.
        out = machine.succeed("LD_BIND_NOW=1 es-de --version")
        assert "ES-DE 3.4.1" in out, out

    # Every `checked` subtest above reports here, so one build lists every
    # defect rather than the first one.
    assert not subtest_failures, "subtests failed:\n" + "\n".join(subtest_failures)
  '';
}
