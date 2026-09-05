# Spike probe for the controllers design pass. NOT part of any change and not
# meant to merge: it answers three questions the pairing design turns on, which
# no amount of reading settles, and then it is deleted with its branch.
#
#   Q1  Can a node built the way this project builds them present a Bluetooth
#       adapter at all? If `hci_vhci` loads there is a route to a virtual
#       controller, and pairing behaviour is testable in a VM. If it does not,
#       every adapter assertion belongs to hardware bring-up.
#   Q2  Does a unit killed at `RuntimeMaxSec` really land in `systemctl
#       --failed`, and does one that finishes inside its limit really not?
#   Q3  Is `systemctl start` refused for an unprivileged user with no
#       authentication agent, and does passwordless sudo change that?
{ }:
{
  name = "controllers-spike-probe";

  nodes.machine =
    { pkgs, ... }:
    {
      hardware.bluetooth.enable = true;
      environment.systemPackages = [
        pkgs.bluez
        pkgs.kmod
      ];

      # A deliberately unprivileged administrator shaped like the real one:
      # in wheel, with passwordless sudo, and no authentication agent.
      users.users.probe = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
      };
      security.sudo.wheelNeedsPassword = false;

      # Q2 fixtures: one unit that overruns its runtime limit and one that
      # finishes well inside it.
      systemd.services.spike-overrun = {
        description = "Runs past its runtime limit";
        serviceConfig = {
          Type = "simple";
          RuntimeMaxSec = 2;
          ExecStart = "${pkgs.coreutils}/bin/sleep 30";
        };
      };
      systemd.services.spike-within = {
        description = "Finishes inside its runtime limit";
        serviceConfig = {
          Type = "oneshot";
          RuntimeMaxSec = 30;
          ExecStart = "${pkgs.coreutils}/bin/sleep 1";
        };
      };
    };

  # Every answer is printed rather than asserted: this is a probe, and a
  # failing assertion would hide the very output the design pass needs.
  testScript = ''
    machine.wait_for_unit("multi-user.target")

    def probe(label, command):
        status, output = machine.execute(command)
        print(f"PROBE {label}: rc={status}\n{output.rstrip()}\n---")

    print("=========== Q1: can this node present a Bluetooth adapter? ===========")
    probe("modprobe hci_vhci", "modprobe hci_vhci")
    probe("vhci module files", "find /run/booted-system/kernel-modules/lib/modules -name 'hci_vhci*' 2>/dev/null | head")
    probe("bluetooth module files", "find /run/booted-system/kernel-modules/lib/modules -path '*bluetooth*' -name '*.ko*' 2>/dev/null | head -20")
    probe("/dev/vhci", "ls -l /dev/vhci")
    probe("bluetoothd active", "systemctl is-active bluetooth.service")
    probe("bluetoothctl list", "bluetoothctl list")
    probe("bluetoothctl show", "bluetoothctl show")
    probe("hciconfig", "hciconfig -a")

    print("=========== Q2: RuntimeMaxSec failure semantics ===========")
    machine.succeed("systemctl start --no-block spike-overrun.service")
    machine.sleep(10)
    probe("overrun state", "systemctl show spike-overrun.service -p Result -p ActiveState -p SubState -p ExecMainStatus")
    probe("failed list after overrun", "systemctl --failed --no-legend --plain")
    machine.execute("systemctl reset-failed")
    machine.succeed("systemctl start spike-within.service")
    probe("within state", "systemctl show spike-within.service -p Result -p ActiveState -p SubState -p ExecMainStatus")
    probe("failed list after within", "systemctl --failed --no-legend --plain")

    print("=========== Q3: does an unprivileged systemctl start need polkit? ===========")
    probe("unprivileged systemctl start", "su - probe -c 'systemctl start spike-within.service' 2>&1")
    probe("unprivileged with sudo", "su - probe -c 'sudo systemctl start spike-within.service' 2>&1")
    probe("polkit running", "systemctl is-active polkit.service")

    print("=========== probe complete ===========")
  '';
}
