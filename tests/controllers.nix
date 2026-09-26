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

  # The fixture value recorded for the pad-identity fact Dolphin's route
  # back and gameplay `Device` lines depend on, so this node exercises the
  # identity-gated keys the same way it exercises everything else recorded
  # beside the fixture ports - a value distinct from any real SDL device
  # name, so a test that passed by accident against a placeholder or
  # another host's value would be obvious on sight.
  fixtureSdlGamepadName = "emubox-test-sdl-gamepad";

  # The fixture value recorded for the pad-identity fact Azahar's whole
  # `[Controls]` section depends on, beside the SDL device name above - a
  # value distinct from any real SDL joystick GUID for the same reason.
  fixtureSdlJoystickGuid = "0300deadbeef00001234000000000000";

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
  # read as a joystick either. It sits on the empty port's recorded path, so
  # the port rule's joystick match, and nothing else, is what keeps that
  # port unlinked.
  keyboardFixture = {
    name = "emubox-test-keyboard";
    vendor = "cafe";
    product = "f00d";
    kind = "keyboard";
    port = emptyPort;
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
    but the controllers status reporter classifies a device by the vendor
    and product it reports, so these values decide whether each device
    reads as the box's accepted mode or an unaccepted one.
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
  # `99-local.rules`). `73` is arbitrary within that 60-99 window; that it
  # runs before the module's rule is proven by the test script below, whose
  # port-resolution subtest finds each fixture pad's `emubox-pN` link, which
  # the module's rule can only create from the `ID_PATH` this rule has
  # already set.
  #
  # Each fixture gamepad is matched by name on both nodes the kernel gives
  # it - its event device and, with joydev loaded, its `jsN` sibling - and
  # marked a joystick on both. The kernel's own classification would mark
  # these capability sets too; marking them here keeps the fixture from
  # depending on it. A gamepad on a recorded port gets that port's `ID_PATH`
  # on both nodes, as `path_id` gives a real pad's two nodes one path, so
  # the module's `KERNEL=="event*"` match is all that keeps its rule off the
  # js node. The keyboard-only device gets the empty port's `ID_PATH` and no
  # joystick mark, so the module's `ID_INPUT_JOYSTICK` match is all that
  # keeps its rule off the keyboard. A gamepad with no recorded port gets no
  # `ID_PATH`, so the module's rule never resolves it to an `emubox-pN` link.
  fixtureRule =
    device:
    lib.concatStringsSep ", " (
      [
        ''SUBSYSTEM=="input"''
        ''KERNEL=="${if device.kind == "gamepad" then "event*|js*" else "event*"}"''
        ''ATTRS{name}=="${device.name}"''
      ]
      ++ lib.optional (device.kind == "gamepad") ''ENV{ID_INPUT_JOYSTICK}="1"''
      ++ lib.optional (device.port != null) ''ENV{ID_PATH}="${device.port}"''
    );
  fixtureRulesPackage = pkgs.writeTextDir "lib/udev/rules.d/73-emubox-test-fixture.rules" (
    lib.concatMapStringsSep "\n" fixtureRule (allGamepadFixtures ++ [ keyboardFixture ])
  );
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
      # Beside the fixture ports: the two pad-identity facts Dolphin's and
      # Azahar's bindings depend on. Forced for the same reason the ports
      # are: once bring-up records the real pad's identity in
      # hosts/emubox/facts.nix, a plain assignment here would conflict with
      # it rather than replace it.
      emubox.facts.controllerIdentities.sdlGamepadName = lib.mkForce fixtureSdlGamepadName;
      emubox.facts.controllerIdentities.sdlJoystickGuid = lib.mkForce fixtureSdlJoystickGuid;

      # /dev/uinput is what the fixture devices script opens; the module is
      # not built into every kernel config, so it is loaded explicitly
      # rather than assumed present. joydev gives each fixture pad the
      # `jsN` sibling a real pad has, which the port rule must never link.
      boot.kernelModules = [
        "uinput"
        "joydev"
      ];

      # A variant of this node whose identity facts are both empty - the
      # host's own default before bring-up records one - for the
      # identity-transition subtest to start from. A specialisation is this
      # node's own module list extended by one module, so the two rendered
      # owned-values documents differ in those two facts and nothing else.
      # `mkOverride 40` outranks the `mkForce` (50) that sets them below.
      specialisation.identity-empty.configuration = {
        emubox.facts.controllerIdentities.sdlGamepadName = lib.mkOverride 40 null;
        emubox.facts.controllerIdentities.sdlJoystickGuid = lib.mkOverride 40 null;
      };

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
      bindings = import ./lib/controller-bindings.nix;
    in
    ''
      import base64
      import json
      import shlex

      ${builtins.readFile ./lib/test_helpers.py}

      APPDATA = ${py appdataDir}
      OWNED_VALUES = ${py ownedValuesFile}
      # A second rendered owned-values document, from this node's
      # identity-empty specialisation - only this constant differs between
      # the two; every other path, fixture and section name below is shared.
      IDENTITY_EMPTY_OWNED_VALUES = ${py nodes.machine.specialisation.identity-empty.configuration.emubox.kiosk.ownedValuesFile}
      PLAYER_HOME = ${py home}
      FIXTURE_PADS = ${py fixturePads}
      FIXTURE_PORTS = ${py fixturePorts}
      EMPTY_PORT = ${py emptyPort}

      def port_index(port):
          """A recorded port's player number, which its emubox-pN link carries."""
          return FIXTURE_PORTS.index(port) + 1

      EMPTY_PORT_INDEX = port_index(EMPTY_PORT)
      SDL_GAMEPAD_NAME = ${py fixtureSdlGamepadName}
      SDL_JOYSTICK_GUID = ${py fixtureSdlJoystickGuid}
      UNACCEPTED_RECORDED = ${py { inherit (unacceptedOnRecordedPort) name vendor product; }}
      UNACCEPTED_LOOSE = ${py { inherit (unacceptedOffRecordedPorts) name vendor product; }}
      KEYBOARD_FIXTURE = ${py { inherit (keyboardFixture) name vendor product; }}
      SWITCHABLE_REPORTER_PATH = ${py switchableReporterPath}

      def run_status():
          """Run the aggregator without asserting its exit status: this
          node has no btrfs snapshot layer, so its backups section warns
          regardless of anything asserted here."""
          return machine.execute("emubox-status")

      def snapshot_owned_files():
          """Every file the rendered owned-values document names, as it
          stands on disk - None for one the editor has not created."""
          owned = json.loads(machine.succeed(f"cat {OWNED_VALUES}"))
          contents = {}
          for path in owned["files"]:
              resolved = path if path.startswith("/") else f"{APPDATA}/{path}"
              rc, text = machine.execute(f"cat {shlex.quote(resolved)}")
              contents[path] = text if rc == 0 else None
          return contents

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

      def find_node_by_name(name, kind):
          """The `kind`N input node (`event` or `js`) whose kernel-reported
          name matches, waiting for the uinput device and udev's rule
          processing to catch up."""
          path = machine.wait_until_succeeds(
              f"grep -rlx {shlex.quote(name)} /sys/class/input/{kind}*/device/name"
          ).strip()
          return path.split("/")[4]

      def find_event_by_name(name):
          return find_node_by_name(name, "event")

      def udev_property(node, name):
          """One udev property of /dev/input/`node`, empty when unset."""
          return machine.succeed(
              f"udevadm info -q property -n /dev/input/{node} --property={name} --value"
          ).strip()

      def port_links(node):
          """The emubox-pN links udev has made to /dev/input/`node`."""
          return [link for link in udev_property(node, "DEVLINKS").split() if "emubox-p" in link]


      def rerun_prepare(owned_values=OWNED_VALUES):
          """Re-run emubox-prepare as player, with no custom-systems
          argument - the same shape tests/kiosk.nix's own helper uses,
          standing in here for the run the kiosk session script makes
          before the frontend starts, which this node never runs because
          its display manager is off. Against this node's own rendered
          owned-values file by default; the identity-transition subtest
          below passes the identity-empty variant's instead."""
          cmd = f'ESDE_APPDATA_DIR={APPDATA} emubox-prepare {owned_values} ""'
          machine.succeed(f"su player -s /bin/sh -c {shlex.quote(cmd)}")

      def read_ini(path):
          return machine.succeed(f"cat {shlex.quote(path)}")

      def assert_ini(path, section, key, expected):
          got = ini_value(read_ini(path), section, key)
          assert got == expected, (path, section, key, got, expected)

      def write_as_player(path, text, *, append=False):
          """Write, or with `append` add, `text` to `path` as `player` (the
          account both emubox-prepare and every standalone emulator run
          as), so a later prepare run's own write is not fighting a
          root-owned file. Through a base64 round trip rather than `sed` or
          a shell literal, since several of the values this test writes
          carry `&`, `/` and quotes - shell metacharacters a replacement
          pattern would otherwise have to escape around."""
          encoded = base64.b64encode(text.encode()).decode()
          redirect = ">>" if append else ">"
          cmd = f"printf %s {shlex.quote(encoded)} | base64 -d {redirect} {shlex.quote(path)}"
          machine.succeed(f"su player -s /bin/sh -c {shlex.quote(cmd)}")

      def set_ini_value(path, section, key, new_value):
          """Overwrite one `key = value` line under `[section]` to
          `new_value`, as `player`."""
          write_as_player(path, ini_edited(read_ini(path), section, key, new_value))

      def remove_ini_line(path, section, key):
          """Delete one `key = value` line under `[section]`, as `player` -
          the complement to `set_ini_value`, putting a seeded key back into
          the "never yet assigned" state a fresh install leaves it in."""
          write_as_player(path, ini_edited(read_ini(path), section, key))

      def insert_ini_key(path, section, key, value):
          """Insert one new `key = value` line into an existing `[section]`
          that does not yet assign this key - the complement to
          `set_ini_value`, which requires the key already present."""
          write_as_player(path, ini_inserted(read_ini(path), section, key, value))

      def write_ini_file(path, sections):
          """Write a whole INI file from scratch, one `[section]` per
          mapping given - simulating an emulator that ran and saved its own
          configuration, with its own values, before bring-up ever recorded
          the pad's identity."""
          lines = []
          for section, keys in sections.items():
              lines.append(f"[{section}]\n")
              for key, value in keys.items():
                  lines.append(f"{key} = {value}\n")
          write_as_player(path, "".join(lines))

      def append_ini_section(path, section, keys):
          """Append a new `[section]` block to an existing file - the same
          simulated-emulator-save use `write_ini_file` serves, for a file
          that already carries some other, identity-free section."""
          lines = [f"\n[{section}]\n"] + [f"{k} = {v}\n" for k, v in keys.items()]
          write_as_player(path, "".join(lines), append=True)

      def assert_ini_section(path, section, expected):
          text = read_ini(path)
          for key, value in expected.items():
              got = ini_value(text, section, key)
              assert got == value, (path, section, key, got, value)

      # The gameplay-binding value tables modules/controllers declares, from
      # tests/lib/controller-bindings.nix's hand-typed copies rather than read
      # back from the module under test, one entry per native player and
      # rendered for this node's fixture identities.
      GC_PAD_BINDINGS = ${py (lib.genList (i: bindings.gcPad i fixtureSdlGamepadName) 4)}
      WIIMOTE_BINDINGS = ${py (lib.genList (i: bindings.wiimote i fixtureSdlGamepadName) 4)}
      PCSX2_PAD_BINDINGS = ${py (lib.genList bindings.pcsx2Pad 2)}
      DUCKSTATION_PAD_BINDINGS = ${py (lib.genList bindings.duckstationPad 2)}
      PPSSPP_CONTROLS_BINDINGS = ${py bindings.ppssppControls}
      AZAHAR_BINDINGS = ${py (bindings.azahar fixtureSdlJoystickGuid)}

      KEYBOARD_STICK_CALIBRATION = "100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42"

      # Full paths hand-typed against each emulator's own file names and
      # directories, independently of emubox.emulators.configDirs - the same
      # reasoning tests/kiosk.nix's own PINNED_OWNED_KEYS tables apply, so a
      # misspelled path in the module under test cannot agree with itself
      # here.
      DOLPHIN_INI = f"{PLAYER_HOME}/.config/dolphin-emu/Dolphin.ini"
      DOLPHIN_HOTKEYS = f"{PLAYER_HOME}/.config/dolphin-emu/Hotkeys.ini"
      DOLPHIN_GCPAD = f"{PLAYER_HOME}/.config/dolphin-emu/GCPadNew.ini"
      DOLPHIN_WIIMOTE = f"{PLAYER_HOME}/.config/dolphin-emu/WiimoteNew.ini"
      PCSX2_INI = f"{PLAYER_HOME}/.config/PCSX2/inis/PCSX2.ini"
      DUCKSTATION_INI = f"{PLAYER_HOME}/.local/share/duckstation/settings.ini"
      PPSSPP_INI = f"{PLAYER_HOME}/.config/ppsspp/PSP/SYSTEM/ppsspp.ini"
      PPSSPP_CONTROLS = f"{PLAYER_HOME}/.config/ppsspp/PSP/SYSTEM/controls.ini"
      SCUMMVM_INI = f"{PLAYER_HOME}/.config/scummvm/scummvm.ini"
      AZAHAR_INI = f"{PLAYER_HOME}/.config/azahar-emu/qt-config.ini"

      machine.wait_for_unit("multi-user.target")
      # Healthy from the start, so every subtest below that runs the
      # aggregator for an unrelated reason sees this section as `ok`.
      write_switchable_reporter(True)

      with subtest("The fixture udev rule is staged where udevd reads it"):
          # Only that the file is where udevd reads it, not its order: udevd
          # sorts every rules file by basename across every directory it
          # reads, and the next subtest is what proves the fixture rule runs
          # before the module's - a pad's emubox-pN link exists only if the
          # module's rule, in 99-local.rules, saw the ID_PATH the fixture
          # rule sets.
          etc_rules = machine.succeed("ls /etc/udev/rules.d").split()
          assert "73-emubox-test-fixture.rules" in etc_rules, etc_rules

      with subtest("Every emubox-pN resolves to its fixture pad's event node, in recorded order"):
          machine.wait_for_unit("emubox-test-fixture-devices.service")
          for pad in FIXTURE_PADS:
              i = port_index(pad["port"])
              # The unit is up as soon as its process forks, before the pads
              # exist: each link is waited for, and udev's queue drained so
              # the properties read below are its settled ones.
              machine.wait_until_succeeds(f"test -e /dev/input/emubox-p{i}")
              machine.succeed("udevadm settle")
              node = machine.succeed(f"readlink -f /dev/input/emubox-p{i}").strip().rsplit("/", 1)[-1]
              # The event node, never the pad's jsN sibling, which carries the
              # same ID_PATH and the same joystick mark.
              assert node.startswith("event"), (i, node, pad)
              got_name = machine.succeed(f"cat /sys/class/input/{node}/device/name").strip()
              assert got_name == pad["name"], (i, got_name, pad)
              path = udev_property(node, "ID_PATH")
              assert path == pad["port"], (i, path, pad)

      with subtest(
          "The port rule links neither a pad's joystick node nor a device udev does"
          " not mark a joystick, though each carries a recorded port's ID_PATH"
      ):
          js_nodes = [(pad, find_node_by_name(pad["name"], "js")) for pad in FIXTURE_PADS]
          keyboard = find_event_by_name(KEYBOARD_FIXTURE["name"])
          machine.succeed("udevadm settle")
          for pad, js in js_nodes:
              # Everything the module's rule matches except an event node's
              # name, so its KERNEL=="event*" match alone keeps this unlinked.
              assert udev_property(js, "ID_PATH") == pad["port"], (js, pad)
              assert udev_property(js, "ID_INPUT_JOYSTICK") == "1", (js, pad)
              assert port_links(js) == [], (js, port_links(js))
          # The empty port's path without the joystick mark, so the module's
          # ID_INPUT_JOYSTICK match alone keeps that port unlinked.
          assert udev_property(keyboard, "ID_PATH") == EMPTY_PORT, keyboard
          assert udev_property(keyboard, "ID_INPUT_JOYSTICK") != "1", keyboard
          assert port_links(keyboard) == [], (keyboard, port_links(keyboard))
          machine.fail(f"test -e /dev/input/emubox-p{EMPTY_PORT_INDEX}")

      with subtest("The session hint carries the recorded ports in order"):
          expected = ":".join(f"/dev/input/emubox-p{i}" for i in range(1, len(FIXTURE_PORTS) + 1))
          hinted = machine.succeed(
              "bash -c 'source /etc/set-environment && printf %s \"$SDL_JOYSTICK_DEVICE\"'"
          )
          assert hinted == expected, (hinted, expected)
          # And through PAM, the way the kiosk session's own login receives
          # it: from an emptied environment, so nothing this shell already
          # carries can stand in for what pam_env sets.
          pam_hinted = machine.succeed(
              "env -i /run/wrappers/bin/su player -s /bin/sh -c 'printf %s \"$SDL_JOYSTICK_DEVICE\"'"
          )
          assert pam_hinted == expected, (pam_hinted, expected)

      with subtest("No caller of the configuration editor is running before the first owned-key check"):
          # The display manager is off, so nothing here ever runs the kiosk
          # session script or the frontend on its own; asserted rather than
          # assumed, since every check below reads what the editor itself
          # writes.
          machine.fail("systemctl is-active display-manager.service")
          machine.fail("pgrep -x emubox-session")
          machine.fail("pgrep -x es-de")

      with subtest("emubox-prepare runs cleanly against this node's own rendered owned values"):
          machine.succeed("test -x /run/current-system/sw/bin/emubox-prepare")
          rerun_prepare()

      with subtest("A second run of emubox-prepare against the same file changes no owned file"):
          before = snapshot_owned_files()
          rerun_prepare()
          after = snapshot_owned_files()
          changed = [path for path in before if before[path] != after[path]]
          assert not changed, changed

      with subtest(
          "The owned-values document's files new to the editor are exactly Dolphin's"
          " GCPadNew.ini, WiimoteNew.ini and Hotkeys.ini, and PPSSPP's controls.ini"
      ):
          # The pre-existing baseline is hand-typed too, not read back from
          # the rendered document: subtracting it from what the document
          # actually carries is what turns "every file the document names"
          # into "every file new to the editor" - a property the document
          # itself carries no flag for.
          pre_existing_files = {
              "settings/es_settings.xml",
              f"{PLAYER_HOME}/.config/retroarch/retroarch.cfg",
              DOLPHIN_INI,
              f"{PLAYER_HOME}/.config/dolphin-emu/RetroAchievements.ini",
              PCSX2_INI,
              f"{PLAYER_HOME}/.config/PCSX2/inis/secrets.ini",
              PPSSPP_INI,
              f"{PLAYER_HOME}/.config/azahar-emu/qt-config.ini",
              DUCKSTATION_INI,
              SCUMMVM_INI,
          }
          expected_new_files = {DOLPHIN_GCPAD, DOLPHIN_WIIMOTE, DOLPHIN_HOTKEYS, PPSSPP_CONTROLS}
          owned = json.loads(machine.succeed(f"cat {OWNED_VALUES}"))
          actual_paths = set(owned["files"])
          missing_baseline = pre_existing_files - actual_paths
          assert not missing_baseline, missing_baseline
          assert actual_paths - pre_existing_files == expected_new_files, actual_paths - pre_existing_files

      with subtest(
          "Every standalone but Azahar carries its enforced route back and its"
          " dependency settings after the first prepare run"
      ):
          assert_ini(DOLPHIN_HOTKEYS, "Hotkeys", "Device", f"SDL/0/{SDL_GAMEPAD_NAME}")
          assert_ini(DOLPHIN_HOTKEYS, "Hotkeys", "General/Stop", "Back&Start")

          assert_ini(PCSX2_INI, "InputSources", "SDL", "true")
          assert_ini(PCSX2_INI, "Hotkeys", "ShutdownVM", "SDL-0/Back & SDL-0/Start")

          assert_ini(DUCKSTATION_INI, "InputSources", "SDL", "true")
          assert_ini(DUCKSTATION_INI, "Hotkeys", "PowerOff", "SDL-0/Back & SDL-0/Start")

          assert_ini(PPSSPP_CONTROLS, "ControlMapping", "Pause", "10-196:10-197")

          assert_ini(SCUMMVM_INI, "scummvm", "joystick_num", "0")
          assert_ini(SCUMMVM_INI, "keymapper", "keymap_global_QUIT", "JOY_GUIDE")
          assert_ini(SCUMMVM_INI, "keymapper", "keymap_global_MENU", "JOY_START")
          assert_ini(SCUMMVM_INI, "keymapper", "keymap_global_VMOUSEUP", "JOY_LEFT_STICK_Y-")
          assert_ini(SCUMMVM_INI, "keymapper", "keymap_global_VMOUSEDOWN", "JOY_LEFT_STICK_Y+")
          assert_ini(SCUMMVM_INI, "keymapper", "keymap_global_VMOUSELEFT", "JOY_LEFT_STICK_X-")
          assert_ini(SCUMMVM_INI, "keymapper", "keymap_global_VMOUSERIGHT", "JOY_LEFT_STICK_X+")
          assert_ini(SCUMMVM_INI, "keymapper", "keymap_gui_INTRCT", "JOY_A")

      with subtest(
          "Every exit-confirmation suppression setting the route backs depend on"
          " holds after the first prepare run"
      ):
          assert_ini(DOLPHIN_INI, "Interface", "ConfirmStop", "False")
          assert_ini(PCSX2_INI, "UI", "ConfirmShutdown", "false")
          assert_ini(DUCKSTATION_INI, "Main", "ConfirmPowerOff", "false")
          assert_ini(PPSSPP_INI, "General", "AskForExitConfirmationAfterSeconds", "0")
          # scummvm.confirm_exit and gui_return_to_launcher_at_exit: already
          # enforced by modules/emulators, not owned again here - only
          # asserted, the same way this subtest asserts every other
          # exit-confirmation suppression setting.
          assert_ini(SCUMMVM_INI, "scummvm", "confirm_exit", "false")
          assert_ini(SCUMMVM_INI, "scummvm", "gui_return_to_launcher_at_exit", "false")

      with subtest(
          "An altered route back, an altered dependency setting and a re-enabled"
          " confirmation are each restored by the next editor run"
      ):
          set_ini_value(DOLPHIN_HOTKEYS, "Hotkeys", "General/Stop", "Start")
          set_ini_value(DOLPHIN_HOTKEYS, "Hotkeys", "Device", "SDL/0/some-other-pad")
          set_ini_value(DOLPHIN_INI, "Interface", "ConfirmStop", "True")

          set_ini_value(PCSX2_INI, "Hotkeys", "ShutdownVM", "SDL-0/Start")
          set_ini_value(PCSX2_INI, "InputSources", "SDL", "false")
          set_ini_value(PCSX2_INI, "UI", "ConfirmShutdown", "true")

          set_ini_value(DUCKSTATION_INI, "Hotkeys", "PowerOff", "SDL-0/Start")
          set_ini_value(DUCKSTATION_INI, "InputSources", "SDL", "false")
          set_ini_value(DUCKSTATION_INI, "Main", "ConfirmPowerOff", "true")

          set_ini_value(PPSSPP_CONTROLS, "ControlMapping", "Pause", "10-197")
          set_ini_value(PPSSPP_INI, "General", "AskForExitConfirmationAfterSeconds", "300")

          set_ini_value(SCUMMVM_INI, "keymapper", "keymap_global_QUIT", "JOY_START")
          set_ini_value(SCUMMVM_INI, "scummvm", "joystick_num", "1")
          set_ini_value(SCUMMVM_INI, "scummvm", "confirm_exit", "true")
          set_ini_value(SCUMMVM_INI, "scummvm", "gui_return_to_launcher_at_exit", "true")

          rerun_prepare()

          assert_ini(DOLPHIN_HOTKEYS, "Hotkeys", "General/Stop", "Back&Start")
          assert_ini(DOLPHIN_HOTKEYS, "Hotkeys", "Device", f"SDL/0/{SDL_GAMEPAD_NAME}")
          assert_ini(DOLPHIN_INI, "Interface", "ConfirmStop", "False")

          assert_ini(PCSX2_INI, "Hotkeys", "ShutdownVM", "SDL-0/Back & SDL-0/Start")
          assert_ini(PCSX2_INI, "InputSources", "SDL", "true")
          assert_ini(PCSX2_INI, "UI", "ConfirmShutdown", "false")

          assert_ini(DUCKSTATION_INI, "Hotkeys", "PowerOff", "SDL-0/Back & SDL-0/Start")
          assert_ini(DUCKSTATION_INI, "InputSources", "SDL", "true")
          assert_ini(DUCKSTATION_INI, "Main", "ConfirmPowerOff", "false")

          assert_ini(PPSSPP_CONTROLS, "ControlMapping", "Pause", "10-196:10-197")
          assert_ini(PPSSPP_INI, "General", "AskForExitConfirmationAfterSeconds", "0")

          assert_ini(SCUMMVM_INI, "keymapper", "keymap_global_QUIT", "JOY_GUIDE")
          assert_ini(SCUMMVM_INI, "scummvm", "joystick_num", "0")
          assert_ini(SCUMMVM_INI, "scummvm", "confirm_exit", "false")
          assert_ini(SCUMMVM_INI, "scummvm", "gui_return_to_launcher_at_exit", "false")

      with subtest(
          "Dolphin's complete GameCube and Wii gameplay profile, and its slot"
          " settings, hold the flake's values for every player up to the"
          " system's native four"
      ):
          for n in range(1, 5):
              i = n - 1
              for key, value in GC_PAD_BINDINGS[i].items():
                  assert_ini(DOLPHIN_GCPAD, f"GCPad{n}", key, value)
              for key, value in WIIMOTE_BINDINGS[i].items():
                  assert_ini(DOLPHIN_WIIMOTE, f"Wiimote{n}", key, value)
          assert_ini(DOLPHIN_INI, "Core", "SIDevice1", "6")
          assert_ini(DOLPHIN_INI, "Core", "SIDevice2", "6")
          assert_ini(DOLPHIN_INI, "Core", "SIDevice3", "6")
          # Both files are new to the editor, so this first run wrote every
          # section they hold: the four native players and no fifth.
          assert ini_sections(read_ini(DOLPHIN_GCPAD)) == [f"GCPad{n}" for n in range(1, 5)]
          assert ini_sections(read_ini(DOLPHIN_WIIMOTE)) == [f"Wiimote{n}" for n in range(1, 5)]

      with subtest(
          "PCSX2 and DuckStation carry the pristine gameplay set for both"
          " native players, their second player's slot setting, and nothing"
          " for a third"
      ):
          for i in range(2):
              assert_ini_section(PCSX2_INI, f"Pad{i + 1}", PCSX2_PAD_BINDINGS[i])
              assert_ini_section(DUCKSTATION_INI, f"Pad{i + 1}", DUCKSTATION_PAD_BINDINGS[i])
          assert_ini(PCSX2_INI, "Pad1", "Type", "DualShock2")
          assert_ini(PCSX2_INI, "Pad2", "Type", "DualShock2")
          assert_ini(DUCKSTATION_INI, "Pad2", "Type", "AnalogController")
          assert "Pad3" not in ini_sections(read_ini(PCSX2_INI)), read_ini(PCSX2_INI)
          assert "Pad3" not in ini_sections(read_ini(DUCKSTATION_INI)), read_ini(DUCKSTATION_INI)

      with subtest("PPSSPP's controls.ini carries the complete gameplay set for its one native player"):
          assert_ini_section(PPSSPP_CONTROLS, "ControlMapping", PPSSPP_CONTROLS_BINDINGS)

      with subtest(
          "Azahar's profile array, its active-profile keys and every gameplay"
          " binding under profiles\\1\\ hold the flake's values, each with"
          " its own \\default companion"
      ):
          assert_ini(AZAHAR_INI, "Controls", "profiles\\size", "1")
          assert_ini(AZAHAR_INI, "Controls", "profile", "0")
          assert_ini(AZAHAR_INI, "Controls", "profile\\default", "false")
          for key, value in AZAHAR_BINDINGS.items():
              assert_ini(AZAHAR_INI, "Controls", f"profiles\\1\\{key}", value)
              assert_ini(AZAHAR_INI, "Controls", f"profiles\\1\\{key}\\default", "false")

      with subtest(
          "PPSSPP's controls.ini, recreated from nothing, carries exactly the"
          " complete gameplay set for its one native player and the enforced"
          " route back, and nothing else"
      ):
          machine.succeed(f"su player -s /bin/sh -c {shlex.quote(f'rm -f {PPSSPP_CONTROLS}')}")
          rerun_prepare()
          text = read_ini(PPSSPP_CONTROLS)
          expected_keys = set(PPSSPP_CONTROLS_BINDINGS) | {"Pause"}
          assert set(ini_section_keys(text, "ControlMapping")) == expected_keys, text
          for key, value in PPSSPP_CONTROLS_BINDINGS.items():
              assert ini_value(text, "ControlMapping", key) == value, (key, text)
          assert ini_value(text, "ControlMapping", "Pause") == "10-196:10-197"

      with subtest(
          "PCSX2's PCSX2.ini and Dolphin's GCPadNew.ini, recreated from nothing,"
          " carry exactly the complete gameplay set for every native player"
      ):
          machine.succeed(
              "su player -s /bin/sh -c " + shlex.quote(f"rm -f {PCSX2_INI} {DOLPHIN_GCPAD}")
          )
          rerun_prepare()
          recreated = [
              (PCSX2_INI, f"Pad{i + 1}", {**PCSX2_PAD_BINDINGS[i], "Type": "DualShock2"})
              for i in range(2)
          ] + [
              (DOLPHIN_GCPAD, f"GCPad{n}", GC_PAD_BINDINGS[n - 1])
              for n in range(1, 5)
          ]
          for path, section, expected in recreated:
              text = read_ini(path)
              assert set(ini_section_keys(text, section)) == set(expected), (path, section, text)
              for key, value in expected.items():
                  assert ini_value(text, section, key) == value, (path, section, key, text)
          # And no section for a player beyond each system's native count.
          gc_pad_text = read_ini(DOLPHIN_GCPAD)
          assert ini_sections(gc_pad_text) == [f"GCPad{n}" for n in range(1, 5)], gc_pad_text
          pcsx2_text = read_ini(PCSX2_INI)
          assert "Pad3" not in ini_sections(pcsx2_text), pcsx2_text

      with subtest(
          "An altered seeded gameplay binding, one per emulator that has"
          " one, and an altered seeded slot setting survive a further"
          " editor run"
      ):
          set_ini_value(PCSX2_INI, "Pad1", "Up", "SDL-0/Something")
          set_ini_value(DUCKSTATION_INI, "Pad1", "Up", "SDL-0/Something")
          set_ini_value(PPSSPP_CONTROLS, "ControlMapping", "Up", "10-999")
          set_ini_value(PCSX2_INI, "Pad2", "Type", "None")

          rerun_prepare()

          assert_ini(PCSX2_INI, "Pad1", "Up", "SDL-0/Something")
          assert_ini(DUCKSTATION_INI, "Pad1", "Up", "SDL-0/Something")
          assert_ini(PPSSPP_CONTROLS, "ControlMapping", "Up", "10-999")
          assert_ini(PCSX2_INI, "Pad2", "Type", "None")

      with subtest(
          "A readable owned file holding a binding for a player beyond the"
          " declared set keeps it, while a missing owned binding in the"
          " same file is written"
      ):
          append_ini_section(PCSX2_INI, "Pad3", {"Up": "SDL-2/DPadUp"})
          remove_ini_line(PCSX2_INI, "Pad1", "Down")

          rerun_prepare()

          assert_ini(PCSX2_INI, "Pad3", "Up", "SDL-2/DPadUp")
          assert_ini(PCSX2_INI, "Pad1", "Down", "SDL-0/DPadDown")

      with subtest(
          "Azahar: a binding altered away from the flake's value with its"
          " \\default companion set to true is restored, the companion is"
          " put back to false, and a further run leaves the file unchanged"
      ):
          set_ini_value(
              AZAHAR_INI, "Controls", "profiles\\1\\button_a", '"code:65,engine:keyboard"'
          )
          set_ini_value(AZAHAR_INI, "Controls", "profiles\\1\\button_a\\default", "true")

          rerun_prepare()

          assert_ini(AZAHAR_INI, "Controls", "profiles\\1\\button_a", AZAHAR_BINDINGS["button_a"])
          assert_ini(AZAHAR_INI, "Controls", "profiles\\1\\button_a\\default", "false")

          before = read_ini(AZAHAR_INI)
          rerun_prepare()
          after = read_ini(AZAHAR_INI)
          assert before == after, (before, after)

      with subtest(
          "The identity-transition test starts from a rendering with no"
          " identity facts, which declares none of Dolphin's gameplay or"
          " slot keys and none of Azahar's Controls keys"
      ):
          # Every earlier subtest ran against this node's own owned-values
          # file, whose identity facts hold their fixture values, so these
          # files already carry gameplay content from those runs. Cleared
          # first, so running against the identity-empty variant next
          # starts from a genuine absence rather than one this file already
          # held from before.
          machine.succeed(
              "su player -s /bin/sh -c "
              + shlex.quote(f"rm -f {DOLPHIN_GCPAD} {DOLPHIN_WIIMOTE} {DOLPHIN_HOTKEYS} {AZAHAR_INI}")
          )
          remove_ini_line(DOLPHIN_INI, "Core", "SIDevice1")
          remove_ini_line(DOLPHIN_INI, "Core", "SIDevice2")
          remove_ini_line(DOLPHIN_INI, "Core", "SIDevice3")

          rerun_prepare(IDENTITY_EMPTY_OWNED_VALUES)

          machine.fail(f"test -e {shlex.quote(DOLPHIN_GCPAD)}")
          machine.fail(f"test -e {shlex.quote(DOLPHIN_WIIMOTE)}")
          machine.fail(f"test -e {shlex.quote(DOLPHIN_HOTKEYS)}")
          assert "SIDevice1" not in read_ini(DOLPHIN_INI)
          assert "[Controls]" not in read_ini(AZAHAR_INI)

      with subtest(
          "Writing non-flake values into every identity-dependent key and"
          " altering one identity-free seeded binding simulates an"
          " emulator that ran and saved its own configuration before"
          " bring-up recorded the pad's identity"
      ):
          insert_ini_key(DOLPHIN_INI, "Core", "SIDevice1", "0")
          insert_ini_key(DOLPHIN_INI, "Core", "SIDevice2", "0")
          insert_ini_key(DOLPHIN_INI, "Core", "SIDevice3", "0")

          gc_pad_sections = {
              f"GCPad{n}": {k: "WRONG" for k in GC_PAD_BINDINGS[n - 1]}
              for n in range(1, 5)
          }
          # What Dolphin itself writes for a stick's calibration before any
          # pad is bound: its keyboard default's square gate.
          gc_pad_sections["GCPad1"]["Main Stick/Calibration"] = KEYBOARD_STICK_CALIBRATION
          write_ini_file(DOLPHIN_GCPAD, gc_pad_sections)
          write_ini_file(
              DOLPHIN_WIIMOTE,
              {
                  f"Wiimote{n}": {k: "WRONG" for k in WIIMOTE_BINDINGS[n - 1]}
                  for n in range(1, 5)
              },
          )
          write_ini_file(
              DOLPHIN_HOTKEYS,
              {"Hotkeys": {"Device": "WRONG", "General/Stop": "WRONG"}},
          )

          append_ini_section(
              AZAHAR_INI,
              "Controls",
              {
                  "profiles\\size": "2",
                  "profile": "1",
                  "profile\\default": "true",
                  **{f"profiles\\1\\{key}": "WRONG" for key in AZAHAR_BINDINGS},
                  **{f"profiles\\1\\{key}\\default": "true" for key in AZAHAR_BINDINGS},
              },
          )

          set_ini_value(PCSX2_INI, "Pad1", "Up", "SDL-0/Wrong")

      with subtest(
          "Running the editor against this node's own owned-values file,"
          " whose identity facts hold their fixture values, replaces every"
          " identity-dependent key with the flake's own value while the"
          " altered seeded binding keeps its own"
      ):
          rerun_prepare()

          # The keyboard calibration is gone: the stick is back to its full
          # range.
          assert_ini(DOLPHIN_GCPAD, "GCPad1", "Main Stick/Calibration", "")
          for n in range(1, 5):
              i = n - 1
              for key, value in GC_PAD_BINDINGS[i].items():
                  assert_ini(DOLPHIN_GCPAD, f"GCPad{n}", key, value)
              for key, value in WIIMOTE_BINDINGS[i].items():
                  assert_ini(DOLPHIN_WIIMOTE, f"Wiimote{n}", key, value)
          assert_ini(DOLPHIN_HOTKEYS, "Hotkeys", "Device", f"SDL/0/{SDL_GAMEPAD_NAME}")
          assert_ini(DOLPHIN_HOTKEYS, "Hotkeys", "General/Stop", "Back&Start")
          assert_ini(DOLPHIN_INI, "Core", "SIDevice1", "6")
          assert_ini(DOLPHIN_INI, "Core", "SIDevice2", "6")
          assert_ini(DOLPHIN_INI, "Core", "SIDevice3", "6")

          assert_ini(AZAHAR_INI, "Controls", "profiles\\size", "1")
          assert_ini(AZAHAR_INI, "Controls", "profile", "0")
          assert_ini(AZAHAR_INI, "Controls", "profile\\default", "false")
          for key, value in AZAHAR_BINDINGS.items():
              assert_ini(AZAHAR_INI, "Controls", f"profiles\\1\\{key}", value)
              assert_ini(AZAHAR_INI, "Controls", f"profiles\\1\\{key}\\default", "false")

          assert_ini(PCSX2_INI, "Pad1", "Up", "SDL-0/Wrong")

      with subtest("A further editor run against the same file changes nothing"):
          watched = (DOLPHIN_INI, DOLPHIN_GCPAD, DOLPHIN_WIIMOTE, DOLPHIN_HOTKEYS, AZAHAR_INI, PCSX2_INI)
          before = {path: read_ini(path) for path in watched}
          rerun_prepare()
          for path in watched:
              assert read_ini(path) == before[path], path

      with subtest(
          "The controllers section reports every recorded port, accepted-mode pads warn about"
          " nothing, and the keyboard-only device is neither classified nor named"
      ):
          # The keyboard-only device exists and udev has settled on it
          # without marking it a joystick, so its absence from the report
          # below is that classification at work, not a device that never
          # appeared.
          keyboard_event = find_event_by_name(KEYBOARD_FIXTURE["name"])
          machine.succeed("udevadm settle")
          keyboard_marked = machine.succeed(
              f"udevadm info -q property -n /dev/input/{keyboard_event}"
              " --property=ID_INPUT_JOYSTICK --value"
          ).strip()
          assert keyboard_marked != "1", (keyboard_event, keyboard_marked)

          _, output = run_status()
          controllers = status_sections(output)["controllers"]
          assert controllers.splitlines()[0] == "controllers: ok", controllers
          for pad in FIXTURE_PADS:
              assert f"port {port_index(pad['port'])}: connected" in controllers, controllers
          assert f"port {EMPTY_PORT_INDEX}: unoccupied" in controllers, controllers
          assert "WARN" not in controllers, controllers
          assert KEYBOARD_FIXTURE["vendor"] not in controllers, controllers
          assert KEYBOARD_FIXTURE["product"] not in controllers, controllers

      with subtest("An unaccepted-mode pad on a recorded port is named in the warning"):
          machine.succeed("systemctl start emubox-test-fixture-unaccepted-recorded.service")
          try:
              # udevd creates the port link before it writes its database,
              # so the property, not the link, says the device is fully
              # classified; the link exists by then as well.
              event = find_event_by_name(UNACCEPTED_RECORDED["name"])
              machine.wait_until_succeeds(
                  f"test $(udevadm info -q property -n /dev/input/{event}"
                  " --property=ID_INPUT_JOYSTICK --value) = 1"
              )
              # The empty port's link names this pad's own event node.
              linked = machine.succeed(
                  f"readlink -f /dev/input/emubox-p{EMPTY_PORT_INDEX}"
              ).strip()
              assert linked == f"/dev/input/{event}", (linked, event)
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
              for pad in FIXTURE_PADS:
                  assert f"port {port_index(pad['port'])}: connected" in controllers, controllers
              assert f"port {EMPTY_PORT_INDEX}: unoccupied" in controllers, controllers
          finally:
              machine.succeed("systemctl stop emubox-test-fixture-unaccepted-loose.service")
              machine.wait_until_fails(
                  f"grep -rlx {shlex.quote(UNACCEPTED_LOOSE['name'])}"
                  " /sys/class/input/event*/device/name"
              )

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
          " and the backups and library sections together, and no unregistered section"
      ):
          # Not asserted successful: this node has no btrfs snapshot layer,
          # so its backups section warns that the local layer has not yet
          # run, whatever the other sections report.
          _, output = run_status()
          sections = status_sections(output)
          assert set(sections) == {"backups", "controllers", "library", "switchable"}, sections
          assert sections["library"].startswith("library: ok\n"), sections["library"]
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
