from pathlib import Path

import pytest

import emubox_controllers_status as ecs


ACCEPTED = ecs.parse_accepted(["045e:028e"])


def test_parse_accepted_lowercases_vendor_and_product() -> None:
    assert ecs.parse_accepted(["045E:028E"]) == [ecs.Mode(vendor="045e", product="028e")]


def test_is_accepted_matches_case_insensitively() -> None:
    joystick = ecs.Joystick(devnode="/dev/input/event3", vendor="045E", product="028E")
    assert ecs.is_accepted(joystick, ACCEPTED)


def test_is_accepted_rejects_an_unlisted_mode() -> None:
    joystick = ecs.Joystick(devnode="/dev/input/event3", vendor="1234", product="5678")
    assert not ecs.is_accepted(joystick, ACCEPTED)


def test_no_ports_recorded_reports_that_and_stays_healthy() -> None:
    lines, status = ecs.classify(port_devnodes=[], joysticks=[], accepted=ACCEPTED)
    assert lines == ["no controller ports are recorded"]
    assert status == 0


def test_a_connected_port_and_a_disconnected_one_are_both_reported() -> None:
    lines, status = ecs.classify(
        port_devnodes=["/dev/input/event3", None],
        joysticks=[ecs.Joystick(devnode="/dev/input/event3", vendor="045e", product="028e")],
        accepted=ACCEPTED,
    )
    assert lines == ["port 1: connected (/dev/input/event3)", "port 2: unoccupied"]
    assert status == 0


def test_an_unaccepted_mode_pad_on_a_recorded_port_is_named_in_the_warning() -> None:
    lines, status = ecs.classify(
        port_devnodes=["/dev/input/event3"],
        joysticks=[ecs.Joystick(devnode="/dev/input/event3", vendor="1234", product="5678")],
        accepted=ACCEPTED,
    )
    assert "port 1: connected (/dev/input/event3)" in lines
    assert any("1234:5678" in line and "WARN" in line for line in lines)
    assert status == 1


def test_an_unaccepted_mode_joystick_outside_the_recorded_slots_is_also_named() -> None:
    """The warning covers every controller the system sees, not only those on
    recorded ports."""

    lines, status = ecs.classify(
        port_devnodes=[],
        joysticks=[ecs.Joystick(devnode="/dev/input/event9", vendor="dead", product="beef")],
        accepted=ACCEPTED,
    )
    assert any("dead:beef" in line and "WARN" in line for line in lines)
    assert status == 1


def test_every_unaccepted_controller_is_named_not_only_the_first() -> None:
    lines, status = ecs.classify(
        port_devnodes=[],
        joysticks=[
            ecs.Joystick(devnode="/dev/input/event3", vendor="1111", product="1111"),
            ecs.Joystick(devnode="/dev/input/event4", vendor="2222", product="2222"),
        ],
        accepted=ACCEPTED,
    )
    assert any("1111:1111" in line for line in lines)
    assert any("2222:2222" in line for line in lines)
    assert status == 1


def test_resolve_port_returns_none_for_an_absent_or_dangling_symlink(tmp_path: Path) -> None:
    dev_input = tmp_path / "dev-input"
    dev_input.mkdir()
    (dev_input / "emubox-p1").symlink_to(dev_input / "event3")

    assert ecs.resolve_port(1, dev_input=dev_input) is None


def test_resolve_port_follows_the_stable_symlink_to_its_event_device(tmp_path: Path) -> None:
    dev_input = tmp_path / "dev-input"
    dev_input.mkdir()
    target = dev_input / "event3"
    target.write_text("")
    (dev_input / "emubox-p1").symlink_to(target)

    assert ecs.resolve_port(1, dev_input=dev_input) == str(target)


def test_discover_joysticks_reads_identity_from_the_input_device_not_udev(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Vendor and product come from the input device's own struct input_id
    in sysfs - never from a udev property - which is what lets a uinput
    device with no USB parent still carry an identity."""

    sys_class_input = tmp_path / "sys-class-input"
    event_dir = sys_class_input / "event3" / "device" / "id"
    event_dir.mkdir(parents=True)
    (event_dir / "vendor").write_text("045E\n")
    (event_dir / "product").write_text("028E\n")

    queried: list[tuple[str, str]] = []

    def fake_check_output(command: list[str], *, text: bool) -> str:
        assert text
        name = command[command.index("-n") + 1]
        prop = next(
            part.removeprefix("--property=") for part in command if part.startswith("--property=")
        )
        queried.append((name, prop))
        return "1\n"

    monkeypatch.setattr(ecs.subprocess, "check_output", fake_check_output)

    joysticks = ecs.discover_joysticks(sys_class_input=sys_class_input)

    assert joysticks == [ecs.Joystick(devnode="/dev/input/event3", vendor="045e", product="028e")]
    assert queried == [("/dev/input/event3", "ID_INPUT_JOYSTICK")]


def test_discover_joysticks_skips_a_device_udev_does_not_mark_as_a_joystick(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    sys_class_input = tmp_path / "sys-class-input"
    event_dir = sys_class_input / "event7" / "device" / "id"
    event_dir.mkdir(parents=True)
    (event_dir / "vendor").write_text("dead\n")
    (event_dir / "product").write_text("beef\n")

    monkeypatch.setattr(ecs.subprocess, "check_output", lambda *_a, **_k: "\n")

    assert ecs.discover_joysticks(sys_class_input=sys_class_input) == []


def test_main_reports_and_exits_the_worst_status(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(ecs, "resolve_port", lambda index, **_k: None)
    monkeypatch.setattr(
        ecs,
        "discover_joysticks",
        lambda **_k: [ecs.Joystick(devnode="/dev/input/event3", vendor="1234", product="5678")],
    )

    exit_status = ecs.main(["--ports", "1", "--accepted", "045e:028e"])

    output = capsys.readouterr().out
    assert exit_status == 1
    assert "port 1: unoccupied" in output
    assert "1234:5678" in output


def test_an_unexpected_failure_exits_outside_the_status_alphabet_and_says_why(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Exit 1 would read as a warning with nothing under it; 3 is outside
    0-2, so the aggregator reports this section as not having run, and the
    error reaches its stderr for the administrator reading that section."""

    def explode(**_kwargs: object) -> list[ecs.Joystick]:
        raise FileNotFoundError("udevadm")

    monkeypatch.setattr(ecs, "discover_joysticks", explode)

    exit_status = ecs.main(["--ports", "0"])

    captured = capsys.readouterr()
    assert exit_status == 3
    assert "FileNotFoundError" in captured.err
    assert "udevadm" in captured.err
