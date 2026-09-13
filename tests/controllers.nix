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

  # A variant of this node's own configuration whose identity facts are
  # both empty - the host's own default before bring-up ever records one -
  # built by extending the same module set the host's flake output already
  # evaluates rather than a second, hand-maintained copy of it. Nothing
  # else this node overrides (its fixture ports, its test-only status
  # reporter, its display manager) reaches `emubox.kiosk.ownedFiles` at
  # all, so this variant's rendered owned-values document is exactly the
  # one the identity-transition subtest below needs to start from.
  identityEmptyOwnedValues =
    (self.nixosConfigurations.emubox.extendModules {
      modules = [
        {
          emubox.facts.controllerIdentities.sdlGamepadName = lib.mkForce null;
          emubox.facts.controllerIdentities.sdlJoystickGuid = lib.mkForce null;
        }
      ];
    }).config.emubox.kiosk.ownedValuesFile;

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
      # Beside the fixture ports: the one pad-identity fact Dolphin's route
      # back depends on. A plain assignment is enough here - unlike
      # `controllerPorts` above, `hosts/emubox/facts.nix`'s own
      # `controllerIdentities = { };` sets no field of this submodule at
      # all, so there is nothing for this node's own definition of
      # `sdlGamepadName` to be merged against.
      emubox.facts.controllerIdentities.sdlGamepadName = fixtureSdlGamepadName;
      emubox.facts.controllerIdentities.sdlJoystickGuid = fixtureSdlJoystickGuid;

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
      import base64
      import json
      import shlex

      APPDATA = ${py appdataDir}
      OWNED_VALUES = ${py ownedValuesFile}
      # A second rendered owned-values document, from a variant of this
      # same node's configuration whose identity facts are both empty -
      # only this constant differs between the two; every other path,
      # fixture and section name below is shared.
      IDENTITY_EMPTY_OWNED_VALUES = ${py identityEmptyOwnedValues}
      PLAYER_HOME = ${py home}
      FIXTURE_PADS = ${py fixturePads}
      FIXTURE_PORTS = ${py fixturePorts}
      EMPTY_PORT_INDEX = len(FIXTURE_PORTS)
      SDL_GAMEPAD_NAME = ${py fixtureSdlGamepadName}
      SDL_JOYSTICK_GUID = ${py fixtureSdlJoystickGuid}
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

      def ini_value(text, section, key):
          """The value of one `key = value` line under `[section]`, or None
          if it is absent - a plain reader, mirroring emubox-prepare's own
          section matching without importing it."""
          in_section = False
          for line in text.splitlines():
              stripped = line.strip()
              if stripped.startswith("[") and stripped.endswith("]"):
                  in_section = stripped[1:-1] == section
                  continue
              if not in_section or "=" not in stripped:
                  continue
              k, _, v = stripped.partition("=")
              if k.strip() == key:
                  return v.strip()
          return None

      def read_ini(path):
          return machine.succeed(f"cat {shlex.quote(path)}")

      def assert_ini(path, section, key, expected):
          got = ini_value(read_ini(path), section, key)
          assert got == expected, (path, section, key, got, expected)

      def set_ini_value(path, section, key, new_value):
          """Overwrite one `key = value` line under `[section]` to
          `new_value`, as `player` (the account both emubox-prepare and
          every standalone emulator run as), so a later prepare run's own
          write is not fighting a root-owned file. Written back through a
          base64 round trip rather than `sed`, since several of the values
          this test sets and restores carry `&` and `/` - shell metacharacters
          a sed replacement pattern would otherwise have to escape around."""
          lines = read_ini(path).splitlines(keepends=True)
          out = []
          in_section = False
          replaced = False
          for line in lines:
              stripped = line.strip()
              if stripped.startswith("[") and stripped.endswith("]"):
                  in_section = stripped[1:-1] == section
                  out.append(line)
                  continue
              if in_section and not replaced and "=" in stripped:
                  k, _, _ = stripped.partition("=")
                  if k.strip() == key:
                      out.append(f"{key} = {new_value}\n")
                      replaced = True
                      continue
              out.append(line)
          assert replaced, f"{path}: no [{section}] {key} line to alter"
          encoded = base64.b64encode("".join(out).encode()).decode()
          cmd = f"printf %s {shlex.quote(encoded)} | base64 -d > {shlex.quote(path)}"
          machine.succeed(f"su player -s /bin/sh -c {shlex.quote(cmd)}")

      def remove_ini_line(path, section, key):
          """Delete one `key = value` line under `[section]`, as `player` -
          the complement to `set_ini_value`, putting a seeded key back into
          the "never yet assigned" state a fresh install leaves it in."""
          lines = read_ini(path).splitlines(keepends=True)
          out = []
          in_section = False
          removed = False
          for line in lines:
              stripped = line.strip()
              if stripped.startswith("[") and stripped.endswith("]"):
                  in_section = stripped[1:-1] == section
                  out.append(line)
                  continue
              if in_section and not removed and "=" in stripped:
                  k, _, _ = stripped.partition("=")
                  if k.strip() == key:
                      removed = True
                      continue
              out.append(line)
          assert removed, f"{path}: no [{section}] {key} line to remove"
          encoded = base64.b64encode("".join(out).encode()).decode()
          cmd = f"printf %s {shlex.quote(encoded)} | base64 -d > {shlex.quote(path)}"
          machine.succeed(f"su player -s /bin/sh -c {shlex.quote(cmd)}")

      def insert_ini_key(path, section, key, value):
          """Insert one new `key = value` line into an existing `[section]`
          that does not yet assign this key - the complement to
          `set_ini_value`, which requires the key already present."""
          lines = read_ini(path).splitlines(keepends=True)
          out = []
          in_section = False
          inserted = False
          for line in lines:
              stripped = line.strip()
              if stripped.startswith("[") and stripped.endswith("]"):
                  if in_section and not inserted:
                      out.append(f"{key} = {value}\n")
                      inserted = True
                  in_section = stripped[1:-1] == section
                  out.append(line)
                  continue
              out.append(line)
          if in_section and not inserted:
              out.append(f"{key} = {value}\n")
              inserted = True
          assert inserted, f"{path}: no [{section}] section to insert into"
          encoded = base64.b64encode("".join(out).encode()).decode()
          cmd = f"printf %s {shlex.quote(encoded)} | base64 -d > {shlex.quote(path)}"
          machine.succeed(f"su player -s /bin/sh -c {shlex.quote(cmd)}")

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
          encoded = base64.b64encode("".join(lines).encode()).decode()
          cmd = f"printf %s {shlex.quote(encoded)} | base64 -d > {shlex.quote(path)}"
          machine.succeed(f"su player -s /bin/sh -c {shlex.quote(cmd)}")

      def append_ini_section(path, section, keys):
          """Append a new `[section]` block to an existing file - the same
          simulated-emulator-save use `write_ini_file` serves, for a file
          that already carries some other, identity-free section."""
          lines = [f"\n[{section}]\n"] + [f"{k} = {v}\n" for k, v in keys.items()]
          encoded = base64.b64encode("".join(lines).encode()).decode()
          cmd = f"printf %s {shlex.quote(encoded)} | base64 -d >> {shlex.quote(path)}"
          machine.succeed(f"su player -s /bin/sh -c {shlex.quote(cmd)}")

      def ini_section_keys(text, section):
          """Every key name present under `[section]`, in the order it
          appears - used to assert a recreated file's key set exactly,
          rather than merely a subset of it."""
          keys = []
          in_section = False
          for line in text.splitlines():
              stripped = line.strip()
              if stripped.startswith("[") and stripped.endswith("]"):
                  in_section = stripped[1:-1] == section
                  continue
              if not in_section or "=" not in stripped:
                  continue
              k, _, _ = stripped.partition("=")
              keys.append(k.strip())
          return keys

      def assert_ini_section(path, section, expected):
          text = read_ini(path)
          for key, value in expected.items():
              got = ini_value(text, section, key)
              assert got == value, (path, section, key, got, value)

      # Independent reimplementations of the gameplay-binding value tables
      # modules/controllers declares, hand-typed the same way SDL_GAMEPAD_NAME
      # above already is, rather than read back from the module under test.

      def gc_pad_bindings(i, name):
          return {
              "Device": f"SDL/{i}/{name}",
              "Buttons/A": "`Button S`",
              "Buttons/B": "`Button E`",
              "Buttons/X": "`Button W`",
              "Buttons/Y": "`Button N`",
              "Buttons/Z": "`Shoulder R`",
              "Buttons/Start": "Start",
              "Main Stick/Up": "`Left Y+`",
              "Main Stick/Down": "`Left Y-`",
              "Main Stick/Left": "`Left X-`",
              "Main Stick/Right": "`Left X+`",
              "C-Stick/Up": "`Right Y+`",
              "C-Stick/Down": "`Right Y-`",
              "C-Stick/Left": "`Right X-`",
              "C-Stick/Right": "`Right X+`",
              "Triggers/L": "`Trigger L`",
              "Triggers/R": "`Trigger R`",
              "Triggers/L-Analog": "`Trigger L`",
              "Triggers/R-Analog": "`Trigger R`",
              "D-Pad/Up": "`Pad N`",
              "D-Pad/Down": "`Pad S`",
              "D-Pad/Left": "`Pad W`",
              "D-Pad/Right": "`Pad E`",
          }

      def wiimote_bindings(i, name):
          bindings = {
              "Device": f"SDL/{i}/{name}",
              "Buttons/A": "`Button S`",
              "Buttons/B": "`Trigger R`",
              "Buttons/1": "`Button W`",
              "Buttons/2": "`Button N`",
              "Buttons/-": "Back",
              "Buttons/+": "Start",
              "Buttons/Home": "Guide",
              "D-Pad/Up": "`Pad N`",
              "D-Pad/Down": "`Pad S`",
              "D-Pad/Left": "`Pad W`",
              "D-Pad/Right": "`Pad E`",
              "IR/Up": "`Right Y+`",
              "IR/Down": "`Right Y-`",
              "IR/Left": "`Right X-`",
              "IR/Right": "`Right X+`",
              "Shake/X": "`Button E`",
              "Shake/Y": "`Button E`",
              "Shake/Z": "`Button E`",
              "Extension": "Nunchuk",
              "Nunchuk/Buttons/C": "`Shoulder L`",
              "Nunchuk/Buttons/Z": "`Trigger L`",
              "Nunchuk/Stick/Up": "`Left Y+`",
              "Nunchuk/Stick/Down": "`Left Y-`",
              "Nunchuk/Stick/Left": "`Left X-`",
              "Nunchuk/Stick/Right": "`Left X+`",
              "Nunchuk/Shake/X": "`Thumb L`",
              "Nunchuk/Shake/Y": "`Thumb L`",
              "Nunchuk/Shake/Z": "`Thumb L`",
          }
          if i != 0:
              bindings["Source"] = "1"
          return bindings

      def pcsx2_pad_bindings(i):
          return {
              "Up": f"SDL-{i}/DPadUp",
              "Right": f"SDL-{i}/DPadRight",
              "Down": f"SDL-{i}/DPadDown",
              "Left": f"SDL-{i}/DPadLeft",
              "Triangle": f"SDL-{i}/FaceNorth",
              "Circle": f"SDL-{i}/FaceEast",
              "Cross": f"SDL-{i}/FaceSouth",
              "Square": f"SDL-{i}/FaceWest",
              "Select": f"SDL-{i}/Back",
              "Start": f"SDL-{i}/Start",
              "L1": f"SDL-{i}/LeftShoulder",
              "L2": f"SDL-{i}/+LeftTrigger",
              "R1": f"SDL-{i}/RightShoulder",
              "R2": f"SDL-{i}/+RightTrigger",
              "L3": f"SDL-{i}/LeftStick",
              "R3": f"SDL-{i}/RightStick",
              "Analog": f"SDL-{i}/Guide",
              "LUp": f"SDL-{i}/-LeftY",
              "LRight": f"SDL-{i}/+LeftX",
              "LDown": f"SDL-{i}/+LeftY",
              "LLeft": f"SDL-{i}/-LeftX",
              "RUp": f"SDL-{i}/-RightY",
              "RRight": f"SDL-{i}/+RightX",
              "RDown": f"SDL-{i}/+RightY",
              "RLeft": f"SDL-{i}/-RightX",
              "LargeMotor": f"SDL-{i}/LargeMotor",
              "SmallMotor": f"SDL-{i}/SmallMotor",
          }

      def duckstation_pad_bindings(i):
          return {
              "Up": f"SDL-{i}/DPadUp",
              "Right": f"SDL-{i}/DPadRight",
              "Down": f"SDL-{i}/DPadDown",
              "Left": f"SDL-{i}/DPadLeft",
              "Triangle": f"SDL-{i}/Y",
              "Circle": f"SDL-{i}/B",
              "Cross": f"SDL-{i}/A",
              "Square": f"SDL-{i}/X",
              "Select": f"SDL-{i}/Back",
              "Start": f"SDL-{i}/Start",
              "L1": f"SDL-{i}/LeftShoulder",
              "L2": f"SDL-{i}/+LeftTrigger",
              "R1": f"SDL-{i}/RightShoulder",
              "R2": f"SDL-{i}/+RightTrigger",
              "L3": f"SDL-{i}/LeftStick",
              "R3": f"SDL-{i}/RightStick",
              "Analog": f"SDL-{i}/Guide",
              "LUp": f"SDL-{i}/-LeftY",
              "LRight": f"SDL-{i}/+LeftX",
              "LDown": f"SDL-{i}/+LeftY",
              "LLeft": f"SDL-{i}/-LeftX",
              "RUp": f"SDL-{i}/-RightY",
              "RRight": f"SDL-{i}/+RightX",
              "RDown": f"SDL-{i}/+RightY",
              "RLeft": f"SDL-{i}/-RightX",
              "LargeMotor": f"SDL-{i}/LargeMotor",
              "SmallMotor": f"SDL-{i}/SmallMotor",
          }

      PPSSPP_CONTROLS_BINDINGS = {
          "Up": "10-19",
          "Down": "10-20",
          "Left": "10-21",
          "Right": "10-22",
          "Cross": "10-189",
          "Circle": "10-190",
          "Square": "10-191",
          "Triangle": "10-188",
          "Start": "10-197",
          "Select": "10-196",
          "L": "10-193",
          "R": "10-192",
          "An.Up": "10-4003",
          "An.Down": "10-4002",
          "An.Left": "10-4001",
          "An.Right": "10-4000",
      }

      def azahar_button(n):
          return f'"button:{n},engine:sdl,guid:{SDL_JOYSTICK_GUID},port:0"'

      def azahar_hat(direction):
          return f'"direction:{direction},engine:sdl,guid:{SDL_JOYSTICK_GUID},hat:0,port:0"'

      def azahar_axis_button(axis):
          return f'"axis:{axis},direction:+,engine:sdl,guid:{SDL_JOYSTICK_GUID},port:0,threshold:0.5"'

      def azahar_analog(x, y):
          return (
              f'"axis_x:{x},axis_y:{y},deadzone:0.100000,engine:sdl,'
              f'guid:{SDL_JOYSTICK_GUID},port:0"'
          )

      AZAHAR_BINDINGS = {
          "button_a": azahar_button(1),
          "button_b": azahar_button(0),
          "button_x": azahar_button(3),
          "button_y": azahar_button(2),
          "button_up": azahar_hat("up"),
          "button_down": azahar_hat("down"),
          "button_left": azahar_hat("left"),
          "button_right": azahar_hat("right"),
          "button_l": azahar_button(4),
          "button_r": azahar_button(5),
          "button_start": azahar_button(7),
          "button_select": azahar_button(6),
          "button_zl": azahar_axis_button(2),
          "button_zr": azahar_axis_button(5),
          "button_home": azahar_button(8),
          "circle_pad": azahar_analog(0, 1),
          "c_stick": azahar_analog(3, 4),
      }

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

      with subtest("Every exit-confirmation suppression setting this task owns holds after the first prepare run"):
          assert_ini(DOLPHIN_INI, "Interface", "ConfirmStop", "False")
          assert_ini(PCSX2_INI, "UI", "ConfirmShutdown", "false")
          assert_ini(DUCKSTATION_INI, "Main", "ConfirmPowerOff", "false")
          assert_ini(PPSSPP_INI, "General", "AskForExitConfirmationAfterSeconds", "0")

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

      with subtest(
          "Dolphin's complete GameCube and Wii gameplay profile, and its slot"
          " settings, hold the flake's values for every player up to the"
          " system's native four"
      ):
          for n in range(1, 5):
              i = n - 1
              for key, value in gc_pad_bindings(i, SDL_GAMEPAD_NAME).items():
                  assert_ini(DOLPHIN_GCPAD, f"GCPad{n}", key, value)
              for key, value in wiimote_bindings(i, SDL_GAMEPAD_NAME).items():
                  assert_ini(DOLPHIN_WIIMOTE, f"Wiimote{n}", key, value)
          assert_ini(DOLPHIN_INI, "Core", "SIDevice1", "6")
          assert_ini(DOLPHIN_INI, "Core", "SIDevice2", "6")
          assert_ini(DOLPHIN_INI, "Core", "SIDevice3", "6")

      with subtest(
          "PCSX2 and DuckStation carry the pristine gameplay set for both"
          " native players, and their second player's slot setting"
      ):
          for i in range(2):
              assert_ini_section(PCSX2_INI, f"Pad{i + 1}", pcsx2_pad_bindings(i))
              assert_ini_section(DUCKSTATION_INI, f"Pad{i + 1}", duckstation_pad_bindings(i))
          assert_ini(PCSX2_INI, "Pad1", "Type", "DualShock2")
          assert_ini(PCSX2_INI, "Pad2", "Type", "DualShock2")
          assert_ini(DUCKSTATION_INI, "Pad2", "Type", "AnalogController")

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

          write_ini_file(
              DOLPHIN_GCPAD,
              {
                  f"GCPad{n}": {k: "WRONG" for k in gc_pad_bindings(n - 1, SDL_GAMEPAD_NAME)}
                  for n in range(1, 5)
              },
          )
          write_ini_file(
              DOLPHIN_WIIMOTE,
              {
                  f"Wiimote{n}": {k: "WRONG" for k in wiimote_bindings(n - 1, SDL_GAMEPAD_NAME)}
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

          for n in range(1, 5):
              i = n - 1
              for key, value in gc_pad_bindings(i, SDL_GAMEPAD_NAME).items():
                  assert_ini(DOLPHIN_GCPAD, f"GCPad{n}", key, value)
              for key, value in wiimote_bindings(i, SDL_GAMEPAD_NAME).items():
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
