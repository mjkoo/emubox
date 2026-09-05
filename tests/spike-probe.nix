# Spike probe for the controllers design pass. NOT part of any change and not
# meant to merge: it answers questions the pairing design turns on, which no
# amount of reading settles, and is deleted with its branch.
#
# Round 2 asked three questions and answered them. Round 3's review found that
# the first answer was read one step too wide: the probe showed `hci_vhci`
# loads and `/dev/vhci` appears, and the design spent that as "a helper that
# opens the node presents an adapter". Opening the node allocates driver state;
# the HCI device is created by a control packet written on the fd, and the
# device that results is a raw controller whose commands are delivered to
# whoever holds the fd. So this round asks the question that was actually
# needed:
#
#   Q1  Writing the create-device packet to /dev/vhci - does an hci device
#       appear, does bluetoothd adopt it, does it come UP, and can pairable and
#       scanning state be set and read back? That decides whether the pairing
#       window is provable in a VM with a bare fd-holder, or whether it needs a
#       userspace controller emulator answering HCI commands.
#
# Every bluetoothctl and hciconfig call is wrapped in `timeout`: round 2's probe
# was not, and two calls blocked for fifteen minutes each against a dead daemon.
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
        pkgs.python3
      ];
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    def probe(label, command, seconds=20):
        status, output = machine.execute(f"timeout {seconds} {command}")
        print(f"PROBE {label}: rc={status}\n{output.rstrip()}\n---")

    print("=========== baseline: before any vhci device is created ===========")
    probe("modprobe hci_vhci", "modprobe hci_vhci")
    probe("devices before", "ls -1 /sys/class/bluetooth/ 2>&1")
    probe("bluetoothd before", "systemctl is-active bluetooth.service")

    # Create the device the way bluez's own btvirt does: a two-byte control
    # packet, HCI_VENDOR_PKT then the device type, written on the open fd. The
    # helper then holds the fd, which is exactly the shape the design assumed
    # was sufficient. It answers no HCI command, which is exactly what the
    # review says is missing - so this run decides between the two readings.
    machine.succeed(
        "cat > /tmp/vhci_hold.py <<'PY'\n"
        "import os, sys, time\n"
        "fd = os.open('/dev/vhci', os.O_RDWR)\n"
        "os.write(fd, bytes([0xff, 0x00]))\n"
        "sys.stderr.write('create packet written\\n')\n"
        "sys.stderr.flush()\n"
        "time.sleep(600)\n"
        "PY"
    )
    machine.succeed("systemd-run --unit=vhci-hold --collect python3 /tmp/vhci_hold.py")
    machine.sleep(5)

    print("=========== Q1: what does a bare fd-holder actually produce? ===========")
    probe("vhci-hold unit", "systemctl is-active vhci-hold.service")
    probe("vhci-hold log", "journalctl -u vhci-hold --no-pager -n 20")
    probe("devices after", "ls -1 /sys/class/bluetooth/ 2>&1")
    probe("hciconfig -a", "hciconfig -a")
    probe("bluetoothd after", "systemctl is-active bluetooth.service")
    probe("bluetoothctl list", "bluetoothctl list")
    probe("bluetoothctl show", "bluetoothctl show")

    print("=========== Q1b: can the adapter be brought up and driven? ===========")
    probe("hciconfig hci0 up", "hciconfig hci0 up")
    probe("hciconfig after up", "hciconfig -a")
    probe("power on", "bluetoothctl power on")
    probe("pairable off", "bluetoothctl pairable off")
    probe("show after pairable off", "bluetoothctl show")
    probe("scan on", "bluetoothctl --timeout 5 scan on", 25)
    probe("show after scan", "bluetoothctl show")

    print("=========== probe complete ===========")
  '';
}
