# The controllers test: the host's software modules booted as a plain node
# with fixture pads on fixture ports, proving the mapping this project owns
# - a recorded port to its player name - and the session hint that follows
# from it, without depending on the virtual machine's own bus topology (see
# the controllers design's fixture decision for why an emulated USB device
# cannot stand in for a pad here).
#
# This node has no graphical session: it turns its display manager off so
# nothing on it ever calls the configuration editor except the test's own
# manual invocations, and it has no btrfs snapshot layer, so its backups
# section (once one exists) reports the local layer as not yet run and
# warns. Neither is asserted here as a failure; a healthy aggregate is the
# install node's proof.
{ self }:
let
  pkgs = self.nixosConfigurations.emubox.pkgs;
  inherit (pkgs) lib;

  # The fixture: three recorded ports, each with its own pad presented
  # through uinput and a test-only udev rule that marks it a joystick at the
  # recorded path. Kept as data, not three copies of similar code, so a
  # later group can add a fourth pad or a differently-shaped device (an
  # unaccepted-mode joystick, a keyboard-only device) beside these without
  # touching the mechanism.
  fixturePorts = [
    "emubox-test-controller-port-1"
    "emubox-test-controller-port-2"
    "emubox-test-controller-port-3"
  ];
  fixturePads = lib.imap1 (i: port: {
    name = "emubox-test-pad-${toString i}";
    vendor = "0000";
    product = "0000";
    kind = "gamepad";
    inherit port;
  }) fixturePorts;

  # Creates one or more uinput devices by name, vendor, product and
  # capability set, and holds them open for the life of the node - the
  # devices themselves, not their udev classification, which the fixture
  # rule below supplies instead of relying on the kernel's own joystick
  # heuristic. Parametric over the device list so a later group's
  # differently-shaped fixture devices (an unaccepted-mode joystick, a
  # keyboard-only device the fixture rule must leave unmarked) are more
  # entries in the same list rather than a second script.
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

  fixtureDevicesSpec = pkgs.writeText "emubox-test-fixture-devices.json" (
    builtins.toJSON (
      map (pad: {
        inherit (pad)
          name
          vendor
          product
          kind
          ;
      }) fixturePads
    )
  );

  testPython = pkgs.python3.withPackages (ps: [ ps.evdev ]);

  # The fixture rule: ordered between the kernel's own input classification
  # (systemd's `60-input-id.rules` and `60-persistent-input.rules`, which run
  # first) and the module's rule (`services.udev.extraRules`, which lands in
  # `99-local.rules`), matching only the fixture pads by name so the
  # non-joystick device a later group creates through the same mechanism
  # stays unmarked. `73` is arbitrary within that 60-99 window; the ordering
  # this relies on is asserted in the test script below rather than assumed.
  fixtureRulesFile = pkgs.writeText "73-emubox-test-fixture.rules" (
    lib.concatMapStringsSep "\n" (
      pad:
      ''SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="${pad.name}", ENV{ID_INPUT_JOYSTICK}="1", ENV{ID_PATH}="${pad.port}"''
    ) fixturePads
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

      emubox.facts.controllerPorts = fixturePorts;

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

      with subtest("The fixture udev rule sorts after the kernel's input classification and before the module's own"):
          rules = sorted(machine.succeed("ls /etc/udev/rules.d").split())
          fixture_rule = "73-emubox-test-fixture.rules"
          assert fixture_rule in rules, rules
          kernel_rules = [r for r in rules if r.startswith("60-") and "input" in r]
          assert kernel_rules, rules
          assert all(r < fixture_rule for r in kernel_rules), (kernel_rules, fixture_rule)
          assert "99-local.rules" in rules, rules
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
    '';
}
