#!/usr/bin/env python3
"""Report which recorded controller ports resolve to a connected pad, and
warn about any controller identifying as none of the box's accepted modes.

A controller, for this report, is an input event device udev marks
``ID_INPUT_JOYSTICK=1`` - the property the port-naming rule already
matches. Its identity is the vendor and product the input device itself
reports (Linux's own ``struct input_id``, read from
``/sys/class/input/eventN/device/id/{vendor,product}``), never udev's
USB-derived ``ID_VENDOR_ID``/``ID_MODEL_ID``: a device created through
``uinput`` has no USB parent to supply those, while it does carry its own
reported vendor and product. Any other input device - a power button, a
keyboard, a receiver - is not a controller here whatever identity it
carries, and is neither classified nor named.

An empty slot is information, not a finding: a recorded port that
resolves to no connected pad, and a box that records no ports at all, are
both reported without warning. A connected controller identifying as none
of the accepted modes is the only condition that makes this report
unhealthy.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

# Outside the status alphabet (0 ok, 1 warn, 2 fail), so the aggregator
# reports this section as not having run rather than as a warning with
# nothing beneath it; the error itself goes to stderr, which the aggregator
# shows under the section.
EXIT_DID_NOT_RUN = 3


@dataclass(frozen=True)
class Mode:
    vendor: str
    product: str


@dataclass(frozen=True)
class Joystick:
    devnode: str
    vendor: str
    product: str


def parse_accepted(modes: Sequence[str]) -> list[Mode]:
    """Parse ``vendor:product`` tokens as given on the command line."""

    parsed = []
    for mode in modes:
        vendor, _, product = mode.partition(":")
        parsed.append(Mode(vendor=vendor.lower(), product=product.lower()))
    return parsed


def is_accepted(joystick: Joystick, accepted: Sequence[Mode]) -> bool:
    return any(
        joystick.vendor.lower() == mode.vendor and joystick.product.lower() == mode.product
        for mode in accepted
    )


def classify(
    *,
    port_devnodes: Sequence[str | None],
    joysticks: Sequence[Joystick],
    accepted: Sequence[Mode],
) -> tuple[list[str], int]:
    """Return the report's lines and its own exit status.

    ``port_devnodes`` holds one entry per recorded port, in player order:
    the event device that port resolves to, or ``None`` for an empty one.
    Slot resolution and the unaccepted-mode warning are independent: a
    port's occupancy is read only from whether it resolves to a device at
    all, and every controller the system sees - on a recorded port or not
    - is checked against the accepted set. Warning for an empty slot would
    make this report unhealthy on a box that plays two-player games with
    two of its four ports empty, for the life of that box.
    """

    lines: list[str] = []
    if not port_devnodes:
        lines.append("no controller ports are recorded")
    else:
        for index, devnode in enumerate(port_devnodes, start=1):
            if devnode is not None:
                lines.append(f"port {index}: connected ({devnode})")
            else:
                lines.append(f"port {index}: unoccupied")

    unaccepted = [joystick for joystick in joysticks if not is_accepted(joystick, accepted)]
    for joystick in unaccepted:
        lines.append(
            f"WARN unaccepted controller mode {joystick.vendor}:{joystick.product}"
            f" ({joystick.devnode})"
        )

    return lines, (1 if unaccepted else 0)


def resolve_port(index: int, *, dev_input: Path = Path("/dev/input")) -> str | None:
    """The event device a recorded port's stable symlink currently resolves
    to, or ``None`` when the port is empty - including a dangling symlink
    left by a device that has since disconnected."""

    path = dev_input / f"emubox-p{index}"
    if not path.exists():
        return None
    return str(path.resolve())


def _udev_property(devnode: str, name: str) -> str | None:
    try:
        return subprocess.check_output(
            [
                "udevadm",
                "info",
                "-q",
                "property",
                "-n",
                devnode,
                f"--property={name}",
                "--value",
            ],
            text=True,
        ).strip()
    except subprocess.CalledProcessError:
        return None


def _input_id(event: str, field: str, *, sys_class_input: Path) -> str | None:
    try:
        return (sys_class_input / event / "device" / "id" / field).read_text().strip().lower()
    except OSError:
        return None


def discover_joysticks(*, sys_class_input: Path = Path("/sys/class/input")) -> list[Joystick]:
    """Every input event device udev currently marks a joystick, with the
    identity the device itself reports."""

    joysticks = []
    for entry in sorted(sys_class_input.glob("event*")):
        devnode = f"/dev/input/{entry.name}"
        if _udev_property(devnode, "ID_INPUT_JOYSTICK") != "1":
            continue
        vendor = _input_id(entry.name, "vendor", sys_class_input=sys_class_input)
        product = _input_id(entry.name, "product", sys_class_input=sys_class_input)
        if vendor is not None and product is not None:
            joysticks.append(Joystick(devnode=devnode, vendor=vendor, product=product))
    return joysticks


def main(argv: Sequence[str] | None = None) -> int:
    try:
        return report(argv)
    except Exception as error:  # noqa: BLE001 - any failure of this report's own
        print(f"emubox-controllers-status: {type(error).__name__}: {error}", file=sys.stderr)
        return EXIT_DID_NOT_RUN


def report(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--ports",
        type=int,
        required=True,
        help="The number of recorded controller ports (emubox.facts.controllerPorts).",
    )
    parser.add_argument(
        "--accepted",
        action="append",
        default=[],
        metavar="VENDOR:PRODUCT",
        help="An accepted controller mode's vendor and product, in hex. May repeat.",
    )
    args = parser.parse_args(argv)

    accepted = parse_accepted(args.accepted)
    port_devnodes = [resolve_port(index) for index in range(1, args.ports + 1)]
    joysticks = discover_joysticks()
    lines, status = classify(
        port_devnodes=port_devnodes,
        joysticks=joysticks,
        accepted=accepted,
    )
    for line in lines:
        print(line)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
