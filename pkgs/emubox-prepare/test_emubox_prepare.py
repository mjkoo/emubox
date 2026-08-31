"""Tests for the three editors, the invocation contract and custom systems.

Everything runs against temporary files: the editors' whole promise is
"assert the keys the flake owns and touch nothing else", which is a property
of one function against a file, not something a VM boot can show.

The "no write when nothing changed" cases stamp the file's mtime to 0 before
calling and assert it is still 0 afterwards, so a rewrite that happens to
produce identical bytes is still a failure.
"""

import base64
import contextlib
import hashlib
import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET
from collections.abc import Iterator
from pathlib import Path

import pytest
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

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


def test_esde_corrects_an_owned_key_stored_under_the_wrong_type(
    tmp_path: Path,
) -> None:
    # The flake owns the element type as well as the value, so a key whose
    # value already matches but whose type drifted is still put right - ES-DE
    # reads `<bool>` and `<string>` into different maps.
    path = tmp_path / "es_settings.xml"
    path.write_text(
        '<?xml version="1.0"?>\n<string name="ShowQuitMenu" value="true" />\n'
    )

    assert ep.set_esde_settings(path, OWNED) is True

    assert esde_named(path, "ShowQuitMenu") == ("bool", "ShowQuitMenu", "true")


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


def test_ini_recreates_a_file_with_a_line_that_is_not_a_setting(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # Readable text, so this reaches the syntax check rather than the decode
    # failure the case above reaches: a line that is neither blank, comment,
    # section header nor assignment means the file is not this format.
    path = tmp_path / "Dolphin.ini"
    path.write_text("[Interface]\nConfirmStop = False\nthis line has no assignment\n")

    assert ep.set_ini_settings(path, INI_OWNED) is True

    text = path.read_text()
    assert "this line has no assignment" not in text
    assert "ConfirmStop = False" in text
    assert "Fullscreen = True" in text
    assert "not a setting" in capsys.readouterr().err


def test_ini_appends_a_key_before_a_trailing_comment(tmp_path: Path) -> None:
    # A new key goes after the section's last setting rather than at the end
    # of its block, so a comment written under the last setting keeps sitting
    # under it instead of being pushed away from what it annotates.
    path = tmp_path / "Dolphin.ini"
    path.write_text(
        "[Interface]\nConfirmStop = False\n[Display]\nRenderToMain = True\n; about the display\n"
    )

    assert ep.set_ini_settings(path, INI_OWNED) is True

    lines = path.read_text().splitlines()
    assert lines[-3:] == [
        "RenderToMain = True",
        "Fullscreen = True",
        "; about the display",
    ]


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
        json.dumps(
            {
                "files": {
                    "settings/es_settings.xml": {"format": "esde-xml", "keys": OWNED}
                },
                "retroachievements": None,
            }
        )
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


# --- Robustness of the write path -----------------------------------------
# Every case below was found by a review that reproduced it against the code;
# each test is the reproduction, kept so the fix cannot regress silently.


def test_write_keeps_an_existing_files_mode(tmp_path: Path) -> None:
    # os.replace installs a new inode, so without carrying the old file's
    # mode across, a run by an admin would leave the frontend unable to save.
    path = tmp_path / "es_settings.xml"
    assert ep.set_esde_settings(path, OWNED) is True
    path.chmod(0o600)

    drifted = {**OWNED, "UIMode": {"type": "string", "value": "full"}}
    assert ep.set_esde_settings(path, drifted) is True

    assert path.stat().st_mode & 0o777 == 0o600


def test_write_leaves_no_temporary_file_behind(tmp_path: Path) -> None:
    path = tmp_path / "settings" / "es_settings.xml"

    assert ep.set_esde_settings(path, OWNED) is True

    assert [p.name for p in path.parent.iterdir()] == ["es_settings.xml"]


def test_concurrent_writers_never_publish_a_mixed_document(tmp_path: Path) -> None:
    # The module is on the system path so it can be run by hand; a run by an
    # admin while the session loop relaunches is a supported scenario, and a
    # shared temp name let both processes write one inode.
    path = tmp_path / "es_settings.xml"
    a = {"K": {"type": "string", "value": "a" * 4000}}
    b = {"K": {"type": "string", "value": "b" * 4000}}

    for _ in range(20):
        pids = []
        for keys in (a, b):
            pid = os.fork()
            if pid == 0:  # pragma: no cover - the child never returns
                # The exit code has to carry the failure: a bare
                # `finally: os._exit(0)` makes the parent's check below
                # unconditionally true, which is how this test passed against
                # the very code it exists to reject.
                code = 0
                try:
                    ep.set_esde_settings(path, keys)
                except BaseException:
                    code = 1
                os._exit(code)
            pids.append(pid)
        for pid in pids:
            _, status = os.waitpid(pid, 0)
            assert os.waitstatus_to_exitcode(status) == 0

        value = esde_named(path, "K")[2]
        assert value in (a["K"]["value"], b["K"]["value"]), "mixed document"


def test_esde_recreates_an_empty_file_and_says_so(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # What a power cut leaves behind, which on this box is every switch-off
    # at the wall. It parses to zero elements, so it must not look healthy.
    path = tmp_path / "es_settings.xml"
    path.write_text("")

    assert ep.set_esde_settings(path, OWNED) is True

    got = {name: (tag, value) for tag, name, value in esde_elements(path)}
    assert got == {k: (v["type"], v["value"]) for k, v in OWNED.items()}
    assert "empty" in capsys.readouterr().err


def test_esde_does_not_grow_a_blank_line_on_every_write(tmp_path: Path) -> None:
    path = tmp_path / "es_settings.xml"
    ep.set_esde_settings(path, OWNED)
    sizes = []
    # Equal-length values, so any difference in size is the file growing and
    # not just a shorter setting.
    for value in ("kiosk", "aaaaa", "kiosk", "aaaaa"):
        ep.set_esde_settings(
            path, {**OWNED, "UIMode": {"type": "string", "value": value}}
        )
        sizes.append(len(path.read_text()))

    assert len(set(sizes)) == 1, sizes


# --- Robustness of the INI parser -----------------------------------------


def test_ini_keeps_a_file_whose_section_header_carries_a_comment(
    tmp_path: Path,
) -> None:
    # Legal INI that configparser and Qt both accept. Rejecting it would send
    # the whole file through the recreate path and lose every unowned key.
    path = tmp_path / "Dolphin.ini"
    path.write_text(
        "[Interface] ; the interface section\nKeepMe = yes\nConfirmStop = True\n"
    )

    assert ep.set_ini_settings(path, INI_OWNED) is True

    text = path.read_text()
    assert "KeepMe = yes" in text
    assert "[Interface] ; the interface section" in text


def test_ini_keeps_a_value_containing_an_exotic_line_separator(
    tmp_path: Path,
) -> None:
    # str.splitlines() breaks on U+2028 and friends, inventing a fragment
    # that fails the syntax check and takes the whole file with it.
    path = tmp_path / "Dolphin.ini"
    path.write_text("[Interface]\nKeepMe = a b\nConfirmStop = True\n")

    assert ep.set_ini_settings(path, INI_OWNED) is True

    assert "KeepMe = a b" in path.read_text()


# --- Robustness of the custom systems step --------------------------------


def test_custom_systems_replaces_a_target_that_is_not_readable_text(
    tmp_path: Path,
) -> None:
    # Reached through _read_text, so it is "not what we want" and rewritten
    # rather than an exception that ends the session at the greeter.
    source = tmp_path / "es_systems.xml"
    source.write_text("<systemList />")
    target = tmp_path / "custom_systems" / "es_systems.xml"
    target.parent.mkdir()
    target.write_bytes(b"\xff\xfe not text")

    assert ep.install_custom_systems(target, str(source)) is True

    assert target.read_text() == "<systemList />"


def test_custom_systems_removes_a_dangling_symlink(tmp_path: Path) -> None:
    # Path.exists() follows the link and would report nothing to remove,
    # leaving exactly the stale entry this branch exists to clear.
    target = tmp_path / "custom_systems" / "es_systems.xml"
    target.parent.mkdir()
    target.symlink_to(tmp_path / "gone.xml")

    assert ep.install_custom_systems(target, "") is True

    assert not target.is_symlink()


# --- main()'s diagnostics --------------------------------------------------


def test_main_reports_unreadable_owned_values_without_a_traceback(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(tmp_path / "es-de"))
    values = tmp_path / "owned.json"
    values.write_text("{not json")

    assert ep.main([str(values), ""]) == 1

    assert "owned-values JSON" in capsys.readouterr().err


def test_main_reports_an_unknown_format_without_a_traceback(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(tmp_path / "es-de"))
    values = tmp_path / "owned.json"
    values.write_text(json.dumps({"files": {"f.conf": {"format": "toml", "keys": {}}}}))

    assert ep.main([str(values), ""]) == 1

    assert "unknown format" in capsys.readouterr().err


# --- The owned-values document shape (design D1) --------------------------


def test_main_rejects_a_top_level_value_that_is_not_an_object(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(tmp_path / "es-de"))
    values = tmp_path / "owned.json"
    values.write_text(json.dumps([]))

    assert ep.main([str(values), ""]) == 1

    assert "object" in capsys.readouterr().err


def test_main_rejects_owned_values_missing_files(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(tmp_path / "es-de"))
    values = tmp_path / "owned.json"
    values.write_text(json.dumps({"retroachievements": None}))

    assert ep.main([str(values), ""]) == 1

    assert "files" in capsys.readouterr().err


def test_main_rejects_files_that_is_not_an_object(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(tmp_path / "es-de"))
    values = tmp_path / "owned.json"
    values.write_text(json.dumps({"files": [], "retroachievements": None}))

    assert ep.main([str(values), ""]) == 1

    assert "files" in capsys.readouterr().err


def test_main_rejects_retroachievements_that_is_not_an_object_or_null(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(tmp_path / "es-de"))
    values = tmp_path / "owned.json"
    values.write_text(json.dumps({"files": {}, "retroachievements": "enabled"}))

    assert ep.main([str(values), ""]) == 1

    assert "retroachievements" in capsys.readouterr().err


def test_main_treats_an_absent_retroachievements_key_as_null(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # design D1: missing is equivalent to null, not an error.
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(tmp_path / "es-de"))
    values = tmp_path / "owned.json"
    values.write_text(json.dumps({"files": {}}))

    assert ep.main([str(values), ""]) == 0


def test_main_accepts_a_valid_non_null_retroachievements_object(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Group 1's review flagged the missing positive case: a well-formed,
    # non-null retroachievements namespace is not itself an error, even
    # before this group taught main() to act on it.
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(tmp_path / "es-de"))
    username_file = tmp_path / "username"
    password_file = tmp_path / "password"
    username_file.write_text("alice\n")
    password_file.write_text("hunter2\n")
    values = tmp_path / "owned.json"
    values.write_text(
        json.dumps(
            {
                "files": {},
                "retroachievements": {
                    "api_url": "http://127.0.0.1:1/dorequest.php",
                    "username_file": str(username_file),
                    "password_file": str(password_file),
                    "cache_file": str(tmp_path / "cache" / "ra-token"),
                    "hardcore": False,
                    "targets": [],
                },
            }
        )
    )

    assert ep.main([str(values), ""]) == 0


# --- RetroAchievements: login2 and the token cache (design D2) ------------
#
# A real http.server.HTTPServer on 127.0.0.1:0 in a thread, never a
# monkeypatched urllib, so the timeout, the POST body and the status
# handling in _login2 are all genuinely exercised.


class _QuietHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        pass  # A passing test should print nothing; failures show the assert.


def _json_handler(
    status: int, payload: object
) -> type[http.server.BaseHTTPRequestHandler]:
    body = json.dumps(payload).encode()

    class Handler(_QuietHandler):
        def do_POST(self) -> None:
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


def _status_handler(status: int) -> type[http.server.BaseHTTPRequestHandler]:
    class Handler(_QuietHandler):
        def do_POST(self) -> None:
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.send_response(status)
            self.end_headers()

    return Handler


def _body_handler(status: int, body: bytes) -> type[http.server.BaseHTTPRequestHandler]:
    class Handler(_QuietHandler):
        def do_POST(self) -> None:
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


def _sleepy_handler(delay: float) -> type[http.server.BaseHTTPRequestHandler]:
    class Handler(_QuietHandler):
        def do_POST(self) -> None:
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            time.sleep(delay)
            self.send_response(200)
            self.end_headers()

    return Handler


@contextlib.contextmanager
def ra_server(handler_class: type[http.server.BaseHTTPRequestHandler]) -> Iterator[str]:
    """A throwaway HTTP server, yielding the login2 URL to point prepare at."""
    server = http.server.HTTPServer(("127.0.0.1", 0), handler_class)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/dorequest.php"
    finally:
        server.shutdown()
        thread.join()


def closed_port_url() -> str:
    """A URL nothing listens on, for the connection-refused branch.

    Bind then immediately close: for the short life of one test the OS will
    not hand this port back out to another process, so a connection to it
    is reliably refused rather than merely usually refused.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return f"http://127.0.0.1:{port}/dorequest.php"


def test_login2_reports_success_with_the_token() -> None:
    with ra_server(_json_handler(200, {"Success": True, "Token": "tok-123"})) as url:
        outcome = ep._login2(url, "alice", "hunter2", timeout=5.0)

    assert outcome == ("success", "tok-123")


def test_login2_reports_rejected_on_explicit_failure() -> None:
    with ra_server(_json_handler(200, {"Success": False, "Error": "bad creds"})) as url:
        outcome = ep._login2(url, "alice", "wrong", timeout=5.0)

    assert outcome == ("rejected", None)


@pytest.mark.parametrize("status", [401, 403])
def test_login2_reports_rejected_on_401_and_403(status: int) -> None:
    with ra_server(_status_handler(status)) as url:
        outcome = ep._login2(url, "alice", "wrong", timeout=5.0)

    assert outcome == ("rejected", None)


def test_login2_reports_unreachable_on_a_server_error() -> None:
    with ra_server(_status_handler(500)) as url:
        outcome = ep._login2(url, "alice", "hunter2", timeout=5.0)

    assert outcome == ("unreachable", None)


def test_login2_reports_unreachable_on_a_body_that_is_not_json() -> None:
    with ra_server(_body_handler(200, b"not json at all")) as url:
        outcome = ep._login2(url, "alice", "hunter2", timeout=5.0)

    assert outcome == ("unreachable", None)


def test_login2_reports_unreachable_on_connection_refused() -> None:
    outcome = ep._login2(closed_port_url(), "alice", "hunter2", timeout=5.0)

    assert outcome == ("unreachable", None)


def test_login2_reports_unreachable_on_a_timeout() -> None:
    # A short configured timeout against a handler that sleeps past it, so
    # the real timeout path is exercised without the suite paying 5 seconds.
    with ra_server(_sleepy_handler(0.5)) as url:
        outcome = ep._login2(url, "alice", "hunter2", timeout=0.05)

    assert outcome == ("unreachable", None)


def test_login2_posts_the_documented_form_fields() -> None:
    received: dict[str, list[str]] = {}

    class Handler(_QuietHandler):
        def do_POST(self) -> None:
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            received.update(urllib.parse.parse_qs(body.decode()))
            payload = json.dumps({"Success": True, "Token": "tok"}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    with ra_server(Handler) as url:
        ep._login2(url, "alice", "hunter2", timeout=5.0)

    assert received == {"r": ["login2"], "u": ["alice"], "p": ["hunter2"]}


def ra_namespace(
    tmp_path: Path, api_url: str, *, cache: str | None = None
) -> tuple[dict[str, object], Path]:
    username_file = tmp_path / "username"
    password_file = tmp_path / "password"
    username_file.write_text("alice\n")
    password_file.write_text("hunter2\n")
    cache_file = tmp_path / "cache" / "ra-token"
    if cache is not None:
        cache_file.parent.mkdir(parents=True, exist_ok=True)
        cache_file.write_text(cache)
    ra: dict[str, object] = {
        "api_url": api_url,
        "username_file": str(username_file),
        "password_file": str(password_file),
        "cache_file": str(cache_file),
        "hardcore": False,
        "targets": [],
    }
    return ra, cache_file


def test_resolve_token_writes_the_cache_mode_0600_on_success(tmp_path: Path) -> None:
    with ra_server(_json_handler(200, {"Success": True, "Token": "tok-123"})) as url:
        ra, cache_file = ra_namespace(tmp_path, url)
        result = ep.resolve_retroachievements_token(ra, tmp_path, timeout=5.0)

    assert result == ("alice", "tok-123")
    assert cache_file.read_text() == "tok-123"
    assert cache_file.stat().st_mode & 0o777 == 0o600


def test_resolve_token_forces_cache_mode_even_if_it_pre_existed(tmp_path: Path) -> None:
    # _write carries a pre-existing file's mode across so an admin's edits
    # survive, but the cache is a credential: its mode is always forced.
    with ra_server(_json_handler(200, {"Success": True, "Token": "new-token"})) as url:
        ra, cache_file = ra_namespace(tmp_path, url, cache="old-token")
        cache_file.chmod(0o644)

        result = ep.resolve_retroachievements_token(ra, tmp_path, timeout=5.0)

    assert result == ("alice", "new-token")
    assert cache_file.read_text() == "new-token"
    assert cache_file.stat().st_mode & 0o777 == 0o600


def test_resolve_token_drops_the_cache_when_credentials_are_rejected(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    with ra_server(_json_handler(200, {"Success": False})) as url:
        ra, cache_file = ra_namespace(tmp_path, url, cache="stale-token")

        result = ep.resolve_retroachievements_token(ra, tmp_path, timeout=5.0)

    assert result is None
    assert not cache_file.exists()
    assert "rejected" in capsys.readouterr().err


def test_resolve_token_falls_back_to_the_cache_when_unreachable(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    ra, cache_file = ra_namespace(tmp_path, closed_port_url(), cache="cached-token")

    result = ep.resolve_retroachievements_token(ra, tmp_path, timeout=5.0)

    assert result == ("alice", "cached-token")
    assert capsys.readouterr().err.strip()


def test_resolve_token_continues_with_no_token_when_unreachable_and_no_cache(
    tmp_path: Path,
) -> None:
    ra, cache_file = ra_namespace(tmp_path, closed_port_url())

    result = ep.resolve_retroachievements_token(ra, tmp_path, timeout=5.0)

    assert result is None
    assert not cache_file.exists()


def test_resolve_token_falls_back_to_the_cache_on_a_timeout(tmp_path: Path) -> None:
    with ra_server(_sleepy_handler(0.5)) as url:
        ra, cache_file = ra_namespace(tmp_path, url, cache="cached-token")

        result = ep.resolve_retroachievements_token(ra, tmp_path, timeout=0.05)

    assert result == ("alice", "cached-token")


def test_resolve_token_skips_login_when_a_credential_file_is_unreadable(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # The server would answer Success if it were ever contacted, so a None
    # result here proves the missing password file short-circuited the
    # login rather than merely that the network happened to fail.
    with ra_server(
        _json_handler(200, {"Success": True, "Token": "should-not-be-used"})
    ) as url:
        ra, cache_file = ra_namespace(tmp_path, url)
        (tmp_path / "password").unlink()

        result = ep.resolve_retroachievements_token(ra, tmp_path, timeout=5.0)

    assert result is None
    assert "password" in capsys.readouterr().err


def test_resolve_token_never_leaks_the_password(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    with ra_server(_json_handler(200, {"Success": True, "Token": "tok-123"})) as url:
        ra, cache_file = ra_namespace(tmp_path, url)
        result = ep.resolve_retroachievements_token(ra, tmp_path, timeout=5.0)

    assert result is not None
    assert "hunter2" not in cache_file.read_text()
    assert "hunter2" not in capsys.readouterr().err


# --- DuckStation's encrypted token (design D3) -----------------------------


def _independent_duckstation_decrypt(
    machine_id: bytes, username: str, ciphertext_b64: str
) -> str:
    """Decrypt a duckstation token without calling any of ep's own functions.

    Re-derives the key and IV by design D3's steps directly - SHA-256 seed,
    100 further rounds, key/IV split from the digest - rather than reusing
    ep._duckstation_key_iv, so a bug shared between encrypt and decrypt
    would not cancel out and hide behind a green round-trip test.
    """
    digest = hashlib.sha256(machine_id + username.encode()).digest()
    for _ in range(100):
        digest = hashlib.sha256(digest).digest()
    key, iv = digest[:16], digest[16:32]
    ciphertext = base64.b64decode(ciphertext_b64)
    decryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    plaintext = decryptor.update(ciphertext) + decryptor.finalize()
    return plaintext.rstrip(b"\x00").decode()


def test_duckstation_token_round_trips_through_an_independent_decrypt() -> None:
    machine_id = b"machine-id-bytes-for-the-round-trip-test\n"
    username = "player_one"
    token = "sess-token-0123456789abcdef"

    encrypted = ep.encrypt_duckstation_token(machine_id, username, token)

    assert _independent_duckstation_decrypt(machine_id, username, encrypted) == token


def test_duckstation_token_matches_a_pinned_fixed_vector() -> None:
    # Computed once from the implementation, then checked step by step
    # against design D3's description - SHA-256 seed over machine id plus
    # username, 100 FURTHER rounds over that seed (101 SHA-256 calls in
    # total), key = digest[0:16], IV = digest[16:32], AES-128-CBC over the
    # zero-padded token, base64 - before being pinned here. Its only job is
    # to catch a silent change to the transform (an off-by-one round, a
    # swapped key/IV split, PKCS#7 instead of zero padding) that a
    # round-trip test alone would miss, because a self-consistent bug on
    # both sides of encrypt/decrypt still round-trips.
    machine_id = b"11111111111111111111111111111111\n"
    username = "testuser"
    token = "abcdef0123456789abcdef0123456789"

    encrypted = ep.encrypt_duckstation_token(machine_id, username, token)

    assert encrypted == "vs/l4/P2mg4aPqlzx+sppCBB+HjVOIk3shjxX5F0KHc="


def test_duckstation_login_values_includes_username_and_encrypted_token(
    tmp_path: Path,
) -> None:
    machine_id_file = tmp_path / "machine-id"
    machine_id_file.write_text("abc123\n")
    target = {
        "name": "duckstation",
        "encoding": "duckstation",
        "machine_id_file": str(machine_id_file),
        "keys": {
            "token": {"file": "settings.ini", "section": "Cheevos", "key": "Token"},
        },
    }

    values = ep.duckstation_login_values(tmp_path, target, "alice", "tok-1")

    assert values["username"] == "alice"
    assert values["token"] == ep.encrypt_duckstation_token(
        b"abc123\n", "alice", "tok-1"
    )
    assert "login_timestamp" not in values


def test_duckstation_login_values_writes_login_timestamp_when_the_token_changes(
    tmp_path: Path,
) -> None:
    machine_id_file = tmp_path / "machine-id"
    machine_id_file.write_text("abc123\n")
    ini_path = tmp_path / "settings.ini"
    ini_path.write_text("[Cheevos]\nToken = stale-ciphertext\n")
    target = {
        "name": "duckstation",
        "encoding": "duckstation",
        "machine_id_file": str(machine_id_file),
        "keys": {
            "token": {"file": str(ini_path), "section": "Cheevos", "key": "Token"},
            "login_timestamp": {
                "file": str(ini_path),
                "section": "Cheevos",
                "key": "LoginTimestamp",
            },
        },
    }

    values = ep.duckstation_login_values(tmp_path, target, "alice", "tok-1")

    assert "login_timestamp" in values
    assert values["login_timestamp"].isdigit()


def test_duckstation_login_values_omits_login_timestamp_when_the_token_is_unchanged(
    tmp_path: Path,
) -> None:
    machine_id_file = tmp_path / "machine-id"
    machine_id_file.write_text("abc123\n")
    ini_path = tmp_path / "settings.ini"
    encrypted = ep.encrypt_duckstation_token(b"abc123\n", "alice", "tok-1")
    ini_path.write_text(f"[Cheevos]\nToken = {encrypted}\n")
    target = {
        "name": "duckstation",
        "encoding": "duckstation",
        "machine_id_file": str(machine_id_file),
        "keys": {
            "token": {"file": str(ini_path), "section": "Cheevos", "key": "Token"},
            "login_timestamp": {
                "file": str(ini_path),
                "section": "Cheevos",
                "key": "LoginTimestamp",
            },
        },
    }

    values = ep.duckstation_login_values(tmp_path, target, "alice", "tok-1")

    assert "login_timestamp" not in values


def test_duckstation_login_values_skips_login_when_machine_id_is_unreadable(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    target = {
        "name": "duckstation",
        "encoding": "duckstation",
        "machine_id_file": str(tmp_path / "missing-machine-id"),
        "keys": {
            "token": {"file": "settings.ini", "section": "Cheevos", "key": "Token"}
        },
    }

    values = ep.duckstation_login_values(tmp_path, target, "alice", "tok-1")

    assert values == {}
    assert "missing-machine-id" in capsys.readouterr().err
