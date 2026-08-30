"""Tests for the three editors, the invocation contract and custom systems.

Everything runs against temporary files: the editors' whole promise is
"assert the keys the flake owns and touch nothing else", which is a property
of one function against a file, not something a VM boot can show.

The "no write when nothing changed" cases stamp the file's mtime to 0 before
calling and assert it is still 0 afterwards, so a rewrite that happens to
produce identical bytes is still a failure.
"""

import json
import os
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

import emubox_prepare as ep

# The owned ES-DE keys in the shape the module renders them (design D6).
OWNED = {
    "UIMode": {"type": "string", "value": "kiosk"},
    "UIMode_passkey": {"type": "string", "value": "uuddlrlrba"},
    "ROMDirectory": {"type": "string", "value": "/data/roms"},
    "MediaDirectory": {"type": "string", "value": "/data/media"},
    "Theme": {"type": "string", "value": "linear-es-de"},
    "ApplicationLanguage": {"type": "string", "value": "en_US"},
    "ShowQuitMenu": {"type": "bool", "value": "true"},
}


def esde_elements(path: Path) -> list[tuple[str, str, str]]:
    """The (tag, name, value) triples of a rootless ES-DE settings document."""
    root = ET.fromstring("<r>" + ep.strip_xml_declaration(path.read_text()) + "</r>")
    return [(e.tag, e.attrib["name"], e.attrib["value"]) for e in root]


def esde_named(path: Path, name: str) -> tuple[str, str, str]:
    matches = [e for e in esde_elements(path) if e[1] == name]
    assert len(matches) == 1, f"{name}: {matches}"
    return matches[0]


def freeze(path: Path) -> None:
    os.utime(path, (0, 0))


def unwritten(path: Path) -> bool:
    return path.stat().st_mtime == 0


# --- ES-DE settings XML ---------------------------------------------------


def test_esde_creates_file_with_every_owned_key(tmp_path: Path) -> None:
    path = tmp_path / "es_settings.xml"

    assert ep.set_esde_settings(path, OWNED) is True

    got = {name: (tag, value) for tag, name, value in esde_elements(path)}
    assert got == {k: (v["type"], v["value"]) for k, v in OWNED.items()}


def test_esde_creates_parent_directories(tmp_path: Path) -> None:
    # tmpfiles creates /data/es-de but not settings/ under it, so the editor
    # is what makes the parents on a box's first boot.
    path = tmp_path / "es-de" / "settings" / "es_settings.xml"

    assert ep.set_esde_settings(path, OWNED) is True

    assert path.is_file()
    assert path.parent.stat().st_mode & 0o777 == 0o755


def test_esde_resets_a_drifted_owned_key(tmp_path: Path) -> None:
    path = tmp_path / "es_settings.xml"
    path.write_text(
        '<?xml version="1.0"?>\n'
        '<string name="UIMode" value="full" />\n'
        '<string name="Theme" value="slate-es-de" />\n'
    )

    assert ep.set_esde_settings(path, OWNED) is True

    assert esde_named(path, "UIMode") == ("string", "UIMode", "kiosk")
    assert esde_named(path, "Theme") == ("string", "Theme", "linear-es-de")


def test_esde_appends_a_missing_owned_key(tmp_path: Path) -> None:
    path = tmp_path / "es_settings.xml"
    path.write_text('<?xml version="1.0"?>\n<string name="UIMode" value="kiosk" />\n')

    assert ep.set_esde_settings(path, OWNED) is True

    assert esde_named(path, "ShowQuitMenu") == ("bool", "ShowQuitMenu", "true")


def test_esde_leaves_an_unowned_element_and_its_position_alone(tmp_path: Path) -> None:
    path = tmp_path / "es_settings.xml"
    path.write_text(
        '<?xml version="1.0"?>\n'
        '<bool name="ScreensaverSlideshow" value="false" />\n'
        '<string name="UIMode" value="full" />\n'
        '<int name="MaxVRAM" value="512" />\n'
        '<float name="AudioVolume" value="0.8" />\n'
    )
    before = esde_elements(path)

    assert ep.set_esde_settings(path, OWNED) is True

    after = esde_elements(path)
    # The three unowned elements keep their values and their indices; the
    # owned keys are appended after them.
    assert after[0] == before[0]
    assert after[2] == before[2]
    assert after[3] == before[3]
    assert ("float", "AudioVolume", "0.8") in after


def test_esde_preserves_typed_bool_and_int_elements(tmp_path: Path) -> None:
    path = tmp_path / "es_settings.xml"
    path.write_text(
        '<?xml version="1.0"?>\n'
        '<bool name="ShowQuitMenu" value="false" />\n'
        '<int name="MaxVRAM" value="512" />\n'
    )

    assert ep.set_esde_settings(path, OWNED) is True

    # The owned bool keeps its element type rather than becoming a string,
    # and the unowned int is untouched.
    assert esde_named(path, "ShowQuitMenu") == ("bool", "ShowQuitMenu", "true")
    assert esde_named(path, "MaxVRAM") == ("int", "MaxVRAM", "512")


def test_esde_does_not_write_when_nothing_changed(tmp_path: Path) -> None:
    path = tmp_path / "es_settings.xml"
    assert ep.set_esde_settings(path, OWNED) is True
    freeze(path)

    assert ep.set_esde_settings(path, OWNED) is False

    assert unwritten(path)


def test_esde_recreates_a_document_truncated_mid_element(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # What a frontend killed mid-write leaves behind.
    path = tmp_path / "es_settings.xml"
    path.write_text(
        '<?xml version="1.0"?>\n'
        '<string name="UIMode" value="kiosk" />\n'
        '<string name="Theme" val'
    )

    assert ep.set_esde_settings(path, OWNED) is True

    got = {name: (tag, value) for tag, name, value in esde_elements(path)}
    assert got == {k: (v["type"], v["value"]) for k, v in OWNED.items()}
    assert "es_settings.xml" in capsys.readouterr().err


# --- INI with sections ----------------------------------------------------

INI_OWNED = {"Interface": {"ConfirmStop": "False"}, "Display": {"Fullscreen": "True"}}


def test_ini_preserves_comments_order_and_unknown_keys(tmp_path: Path) -> None:
    path = tmp_path / "Dolphin.ini"
    path.write_text(
        "# written by the emulator\n"
        "[Interface]\n"
        "Language = 0\n"
        "ConfirmStop = True\n"
        "; a trailing comment\n"
        "[Display]\n"
        "Fullscreen = False\n"
        "RenderToMain = True\n"
    )

    assert ep.set_ini_settings(path, INI_OWNED) is True

    lines = path.read_text().splitlines()
    assert lines[0] == "# written by the emulator"
    assert lines[1] == "[Interface]"
    assert lines[2] == "Language = 0"
    assert lines[3] == "ConfirmStop = False"
    assert lines[4] == "; a trailing comment"
    assert lines[-1] == "RenderToMain = True"


def test_ini_sets_the_key_in_the_right_section(tmp_path: Path) -> None:
    # The same key name in two sections: only the owned section's is set.
    path = tmp_path / "Dolphin.ini"
    path.write_text(
        "[Other]\nFullscreen = False\n[Display]\nFullscreen = False\n[Interface]\nConfirmStop = False\n"
    )

    assert ep.set_ini_settings(path, INI_OWNED) is True

    text = path.read_text()
    assert "[Other]\nFullscreen = False\n" in text
    assert "[Display]\nFullscreen = True\n" in text


def test_ini_creates_a_missing_section(tmp_path: Path) -> None:
    path = tmp_path / "Dolphin.ini"
    path.write_text("[Interface]\nConfirmStop = False\n")

    assert ep.set_ini_settings(path, INI_OWNED) is True

    text = path.read_text()
    assert "[Display]" in text
    assert "Fullscreen = True" in text


def test_ini_creates_the_file_when_absent(tmp_path: Path) -> None:
    path = tmp_path / "sub" / "Dolphin.ini"

    assert ep.set_ini_settings(path, INI_OWNED) is True

    text = path.read_text()
    assert "[Interface]" in text and "ConfirmStop = False" in text
    assert "[Display]" in text and "Fullscreen = True" in text


def test_ini_does_not_write_when_nothing_changed(tmp_path: Path) -> None:
    path = tmp_path / "Dolphin.ini"
    assert ep.set_ini_settings(path, INI_OWNED) is True
    freeze(path)

    assert ep.set_ini_settings(path, INI_OWNED) is False

    assert unwritten(path)


def test_ini_recreates_an_unreadable_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "Dolphin.ini"
    path.write_bytes(b"[Interface]\n\xff\xfe not a line of this file's format\n")

    assert ep.set_ini_settings(path, INI_OWNED) is True

    text = path.read_text()
    assert "ConfirmStop = False" in text
    assert "Fullscreen = True" in text
    assert "not a line of this file's format" not in text
    assert "Dolphin.ini" in capsys.readouterr().err


# --- RetroArch flat file --------------------------------------------------

RA_OWNED = {"menu_driver": "ozone", "video_fullscreen": "true"}


def test_retroarch_preserves_comments_order_and_unknown_keys(tmp_path: Path) -> None:
    path = tmp_path / "retroarch.cfg"
    path.write_text(
        "# RetroArch config\n"
        'menu_driver = "rgui"\n'
        'input_driver = "sdl"\n'
        'video_fullscreen = "false"\n'
    )

    assert ep.set_retroarch_settings(path, RA_OWNED) is True

    lines = path.read_text().splitlines()
    assert lines[0] == "# RetroArch config"
    assert lines[1] == 'menu_driver = "ozone"'
    assert lines[2] == 'input_driver = "sdl"'
    assert lines[3] == 'video_fullscreen = "true"'


def test_retroarch_appends_a_missing_key(tmp_path: Path) -> None:
    path = tmp_path / "retroarch.cfg"
    path.write_text('menu_driver = "ozone"\n')

    assert ep.set_retroarch_settings(path, RA_OWNED) is True

    assert 'video_fullscreen = "true"' in path.read_text()


def test_retroarch_creates_the_file_when_absent(tmp_path: Path) -> None:
    path = tmp_path / "sub" / "retroarch.cfg"

    assert ep.set_retroarch_settings(path, RA_OWNED) is True

    text = path.read_text()
    assert 'menu_driver = "ozone"' in text
    assert 'video_fullscreen = "true"' in text


def test_retroarch_does_not_write_when_nothing_changed(tmp_path: Path) -> None:
    path = tmp_path / "retroarch.cfg"
    assert ep.set_retroarch_settings(path, RA_OWNED) is True
    freeze(path)

    assert ep.set_retroarch_settings(path, RA_OWNED) is False

    assert unwritten(path)


def test_retroarch_recreates_an_unreadable_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "retroarch.cfg"
    path.write_bytes(b'menu_driver = "ozone"\n\xff\xfe a line with no assignment\n')

    assert ep.set_retroarch_settings(path, RA_OWNED) is True

    text = path.read_text()
    assert 'menu_driver = "ozone"' in text
    assert 'video_fullscreen = "true"' in text
    assert "no assignment" not in text
    assert "retroarch.cfg" in capsys.readouterr().err


# --- The custom systems step ----------------------------------------------


def test_custom_systems_copies_into_a_directory_that_does_not_exist(
    tmp_path: Path,
) -> None:
    source = tmp_path / "es_systems.xml"
    source.write_text("<systemList><system><name>nes</name></system></systemList>")
    target = tmp_path / "appdata" / "custom_systems" / "es_systems.xml"

    assert ep.install_custom_systems(target, str(source)) is True

    assert target.read_text() == source.read_text()
    assert target.parent.stat().st_mode & 0o777 == 0o755


def test_custom_systems_copies_on_difference(tmp_path: Path) -> None:
    source = tmp_path / "es_systems.xml"
    source.write_text("<systemList><system><name>snes</name></system></systemList>")
    target = tmp_path / "custom_systems" / "es_systems.xml"
    target.parent.mkdir()
    target.write_text("<systemList />")

    assert ep.install_custom_systems(target, str(source)) is True

    assert target.read_text() == source.read_text()


def test_custom_systems_is_a_no_op_when_equal(tmp_path: Path) -> None:
    source = tmp_path / "es_systems.xml"
    source.write_text("<systemList />")
    target = tmp_path / "custom_systems" / "es_systems.xml"
    target.parent.mkdir()
    target.write_text("<systemList />")
    freeze(target)

    assert ep.install_custom_systems(target, str(source)) is False

    assert unwritten(target)


def test_custom_systems_removes_the_file_when_the_argument_is_empty(
    tmp_path: Path,
) -> None:
    target = tmp_path / "custom_systems" / "es_systems.xml"
    target.parent.mkdir()
    target.write_text("<systemList />")

    assert ep.install_custom_systems(target, "") is True

    assert not target.exists()


def test_custom_systems_empty_argument_with_no_file_is_not_an_error(
    tmp_path: Path,
) -> None:
    # Every launch of the frontend on the box as shipped takes this branch.
    target = tmp_path / "custom_systems" / "es_systems.xml"

    assert ep.install_custom_systems(target, "") is False

    assert not target.exists()


# --- The invocation contract ----------------------------------------------


def owned_values_file(tmp_path: Path) -> Path:
    path = tmp_path / "owned.json"
    path.write_text(
        json.dumps({"settings/es_settings.xml": {"format": "esde-xml", "keys": OWNED}})
    )
    return path


def test_main_writes_the_settings_file_under_the_appdata_directory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    appdata = tmp_path / "es-de"
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(appdata))

    assert ep.main([str(owned_values_file(tmp_path)), ""]) == 0

    got = {
        name: (tag, value)
        for tag, name, value in esde_elements(appdata / "settings" / "es_settings.xml")
    }
    assert got == {k: (v["type"], v["value"]) for k, v in OWNED.items()}


@pytest.mark.parametrize("value", [None, ""])
def test_main_fails_loudly_without_the_appdata_directory(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    value: str | None,
) -> None:
    # A broken call site, not a broken configuration: the recreate policy
    # does not cover it, and the session ending at the greeter is the point.
    if value is None:
        monkeypatch.delenv("ESDE_APPDATA_DIR", raising=False)
    else:
        monkeypatch.setenv("ESDE_APPDATA_DIR", value)
    values = str(owned_values_file(tmp_path))
    before = sorted(p.name for p in tmp_path.iterdir())

    assert ep.main([values, ""]) != 0

    assert "ESDE_APPDATA_DIR" in capsys.readouterr().err
    assert sorted(p.name for p in tmp_path.iterdir()) == before


def test_main_installs_and_then_removes_the_custom_systems_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    appdata = tmp_path / "es-de"
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(appdata))
    source = tmp_path / "stub.xml"
    source.write_text("<systemList><system><name>nes</name></system></systemList>")
    target = appdata / "custom_systems" / "es_systems.xml"
    values = str(owned_values_file(tmp_path))

    assert ep.main([values, str(source)]) == 0
    assert target.read_text() == source.read_text()

    assert ep.main([values, ""]) == 0
    assert not target.exists()


def test_main_requires_exactly_two_positional_arguments(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(tmp_path / "es-de"))

    assert ep.main([str(owned_values_file(tmp_path))]) != 0

    assert capsys.readouterr().err.strip()


def test_the_script_runs_as_a_program(tmp_path: Path) -> None:
    # The session and the test driver invoke it as `emubox-prepare <json> ""`,
    # so the module has to work as a script, not only as an import.
    appdata = tmp_path / "es-de"
    result = subprocess.run(
        [sys.executable, str(Path(ep.__file__)), str(owned_values_file(tmp_path)), ""],
        env={**os.environ, "ESDE_APPDATA_DIR": str(appdata)},
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert (appdata / "settings" / "es_settings.xml").is_file()
