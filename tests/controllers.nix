# The controllers test: the host's software modules booted as a plain node
# with fixture pads on fixture ports, proving the mapping this project owns
# - a recorded port to its player name - the session hint that follows from
# it, and the controllers status reporter's classification of what the
# fixture presents, without depending on the virtual machine's own bus
# topology. The pads are uinput devices rather than emulated USB ones
# because no emulated USB device QEMU offers presents gamepad capabilities,
# so udev would never mark one a joystick and the port rule would never
# fire.
#
# Four recorded ports: three carry a permanent, accepted-mode pad each, and
# the fourth stays empty so an unoccupied recorded port is proven too. A
# permanent keyboard-only device carries an unaccepted identity that the
# fixture rule leaves unmarked, proving that classification, not identity,
# is what keeps it out of the report. Two further devices are switchable -
# started and stopped by the test - so an unaccepted mode is proven both on
# a recorded port and off every recorded port without leaving either state
# in place for the rest of the file; a second, test-only status reporter
# with a mutable command path is switched the same way, to prove a reporter
# that cannot be executed without disturbing every other section.
#
# This node has no graphical session: it turns its display manager off so
# nothing on it ever calls the configuration editor except the test's own
# manual invocations, and it has no btrfs snapshot layer, so its backups
# section reports the local layer as not yet run and warns. Neither is
# asserted here as a failure; a healthy aggregate is the install node's
# proof.
{ self }:
let
  pkgs = self.nixosConfigurations.emubox.pkgs;
  inherit (pkgs) lib;

  # The fixture: four recorded ports. Three carry a permanently connected pad
  # each, presented through uinput and a test-only udev rule that marks it a
  # joystick at the recorded path; the fourth is left with none, for the
  # recorded-port-with-no-pad case. Kept as data, not repeated copies of
  # similar code, so a differently-shaped device (an unaccepted-mode
  # joystick, a keyboard-only device) sits beside these without touching the
  # mechanism.
  fixturePorts = [
    "emubox-test-controller-port-1"
    "emubox-test-controller-port-2"
    "emubox-test-controller-port-3"
    "emubox-test-controller-port-4"
  ];
  emptyPort = lib.elemAt fixturePorts 3;

  # The wired pad's identity under the in-kernel xpad driver - the one mode
  # modules/controllers accepts - so these permanent fixture pads produce no
  # warning.
  fixturePads = lib.imap1 (i: port: {
    name = "emubox-test-pad-${toString i}";
    vendor = "045e";
    product = "028e";
    kind = "gamepad";
    inherit port;
  }) (lib.take 3 fixturePorts);

  # A keyboard-only device the fixture rule below leaves unmarked, carrying
  # an unaccepted vendor and product to prove that being unmarked, not its
  # identity, is what keeps it out of the controllers report: its capability
  # set is ordinary keys, which the kernel's own classification does not
  # read as a joystick either.
  keyboardFixture = {
    name = "emubox-test-keyboard";
    vendor = "cafe";
    product = "f00d";
    kind = "keyboard";
    port = null;
  };

  # Two switchable devices, started and stopped by the test independently of
  # the permanent fixture pads above: one presents an unaccepted mode on the
  # empty port's own recorded slot, the other presents an unaccepted mode
  # with no recorded port at all, so the warning's reach - every controller
  # the system sees, on a recorded port or not - is proven both ways in the
  # same run.
  unacceptedOnRecordedPort = {
    name = "emubox-test-pad-unaccepted-recorded";
    vendor = "1234";
    product = "5678";
    kind = "gamepad";
    port = emptyPort;
  };
  unacceptedOffRecordedPorts = {
    name = "emubox-test-pad-unaccepted-loose";
    vendor = "dead";
    product = "beef";
    kind = "gamepad";
    port = null;
  };

  allGamepadFixtures = fixturePads ++ [
    unacceptedOnRecordedPort
    unacceptedOffRecordedPorts
  ];
  persistentDevices = fixturePads ++ [ keyboardFixture ];

  # A mutable status reporter this test switches at runtime: registered
  # through emubox.status.reporters on this node alone, its command is a
  # single path outside the read-only store. Healthy (executable) by
  # default, so every other assertion that runs the aggregator sees it as
  # `ok`; only its own subtest makes it non-executable or removes it.
  switchableReporterPath = "/run/emubox-test-switchable-reporter.sh";

  # Creates one or more uinput devices by name, vendor, product and
  # capability set, and holds them open for the life of the process - the
  # devices themselves, not their udev classification, which the fixture
  # rule below supplies instead of relying on the kernel's own joystick
  # heuristic. Parametric over the device list, so a differently-shaped
  # fixture device (an unaccepted-mode joystick, or a keyboard-only device
  # the fixture rule must leave unmarked) is one more entry in the same list
  # rather than a second script; a separate systemd service can point it at
  # a spec of its own to make that device switchable independently of the
  # others.
  fixtureDevicesScript = pkgs.writeText "emubox-test-fixture-devices.py" ''
    """Create the uinput devices the fixture udev rule matches by name, and
    hold them open for the life of the test.

    Reads one JSON array from the path given as its only argument: a list of
    objects, each an evdev device to create with its own name, vendor and
    product identifiers (hex strings) and a capability set - "gamepad" for
    button-and-axis capabilities, or "keyboard" for a handful of key
    capabilities and nothing else. The fixture rule matches by name alone,
    so the vendor and product values here are placeholders distinct from
    the box's own accepted pad, not a fact this script has to get right.
    """

    import json
    import sys
    import time

    from evdev import AbsInfo, UInput
    from evdev import ecodes as e

    CAPABILITIES = {
        "gamepad": {
            e.EV_KEY: [
                e.BTN_SOUTH,
                e.BTN_EAST,
                e.BTN_NORTH,
                e.BTN_WEST,
                e.BTN_START,
                e.BTN_SELECT,
            ],
            e.EV_ABS: [
                (e.ABS_X, AbsInfo(value=0, min=-32768, max=32767, fuzz=0, flat=0, resolution=0)),
                (e.ABS_Y, AbsInfo(value=0, min=-32768, max=32767, fuzz=0, flat=0, resolution=0)),
            ],
        },
        "keyboard": {
            e.EV_KEY: [e.KEY_A, e.KEY_B, e.KEY_ENTER],
        },
    }


    def main(spec_path):
        with open(spec_path) as f:
            specs = json.load(f)
        devices = [
            UInput(
                CAPABILITIES[spec["kind"]],
                name=spec["name"],
                vendor=int(spec["vendor"], 16),
                product=int(spec["product"], 16),
            )
            for spec in specs
        ]
        try:
            while True:
                time.sleep(3600)
        finally:
            for device in devices:
                device.close()


    if __name__ == "__main__":
        main(sys.argv[1])
  '';

  deviceSpecJson =
    devices:
    builtins.toJSON (
      map (device: {
        inherit (device)
          name
          vendor
          product
          kind
          ;
      }) devices
    );

  # The permanently running fixture: the accepted-mode pads and the
  # keyboard-only device, all held open by one service for the life of the
  # node.
  fixtureDevicesSpec = pkgs.writeText "emubox-test-fixture-devices.json" (
    deviceSpecJson persistentDevices
  );

  # Each switchable device gets its own one-item spec, so the test can start
  # and stop its systemd service independently of the permanent fixture and
  # of the other switchable device.
  unacceptedOnRecordedPortSpec =
    pkgs.writeText "emubox-test-fixture-unaccepted-recorded.json"
      (deviceSpecJson [ unacceptedOnRecordedPort ]);
  unacceptedOffRecordedPortsSpec =
    pkgs.writeText "emubox-test-fixture-unaccepted-loose.json"
      (deviceSpecJson [ unacceptedOffRecordedPorts ]);

  testPython = pkgs.python3.withPackages (ps: [ ps.evdev ]);

  # The fixture rule: ordered between the kernel's own input classification
  # (systemd's `60-input-id.rules` and `60-persistent-input.rules`, which run
  # first) and the module's rule (`services.udev.extraRules`, which lands in
  # `99-local.rules`), matching only the fixture gamepads by name, so any
  # other device created through the same mechanism, the keyboard-only one
  # included, stays unmarked. `73` is arbitrary within that 60-99 window; the
  # ordering this relies on is asserted in the test script below rather than
  # assumed. A gamepad fixture with no recorded port is marked a joystick but
  # given no `ID_PATH`, so the module's own port rule never resolves it to an
  # `emubox-pN` symlink.
  fixtureRulesFile = pkgs.writeText "73-emubox-test-fixture.rules" (
    lib.concatMapStringsSep "\n" (
      pad:
      if pad.port != null then
        ''SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="${pad.name}", ENV{ID_INPUT_JOYSTICK}="1", ENV{ID_PATH}="${pad.port}"''
      else
        ''SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="${pad.name}", ENV{ID_INPUT_JOYSTICK}="1"''
    ) allGamepadFixtures
  );
  fixtureRulesPackage = pkgs.runCommand "emubox-test-fixture-rules" { } ''
    mkdir -p "$out/lib/udev/rules.d"
    cp ${fixtureRulesFile} "$out/lib/udev/rules.d/73-emubox-test-fixture.rules"
  '';
in
{
  name = "emubox-controllers";

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        self.nixosModules.emubox
        ../hosts/emubox/facts.nix
        ./boot-adaptations.nix
      ];

      system.stateVersion = "26.05";

      # Less than the kiosk node's 3072: no compositor, no GPU and no
      # concurrent emulator launches here, just the box's full modules
      # starting headless, the fixture devices, and the test's own
      # emubox-prepare runs.
      virtualisation.memorySize = 1536;

      # Forced: a list option concatenates definitions of equal priority, so
      # a plain assignment would add the fixture ports to whatever ports
      # the host's facts record rather than replace them.
      emubox.facts.controllerPorts = lib.mkForce fixturePorts;

      # /dev/uinput is what the fixture devices script opens; the module is
      # not built into every kernel config, so it is loaded explicitly
      # rather than assumed present.
      boot.kernelModules = [ "uinput" ];

      services.udev.packages = [ fixtureRulesPackage ];

      systemd.services.emubox-test-fixture-devices = {
        description = "Fixture uinput devices for the controllers VM test";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${testPython}/bin/python3 ${fixtureDevicesScript} ${fixtureDevicesSpec}";
          Restart = "always";
        };
      };

      # Not in `wantedBy`: these two start stopped, and the test starts and
      # stops each on its own to prove the unaccepted-mode warning both on a
      # recorded port and off every recorded port, without leaving either
      # condition in place for every other assertion in the file.
      systemd.services.emubox-test-fixture-unaccepted-recorded = {
        description = "Switchable unaccepted-mode pad on the empty recorded controller port";
        serviceConfig = {
          ExecStart = "${testPython}/bin/python3 ${fixtureDevicesScript} ${unacceptedOnRecordedPortSpec}";
          Restart = "on-failure";
        };
      };
      systemd.services.emubox-test-fixture-unaccepted-loose = {
        description = "Switchable unaccepted-mode joystick outside the recorded controller ports";
        serviceConfig = {
          ExecStart = "${testPython}/bin/python3 ${fixtureDevicesScript} ${unacceptedOffRecordedPortsSpec}";
          Restart = "on-failure";
        };
      };

      # A second reporter, test-only and registered on this node alone: its
      # command is a mutable path outside the read-only store, which the
      # test itself creates, healthy, before any assertion below runs the
      # aggregator, and later switches off and back on for its own subtest.
      emubox.status.reporters = [
        {
          name = "switchable";
          command = [ switchableReporterPath ];
        }
      ];

      # No graphical session, because it turns one off rather than being
      # merely spared one: the boot adaptations leave the display manager
      # and its autologin on, and the kiosk session runs emubox-prepare on
      # every loop before starting the frontend, which on this node would
      # run the editor alongside, and between, the test's own runs. Off
      # here, on the node itself, as the install node does - not in the
      # shared boot-adaptations module, which the kiosk node still needs its
      # session from.
      services.displayManager.sddm.enable = lib.mkForce false;
    };

  testScript =
    { nodes }:
    let
      inherit (nodes.machine.emubox.kiosk) appdataDir ownedValuesFile;
      inherit (nodes.machine.users.users.player) home;
      py = builtins.toJSON;
    in
    ''
      import shlex

      APPDATA = ${py appdataDir}
      OWNED_VALUES = ${py ownedValuesFile}
      PLAYER_HOME = ${py home}
      FIXTURE_PADS = ${py fixturePads}
      FIXTURE_PORTS = ${py fixturePorts}
      EMPTY_PORT_INDEX = len(FIXTURE_PORTS)
      UNACCEPTED_RECORDED = ${py { inherit (unacceptedOnRecordedPort) name vendor product; }}
      UNACCEPTED_LOOSE = ${py { inherit (unacceptedOffRecordedPorts) name vendor product; }}
      KEYBOARD_FIXTURE = ${py { inherit (keyboardFixture) name vendor product; }}
      SWITCHABLE_REPORTER_PATH = ${py switchableReporterPath}
      # udevd's own vendor rules - the kernel's input classification among
      # them - are compiled in from systemd's own store path rather than
      # copied into /etc/udev/rules.d; NixOS never stages them there. All
      # rules from both places are still sorted together by basename alone,
      # regardless of which directory holds them.
      SYSTEMD_PACKAGE = ${py nodes.machine.systemd.package}

      def run_status():
          """Run the aggregator without asserting its exit status: this
          node has no btrfs snapshot layer, so its backups section warns
          regardless of anything asserted here."""
          return machine.execute("emubox-status")

      def status_sections(output):
          """Split the aggregator's output into one block per section, keyed
          by name - the aggregator separates every section with a blank
          line, and each section's own first line starts "name: status"."""
          return {
              block.split(":", 1)[0]: block
              for block in output.strip("\n").split("\n\n")
              if block.strip()
          }

      def write_switchable_reporter(healthy):
          """Create or remove the switchable reporter's mutable command.

          Healthy is the steady state, so every other subtest that runs the
          aggregator sees this section as `ok`; only the subtest that owns
          this fixture ever calls it with False, or removes the file
          outright, and restores it before moving on.
          """
          if healthy:
              machine.succeed(
                  "printf '#!/bin/sh\\nexit 0\\n' > "
                  f"{SWITCHABLE_REPORTER_PATH} && chmod 755 {SWITCHABLE_REPORTER_PATH}"
              )
          else:
              machine.succeed(f"rm -f {SWITCHABLE_REPORTER_PATH}")

      def find_event_by_name(name):
          """The eventN device whose kernel-reported name matches, waiting
          for the uinput device and udev's rule processing to catch up."""
          path = machine.wait_until_succeeds(
              f"grep -rlx {shlex.quote(name)} /sys/class/input/event*/device/name"
          ).strip()
          return path.split("/")[4]

      def rerun_prepare():
          """Re-run emubox-prepare as player against this node's own
          rendered owned-values file, with no custom-systems argument - the
          same shape tests/kiosk.nix's own helper uses, standing in here for
          the run the kiosk session script makes before the frontend
          starts, which this node never runs because its display manager is
          off."""
          cmd = f'ESDE_APPDATA_DIR={APPDATA} emubox-prepare {OWNED_VALUES} ""'
          machine.succeed(f"su player -s /bin/sh -c {shlex.quote(cmd)}")

      machine.wait_for_unit("multi-user.target")
      # Healthy from the start, so every subtest below that runs the
      # aggregator for an unrelated reason sees this section as `ok`.
      write_switchable_reporter(True)

      with subtest("The fixture udev rule sorts after the kernel's input classification and before the module's own"):
          # udevd sorts every rules file it reads by basename alone across
          # every directory it reads from, so the kernel's classification
          # rules (in systemd's own store path) and this project's rules
          # (staged into /etc/udev/rules.d) are compared as one sequence
          # even though neither directory holds the other's files.
          etc_rules = sorted(machine.succeed("ls /etc/udev/rules.d").split())
          vendor_rules = sorted(
              machine.succeed(f"ls {SYSTEMD_PACKAGE}/lib/udev/rules.d").split()
          )
          fixture_rule = "73-emubox-test-fixture.rules"
          assert fixture_rule in etc_rules, etc_rules
          kernel_rules = [r for r in vendor_rules if r.startswith("60-") and "input" in r]
          assert kernel_rules, vendor_rules
          assert all(r < fixture_rule for r in kernel_rules), (kernel_rules, fixture_rule)
          assert "99-local.rules" in etc_rules, etc_rules
          assert fixture_rule < "99-local.rules"

      with subtest("Every emubox-pN resolves to its fixture pad in recorded order"):
          machine.wait_for_unit("emubox-test-fixture-devices.service")
          for i, pad in enumerate(FIXTURE_PADS, start=1):
              event = machine.succeed(f"readlink -f /dev/input/emubox-p{i}").strip()
              node = event.rsplit("/", 1)[-1]
              got_name = machine.succeed(f"cat /sys/class/input/{node}/device/name").strip()
              assert got_name == pad["name"], (i, got_name, pad)
              path = machine.succeed(
                  f"udevadm info -q property -n {event} --property=ID_PATH --value"
              ).strip()
              assert path == pad["port"], (i, path, pad)

      with subtest("The session hint carries the recorded ports in order"):
          hinted = machine.succeed(
              "bash -c 'source /etc/set-environment && printf %s \"$SDL_JOYSTICK_DEVICE\"'"
          )
          expected = ":".join(f"/dev/input/emubox-p{i}" for i in range(1, len(FIXTURE_PORTS) + 1))
          assert hinted == expected, (hinted, expected)

      with subtest("No caller of the configuration editor is running before the first owned-key check"):
          # The display manager is off, so nothing here ever runs the kiosk
          # session script or the frontend on its own; asserted rather than
          # assumed, since every check below reads what the editor itself
          # writes.
          machine.fail("pgrep -x emubox-session")
          machine.fail("pgrep -x es-de")

      with subtest("emubox-prepare runs cleanly against this node's own rendered owned values"):
          machine.succeed("test -x /run/current-system/sw/bin/emubox-prepare")
          rerun_prepare()

      with subtest("A second run of emubox-prepare against the same file is idempotent"):
          rerun_prepare()

      with subtest(
          "The controllers section reports every recorded port, accepted-mode pads warn about"
          " nothing, and the keyboard-only device is neither classified nor named"
      ):
          _, output = run_status()
          controllers = status_sections(output)["controllers"]
          assert controllers.splitlines()[0] == "controllers: ok", controllers
          for i in range(1, EMPTY_PORT_INDEX):
              assert f"port {i}: connected" in controllers, controllers
          assert f"port {EMPTY_PORT_INDEX}: unoccupied" in controllers, controllers
          assert "WARN" not in controllers, controllers
          assert KEYBOARD_FIXTURE["vendor"] not in controllers, controllers
          assert KEYBOARD_FIXTURE["product"] not in controllers, controllers

      with subtest(
          "A recorded port with no pad is unoccupied and the section's own status is ok,"
          " independent of the aggregate exit status"
      ):
          rc, output = run_status()
          controllers = status_sections(output)["controllers"]
          assert f"port {EMPTY_PORT_INDEX}: unoccupied" in controllers, controllers
          assert controllers.splitlines()[0] == "controllers: ok", controllers
          # Not asserted here: this node's backups section warns regardless
          # (no btrfs snapshot layer), so the aggregate is never successful
          # on it.
          assert rc != 0

      with subtest("An unaccepted-mode pad on a recorded port is named in the warning"):
          machine.succeed("systemctl start emubox-test-fixture-unaccepted-recorded.service")
          machine.wait_until_succeeds(f"test -e /dev/input/emubox-p{EMPTY_PORT_INDEX}")
          try:
              _, output = run_status()
              controllers = status_sections(output)["controllers"]
              assert controllers.splitlines()[0] == "controllers: warn", controllers
              assert f"port {EMPTY_PORT_INDEX}: connected" in controllers, controllers
              mode = f"{UNACCEPTED_RECORDED['vendor']}:{UNACCEPTED_RECORDED['product']}"
              assert mode in controllers, controllers
          finally:
              machine.succeed("systemctl stop emubox-test-fixture-unaccepted-recorded.service")
              machine.wait_until_fails(f"test -e /dev/input/emubox-p{EMPTY_PORT_INDEX}")

      with subtest("An unaccepted-mode joystick outside the recorded ports is also named"):
          machine.succeed("systemctl start emubox-test-fixture-unaccepted-loose.service")
          try:
              event = find_event_by_name(UNACCEPTED_LOOSE["name"])
              machine.wait_until_succeeds(
                  f"test $(udevadm info -q property -n /dev/input/{event}"
                  " --property=ID_INPUT_JOYSTICK --value) = 1"
              )
              _, output = run_status()
              controllers = status_sections(output)["controllers"]
              assert controllers.splitlines()[0] == "controllers: warn", controllers
              mode = f"{UNACCEPTED_LOOSE['vendor']}:{UNACCEPTED_LOOSE['product']}"
              assert mode in controllers, controllers
              # Every recorded port still resolves exactly as it did before
              # this off-slot device appeared: the warning covers every
              # controller the system sees, without disturbing slot
              # resolution for the ones that are recorded.
              for i in range(1, EMPTY_PORT_INDEX):
                  assert f"port {i}: connected" in controllers, controllers
              assert f"port {EMPTY_PORT_INDEX}: unoccupied" in controllers, controllers
          finally:
              machine.succeed("systemctl stop emubox-test-fixture-unaccepted-loose.service")

      with subtest(
          "A reporter that cannot be executed is reported as not having run,"
          " and does not suppress the other sections"
      ):
          try:
              machine.succeed(f"chmod 000 {SWITCHABLE_REPORTER_PATH}")
              rc, output = run_status()
              assert rc == 2, (rc, output)
              assert "switchable: did not run" in output, output
              assert "backups:" in output, output
              assert "controllers:" in output, output

              machine.succeed(f"rm -f {SWITCHABLE_REPORTER_PATH}")
              rc, output = run_status()
              assert rc == 2, (rc, output)
              assert "switchable: did not run" in output, output
              assert "backups:" in output, output
              assert "controllers:" in output, output
          finally:
              write_switchable_reporter(True)
          _, output = run_status()
          assert "switchable: ok" in output, output

      with subtest(
          "One emubox-status run carries the switchable reporter, the controllers section"
          " and the backups section together, and no section for an unregistered capability"
      ):
          # Not asserted successful: this node has no btrfs snapshot layer,
          # so its backups section warns that the local layer has not yet
          # run, whatever the other two sections report.
          _, output = run_status()
          sections = status_sections(output)
          assert set(sections) == {"backups", "controllers", "switchable"}, sections
          assert sections["switchable"].splitlines()[0] == "switchable: ok", sections["switchable"]
          # This node leaves off-site backup off, so its backups section
          # carries the local snapshot layer and neither off-site layer -
          # the "a capability contributes no report" case belongs to a
          # capability that registers nothing at all, which the set
          # equality above already covers, now that backups registers on
          # every box regardless of off-site backup.
          backups = sections["backups"]
          assert "btrbk-local.service" in backups, backups
          assert "restic-backups-emubox.service" not in backups, backups
          assert "restic-backups-emubox-maintenance.service" not in backups, backups
    '';
}
