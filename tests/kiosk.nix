# The kiosk test: the host's software modules booted as a plain node with a
# graphical stack, so CI can see the session the install test cannot.
#
# Why a second test rather than more assertions on the first: disko's install
# test starts the installed VM with a hard-coded 1 GB and exposes no memory
# knob, which is why the base layer forces SDDM off there. This node gives up
# the real boot path - no disk layout, no boot loader, no initrd rollback -
# and gets in exchange a memory size, a virtual GPU and a display manager.
# The two tests are complementary and both are enrolled in `nix flake check`:
# the install test owns the boot path, this one owns the session.
#
# What it proves is design D5's coverage table, which is the change's single
# enumeration of what proves each kiosk scenario. An assertion added or
# dropped here starts as an edit there.
{ self }:
let
  # The one test hook the session script carries (design D5). A number here,
  # rendered into the node's environment and into the script's waits, so the
  # two cannot drift.
  crashWindow = 30;
in
{
  name = "emubox-kiosk";

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        self.nixosModules.emubox
        ../hosts/emubox/facts.nix
      ];

      system.stateVersion = "26.05";

      # No disko layout and no boot loader here, so the initrd units that
      # roll the root subvolume back and bind /persist have nothing to act
      # on. Their behaviour is the install test's subject, not this one's.
      #
      # `suppressedUnits`, emphatically not `services.<name>.enable = false`:
      # `enable = false` *masks* a unit (a symlink to /dev/null) but still
      # emits its `.requires` links, and `modules/persistence` declares
      # `requiredBy = [ "sysroot.mount" ]` and `requiredBy =
      # [ "initrd-nixos-activation.service" ]`. systemd refuses to enqueue a
      # job that Requires= a masked unit, so sysroot.mount would fail, the
      # initrd would drop to emergency, and the test node would never boot.
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
      # every run. Nothing in this test asserts on it.
      services.openssh.enable = lib.mkForce false;

      # SDDM, cage and ES-DE under llvmpipe. 2 GB and a virtio GPU are what
      # nixpkgs' own cage test uses; both are one-line adjustments if the
      # frontend turns out to need more.
      virtualisation.memorySize = 2048;
      virtualisation.qemu.options = [ "-vga none -device virtio-gpu-pci" ];

      # The one test hook the session script carries. SDDM's PAM stack
      # exports environment.sessionVariables into the `player` session, so
      # the module needs no knowledge of tests. The value answers two
      # opposing constraints: the relaunch subtest needs one run longer than
      # the window before its kill, and the greeter subtest needs three runs
      # each shorter than it. 30 s rather than the 10 s first written here,
      # because `started=$SECONDS` is set before `cage -- es-de`, so a run's
      # measured length includes cage's wlroots and DRM initialisation and
      # ES-DE's start under llvmpipe; at 10 s a slow runner could push a
      # killed run past the window and stop it counting as a crash. Both
      # constraints scale with the value, so the cost of the larger number is
      # only the seconds the relaunch subtest waits out. The box's figure
      # stays the kiosk spec's unconditional 60 s.
      environment.sessionVariables.EMUBOX_CRASH_WINDOW = toString crashWindow;

      # ES-DE with no game files at all shows a "no game files were found"
      # screen and keeps running, which is all this test needs - but every
      # assertion here hangs off the frontend staying up, so one dummy file
      # removes the dependency on that behaviour rather than trusting it.
      systemd.tmpfiles.rules = [
        "d /data/roms/emuboxtest 0755 player player -"
        "f /data/roms/emuboxtest/dummy.test 0644 player player -"
      ];

      # Deliberately not ES-DE's default: a passkey assertion against the
      # default would pass whether or not the option is wired to anything.
      emubox.kiosk.passkey = "ablrablrud";

      # A complete es_systems.xml document, <systemList> wrapper included,
      # because the module writes the option verbatim and adds no wrapper.
      emubox.kiosk.customSystems = ''
        <?xml version="1.0"?>
        <systemList>
          <system>
            <name>emuboxtest</name>
            <fullname>emubox test system</fullname>
            <path>/data/roms/emuboxtest</path>
            <extension>.test</extension>
            <command>/bin/true %ROM%</command>
            <platform>test</platform>
            <theme>emuboxtest</theme>
          </system>
        </systemList>
      '';
    };

  testScript =
    { nodes }:
    let
      inherit (nodes.machine.emubox.kiosk)
        appdataDir
        ownedValuesFile
        passkey
        customSystems
        ;
      py = builtins.toJSON;
    in
    ''
      import json
      import re
      import shlex
      import xml.etree.ElementTree as ET

      APPDATA = ${py appdataDir}
      OWNED_VALUES = ${py ownedValuesFile}
      SETTINGS = f"{APPDATA}/settings/es_settings.xml"
      CUSTOM_SYSTEMS = f"{APPDATA}/custom_systems/es_systems.xml"

      def esde_pids():
          rc, out = machine.execute("pgrep -x es-de")
          return [int(p) for p in out.split()] if rc == 0 else []

      def session_on_seat(user):
          """Is `user` holding an active session on seat0?

          `loginctl show-seat`/`show-session` rather than column indices into
          `list-sessions`, so a future column does not silently change what
          this reads.
          """
          rc, sid = machine.execute("loginctl show-seat seat0 -p ActiveSession --value")
          sid = sid.strip()
          if rc != 0 or not sid:
              return False
          rc, out = machine.execute(f"loginctl show-session {sid} -p Name -p Active --value")
          if rc != 0:
              return False
          fields = out.split()
          return fields[:2] == [user, "yes"] or fields[:2] == ["yes", user]

      def ancestry(pid):
          """The comm of every ancestor of `pid`, read in one guest command.

          One command rather than a `ps` per level: a process exiting between
          two round trips would otherwise fail the test rather than answer it.
          """
          script = (
              "p=" + str(pid) + "; chain=; "
              "while [ \"$p\" -gt 1 ] && [ -r /proc/$p/stat ]; do "
              "set -- $(awk '{print $2, $4}' /proc/$p/stat); "
              "chain=\"$chain $1\"; p=$2; "
              "done; echo \"$chain\""
          )
          return machine.succeed(script).split()

      def settings_elements():
          # ES-DE writes a rootless forest of typed elements, so the body is
          # wrapped before parsing (the same shape emubox-prepare reads).
          text = machine.succeed(f"cat {SETTINGS}")
          body = re.sub(r"^\s*<\?xml[^>]*\?>", "", text, count=1)
          return {
              e.get("name"): (e.tag, e.get("value"))
              for e in ET.fromstring(f"<r>{body}</r>")
          }

      machine.wait_for_unit("multi-user.target")

      # --- vm-test: the session comes up ------------------------------------

      with subtest("Display manager is up and player holds the seat's session"):
          machine.wait_for_unit("display-manager.service")
          # Autologin proved by the session itself, not by the greeter's
          # absence: an active `player` session on seat0 is what "autologin
          # happened" actually means.
          retry(lambda _: session_on_seat("player"), timeout_seconds=120)

      with subtest("es-de runs inside the cage compositor"):
          # 120 s is this test's budget, chosen with headroom for ES-DE
          # starting under llvmpipe. It is not the box's figure, which stays
          # the kiosk spec's 60 s and is measured on hardware at bring-up.
          machine.wait_until_succeeds("pgrep -x es-de", timeout=120)
          chain = ancestry(esde_pids()[0])
          assert any("cage" in name for name in chain), chain

      with subtest("The crash window reached the session"):
          # Asserted rather than assumed: if environment.sessionVariables did
          # not reach the session the window would silently stay at 60, and
          # both timing subtests below would fail for a reason that points
          # nowhere near the cause.
          environ = machine.succeed(
              "tr '\\0' '\\n' < /proc/$(pgrep -x cage | head -1)/environ"
          )
          assert "EMUBOX_CRASH_WINDOW=${toString crashWindow}" in environ, environ

      # --- kiosk: the settings the flake owns -------------------------------

      with subtest("Every owned key holds the flake's value"):
          # Two assertions, and they check different things. The first pins
          # the table itself against the spec's enumeration; the second walks
          # the settings file the frontend will read and checks it carries
          # what the table says. Neither alone is enough: the table could be
          # right and unapplied, or applied and wrong.
          owned = json.loads(machine.succeed(f"cat {OWNED_VALUES}"))
          keys = owned["settings/es_settings.xml"]["keys"]

          # Pinned here, literally, and deliberately not derived from the
          # module: the loop below compares the settings file against this
          # same rendered JSON, so on its own it would pass for whatever the
          # module happened to render, and dropping an owned key would break
          # no check anywhere. This is the kiosk spec's own enumeration -
          # "kiosk UI mode, the unlock sequence, the ROM and media
          # directories under /data, the theme, the en_US language and the
          # quit menu enabled" - so a key leaving the module has to be a
          # deliberate edit here too.
          assert keys == {
              "UIMode": {"type": "string", "value": "kiosk"},
              "UIMode_passkey": {"type": "string", "value": ${py passkey}},
              "ROMDirectory": {"type": "string", "value": "/data/roms"},
              "MediaDirectory": {"type": "string", "value": "/data/media"},
              "Theme": {"type": "string", "value": "linear-es-de"},
              "ApplicationLanguage": {"type": "string", "value": "en_US"},
              "ShowQuitMenu": {"type": "bool", "value": "true"},
          }, keys

          got = settings_elements()
          for name, spec in keys.items():
              assert got.get(name) == (spec["type"], spec["value"]), (
                  f"{name}: {got.get(name)} != {(spec['type'], spec['value'])}"
              )
          # Named separately because this is what proves the option is wired
          # rather than that ES-DE's own default happens to be in the file.
          assert got["UIMode_passkey"] == ("string", ${py passkey}), got["UIMode_passkey"]
          assert got["UIMode"] == ("string", "kiosk"), got["UIMode"]

      # --- kiosk: custom systems, both branches -----------------------------

      with subtest("The custom systems file holds exactly the definition"):
          assert machine.succeed(f"cat {CUSTOM_SYSTEMS}") == ${py customSystems}

      with subtest("An empty definition removes the file"):
          # Before any kill: a later loop iteration re-runs prepare with the
          # module's non-empty path and would recreate the file, so this
          # ordering is load-bearing rather than incidental.
          #
          # The binary is found by bare name on the system path, which is
          # also what proves the packages capability's program-path scenario,
          # and the JSON's path comes from the module's readonly option
          # rather than from scraping the session script.
          machine.succeed("test -x /run/current-system/sw/bin/emubox-prepare")
          prepare = f'ESDE_APPDATA_DIR={APPDATA} emubox-prepare {OWNED_VALUES} ""'
          machine.succeed(f"su player -s /bin/sh -c {shlex.quote(prepare)}")
          machine.fail(f"test -e {CUSTOM_SYSTEMS}")

      # --- kiosk: the frontend is kept up -----------------------------------

      with subtest("A frontend that ran longer than the window is relaunched"):
          # Outlast the window so this exit resets the counter rather than
          # counting as a crash.
          machine.sleep(${toString (crashWindow + 5)})
          # Re-read the pid here, not before the sleep: had the frontend
          # exited and relaunched on its own during it, killing the new
          # process while comparing against the old one would satisfy the
          # assertion with no relaunch having happened.
          before = esde_pids()[0]
          machine.succeed(f"kill {before}")
          # Proved by PID, not by presence: without waiting for the old
          # process to die, the dying process satisfies "es-de is running"
          # and the subtest passes with no relaunch having happened.
          machine.wait_until_fails(f"kill -0 {before}", timeout=30)

          def relaunched(_last):
              return any(p != before for p in esde_pids())

          # 15 s is the kiosk spec's own constant, asserted as written.
          retry(relaunched, timeout_seconds=15)

      with subtest("Three short runs in a row end at the greeter"):
          for _ in range(3):
              machine.wait_until_succeeds("pgrep -x es-de", timeout=120)
              # By pid, and waited out. `pkill -x es-de` in a tight loop
              # re-signals the process still shutting down from the previous
              # iteration - SIGTERM reaches SDL, which unwinds over seconds -
              # so three passes would land on one process and record one
              # crash, and the session would never give up.
              pid = esde_pids()[0]
              machine.succeed(f"kill {pid}")
              machine.wait_until_fails(f"kill -0 {pid}", timeout=60)

          # Longer than the loop's 2 s relaunch pause: without the grace
          # period "no frontend" is momentarily true after any kill and the
          # assertion would go green against a counter that never fired.
          machine.sleep(15)
          for _ in range(5):
              assert not esde_pids(), "the session relaunched after three crashes"
              machine.sleep(2)
          # The primary assertion is this pair: the frontend is gone and the
          # display manager is still there to serve a login.
          machine.succeed("systemctl is-active display-manager.service")
          # Secondary, and the one observable design D5 calls brittle. `-x`
          # against the compositor's own name, never `pgrep -f`: `-f` matches
          # the full command line and pgrep excludes only its own pid, so the
          # driver's `bash -c` and `timeout` processes carry the pattern
          # themselves and `pgrep -f 'sddm-greeter|kwin'` succeeds on any
          # booted machine, greeter or not. This pin's greeter compositor is
          # kwin (sddm.wayland.compositor), and the kiosk session runs cage,
          # so kwin_wayland running at all is the greeter.
          machine.wait_until_succeeds("pgrep -x kwin_wayland", timeout=60)
          # And the seat is no longer player's, which is the other half of
          # "no automatic login while this display manager keeps running".
          assert not session_on_seat("player")

      with subtest("A reboot from the greeter restores the kiosk"):
          # Last, so that the reboot is genuinely from the greeter and this
          # proves that ending there does not outlive the boot.
          #
          # shutdown()/start(), not machine.reboot(): the driver starts the
          # VM with `-no-reboot` unless it was started with allow_reboot, so
          # a reset would end QEMU and every later assertion would fail
          # against a dead machine. reboot() is also only a Ctrl-Alt-Del
          # keypress, which the greeter's compositor owns the VT for. This is
          # the same shape the install test already uses.
          machine.shutdown()
          machine.start()
          machine.wait_for_unit("display-manager.target")
          machine.wait_for_unit("display-manager.service")
          retry(lambda _: session_on_seat("player"), timeout_seconds=120)
          machine.wait_until_succeeds("pgrep -x es-de", timeout=120)
    '';
}
