"""Tests for the three editors, the invocation contract and custom systems.

Everything runs against temporary files: the editors' whole promise is
"assert the keys the flake owns and touch nothing else", which is a property
of one function against a file, not something a VM boot can show.

The "no write when nothing changed" cases stamp the file's mtime to 0 before
calling and assert it is still 0 afterwards, so a rewrite that happens to
produce identical bytes is still a failure.
"""

import ast
import base64
import builtins
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
from typing import Any, cast

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


def test_ini_appends_a_key_into_a_section_ending_in_a_comment(
    tmp_path: Path,
) -> None:
    # A section whose last line is a comment is the shape that used to decide
    # where a seeded key went: it was inserted after the section's last
    # assignment so the comment kept sitting under what it annotated. Where
    # the key lands within its section is not something an emulator can
    # observe, so it is not promised; what is promised is that the key is
    # under its own section, that the comment is still in the file, and that
    # no setting has moved to another section.
    path = tmp_path / "Dolphin.ini"
    path.write_text(
        "[Interface]\nConfirmStop = False\n[Display]\nRenderToMain = True\n; about the display\n"
    )

    assert ep.set_ini_settings(path, INI_OWNED) is True

    text = path.read_text()
    assert "; about the display" in text
    display = text.split("[Display]\n", 1)[1]
    assert "Fullscreen = True" in display
    assert "RenderToMain = True" in display
    assert "ConfirmStop = False" in text.split("[Display]\n", 1)[0]


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


def test_ini_an_empty_file_owning_only_a_removal_writes_and_notes_nothing(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # The "is empty; recreating it" note used to fire here unconditionally,
    # even though the very next line ("every owned key in this file is a
    # removal...") already meant no write would follow it. secrets.ini
    # before any token has ever resolved, or every target's login keys
    # once RetroAchievements is switched off, are real, reachable shapes
    # for this, not a hypothetical - and both would have logged a lie on
    # every single launch, forever.
    path = tmp_path / "secrets.ini"
    path.write_text("")
    freeze(path)

    assert ep.set_ini_settings(path, {"Achievements": {"Token": ep.REMOVE}}) is False

    assert unwritten(path)
    assert capsys.readouterr().err == ""


def test_ini_an_empty_file_owning_a_real_value_still_notes_the_recreation(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # The other half of that fix: deferring the note to `set_ini_settings`
    # must not silence it when a write genuinely does follow.
    path = tmp_path / "settings.ini"
    path.write_text("")

    assert (
        ep.set_ini_settings(
            path, {"Achievements": {"Enabled": "true", "Token": ep.REMOVE}}
        )
        is True
    )

    assert "Enabled = true" in path.read_text()
    assert "is empty; recreating it" in capsys.readouterr().err


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


def test_main_survives_a_custom_systems_file_it_cannot_write(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # The custom systems step reaches the disk through the same `_write` the
    # editors do, so it meets the same runtime conditions: /data full, or
    # remounted read-only after a power cut, which is what btrfs does on
    # ENOSPC. The editor loop above it has carried a guard for exactly that
    # since a credential removal proved it reachable; this call had none, so
    # an OSError here ended the session at the greeter under the session
    # script's `set -e`.
    #
    # Only live once the box actually ships a custom systems document: with
    # an empty source this takes the removal branch and never writes at all,
    # which is why nothing caught it earlier.
    #
    # The read-only directory stands in for the read-only /data: nix runs
    # this suite as an unprivileged user, so the mode is enforced.
    appdata = tmp_path / "es-de"
    (appdata / "settings").mkdir(parents=True)
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(appdata))
    locked = appdata / "custom_systems"
    locked.mkdir()
    locked.chmod(0o500)
    source = tmp_path / "es_systems.xml"
    source.write_text("<systemList />")
    values = tmp_path / "owned.json"
    values.write_text(
        json.dumps(
            {
                "files": {
                    "settings/es_settings.xml": {
                        "format": "esde-xml",
                        "keys": {"Theme": {"type": "string", "value": "slate"}},
                    }
                },
                "retroachievements": None,
            }
        )
    )

    try:
        assert ep.main([str(values), str(source)]) == 0
    finally:
        locked.chmod(0o700)

    err = capsys.readouterr().err
    assert "custom systems" in err
    assert "Traceback" not in err
    # The step that could run still ran: one unwritable file costs that
    # file, not the family's evening at the greeter.
    assert "slate" in (appdata / "settings" / "es_settings.xml").read_text()


def test_install_custom_systems_still_raises_on_a_target_it_cannot_replace(
    tmp_path: Path,
) -> None:
    # The counterpart to the guard in `main`: the function itself keeps
    # raising, so the two callers that are not the session - a test, or an
    # admin driving it by hand - still see the failure rather than a return
    # value that says "no change" and means "could not write".
    source = tmp_path / "es_systems.xml"
    source.write_text("<systemList />")
    locked = tmp_path / "custom_systems"
    locked.mkdir()
    target = locked / "es_systems.xml"
    locked.chmod(0o500)

    try:
        with pytest.raises(OSError):
            ep.install_custom_systems(target, str(source))
    finally:
        locked.chmod(0o700)


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
    # The positive case, which is the easy one to leave out: a well-formed,
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


def test_main_rejects_keys_that_is_not_an_object(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # `keys` was checked for being present but never for being an object, so
    # a list walked straight into the editor and died there with
    # `AttributeError: 'list' object has no attribute 'values'` - outside
    # the editor loop's `except OSError`, so it reached the top as a
    # traceback. The session ends at the greeter either way; what this is
    # about is the module docstring's promise that an admin reading
    # `journalctl` gets a line rather than a stack trace.
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(tmp_path / "es-de"))
    values = tmp_path / "owned.json"
    values.write_text(json.dumps({"files": {"f.ini": {"format": "ini", "keys": []}}}))

    assert ep.main([str(values), ""]) == 1

    err = capsys.readouterr().err
    assert "keys" in err
    assert "Traceback" not in err


def test_main_rejects_an_ini_section_table_that_is_not_an_object(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # One level in from the check above, and the same failure: the INI
    # editor iterates a section's own table, so a section holding anything
    # but an object is another AttributeError past the OSError guard.
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(tmp_path / "es-de"))
    values = tmp_path / "owned.json"
    values.write_text(
        json.dumps({"files": {"f.ini": {"format": "ini", "keys": {"Main": "on"}}}})
    )

    assert ep.main([str(values), ""]) == 1

    err = capsys.readouterr().err
    assert "Main" in err
    assert "Traceback" not in err


def test_main_rejects_an_esde_value_that_is_not_a_string(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # ES-DE values reach `ET.Element.set`, which stores whatever it is given
    # and lets `ET.tostring` raise `TypeError: cannot serialize 5` much
    # later - past the editor loop's OSError guard, so a traceback. The Nix
    # side types `ownedFiles.<file>.keys` as `attrsOf anything`, so a module
    # written later that says `value = true` or `value = 5` finds this out
    # here rather than on a box.
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(tmp_path / "es-de"))
    values = tmp_path / "owned.json"
    values.write_text(
        json.dumps(
            {
                "files": {
                    "settings/es_settings.xml": {
                        "format": "esde-xml",
                        "keys": {"MaxVRAM": {"type": "int", "value": 5}},
                    }
                }
            }
        )
    )

    assert ep.main([str(values), ""]) == 1

    err = capsys.readouterr().err
    assert "MaxVRAM" in err
    assert "Traceback" not in err


def test_main_rejects_an_esde_key_that_is_not_a_typed_object(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # The same hole one level out: the editor subscripts the spec for
    # `type` and `value`, so a bare string there is a TypeError rather than
    # a journal line.
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(tmp_path / "es-de"))
    values = tmp_path / "owned.json"
    values.write_text(
        json.dumps(
            {
                "files": {
                    "settings/es_settings.xml": {
                        "format": "esde-xml",
                        "keys": {"Theme": "slate"},
                    }
                }
            }
        )
    )

    assert ep.main([str(values), ""]) == 1

    err = capsys.readouterr().err
    assert "Theme" in err
    assert "Traceback" not in err


# --- RetroAchievements: login2 and the token cache (design D2) ------------
#
# A real http.server.HTTPServer on 127.0.0.1:0 in a thread, never a
# monkeypatched urllib, so the timeout, the POST body and the status
# handling in _login2 are all genuinely exercised.


class _QuietHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        pass  # A passing test should print nothing; failures show the assert.


class _QuietErrors:
    """Swallow socketserver's traceback when a client walks away early.

    Several tests below prove exactly that: the login gives up on a body
    the server is still writing, so the write fails with EPIPE and
    socketserver prints a traceback that means nothing but noise here.
    """

    def handle_error(self, request: object, client_address: object) -> None:
        pass


class _QuietHTTPServer(_QuietErrors, http.server.HTTPServer):
    pass


class _QuietThreadingHTTPServer(_QuietErrors, http.server.ThreadingHTTPServer):
    pass


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


def _counting_handler(
    requests: list[str],
) -> type[http.server.BaseHTTPRequestHandler]:
    """A successful login that records every request it is handed.

    For the requirements that are negative - "no login SHALL be attempted"
    when the feature is off - which a closed port cannot prove: a login
    that fails against a closed port leaves the same visible state behind
    as a login that never happened. Only a listener that answers, and says
    afterwards whether it was ever asked, can tell those two apart.
    """
    body = json.dumps({"Success": True, "Token": "tok-live"}).encode()

    class Handler(_QuietHandler):
        def do_POST(self) -> None:
            requests.append(self.path)
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


def _sleepy_handler(delay: float) -> type[http.server.BaseHTTPRequestHandler]:
    """A successful login that arrives late.

    The body is the point. With none - a bare `send_response(200)` and
    `end_headers()`, which is what this handler used to do - the client
    reaches `json.loads(b"")`, and that is itself the "unreachable"
    outcome, so every test asserting a timeout passed whether or not the
    timeout fired: deleting `timeout=timeout` from the urlopen call left
    the whole suite green. With a valid success body the only route to
    "unreachable" is the deadline actually firing.
    """
    body = json.dumps({"Success": True, "Token": "slow-tok"}).encode()

    class Handler(_QuietHandler):
        def do_POST(self) -> None:
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            time.sleep(delay)
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


def _dribbling_handler(
    duration: float, chunks: int = 40
) -> type[http.server.BaseHTTPRequestHandler]:
    """A successful login trickled out one byte at a time over `duration`.

    The case a per-socket timeout cannot catch: every individual gap is
    far inside the configured timeout, so the socket deadline is reset on
    every byte and never fires, however long the whole response takes.
    Only a wall-clock bound around the entire call ends this.
    """
    body = json.dumps({"Success": True, "Token": "dribble-tok"}).encode()
    body = body.ljust(chunks, b" ")  # trailing spaces still parse as JSON
    gap = duration / len(body)

    class Handler(_QuietHandler):
        def do_POST(self) -> None:
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            # Suppressed because the client is expected to walk away
            # mid-response: that is what the test is proving.
            with contextlib.suppress(OSError):
                for index in range(len(body)):
                    self.wfile.write(body[index : index + 1])
                    self.wfile.flush()
                    time.sleep(gap)

    return Handler


def _endless_handler() -> type[http.server.BaseHTTPRequestHandler]:
    """A valid login followed by a body that never ends.

    Exactly the cap's job: the first 64 KiB carry the whole answer, and a
    reader with no bound would sit here until the wall-clock deadline gave
    up on a login that had in fact succeeded.
    """
    payload = json.dumps({"Success": True, "Token": "capped-tok"}).encode()
    prefix = payload.ljust(1 << 16, b" ")  # trailing spaces still parse

    class Handler(_QuietHandler):
        def do_POST(self) -> None:
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.send_response(200)
            self.send_header("Content-Length", str(1 << 30))
            self.end_headers()
            with contextlib.suppress(OSError):
                self.wfile.write(prefix)
                while True:
                    self.wfile.write(b" " * 4096)

    return Handler


@contextlib.contextmanager
def raw_reply_server(reply: bytes) -> Iterator[str]:
    """A listener that answers whatever it is sent with bytes that are not HTTP.

    `http.client` raises `BadStatusLine` for this - an `HTTPException`,
    which is not an `OSError`, so it escaped the login's own guard.
    """
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]

    def serve() -> None:
        with contextlib.suppress(OSError):
            connection, _address = listener.accept()
            with connection:
                connection.recv(65536)
                connection.sendall(reply)

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{port}/dorequest.php"
    finally:
        listener.close()
        thread.join(timeout=2.0)


@contextlib.contextmanager
def ra_server(
    handler_class: type[http.server.BaseHTTPRequestHandler], *, threaded: bool = False
) -> Iterator[str]:
    """A throwaway HTTP server, yielding the login2 URL to point prepare at.

    `threaded` for the slow handlers: `ThreadingHTTPServer` sets
    `daemon_threads`, so `shutdown()` returns at once instead of waiting
    out a response the client has already abandoned - which is every test
    that proves the login deadline fires.
    """
    server_class = _QuietThreadingHTTPServer if threaded else _QuietHTTPServer
    server = server_class(("127.0.0.1", 0), handler_class)
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
    # The handler answers Success once it wakes, so the only way to reach
    # "unreachable" here is the deadline firing first.
    with ra_server(_sleepy_handler(0.5), threaded=True) as url:
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
    with ra_server(_sleepy_handler(0.5), threaded=True) as url:
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


# --- RetroAchievements: the owned-table merge (design D1, D2) -------------
#
# One function per emulator-shaped target, so each test names the target
# the way a real one would be built rather than exercising encodings in the
# abstract - a PCSX2-style split across two files included.


def plain_target(
    name: str, file_relative: str, *, booleans: dict[str, str] | None = None
) -> dict[str, object]:
    return {
        "name": name,
        "encoding": "plain",
        "booleans": booleans or {"true": "true", "false": "false"},
        "keys": {
            "enabled": {"file": file_relative, "key": "cheevos_enable"},
            "hardcore": {"file": file_relative, "key": "cheevos_hardcore_mode_enable"},
            "username": {"file": file_relative, "key": "cheevos_username"},
            "token": {"file": file_relative, "key": "cheevos_token"},
        },
    }


def ini_target(
    name: str,
    file_relative: str,
    section: str = "Cheevos",
    *,
    booleans: dict[str, str] | None = None,
) -> dict[str, object]:
    return {
        "name": name,
        "encoding": "plain",
        "booleans": booleans or {"true": "True", "false": "False"},
        "keys": {
            "enabled": {"file": file_relative, "section": section, "key": "Enabled"},
            "hardcore": {
                "file": file_relative,
                "section": section,
                "key": "ChallengeMode",
            },
            "username": {"file": file_relative, "section": section, "key": "Username"},
            "token": {"file": file_relative, "section": section, "key": "Token"},
        },
    }


def pcsx2_target() -> dict[str, object]:
    return {
        "name": "pcsx2",
        "encoding": "plain",
        "booleans": {"true": "true", "false": "false"},
        "keys": {
            "enabled": {
                "file": "PCSX2.ini",
                "section": "Achievements",
                "key": "Enabled",
            },
            "hardcore": {
                "file": "PCSX2.ini",
                "section": "Achievements",
                "key": "ChallengeMode",
            },
            "username": {
                "file": "secrets.ini",
                "section": "Achievements",
                "key": "Username",
            },
            "token": {"file": "secrets.ini", "section": "Achievements", "key": "Token"},
        },
    }


def secret_file_target(token_file: Path) -> dict[str, object]:
    return {
        "name": "ppsspp",
        "encoding": "secret-file",
        "booleans": {"true": "True", "false": "False"},
        "keys": {
            "enabled": {
                "file": "ppsspp.ini",
                "section": "Achievements",
                "key": "AchievementsEnable",
            },
            "hardcore": {
                "file": "ppsspp.ini",
                "section": "Achievements",
                "key": "AchievementsChallengeMode",
            },
            "username": {
                "file": "ppsspp.ini",
                "section": "Achievements",
                "key": "AchievementsUserName",
            },
        },
        "token_file": str(token_file),
    }


def duckstation_target(
    machine_id_file: Path, ini_relative: str, *, with_timestamp: bool = True
) -> dict[str, object]:
    keys: dict[str, object] = {
        "enabled": {"file": ini_relative, "section": "Cheevos", "key": "Enabled"},
        "hardcore": {
            "file": ini_relative,
            "section": "Cheevos",
            "key": "ChallengeMode",
        },
        "username": {"file": ini_relative, "section": "Cheevos", "key": "Username"},
        "token": {"file": ini_relative, "section": "Cheevos", "key": "Token"},
    }
    if with_timestamp:
        keys["login_timestamp"] = {
            "file": ini_relative,
            "section": "Cheevos",
            "key": "LoginTimestamp",
        }
    return {
        "name": "duckstation",
        "encoding": "duckstation",
        "machine_id_file": str(machine_id_file),
        "booleans": {"true": "true", "false": "false"},
        "keys": keys,
    }


def retroachievements_namespace(
    tmp_path: Path,
    api_url: str,
    targets: list[dict[str, object]],
    *,
    hardcore: bool = False,
    cache: str | None = None,
) -> dict[str, object]:
    ra, _cache_file = ra_namespace(tmp_path, api_url, cache=cache)
    ra["hardcore"] = hardcore
    ra["targets"] = targets
    return ra


def test_apply_writes_enabled_and_hardcore_even_without_a_resolved_token(
    tmp_path: Path,
) -> None:
    files: dict[str, object] = {"retroarch.cfg": {"format": "retroarch", "keys": {}}}
    target = plain_target("retroarch", "retroarch.cfg")
    ra = retroachievements_namespace(
        tmp_path, closed_port_url(), [target], hardcore=True
    )

    assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    keys = files["retroarch.cfg"]["keys"]
    assert keys["cheevos_enable"] == "true"
    assert keys["cheevos_hardcore_mode_enable"] == "true"
    # Marked for removal rather than omitted: omitting them left
    # whatever a previous, luckier run had written on disk.
    assert keys["cheevos_username"] is ep.REMOVE
    assert keys["cheevos_token"] is ep.REMOVE


def test_apply_writes_username_and_token_for_a_plain_target(tmp_path: Path) -> None:
    with ra_server(_json_handler(200, {"Success": True, "Token": "tok-1"})) as url:
        files: dict[str, object] = {
            "retroarch.cfg": {"format": "retroarch", "keys": {}}
        }
        target = plain_target("retroarch", "retroarch.cfg")
        ra = retroachievements_namespace(tmp_path, url, [target])

        assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    keys = files["retroarch.cfg"]["keys"]
    assert keys["cheevos_username"] == "alice"
    assert keys["cheevos_token"] == "tok-1"
    assert keys["cheevos_enable"] == "true"
    assert keys["cheevos_hardcore_mode_enable"] == "false"


def test_apply_writes_a_dolphin_style_ini_target_with_its_own_boolean_spellings(
    tmp_path: Path,
) -> None:
    with ra_server(_json_handler(200, {"Success": True, "Token": "tok-2"})) as url:
        files: dict[str, object] = {"Dolphin.ini": {"format": "ini", "keys": {}}}
        target = ini_target("dolphin", "Dolphin.ini")
        ra = retroachievements_namespace(tmp_path, url, [target], hardcore=True)

        assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    section = files["Dolphin.ini"]["keys"]["Cheevos"]
    assert section == {
        "Enabled": "True",
        "ChallengeMode": "True",
        "Username": "alice",
        "Token": "tok-2",
    }


def test_apply_splits_pcsx2_keys_across_two_files(tmp_path: Path) -> None:
    # Nothing special is needed for this - it falls out of the per-key
    # `file` - but the design calls it out explicitly as worth proving.
    with ra_server(_json_handler(200, {"Success": True, "Token": "tok-3"})) as url:
        files: dict[str, object] = {
            "PCSX2.ini": {"format": "ini", "keys": {}},
            "secrets.ini": {"format": "ini", "keys": {}},
        }
        ra = retroachievements_namespace(tmp_path, url, [pcsx2_target()])

        assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    assert files["PCSX2.ini"]["keys"]["Achievements"] == {
        "Enabled": "true",
        "ChallengeMode": "false",
    }
    assert files["secrets.ini"]["keys"]["Achievements"] == {
        "Username": "alice",
        "Token": "tok-3",
    }


def test_apply_writes_a_secret_file_token_for_ppsspp(tmp_path: Path) -> None:
    token_file = tmp_path / "ppsspp_retroachievements.dat"
    with ra_server(_json_handler(200, {"Success": True, "Token": "tok-4"})) as url:
        files: dict[str, object] = {"ppsspp.ini": {"format": "ini", "keys": {}}}
        ra = retroachievements_namespace(
            tmp_path, url, [secret_file_target(token_file)]
        )

        assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    section = files["ppsspp.ini"]["keys"]["Achievements"]
    assert section["AchievementsUserName"] == "alice"
    assert "token" not in {k.lower() for k in section}
    # No trailing newline: the file's entire content is the raw token bytes.
    assert token_file.read_bytes() == b"tok-4"
    assert token_file.stat().st_mode & 0o777 == 0o600


def test_apply_forces_the_secret_files_mode_even_if_it_pre_existed(
    tmp_path: Path,
) -> None:
    token_file = tmp_path / "ppsspp_retroachievements.dat"
    token_file.write_bytes(b"stale-token")
    token_file.chmod(0o644)
    with ra_server(_json_handler(200, {"Success": True, "Token": "tok-5"})) as url:
        files: dict[str, object] = {"ppsspp.ini": {"format": "ini", "keys": {}}}
        ra = retroachievements_namespace(
            tmp_path, url, [secret_file_target(token_file)]
        )

        assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    assert token_file.read_bytes() == b"tok-5"
    assert token_file.stat().st_mode & 0o777 == 0o600


def test_apply_removes_a_stale_secret_file_when_no_token_resolves(
    tmp_path: Path,
) -> None:
    token_file = tmp_path / "ppsspp_retroachievements.dat"
    token_file.write_bytes(b"stale-token")
    files: dict[str, object] = {"ppsspp.ini": {"format": "ini", "keys": {}}}
    ra = retroachievements_namespace(
        tmp_path, closed_port_url(), [secret_file_target(token_file)]
    )

    assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    assert not token_file.exists()


def test_apply_never_leaks_the_password_into_the_secret_file(tmp_path: Path) -> None:
    token_file = tmp_path / "ppsspp_retroachievements.dat"
    with ra_server(_json_handler(200, {"Success": True, "Token": "tok-6"})) as url:
        files: dict[str, object] = {"ppsspp.ini": {"format": "ini", "keys": {}}}
        ra = retroachievements_namespace(
            tmp_path, url, [secret_file_target(token_file)]
        )

        ep.apply_retroachievements(files, ra, tmp_path)

    assert b"hunter2" not in token_file.read_bytes()


def test_apply_writes_a_duckstation_target_end_to_end(tmp_path: Path) -> None:
    machine_id_file = tmp_path / "machine-id"
    machine_id_file.write_text("abc123\n")
    with ra_server(_json_handler(200, {"Success": True, "Token": "tok-7"})) as url:
        files: dict[str, object] = {"settings.ini": {"format": "ini", "keys": {}}}
        target = duckstation_target(machine_id_file, "settings.ini")
        ra = retroachievements_namespace(tmp_path, url, [target])

        assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    section = files["settings.ini"]["keys"]["Cheevos"]
    assert section["Username"] == "alice"
    assert section["Token"] == ep.encrypt_duckstation_token(
        b"abc123\n", "alice", "tok-7"
    )
    assert section["Enabled"] == "true"
    assert section["ChallengeMode"] == "false"
    assert "LoginTimestamp" in section


def test_apply_with_no_targets_is_a_no_op(tmp_path: Path) -> None:
    files: dict[str, object] = {}
    ra = retroachievements_namespace(tmp_path, closed_port_url(), [])

    assert ep.apply_retroachievements(files, ra, tmp_path) == 0
    assert files == {}


def test_apply_rejects_a_target_key_naming_an_undeclared_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    files: dict[str, object] = {}
    ra = retroachievements_namespace(
        tmp_path, closed_port_url(), [plain_target("retroarch", "retroarch.cfg")]
    )

    assert ep.apply_retroachievements(files, ra, tmp_path) == 1
    assert "retroarch.cfg" in capsys.readouterr().err


def test_apply_rejects_an_ini_key_missing_a_section(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    files: dict[str, object] = {"Dolphin.ini": {"format": "ini", "keys": {}}}
    # plain_target's key entries have no "section", which an ini file needs.
    ra = retroachievements_namespace(
        tmp_path, closed_port_url(), [plain_target("dolphin", "Dolphin.ini")]
    )

    assert ep.apply_retroachievements(files, ra, tmp_path) == 1
    assert "section" in capsys.readouterr().err


def test_apply_rejects_a_retroarch_key_carrying_a_section(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    files: dict[str, object] = {"retroarch.cfg": {"format": "retroarch", "keys": {}}}
    # ini_target's key entries carry a "section", which a retroarch file must not.
    ra = retroachievements_namespace(
        tmp_path, closed_port_url(), [ini_target("retroarch-ish", "retroarch.cfg")]
    )

    assert ep.apply_retroachievements(files, ra, tmp_path) == 1
    assert "section" in capsys.readouterr().err


def test_apply_rejects_a_target_key_naming_an_esde_xml_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    files: dict[str, object] = {"es_settings.xml": {"format": "esde-xml", "keys": {}}}
    ra = retroachievements_namespace(
        tmp_path, closed_port_url(), [plain_target("bogus", "es_settings.xml")]
    )

    assert ep.apply_retroachievements(files, ra, tmp_path) == 1
    assert "es_settings.xml" in capsys.readouterr().err


def test_apply_rejects_a_secret_file_target_that_declares_a_token_key(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    files: dict[str, object] = {"ppsspp.ini": {"format": "ini", "keys": {}}}
    target = secret_file_target(tmp_path / "ppsspp.dat")
    keys = cast("dict[str, object]", target["keys"])
    keys["token"] = {"file": "ppsspp.ini", "section": "Achievements", "key": "Token"}
    ra = retroachievements_namespace(tmp_path, closed_port_url(), [target])

    assert ep.apply_retroachievements(files, ra, tmp_path) == 1
    assert "token" in capsys.readouterr().err.lower()


def test_apply_rejects_a_secret_file_target_missing_token_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    files: dict[str, object] = {"ppsspp.ini": {"format": "ini", "keys": {}}}
    target = secret_file_target(tmp_path / "ppsspp.dat")
    del target["token_file"]
    ra = retroachievements_namespace(tmp_path, closed_port_url(), [target])

    assert ep.apply_retroachievements(files, ra, tmp_path) == 1
    assert "token_file" in capsys.readouterr().err


def test_apply_rejects_a_plain_target_that_carries_a_token_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    files: dict[str, object] = {"retroarch.cfg": {"format": "retroarch", "keys": {}}}
    target = plain_target("retroarch", "retroarch.cfg")
    target["token_file"] = "/should/not/be/here"
    ra = retroachievements_namespace(tmp_path, closed_port_url(), [target])

    assert ep.apply_retroachievements(files, ra, tmp_path) == 1
    assert "token_file" in capsys.readouterr().err


def test_apply_rejects_an_unknown_encoding(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    files: dict[str, object] = {"retroarch.cfg": {"format": "retroarch", "keys": {}}}
    target = plain_target("retroarch", "retroarch.cfg")
    target["encoding"] = "rot13"
    ra = retroachievements_namespace(tmp_path, closed_port_url(), [target])

    assert ep.apply_retroachievements(files, ra, tmp_path) == 1
    assert "encoding" in capsys.readouterr().err


def test_main_null_retroachievements_changes_nothing_beyond_ordinary_files(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    appdata = tmp_path / "es-de"
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(appdata))
    values = tmp_path / "owned.json"
    values.write_text(
        json.dumps(
            {
                "files": {
                    "retroarch.cfg": {
                        "format": "retroarch",
                        "keys": {"menu_driver": "ozone"},
                    }
                },
                "retroachievements": None,
            }
        )
    )

    assert ep.main([str(values), ""]) == 0

    text = (appdata / "retroarch.cfg").read_text()
    assert 'menu_driver = "ozone"' in text
    assert "cheevos" not in text


def test_main_end_to_end_with_retroachievements_never_leaks_the_password(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    appdata = tmp_path / "es-de"
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(appdata))
    username_file = tmp_path / "username"
    password_file = tmp_path / "password"
    username_file.write_text("alice\n")
    password_file.write_text("hunter2\n")

    with ra_server(_json_handler(200, {"Success": True, "Token": "tok-e2e"})) as url:
        values = tmp_path / "owned.json"
        values.write_text(
            json.dumps(
                {
                    "files": {"retroarch.cfg": {"format": "retroarch", "keys": {}}},
                    "retroachievements": {
                        "api_url": url,
                        "username_file": str(username_file),
                        "password_file": str(password_file),
                        "cache_file": str(tmp_path / "cache" / "ra-token"),
                        "hardcore": False,
                        "targets": [plain_target("retroarch", "retroarch.cfg")],
                    },
                }
            )
        )

        assert ep.main([str(values), ""]) == 0

    text = (appdata / "retroarch.cfg").read_text()
    assert 'cheevos_username = "alice"' in text
    assert 'cheevos_token = "tok-e2e"' in text
    assert "hunter2" not in text
    assert "hunter2" not in capsys.readouterr().err


# --- RetroAchievements: degrading without ever writing more than it must ---


def test_resolve_token_continues_when_a_credential_file_is_not_valid_utf8(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # UnicodeDecodeError is a ValueError, not an OSError, so it needs its
    # own except clause - otherwise it propagates out of main() as an
    # uncaught traceback instead of the clean "no token" degradation the
    # whole design exists to provide, and a power cut can leave a
    # credential file exactly this broken.
    ra, _cache_file = ra_namespace(tmp_path, closed_port_url())
    (tmp_path / "username").write_bytes(b"\xff\xfe not valid utf-8")

    result = ep.resolve_retroachievements_token(ra, tmp_path, timeout=5.0)

    assert result is None
    assert capsys.readouterr().err.strip()


def test_resolve_token_continues_when_the_cache_is_not_valid_utf8(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    ra, cache_file = ra_namespace(tmp_path, closed_port_url())
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    cache_file.write_bytes(b"\xff\xfe not valid utf-8")

    result = ep.resolve_retroachievements_token(ra, tmp_path, timeout=5.0)

    assert result is None
    assert capsys.readouterr().err.strip()


def test_apply_and_editors_leave_the_duckstation_file_untouched_when_the_token_is_unchanged(
    tmp_path: Path,
) -> None:
    # The requirement is the file's bytes, not merely that the returned
    # mapping omits "login_timestamp" - this runs the full apply-then-write
    # pipeline twice with the same token and proves the second pass writes
    # nothing at all, mtime included.
    machine_id_file = tmp_path / "machine-id"
    machine_id_file.write_text("abc123\n")
    ini_path = tmp_path / "settings.ini"

    def run_once() -> None:
        files: dict[str, object] = {"settings.ini": {"format": "ini", "keys": {}}}
        target = duckstation_target(machine_id_file, "settings.ini")
        with ra_server(
            _json_handler(200, {"Success": True, "Token": "tok-stable"})
        ) as url:
            ra = retroachievements_namespace(tmp_path, url, [target])
            assert ep.apply_retroachievements(files, ra, tmp_path) == 0
        table = cast("dict[str, object]", files["settings.ini"])
        ep.set_ini_settings(ini_path, cast("dict[str, dict[str, str]]", table["keys"]))

    run_once()
    freeze(ini_path)

    run_once()

    assert unwritten(ini_path)


def test_apply_folds_the_cached_token_into_the_owned_tables_when_offline(
    tmp_path: Path,
) -> None:
    # The resolve layer's cache fallback is covered on its own, but the
    # "Offline with a cached token" spec scenario is about what actually
    # lands in the emulator configs.
    files: dict[str, object] = {"retroarch.cfg": {"format": "retroarch", "keys": {}}}
    target = plain_target("retroarch", "retroarch.cfg")
    ra = retroachievements_namespace(
        tmp_path, closed_port_url(), [target], cache="cached-tok"
    )

    assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    keys = files["retroarch.cfg"]["keys"]
    assert keys["cheevos_username"] == "alice"
    assert keys["cheevos_token"] == "cached-tok"


def test_resolve_token_notes_falling_back_to_the_cache_when_unreachable(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    ra, _cache_file = ra_namespace(tmp_path, closed_port_url(), cache="cached-token")

    result = ep.resolve_retroachievements_token(ra, tmp_path, timeout=5.0)

    assert result == ("alice", "cached-token")
    assert "falling back to the cached token" in capsys.readouterr().err


def test_resolve_token_notes_no_cache_to_fall_back_to_when_unreachable(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # Distinct from the message above - an admin reading the journal in
    # the no-network-no-cache scenario must not see wording implying a
    # fallback happened when none did.
    ra, _cache_file = ra_namespace(tmp_path, closed_port_url())

    result = ep.resolve_retroachievements_token(ra, tmp_path, timeout=5.0)

    assert result is None
    err = capsys.readouterr().err
    assert "no cached token exists" in err
    assert "falling back" not in err


def test_apply_rejects_a_non_boolean_hardcore(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # Every other malformed field in this namespace is a call-site
    # failure; a JSON string like "false" being silently truthy under a
    # bare bool(...) would be the one exception.
    files: dict[str, object] = {"retroarch.cfg": {"format": "retroarch", "keys": {}}}
    ra = retroachievements_namespace(
        tmp_path, closed_port_url(), [plain_target("retroarch", "retroarch.cfg")]
    )
    ra["hardcore"] = "false"

    assert ep.apply_retroachievements(files, ra, tmp_path) == 1
    assert "hardcore" in capsys.readouterr().err


def test_apply_never_leaks_the_password_across_every_target_shape(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # The earlier password tests each sweep one file; this one runs
    # every target shape together and sweeps every resulting file plus
    # stderr in one pass.
    machine_id_file = tmp_path / "machine-id"
    machine_id_file.write_text("abc123\n")
    ppsspp_token_file = tmp_path / "ppsspp_retroachievements.dat"

    with ra_server(_json_handler(200, {"Success": True, "Token": "tok-sweep"})) as url:
        files: dict[str, object] = {
            "retroarch.cfg": {"format": "retroarch", "keys": {}},
            "Dolphin.ini": {"format": "ini", "keys": {}},
            "PCSX2.ini": {"format": "ini", "keys": {}},
            "secrets.ini": {"format": "ini", "keys": {}},
            "ppsspp.ini": {"format": "ini", "keys": {}},
            "settings.ini": {"format": "ini", "keys": {}},
        }
        targets = [
            plain_target("retroarch", "retroarch.cfg"),
            ini_target("dolphin", "Dolphin.ini"),
            pcsx2_target(),
            secret_file_target(ppsspp_token_file),
            duckstation_target(machine_id_file, "settings.ini"),
        ]
        ra = retroachievements_namespace(tmp_path, url, targets)

        assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    for relative, raw_table in files.items():
        assert isinstance(raw_table, dict)
        table = cast("dict[str, object]", raw_table)
        assert "hunter2" not in json.dumps(table["keys"]), relative
    assert b"hunter2" not in ppsspp_token_file.read_bytes()
    assert "hunter2" not in capsys.readouterr().err


# --- The crash boundary: what must never reach main as a traceback ---------


def test_main_survives_a_settings_ini_that_is_not_valid_utf8(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # DuckStation writes ROM paths and memory card names into
    # settings.ini verbatim, so one latin-1 byte off a FAT stick makes the
    # file undecodable. The read that change-gates LoginTimestamp happens
    # before any editor runs, so a UnicodeDecodeError escaping there ends
    # every launch at the greeter and the recreate policy never gets its
    # turn. Driven through main() because that is where the damage lands.
    appdata = tmp_path / "es-de"
    appdata.mkdir()
    machine_id_file = tmp_path / "machine-id"
    machine_id_file.write_text("abc123\n")
    ini_path = appdata / "settings.ini"
    ini_path.write_bytes(
        b"[Cheevos]\nToken = abc\n\n[GameList]\nRecentPath = /roms/Pok\xe9mon.chd\n"
    )
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(appdata))

    with ra_server(_json_handler(200, {"Success": True, "Token": "tok-utf8"})) as url:
        values = tmp_path / "owned.json"
        values.write_text(
            json.dumps(
                {
                    "files": {"settings.ini": {"format": "ini", "keys": {}}},
                    "retroachievements": retroachievements_namespace(
                        tmp_path,
                        url,
                        [duckstation_target(machine_id_file, "settings.ini")],
                    ),
                }
            )
        )

        assert ep.main([str(values), ""]) == 0

    # Recreated by the editors' ordinary policy, carrying the owned keys.
    assert "Username = alice" in ini_path.read_text()
    assert "unreadable" in capsys.readouterr().err


def test_login2_bounds_a_dribbling_server_by_wall_clock() -> None:
    # urlopen's timeout is per socket operation, so a server sending a
    # byte at a time resets it forever and the login never returns. The
    # assertion on elapsed time is the one that pins the bound: without a
    # wall-clock deadline this call runs for the whole dribble and beyond.
    dribble = 1.0
    with ra_server(_dribbling_handler(dribble), threaded=True) as url:
        started = time.monotonic()
        outcome = ep._login2(url, "alice", "hunter2", timeout=0.2)
        elapsed = time.monotonic() - started

    assert outcome == ("unreachable", None)
    assert elapsed < dribble


def test_resolve_token_falls_back_to_the_cache_when_the_server_dribbles(
    tmp_path: Path,
) -> None:
    # The same bound where it matters: the session gets the cached token
    # and the frontend, rather than a black screen for as long as the
    # server feels like trickling.
    dribble = 1.0
    with ra_server(_dribbling_handler(dribble), threaded=True) as url:
        ra, _cache_file = ra_namespace(tmp_path, url, cache="cached-token")
        started = time.monotonic()
        result = ep.resolve_retroachievements_token(ra, tmp_path, timeout=0.2)
        elapsed = time.monotonic() - started

    assert result == ("alice", "cached-token")
    assert elapsed < dribble


def test_login2_does_not_leave_its_abandoned_request_running(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The wall-clock deadline abandons the request rather than cancelling
    # it, which leaves the per-socket timeout a job of its own: without it
    # the abandoned thread sits in recv for as long as the server holds the
    # connection - ten seconds here, indefinitely on a half-up network.
    #
    # Proved by capturing the actual `threading.Thread` objects `_login2`
    # (and, on the server side, `ThreadingHTTPServer`) create while the call
    # is in flight - patching `threading.Thread` for the call's duration -
    # rather than sampling `threading.enumerate()` by name at some later,
    # arbitrary moment. A sampled snapshot only shows whether a same-named
    # thread had not finished the instant it happened to be checked, which
    # stayed timing-sensitive under a busy sandboxed build even filtered by
    # name and polled with a deadline. The name still has to pick the one
    # worker out of what this test captures, but only among threads its own
    # `with` block created - no earlier or later test's thread can ever
    # reach this list. `Thread.join` then blocks until that exact thread
    # object reports completion, so the result is precise no matter how
    # little CPU time a loaded build hands it.
    created: list[threading.Thread] = []
    real_thread = threading.Thread

    def capturing_thread(*args: Any, **kwargs: Any) -> threading.Thread:
        thread = real_thread(*args, **kwargs)
        created.append(thread)
        return thread

    with ra_server(_sleepy_handler(10.0), threaded=True) as url:
        # `monkeypatch.setattr` on `threading.Thread` is process-global, so
        # the window is kept to this one statement and undone the moment it
        # returns. Inside that window a live `ThreadingHTTPServer` is
        # spawning per-connection threads of its own, so `created` holds
        # more than `_login2`'s worker and the worker is picked out by the
        # one name `_login2` gives it, not by position. Nothing else runs
        # concurrently with the window - pytest is single-threaded and the
        # only other threads alive are this test's own server - so the
        # capture cannot pick up a thread from anywhere else.
        monkeypatch.setattr(threading, "Thread", capturing_thread)
        assert ep._login2(url, "alice", "hunter2", timeout=0.2) == (
            "unreachable",
            None,
        )
        monkeypatch.undo()

    workers = [t for t in created if t.name == "emubox-ra-login2"]
    assert len(workers) == 1, created
    worker = workers[0]
    # The bound has to sit BELOW the handler's hold - 10 s, above - and
    # that is the only thing that makes this a test at all. The abandoned
    # worker leaves recv() early because of the per-socket timeout; without
    # one it stays there until the server finally answers, so any bound
    # above the hold sees the worker finish on its own either way and
    # asserts nothing. A 30 s bound did exactly that: deleting
    # `timeout=timeout` from the urlopen call left this test green.
    #
    # 5 s is comfortably under the 10 s hold and comfortably over the 0.2 s
    # per-socket schedule the worker really gives up on, and `join` returns
    # the moment the thread finishes, so a passing run does not wait here.
    worker.join(timeout=5.0)
    assert not worker.is_alive(), "abandoned login2 worker thread is still running"


# The four exception families below are asserted against `_login2_request`,
# the function whose except clauses they are about, rather than through
# `_login2`: the wall-clock wrapper has a catch-all of its own, so going
# through it would report "unreachable" whether the clauses were right or
# missing entirely. The wrapper's own note is asserted absent in the first
# of them, which is what says the request handled its failure itself.


def test_login2_reports_unreachable_when_the_reply_is_not_http(
    capsys: pytest.CaptureFixture[str],
) -> None:
    # BadStatusLine is an http.client.HTTPException, not an OSError, so
    # it escaped to main as a traceback and the session ended at a greeter.
    with raw_reply_server(b"gibberish not a status line\r\n\r\n") as url:
        assert ep._login2_request(url, "alice", "hunter2", 5.0) == (
            "unreachable",
            None,
        )
    with raw_reply_server(b"gibberish not a status line\r\n\r\n") as url:
        assert ep._login2(url, "alice", "hunter2", timeout=5.0) == ("unreachable", None)

    assert "unexpectedly" not in capsys.readouterr().err


def test_login2_reports_unreachable_when_the_reply_headers_are_endless() -> None:
    # LineTooLong, the other HTTPException a listener can produce at will.
    with raw_reply_server(b"HTTP/1.1 200 OK\r\nX: " + b"a" * 200000) as url:
        outcome = ep._login2_request(url, "alice", "hunter2", 5.0)

    assert outcome == ("unreachable", None)


def test_login2_reports_unreachable_on_a_url_with_no_usable_scheme() -> None:
    # ValueError("unknown url type"), raised by Request() before any socket
    # exists - which is why the construction had to move inside the try.
    outcome = ep._login2_request("not a url at all", "alice", "hunter2", 5.0)

    assert outcome == ("unreachable", None)


def test_login2_never_puts_the_password_in_the_journal(
    capsys: pytest.CaptureFixture[str],
) -> None:
    # `urlencode` is the only call in this program that holds the plaintext
    # password, and it sat outside the try. A password it cannot encode
    # raised through the worker thread to the catch-all there, which
    # printed `{error!r}` - and a UnicodeEncodeError's repr carries the
    # offending string, so the password would have gone into the journal
    # `journalctl` keeps.
    #
    # A lone surrogate is not reachable from a sops secret today, since
    # `_read_secret` decodes strict UTF-8; the point is that the call
    # holding the secret must not be the one call left outside the guard
    # that exists for exactly this - `Request()` one line below it was
    # already moved inside for the same class of reason.
    outcome = ep._login2("http://127.0.0.1:1/x", "alice", "hunter\ud8002", 5.0)

    assert outcome == ("unreachable", None)
    err = capsys.readouterr().err
    assert "hunter" not in err
    assert "\\ud800" not in err


def test_login2_reports_unreachable_on_a_deeply_nested_json_body() -> None:
    # RecursionError, which is not a ValueError, so the json.loads guard
    # missed it entirely.
    with ra_server(_body_handler(200, b"[" * 100000)) as url:
        outcome = ep._login2_request(url, "alice", "hunter2", 5.0)

    assert outcome == ("unreachable", None)


def test_login2_reads_a_bounded_body() -> None:
    # An unbounded read() against a body that never ends is another way to
    # block the session forever; the cap turns it into an ordinary success.
    with ra_server(_endless_handler(), threaded=True) as url:
        outcome = ep._login2(url, "alice", "hunter2", timeout=5.0)

    assert outcome == ("success", "capped-tok")


def test_main_absorbs_an_unexpected_failure_in_the_retroachievements_step(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # An exception from anywhere in the RA step costs the achievements
    # and nothing else. Anything else ends the session at the greeter, and
    # nobody in the family can play until an admin logs in over SSH.
    appdata = tmp_path / "es-de"
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(appdata))

    def explode(*_args: object, **_kwargs: object) -> int:
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(ep, "apply_retroachievements", explode)
    values = tmp_path / "owned.json"
    values.write_text(
        json.dumps(
            {
                "files": {
                    "retroarch.cfg": {
                        "format": "retroarch",
                        "keys": {"menu_driver": "ozone"},
                    }
                },
                "retroachievements": retroachievements_namespace(
                    tmp_path,
                    closed_port_url(),
                    [plain_target("retroarch", "retroarch.cfg")],
                ),
            }
        )
    )

    assert ep.main([str(values), ""]) == 0

    # The ordinary files are still written: only the achievements are lost.
    assert 'menu_driver = "ozone"' in (appdata / "retroarch.cfg").read_text()
    assert "No space left on device" in capsys.readouterr().err


def test_main_still_refuses_a_malformed_retroachievements_document(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # The other half of the guard: a malformed owned-values document is a
    # broken call site, and the greeter remains the correct answer to it.
    # The blanket except must not swallow this into a silent success.
    appdata = tmp_path / "es-de"
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(appdata))
    target = plain_target("retroarch", "retroarch.cfg")
    target["encoding"] = "rot13"
    values = tmp_path / "owned.json"
    values.write_text(
        json.dumps(
            {
                "files": {"retroarch.cfg": {"format": "retroarch", "keys": {}}},
                "retroachievements": retroachievements_namespace(
                    tmp_path, closed_port_url(), [target]
                ),
            }
        )
    )

    assert ep.main([str(values), ""]) == 1
    assert "encoding" in capsys.readouterr().err
    assert not (appdata / "retroarch.cfg").exists()


# --- Writes that should not happen: mode ordering, unchanged content ------


def test_write_applies_a_requested_mode_before_the_rename(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # A chmod after os.replace publishes a credential at 0644 for the
    # length of a syscall, and leaves it there for good if that chmod is
    # the call that fails. The assertion is on the temporary file's mode as
    # the rename sees it, not merely on the mode afterwards.
    path = tmp_path / "ra-token"
    seen: list[int] = []
    real_replace = os.replace

    def watched_replace(source: object, destination: object) -> None:
        seen.append(os.stat(cast("str", source)).st_mode & 0o777)
        real_replace(cast("str", source), cast("str", destination))

    monkeypatch.setattr(ep.os, "replace", watched_replace)
    ep._write(path, "tok", mode=0o600)

    assert seen == [0o600]
    assert path.stat().st_mode & 0o777 == 0o600


def test_resolve_token_does_not_rewrite_an_unchanged_cache(tmp_path: Path) -> None:
    # Identical content wrote a fresh inode on every launch - two full
    # write+fsync+rename+dir-fsync cycles per launch on a flash appliance,
    # on the critical path before the frontend, for nothing.
    with ra_server(_json_handler(200, {"Success": True, "Token": "same-tok"})) as url:
        ra, cache_file = ra_namespace(tmp_path, url)

        assert ep.resolve_retroachievements_token(ra, tmp_path, timeout=5.0) is not None
        freeze(cache_file)

        assert ep.resolve_retroachievements_token(ra, tmp_path, timeout=5.0) is not None

    assert unwritten(cache_file)
    assert cache_file.read_text() == "same-tok"


def test_resolve_token_corrects_the_cache_mode_without_rewriting_it(
    tmp_path: Path,
) -> None:
    # The other half: skipping the write must not skip the mode, or a box
    # that is offline for months keeps a world-readable bearer token.
    with ra_server(_json_handler(200, {"Success": True, "Token": "same-tok"})) as url:
        ra, cache_file = ra_namespace(tmp_path, url, cache="same-tok")
        cache_file.chmod(0o644)
        freeze(cache_file)

        assert ep.resolve_retroachievements_token(ra, tmp_path, timeout=5.0) is not None

    assert unwritten(cache_file)
    assert cache_file.stat().st_mode & 0o777 == 0o600


def test_apply_does_not_rewrite_an_unchanged_secret_file(tmp_path: Path) -> None:
    # The same unchanged-content rule, for PPSSPP's whole-file token.
    token_file = tmp_path / "ppsspp_retroachievements.dat"

    def run_once() -> None:
        with ra_server(_json_handler(200, {"Success": True, "Token": "tok-same"})) as u:
            files: dict[str, object] = {"ppsspp.ini": {"format": "ini", "keys": {}}}
            ra = retroachievements_namespace(
                tmp_path, u, [secret_file_target(token_file)]
            )
            assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    run_once()
    freeze(token_file)

    run_once()

    assert unwritten(token_file)
    assert token_file.read_bytes() == b"tok-same"


def test_apply_corrects_the_secret_files_mode_without_rewriting_it(
    tmp_path: Path,
) -> None:
    token_file = tmp_path / "ppsspp_retroachievements.dat"
    token_file.write_text("tok-same")
    token_file.chmod(0o644)
    freeze(token_file)

    with ra_server(_json_handler(200, {"Success": True, "Token": "tok-same"})) as url:
        files: dict[str, object] = {"ppsspp.ini": {"format": "ini", "keys": {}}}
        ra = retroachievements_namespace(
            tmp_path, url, [secret_file_target(token_file)]
        )

        assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    assert unwritten(token_file)
    assert token_file.stat().st_mode & 0o777 == 0o600


def test_apply_keeps_the_token_when_the_cache_cannot_be_written(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # The crash boundary's OSError family, where it is most plausible: a
    # cache path that cannot be written (here a directory; on the box,
    # /data full or remounted read-only after a power cut). The login
    # succeeded, so the session keeps its achievements - it only loses the
    # offline fallback.
    with ra_server(
        _json_handler(200, {"Success": True, "Token": "tok-nocache"})
    ) as url:
        files: dict[str, object] = {
            "retroarch.cfg": {"format": "retroarch", "keys": {}}
        }
        ra = retroachievements_namespace(
            tmp_path, url, [plain_target("retroarch", "retroarch.cfg")]
        )
        cache_file = Path(cast("str", ra["cache_file"]))
        cache_file.mkdir(parents=True)

        assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    keys = files["retroarch.cfg"]["keys"]
    assert keys["cheevos_token"] == "tok-nocache"
    assert "could not be written" in capsys.readouterr().err


def test_apply_survives_a_secret_file_that_cannot_be_removed(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # The offline half of the same family: no token resolved, so PPSSPP's
    # token file is deleted - and a directory there raised IsADirectoryError
    # straight out of the step that runs before every launch.
    token_file = tmp_path / "ppsspp_retroachievements.dat"
    token_file.mkdir()
    files: dict[str, object] = {"ppsspp.ini": {"format": "ini", "keys": {}}}
    ra = retroachievements_namespace(
        tmp_path, closed_port_url(), [secret_file_target(token_file)]
    )

    assert ep.apply_retroachievements(files, ra, tmp_path) == 0
    assert "could not be removed" in capsys.readouterr().err


def test_ini_does_not_create_a_file_when_nothing_is_owned(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # PCSX2's secrets.ini is declared with no keys of its own, so every
    # launch that resolves no token used to write a lone newline, read it
    # back as empty and log "is empty; recreating it" - forever.
    path = tmp_path / "secrets.ini"

    assert ep.set_ini_settings(path, {}) is False
    assert ep.set_ini_settings(path, {"Achievements": {}}) is False

    assert not path.exists()
    assert capsys.readouterr().err == ""


def test_ini_leaves_an_existing_file_alone_when_nothing_is_owned(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "secrets.ini"
    path.write_text("[Achievements]\nUsername = someone\n")
    freeze(path)

    assert ep.set_ini_settings(path, {}) is False

    assert unwritten(path)
    assert capsys.readouterr().err == ""


def test_retroarch_and_esde_also_leave_a_file_they_own_nothing_in_alone(
    tmp_path: Path,
) -> None:
    cfg = tmp_path / "retroarch.cfg"
    settings = tmp_path / "es_settings.xml"

    assert ep.set_retroarch_settings(cfg, {}) is False
    assert ep.set_esde_settings(settings, {}) is False

    assert not cfg.exists()
    assert not settings.exists()


def test_main_leaves_a_keyless_secrets_file_alone_on_an_offline_box(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # The same finding where it bites: PCSX2's split puts Username and Token
    # in secrets.ini, so with no token resolved that file is owned but has
    # nothing in it, on every launch of an offline box.
    appdata = tmp_path / "es-de"
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(appdata))
    values = tmp_path / "owned.json"
    values.write_text(
        json.dumps(
            {
                "files": {
                    "PCSX2.ini": {"format": "ini", "keys": {}},
                    "secrets.ini": {"format": "ini", "keys": {}},
                },
                "retroachievements": retroachievements_namespace(
                    tmp_path, closed_port_url(), [pcsx2_target()]
                ),
            }
        )
    )

    assert ep.main([str(values), ""]) == 0
    assert ep.main([str(values), ""]) == 0

    assert not (appdata / "secrets.ini").exists()
    assert "recreating" not in capsys.readouterr().err


# --- The token is data from the network, not a value the flake chose ------

INJECTED_TOKENS = ["tok\nCheevos_evil = 1", "tok\nJUST-GARBAGE", "tok with space"]


@pytest.mark.parametrize("token", INJECTED_TOKENS)
def test_login2_refuses_a_token_that_is_not_one_safe_line(
    token: str, capsys: pytest.CaptureFixture[str]
) -> None:
    # The token was accepted as any non-empty str and written into
    # every config. A newline in it either grows the file by a line on
    # every launch or sends it through the recreate path, destroying every
    # unowned preference in it.
    with ra_server(_json_handler(200, {"Success": True, "Token": token})) as url:
        outcome = ep._login2_request(url, "alice", "hunter2", 5.0)

    assert outcome == ("unreachable", None)
    assert "will not write" in capsys.readouterr().err


@pytest.mark.parametrize("token", INJECTED_TOKENS)
def test_resolve_token_refuses_a_cached_token_that_is_not_one_safe_line(
    token: str, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # The second route in: `_read_cached_token` strips the ends but never
    # the middle, so a corrupted cache poisons every boot until someone
    # deletes it by hand.
    ra, cache_file = ra_namespace(tmp_path, closed_port_url())
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(token)

    result = ep.resolve_retroachievements_token(ra, tmp_path, timeout=5.0)

    assert result is None
    assert "will not write" in capsys.readouterr().err


@pytest.mark.parametrize("token", INJECTED_TOKENS[:2])
def test_a_config_neither_grows_nor_loses_keys_to_an_injected_token(
    token: str, tmp_path: Path
) -> None:
    # Both reproductions end to end: the file must be byte-identical after
    # a second launch, with the unowned preference still in it.
    cfg = tmp_path / "retroarch.cfg"
    cfg.write_text('# a comment\nvideo_fullscreen = "true"\n')

    def run_once() -> None:
        with ra_server(_json_handler(200, {"Success": True, "Token": token})) as url:
            files: dict[str, object] = {
                "retroarch.cfg": {"format": "retroarch", "keys": {}}
            }
            ra = retroachievements_namespace(
                tmp_path, url, [plain_target("retroarch", "retroarch.cfg")]
            )
            assert ep.apply_retroachievements(files, ra, tmp_path) == 0
        table = cast("dict[str, object]", files["retroarch.cfg"])
        ep.set_retroarch_settings(cfg, cast("dict[str, str]", table["keys"]))

    run_once()
    first = cfg.read_text()
    run_once()

    assert cfg.read_text() == first
    assert "# a comment" in first
    assert 'video_fullscreen = "true"' in first
    assert "evil" not in first
    assert "GARBAGE" not in first


# --- Validation that promised a journal line rather than a traceback ------


@pytest.mark.parametrize(
    "field", ["username_file", "password_file", "cache_file", "api_url"]
)
def test_apply_rejects_a_namespace_missing_a_required_field(
    field: str, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # Each of these is subscripted bare, so a document missing one died
    # with `KeyError 'password_file'` - a stack trace in the journal, which
    # is exactly what `_target_validation_error`'s docstring promises an
    # admin will never have to read.
    files: dict[str, object] = {"retroarch.cfg": {"format": "retroarch", "keys": {}}}
    ra = retroachievements_namespace(
        tmp_path, closed_port_url(), [plain_target("retroarch", "retroarch.cfg")]
    )
    del ra[field]

    assert ep.apply_retroachievements(files, ra, tmp_path) == 1
    assert field in capsys.readouterr().err


def test_apply_rejects_a_duckstation_target_without_a_machine_id_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    files: dict[str, object] = {"settings.ini": {"format": "ini", "keys": {}}}
    target = duckstation_target(tmp_path / "machine-id", "settings.ini")
    del target["machine_id_file"]
    ra = retroachievements_namespace(tmp_path, closed_port_url(), [target])

    assert ep.apply_retroachievements(files, ra, tmp_path) == 1
    assert "machine_id_file" in capsys.readouterr().err


def test_apply_rejects_a_key_entry_that_carries_no_key(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # Passed validation and then died with `KeyError 'key'` in the merge.
    files: dict[str, object] = {"retroarch.cfg": {"format": "retroarch", "keys": {}}}
    target = plain_target("retroarch", "retroarch.cfg")
    keys = cast("dict[str, object]", target["keys"])
    keys["token"] = {"file": "retroarch.cfg"}
    ra = retroachievements_namespace(tmp_path, closed_port_url(), [target])

    assert ep.apply_retroachievements(files, ra, tmp_path) == 1
    assert "'key'" in capsys.readouterr().err


# --- No stale token survives a run ----------------------------------------


def test_ini_removes_an_owned_key_and_keeps_everything_else(tmp_path: Path) -> None:
    path = tmp_path / "settings.ini"
    path.write_text(
        "# a comment\n[Cheevos]\nEnabled = true\nToken = stale\n# trailing note\n"
    )

    assert ep.set_ini_settings(path, {"Cheevos": {"Token": ep.REMOVE}}) is True

    text = path.read_text()
    assert "Token" not in text
    assert "Enabled = true" in text
    assert "# a comment" in text
    assert "# trailing note" in text


def test_ini_removing_a_key_that_is_not_there_reports_no_write(
    tmp_path: Path,
) -> None:
    path = tmp_path / "settings.ini"
    path.write_text("[Cheevos]\nEnabled = true\n")
    freeze(path)

    assert ep.set_ini_settings(path, {"Cheevos": {"Token": ep.REMOVE}}) is False

    assert unwritten(path)


def test_retroarch_removes_an_owned_key_and_keeps_everything_else(
    tmp_path: Path,
) -> None:
    path = tmp_path / "retroarch.cfg"
    path.write_text('# a comment\nvideo_fullscreen = "true"\ncheevos_token = "stale"\n')

    assert ep.set_retroarch_settings(path, {"cheevos_token": ep.REMOVE}) is True

    text = path.read_text()
    assert "cheevos_token" not in text
    assert 'video_fullscreen = "true"' in text
    assert "# a comment" in text


def test_retroarch_removing_a_key_that_is_not_there_reports_no_write(
    tmp_path: Path,
) -> None:
    path = tmp_path / "retroarch.cfg"
    path.write_text('video_fullscreen = "true"\n')
    freeze(path)

    assert ep.set_retroarch_settings(path, {"cheevos_token": ep.REMOVE}) is False

    assert unwritten(path)


# --- Final wave: a removal means the key is not in the file at all --------
#
# `Removal`'s docstring says the key "must not be in this file at all", and
# the editors used to remove at most one occurrence, in at most the first
# instance of the named section, and never one sitting above every header.
# That was tolerable while REMOVE only meant "do not leave a stale
# preference"; it now also means "this bearer token is off the box", so the
# code was made to match the claim rather than the other way round.


def test_ini_removal_sweeps_a_duplicated_section(tmp_path: Path) -> None:
    path = tmp_path / "secrets.ini"
    path.write_text(
        "[Achievements]\nToken = TOKENfirst\nKeepMe = yes\n"
        "[Other]\nToken = not-ours\n"
        "[Achievements]\nToken = TOKENsecond\n"
    )

    assert ep.set_ini_settings(path, {"Achievements": {"Token": ep.REMOVE}}) is True

    text = path.read_text()
    assert "TOKENfirst" not in text
    assert "TOKENsecond" not in text
    # Someone else's key of the same name, under their own section, is not
    # this program's to delete.
    assert "Token = not-ours" in text
    assert "KeepMe = yes" in text


def test_ini_removal_sweeps_a_key_repeated_within_one_section(tmp_path: Path) -> None:
    path = tmp_path / "secrets.ini"
    path.write_text("[Achievements]\nToken = TOKENone\nToken = TOKENtwo\n")

    assert ep.set_ini_settings(path, {"Achievements": {"Token": ep.REMOVE}}) is True

    assert "TOKEN" not in path.read_text()


def test_ini_removal_sweeps_a_key_written_above_every_section_header(
    tmp_path: Path,
) -> None:
    # An assignment before any header belongs to no section, so no other
    # section's owner can claim it - and leaving a line spelled
    # `Token = <live token>` in a file this program removes `Token` from
    # would defeat the promise for the sake of a shape no emulator writes.
    path = tmp_path / "secrets.ini"
    path.write_text("Token = TOKENstray\n[Achievements]\nUsername = alice\n")

    assert ep.set_ini_settings(path, {"Achievements": {"Token": ep.REMOVE}}) is True

    text = path.read_text()
    assert "TOKENstray" not in text
    assert "Username = alice" in text


def test_ini_removal_still_reports_no_write_when_only_other_sections_match(
    tmp_path: Path,
) -> None:
    path = tmp_path / "secrets.ini"
    path.write_text("[Other]\nToken = not-ours\n[Achievements]\nUsername = alice\n")
    freeze(path)

    assert ep.set_ini_settings(path, {"Achievements": {"Token": ep.REMOVE}}) is False

    assert unwritten(path)


def test_retroarch_removal_sweeps_every_occurrence(tmp_path: Path) -> None:
    path = tmp_path / "retroarch.cfg"
    path.write_text(
        'cheevos_token = "TOKENone"\nvideo_fullscreen = "true"\n'
        'cheevos_token = "TOKENtwo"\n'
    )

    assert ep.set_retroarch_settings(path, {"cheevos_token": ep.REMOVE}) is True

    text = path.read_text()
    assert "TOKEN" not in text
    assert 'video_fullscreen = "true"' in text


# --- A written key leaves exactly one assignment behind --------------------
#
# The mirror of the removal sweeps above, and it was missing. Removals were
# careful about a repeated key from the start; writes were not, so they
# edited the first assignment and left every later one saying whatever it
# said. Both readers this box writes for resolve a repeat to the *last*
# assignment, so the file held the flake's value while the emulator went on
# reading the stale one - and since the writing pass then found its own
# value already in place, it reported nothing to do on every launch after.
# For `username` and `token` that is a stale account surviving in exactly
# the place the removal sweep exists to clear it from.
#
# The invariant all three editors now share: after a write, exactly one
# assignment of an owned key is in the file and it holds the flake's value.
# What each editor may never do is touch a key it does not own, including a
# same-named one under somebody else's section.


def test_ini_write_leaves_no_stale_twin_in_a_duplicated_section(
    tmp_path: Path,
) -> None:
    path = tmp_path / "settings.ini"
    path.write_text(
        "[Achievements]\nUsername = stale-first\nKeepMe = yes\n"
        "[Other]\nUsername = not-ours\n"
        "[Achievements]\nUsername = stale-second\n"
    )

    assert ep.set_ini_settings(path, {"Achievements": {"Username": "correct"}}) is True

    text = path.read_text()
    assert text.count("Username = correct") == 1
    assert "stale-first" not in text
    assert "stale-second" not in text
    # Neither an unowned key nor a same-named key under a section this
    # program does not own is its to rewrite or remove.
    assert "KeepMe = yes" in text
    assert "Username = not-ours" in text


def test_ini_write_sweeps_a_stray_assignment_above_every_section_header(
    tmp_path: Path,
) -> None:
    # The write side of `..._removal_sweeps_a_key_written_above_every_section_header`:
    # an orphan assignment belongs to no section, so it is claimed by the
    # same owner - and it sorts *before* the section, which is why the
    # pruning pass recomputes the section bounds after every deletion.
    path = tmp_path / "settings.ini"
    path.write_text("Username = stray\n[Achievements]\nUsername = stale\n")

    assert ep.set_ini_settings(path, {"Achievements": {"Username": "correct"}}) is True

    text = path.read_text()
    assert "stray" not in text
    assert text.count("Username = correct") == 1


def test_ini_write_is_idempotent_after_collapsing_a_duplicate(tmp_path: Path) -> None:
    # The property that made the bug invisible: a second run must agree the
    # file is already right, and must not report a write it did not make.
    path = tmp_path / "settings.ini"
    path.write_text(
        "[Achievements]\nUsername = stale-first\n[Achievements]\nUsername = stale-second\n"
    )
    ep.set_ini_settings(path, {"Achievements": {"Username": "correct"}})
    freeze(path)

    assert ep.set_ini_settings(path, {"Achievements": {"Username": "correct"}}) is False

    assert unwritten(path)


def test_retroarch_write_leaves_no_stale_twin(tmp_path: Path) -> None:
    path = tmp_path / "retroarch.cfg"
    path.write_text(
        'cheevos_username = "stale-first"\nvideo_fullscreen = "true"\n'
        'cheevos_username = "stale-last"\n'
    )

    assert ep.set_retroarch_settings(path, {"cheevos_username": "correct"}) is True

    text = path.read_text()
    assert text.count('cheevos_username = "correct"') == 1
    assert "stale" not in text
    assert 'video_fullscreen = "true"' in text


def test_retroarch_write_is_idempotent_after_collapsing_a_duplicate(
    tmp_path: Path,
) -> None:
    path = tmp_path / "retroarch.cfg"
    path.write_text('cheevos_username = "one"\ncheevos_username = "two"\n')
    ep.set_retroarch_settings(path, {"cheevos_username": "correct"})
    freeze(path)

    assert ep.set_retroarch_settings(path, {"cheevos_username": "correct"}) is False

    assert unwritten(path)


def test_esde_write_collapses_a_repeated_owned_element(tmp_path: Path) -> None:
    # ES-DE had the same defect inverted: a dict comprehension over the
    # parsed elements kept the *last* repeat, so the write landed there and
    # the earlier element stayed behind holding the old value.
    path = tmp_path / "es_settings.xml"
    path.write_text(
        '<?xml version="1.0"?>\n'
        '<string name="Theme" value="stale-first" />\n'
        '<string name="Other" value="keep" />\n'
        '<string name="Theme" value="stale-last" />\n'
    )

    assert (
        ep.set_esde_settings(path, {"Theme": {"type": "string", "value": "correct"}})
        is True
    )

    names = [(n, v) for _, n, v in esde_elements(path)]
    assert names.count(("Theme", "correct")) == 1
    assert len([n for n, _ in names if n == "Theme"]) == 1
    assert ("Other", "keep") in names


def test_esde_write_leaves_a_repeated_unowned_element_alone(tmp_path: Path) -> None:
    # Collapsing is only ever applied to a name the flake owns. Two
    # elements the frontend wrote under one unowned name are the frontend's
    # business, and this program does not get to pick one.
    path = tmp_path / "es_settings.xml"
    path.write_text(
        '<?xml version="1.0"?>\n'
        '<string name="Unowned" value="one" />\n'
        '<string name="Unowned" value="two" />\n'
        '<string name="Theme" value="stale" />\n'
    )

    ep.set_esde_settings(path, {"Theme": {"type": "string", "value": "correct"}})

    names = [(n, v) for _, n, v in esde_elements(path)]
    assert ("Unowned", "one") in names
    assert ("Unowned", "two") in names


def test_esde_write_is_idempotent_after_collapsing_a_duplicate(tmp_path: Path) -> None:
    path = tmp_path / "es_settings.xml"
    path.write_text(
        '<?xml version="1.0"?>\n'
        '<string name="Theme" value="one" />\n'
        '<string name="Theme" value="two" />\n'
    )
    ep.set_esde_settings(path, {"Theme": {"type": "string", "value": "correct"}})
    freeze(path)

    assert (
        ep.set_esde_settings(path, {"Theme": {"type": "string", "value": "correct"}})
        is False
    )

    assert unwritten(path)


# --- Final wave: an unparseable file is not an absent one -----------------
#
# The all-removals branch of both flat-file editors used to read "the parser
# said None" as "there is nothing on disk", and return without writing so as
# not to create a file to hold nothing. `secrets.ini` is the one owned file
# whose only owned key on the disabled path is a removal, so a single torn
# line in it - the box is switched off at the wall, so torn writes are
# routine - left a live bearer token sitting there through every launch,
# forever, while the journal said "recreating it" each time.


def test_ini_a_torn_file_owning_only_a_removal_is_recreated_without_the_token(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "secrets.ini"
    path.write_text("[Achievements]\nTok\nToken = TOKENabc123DEADBEEF\n")

    assert ep.set_ini_settings(path, {"Achievements": {"Token": ep.REMOVE}}) is True

    assert "TOKENabc123DEADBEEF" not in path.read_text()
    # The note the load helper already printed is now true: the recreation
    # it promises is the very thing that drops the credential.
    assert "recreating it" in capsys.readouterr().err


def test_ini_recreating_a_torn_removal_only_file_reaches_a_steady_state(
    tmp_path: Path,
) -> None:
    # The property that makes the fall-through safe to run before every
    # launch: what it writes parses cleanly, so the second run changes
    # nothing and the journal stays quiet from then on.
    path = tmp_path / "secrets.ini"
    path.write_text("[Achievements]\nTok\nToken = TOKENabc123DEADBEEF\n")
    sections: dict[str, dict[str, str | ep.Removal]] = {
        "Achievements": {"Token": ep.REMOVE}
    }

    assert ep.set_ini_settings(path, sections) is True
    freeze(path)

    assert ep.set_ini_settings(path, sections) is False
    assert unwritten(path)


def test_ini_an_unreadable_file_owning_only_a_removal_is_recreated(
    tmp_path: Path,
) -> None:
    # The other ways a file that is very much present reads as unusable: a
    # non-UTF-8 byte, and a mode that forbids reading it. Both
    # have to reach the same recreation, because both may be hiding a live
    # token from a parser that cannot see it.
    undecodable = tmp_path / "undecodable.ini"
    undecodable.write_bytes(b"[Achievements]\nToken = TOKEN\xff\xfebytes\n")
    unreadable = tmp_path / "unreadable.ini"
    unreadable.write_text("[Achievements]\nToken = TOKENabc123DEADBEEF\n")
    unreadable.chmod(0o000)

    for path in (undecodable, unreadable):
        assert ep.set_ini_settings(path, {"Achievements": {"Token": ep.REMOVE}}) is True

    assert b"TOKEN" not in undecodable.read_bytes()
    # `_write` carries the old file's mode onto the replacement, so the
    # recreated file is still mode 000 and has to be opened up to read back.
    assert unreadable.stat().st_mode & 0o777 == 0o000
    unreadable.chmod(0o600)
    assert "TOKEN" not in unreadable.read_text()


def test_retroarch_a_torn_file_owning_only_a_removal_is_recreated(
    tmp_path: Path,
) -> None:
    # The identical shape in the other flat-file editor. Unreachable in this
    # configuration - RetroArch always owns static keys too - but the guard
    # moves with its twin so a later target that owns only credentials in a
    # retroarch-format file cannot inherit the bug back.
    path = tmp_path / "retroarch.cfg"
    path.write_text('torn line with no separator\ncheevos_token = "TOKENabc123"\n')

    assert ep.set_retroarch_settings(path, {"cheevos_token": ep.REMOVE}) is True

    assert "TOKENabc123" not in path.read_text()
    freeze(path)
    assert ep.set_retroarch_settings(path, {"cheevos_token": ep.REMOVE}) is False
    assert unwritten(path)


def test_a_rejected_login_leaves_no_token_behind_in_retroarch(tmp_path: Path) -> None:
    # The reproduction: after a success then a rejection, retroarch.cfg
    # still held the username, the token and cheevos_enable = "true". The
    # spec says a rejection starts the session with achievements absent.
    cfg = tmp_path / "retroarch.cfg"
    cfg.write_text('# keep me\nvideo_fullscreen = "true"\n')

    def run_once(payload: object) -> None:
        with ra_server(_json_handler(200, payload)) as url:
            files: dict[str, object] = {
                "retroarch.cfg": {"format": "retroarch", "keys": {}}
            }
            ra = retroachievements_namespace(
                tmp_path, url, [plain_target("retroarch", "retroarch.cfg")]
            )
            assert ep.apply_retroachievements(files, ra, tmp_path) == 0
        table = cast("dict[str, object]", files["retroarch.cfg"])
        ep.set_retroarch_settings(cfg, cast("dict[str, str]", table["keys"]))

    run_once({"Success": True, "Token": "tok-before"})
    assert 'cheevos_token = "tok-before"' in cfg.read_text()

    run_once({"Success": False, "Error": "bad creds"})

    text = cfg.read_text()
    assert "cheevos_token" not in text
    assert "cheevos_username" not in text
    assert "# keep me" in text
    assert 'video_fullscreen = "true"' in text


def test_an_offline_boot_with_no_cache_clears_a_duckstation_login(
    tmp_path: Path,
) -> None:
    # The same for the encrypted encoding, LoginTimestamp included.
    machine_id_file = tmp_path / "machine-id"
    machine_id_file.write_text("abc123\n")
    ini_path = tmp_path / "settings.ini"

    def run_once(url: str) -> None:
        files: dict[str, object] = {"settings.ini": {"format": "ini", "keys": {}}}
        ra = retroachievements_namespace(
            tmp_path, url, [duckstation_target(machine_id_file, "settings.ini")]
        )
        assert ep.apply_retroachievements(files, ra, tmp_path) == 0
        table = cast("dict[str, object]", files["settings.ini"])
        ep.set_ini_settings(ini_path, cast("dict[str, dict[str, str]]", table["keys"]))

    with ra_server(_json_handler(200, {"Success": True, "Token": "tok-ds"})) as url:
        run_once(url)
    ini_path.write_text(ini_path.read_text() + "[GameList]\nRecentPath = /roms/x.chd\n")
    assert "LoginTimestamp" in ini_path.read_text()

    # No cached token either: the first run left one, and the cache is an
    # offline fallback, not part of what is being cleared here.
    (tmp_path / "cache" / "ra-token").unlink()

    run_once(closed_port_url())

    text = ini_path.read_text()
    assert "Token" not in text
    assert "Username" not in text
    assert "LoginTimestamp" not in text
    assert "Enabled = true" in text
    assert "RecentPath = /roms/x.chd" in text


def test_a_run_with_no_token_leaves_the_ppsspp_username_out_too(
    tmp_path: Path,
) -> None:
    # The asymmetry that gave the finding away: PPSSPP's token file was
    # already deleted when no token resolved, but the username key beside
    # it in ppsspp.ini was merely omitted, so it stayed on disk.
    token_file = tmp_path / "ppsspp_retroachievements.dat"
    files: dict[str, object] = {"ppsspp.ini": {"format": "ini", "keys": {}}}
    ra = retroachievements_namespace(
        tmp_path, closed_port_url(), [secret_file_target(token_file)]
    )

    assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    keys = cast("dict[str, object]", files["ppsspp.ini"])["keys"]
    achievements = cast("dict[str, object]", keys)["Achievements"]
    assert cast("dict[str, object]", achievements)["AchievementsUserName"] is ep.REMOVE


# --- A secret is read exactly as sops wrote it ----------------------------


def test_read_secret_keeps_whitespace_inside_a_password(tmp_path: Path) -> None:
    # Only the one newline sops appends is dropped. A password with a
    # leading or trailing space could never authenticate, and the failure
    # looked exactly like a rejection.
    path = tmp_path / "password"
    path.write_text("  hunter2  \n")

    assert ep._read_secret(path) == "  hunter2  "


def test_the_login_posts_a_password_with_its_whitespace_intact(
    tmp_path: Path,
) -> None:
    received: dict[str, list[str]] = {}

    class Handler(_QuietHandler):
        def do_POST(self) -> None:
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            received.update(
                urllib.parse.parse_qs(body.decode(), keep_blank_values=True)
            )
            payload = json.dumps({"Success": True, "Token": "tok"}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    with ra_server(Handler) as url:
        ra, _cache_file = ra_namespace(tmp_path, url)
        (tmp_path / "password").write_text(" hunter2 \n")

        assert ep.resolve_retroachievements_token(ra, tmp_path, timeout=5.0) is not None

    assert received["p"] == [" hunter2 "]


# --- Switching RetroAchievements off removes every credential -------------
#
# `enable = false` used to leave a stale username and a live bearer token
# sitting in every supporting emulator's config, PPSSPP's raw token file and
# the login cache - the same class of bug already fixed for the
# no-token-resolved case, just never applied to the disabled case at all
# (raDisabledFiles, modules/emulators, only ever forced `enabled`/`hardcore`
# off). These tests exercise the namespace's own `enabled: false` field
# instead - the `_apply_retroachievements_disabled_cleanup` path apply_retroachievements
# now takes when it is set.


def test_apply_rejects_a_non_boolean_enabled(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    files: dict[str, object] = {"retroarch.cfg": {"format": "retroarch", "keys": {}}}
    ra = retroachievements_namespace(
        tmp_path, closed_port_url(), [plain_target("retroarch", "retroarch.cfg")]
    )
    ra["enabled"] = "false"

    assert ep.apply_retroachievements(files, ra, tmp_path) == 1
    assert "enabled" in capsys.readouterr().err


def test_apply_disabled_removes_login_keys_but_leaves_enabled_and_hardcore_alone(
    tmp_path: Path,
) -> None:
    # Not touched here on purpose: `raDisabledFiles` already forces those
    # two off as ordinary static owned keys with no runtime step at all, so
    # writing them again from here would just be a second, redundant source
    # for the same fact.
    files: dict[str, object] = {
        "retroarch.cfg": {"format": "retroarch", "keys": {}},
        "Dolphin.ini": {"format": "ini", "keys": {}},
    }
    ra = retroachievements_namespace(
        tmp_path,
        closed_port_url(),
        [
            plain_target("retroarch", "retroarch.cfg"),
            ini_target("dolphin", "Dolphin.ini"),
        ],
    )
    ra["enabled"] = False

    assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    retroarch_keys = cast("dict[str, object]", files["retroarch.cfg"]["keys"])
    assert retroarch_keys["cheevos_username"] is ep.REMOVE
    assert retroarch_keys["cheevos_token"] is ep.REMOVE
    assert "cheevos_enable" not in retroarch_keys
    assert "cheevos_hardcore_mode_enable" not in retroarch_keys

    dolphin_section = cast("dict[str, object]", files["Dolphin.ini"]["keys"]["Cheevos"])
    assert dolphin_section["Username"] is ep.REMOVE
    assert dolphin_section["Token"] is ep.REMOVE
    assert "Enabled" not in dolphin_section
    assert "ChallengeMode" not in dolphin_section


def test_apply_disabled_deletes_the_secret_file_token_and_the_cache(
    tmp_path: Path,
) -> None:
    token_file = tmp_path / "ppsspp_retroachievements.dat"
    token_file.write_text("stale-token")
    cache_file = tmp_path / "cache" / "ra-token"
    cache_file.parent.mkdir()
    cache_file.write_text("stale-cache-token")

    files: dict[str, object] = {"ppsspp.ini": {"format": "ini", "keys": {}}}
    ra = retroachievements_namespace(
        tmp_path, closed_port_url(), [secret_file_target(token_file)]
    )
    ra["cache_file"] = str(cache_file)
    ra["enabled"] = False

    assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    assert not token_file.exists()
    assert not cache_file.exists()
    keys = cast("dict[str, object]", files["ppsspp.ini"]["keys"]["Achievements"])
    assert keys["AchievementsUserName"] is ep.REMOVE


def test_apply_disabled_prunes_the_directory_the_cache_lived_in(
    tmp_path: Path,
) -> None:
    # The cache has a directory to itself (`retroachievements/` under the
    # appdata root), so unlinking the file used to leave an empty directory
    # behind on every box with the feature switched off. Cosmetic, but the
    # box is meant to look like it never had the feature on.
    cache_file = tmp_path / "retroachievements" / "token-cache"
    cache_file.parent.mkdir()
    cache_file.write_text("stale-cache-token")

    files: dict[str, object] = {"retroarch.cfg": {"format": "retroarch", "keys": {}}}
    ra = retroachievements_namespace(
        tmp_path, closed_port_url(), [plain_target("retroarch", "retroarch.cfg")]
    )
    ra["cache_file"] = str(cache_file)
    ra["enabled"] = False

    assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    assert not cache_file.parent.exists()


def test_remove_credential_never_prunes_the_appdata_root(tmp_path: Path) -> None:
    # The pruning is for a directory the cache has to itself. `cache_file`
    # is configuration, though, and its type permits a bare filename - which
    # would put the cache directly in the appdata root and aim the `rmdir`
    # at `/data/es-de` itself. The root being empty was the only thing
    # standing in the way, and on a box with the feature switched off before
    # anything else has been written there, it is empty.
    root = tmp_path / "es-de"
    root.mkdir()
    cache_file = root / "token-cache"
    cache_file.write_text("stale-cache-token")

    ep._remove_credential(cache_file, prune_empty_parent_under=root)

    assert not cache_file.exists()
    assert root.is_dir()


def test_remove_credential_never_prunes_outside_the_appdata_root(
    tmp_path: Path,
) -> None:
    # The other half of the same rule: an absolute `cache_file` pointing
    # somewhere else entirely gets its file removed, but no directory this
    # program has no business in.
    root = tmp_path / "es-de"
    root.mkdir()
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    cache_file = elsewhere / "token-cache"
    cache_file.write_text("stale-cache-token")

    ep._remove_credential(cache_file, prune_empty_parent_under=root)

    assert not cache_file.exists()
    assert elsewhere.is_dir()


def test_apply_disabled_keeps_a_cache_directory_that_holds_anything_else(
    tmp_path: Path,
) -> None:
    # `rmdir` removes only an empty directory, which is what makes the
    # pruning above safe to run against a path the owned-values document
    # chose: anything else living there keeps its home.
    cache_file = tmp_path / "retroachievements" / "token-cache"
    cache_file.parent.mkdir()
    cache_file.write_text("stale-cache-token")
    neighbour = cache_file.parent / "someone-elses.dat"
    neighbour.write_text("not ours")

    files: dict[str, object] = {"retroarch.cfg": {"format": "retroarch", "keys": {}}}
    ra = retroachievements_namespace(
        tmp_path, closed_port_url(), [plain_target("retroarch", "retroarch.cfg")]
    )
    ra["cache_file"] = str(cache_file)
    ra["enabled"] = False

    assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    assert not cache_file.exists()
    assert neighbour.read_text() == "not ours"


def test_apply_disabled_stages_its_removals_and_says_nothing(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # What this one covers is the cleanup call itself: it stages REMOVE
    # entries into `files` and unlinks an absent token file, and neither of
    # those may print anything - the invariant that keeps a
    # permanently-disabled box's journal quiet. The keys really coming to
    # nothing happens downstream in the editors, so the box that never had
    # the feature enabled is covered end to end by
    # `test_main_disabled_on_a_never_enabled_box_writes_nothing_at_all`
    # rather than here.
    token_file = tmp_path / "ppsspp_retroachievements.dat"
    files: dict[str, object] = {
        "retroarch.cfg": {"format": "retroarch", "keys": {}},
        "ppsspp.ini": {"format": "ini", "keys": {}},
    }
    ra = retroachievements_namespace(
        tmp_path,
        closed_port_url(),
        [
            plain_target("retroarch", "retroarch.cfg"),
            secret_file_target(token_file),
        ],
    )
    ra["enabled"] = False

    assert ep.apply_retroachievements(files, ra, tmp_path) == 0

    assert not token_file.exists()
    assert capsys.readouterr().err == ""


def test_main_survives_a_credential_removal_it_cannot_write(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # `apply_retroachievements` only *stages* the removals into `files`; the
    # writes that take a credential off disk happen in the editor loop
    # below it, outside that call's blanket guard. An OSError there - /data
    # full, remounted read-only after a power cut, a directory that cannot
    # be written - escaped as a traceback and ended the session at the
    # greeter, which is exactly what design D2 forbids. Making the disabled
    # path do removals is what made it reachable on a disabled box, the
    # configuration nearly every real box is in.
    #
    # The read-only directory stands in for the read-only /data: nix runs
    # this suite as an unprivileged user, so the mode is enforced.
    appdata = tmp_path / "es-de"
    appdata.mkdir()
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(appdata))
    locked = appdata / "pcsx2"
    locked.mkdir()
    secrets = locked / "secrets.ini"
    secrets.write_text("[Achievements]\nUsername = alice\nToken = TOKENabc123\n")
    retroarch = appdata / "retroarch.cfg"
    retroarch.write_text('cheevos_username = "alice"\ncheevos_token = "TOKENabc123"\n')
    locked.chmod(0o500)

    ra = retroachievements_namespace(
        tmp_path,
        closed_port_url(),
        [
            ini_target("pcsx2", "pcsx2/secrets.ini", "Achievements"),
            plain_target("retroarch", "retroarch.cfg"),
        ],
    )
    ra["enabled"] = False
    values = tmp_path / "owned.json"
    values.write_text(
        json.dumps(
            {
                "files": {
                    "pcsx2/secrets.ini": {"format": "ini", "keys": {}},
                    "retroarch.cfg": {"format": "retroarch", "keys": {}},
                },
                "retroachievements": ra,
            }
        )
    )

    try:
        assert ep.main([str(values), ""]) == 0
    finally:
        locked.chmod(0o700)

    err = capsys.readouterr().err
    assert "pcsx2/secrets.ini could not be updated" in err
    assert "Traceback" not in err
    # The file that could be written still lost its credential: one
    # unwritable file costs that file's keys, not the family's evening.
    assert "TOKENabc123" not in retroarch.read_text()
    assert "TOKENabc123" in secrets.read_text()


def test_main_still_fails_the_session_on_a_malformed_document(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # The distinction the editor guard above must not blur, and which has
    # been broken once already: an unwritable file is a runtime condition
    # the box continues through, while a malformed owned-values document is
    # a broken call site the greeter is the correct answer to. Both
    # conditions are present here at once and the greeter still wins.
    appdata = tmp_path / "es-de"
    appdata.mkdir()
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(appdata))
    locked = appdata / "pcsx2"
    locked.mkdir()
    (locked / "secrets.ini").write_text("[Achievements]\nToken = TOKENabc123\n")
    locked.chmod(0o500)

    ra = retroachievements_namespace(
        tmp_path,
        closed_port_url(),
        [ini_target("pcsx2", "pcsx2/secrets.ini", "Achievements")],
    )
    ra["enabled"] = False
    del ra["api_url"]
    values = tmp_path / "owned.json"
    values.write_text(
        json.dumps(
            {
                "files": {"pcsx2/secrets.ini": {"format": "ini", "keys": {}}},
                "retroachievements": ra,
            }
        )
    )

    try:
        assert ep.main([str(values), ""]) == 1
    finally:
        locked.chmod(0o700)

    assert "api_url" in capsys.readouterr().err


def test_main_disabled_on_a_never_enabled_box_writes_nothing_at_all(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # The common case, end to end: RetroAchievements has never been on, so
    # not one of the files the cleanup stages removals into exists. Every
    # target shape is present - plain, ini, PCSX2's split across two files,
    # PPSSPP's whole-file token - and the run must create nothing, remove
    # nothing and print nothing, twice over. Asserted only indirectly
    # before this: the apply-level test above sees `files` gain REMOVE
    # entries, and it is the editors underneath it that turn those into
    # nothing at all.
    appdata = tmp_path / "es-de"
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(appdata))
    token_file = appdata / "ppsspp_retroachievements.dat"

    ra = retroachievements_namespace(
        tmp_path,
        closed_port_url(),
        [
            plain_target("retroarch", "retroarch.cfg"),
            ini_target("dolphin", "Dolphin.ini"),
            pcsx2_target(),
            secret_file_target(token_file),
        ],
    )
    ra["enabled"] = False
    values = tmp_path / "owned.json"
    values.write_text(
        json.dumps(
            {
                "files": {
                    "retroarch.cfg": {"format": "retroarch", "keys": {}},
                    "Dolphin.ini": {"format": "ini", "keys": {}},
                    "PCSX2.ini": {"format": "ini", "keys": {}},
                    "secrets.ini": {"format": "ini", "keys": {}},
                    "ppsspp.ini": {"format": "ini", "keys": {}},
                },
                "retroachievements": ra,
            }
        )
    )

    for _ in range(2):
        assert ep.main([str(values), ""]) == 0
        assert not appdata.exists(), sorted(appdata.rglob("*"))
        assert capsys.readouterr().err == ""


def test_main_disabled_attempts_no_login_at_all(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The spec's requirement for the disabled case is a negative one - no
    # login SHALL be attempted - and nothing asserted it. The end-to-end
    # test above points `main` at a live server, so a stray login would
    # succeed, write the cache, and have the cleanup delete it again,
    # leaving every visible assertion green; a reviewer's mutation that ran
    # the login before the cleanup and threw the result away was caught by
    # exactly one test, and only incidentally, because a closed port
    # printed a note. A quiet login attempt went undetected - while
    # spending the 5 s login budget on every launch of a box with the
    # feature off.
    #
    # So the server counts what it is asked, and the enabled run goes first
    # to prove the counter is not vacuous: a handler nothing ever reaches
    # would satisfy the disabled assertion for the wrong reason.
    appdata = tmp_path / "es-de"
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(appdata))
    requests: list[str] = []
    values = tmp_path / "owned.json"

    def write_document(*, enabled: bool, api_url: str) -> None:
        ra = retroachievements_namespace(
            tmp_path, api_url, [plain_target("retroarch", "retroarch.cfg")]
        )
        ra["enabled"] = enabled
        values.write_text(
            json.dumps(
                {
                    "files": {"retroarch.cfg": {"format": "retroarch", "keys": {}}},
                    "retroachievements": ra,
                }
            )
        )

    with ra_server(_counting_handler(requests)) as url:
        write_document(enabled=True, api_url=url)
        assert ep.main([str(values), ""]) == 0
        assert len(requests) == 1, requests
        assert 'cheevos_token = "tok-live"' in (appdata / "retroarch.cfg").read_text()

        write_document(enabled=False, api_url=url)
        assert ep.main([str(values), ""]) == 0

    assert requests == ["/dorequest.php"], requests
    assert "cheevos_token" not in (appdata / "retroarch.cfg").read_text()


def test_main_disabled_recreates_a_torn_secrets_file_without_the_live_token(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # The end-to-end shape of the unparseable-file finding, on the exact
    # file it bites: PCSX2's `secrets.ini` is the one owned file whose only
    # owned key on the disabled path is a removal, so it is the one file for
    # which "the parser said None" used to mean "write nothing" - and the
    # box is switched off at the wall, so one torn line in it is routine.
    # Before the fix these three runs each printed "recreating it" and each
    # left `Token = <live token>` exactly where it was.
    appdata = tmp_path / "es-de"
    appdata.mkdir()
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(appdata))
    secrets = appdata / "secrets.ini"
    secrets.write_text("[Achievements]\nTok\nToken = TOKENabc123DEADBEEF\n")

    ra = retroachievements_namespace(tmp_path, closed_port_url(), [pcsx2_target()])
    ra["enabled"] = False
    values = tmp_path / "owned.json"
    values.write_text(
        json.dumps(
            {
                "files": {
                    "PCSX2.ini": {"format": "ini", "keys": {}},
                    "secrets.ini": {"format": "ini", "keys": {}},
                },
                "retroachievements": ra,
            }
        )
    )

    assert ep.main([str(values), ""]) == 0

    assert "TOKENabc123DEADBEEF" not in secrets.read_text()
    assert "Token" not in secrets.read_text()
    capsys.readouterr()

    # And it settles: what the recreation wrote parses, so a disabled box
    # neither rewrites the file nor repeats the note on every later launch.
    freeze(secrets)
    assert ep.main([str(values), ""]) == 0
    assert unwritten(secrets)
    assert capsys.readouterr().err == ""


def test_main_enabled_then_disabled_removes_every_credential_and_stays_idempotent(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # The end-to-end shape of the finding: a real login through `main`
    # writes real credentials to real files, and switching the namespace to
    # `enabled: false` and running `main` again has to take every one of
    # them back off disk - and a THIRD run against that same disabled
    # document must change nothing at all, the idempotency property this
    # fix cares about most.
    appdata = tmp_path / "es-de"
    monkeypatch.setenv("ESDE_APPDATA_DIR", str(appdata))
    username_file = tmp_path / "username"
    password_file = tmp_path / "password"
    username_file.write_text("alice\n")
    password_file.write_text("hunter2\n")
    machine_id_file = tmp_path / "machine-id"
    machine_id_file.write_text("deadbeefdeadbeef\n")
    cache_file = tmp_path / "cache" / "ra-token"
    token_file = appdata / "ppsspp_retroachievements.dat"

    config_files = ["retroarch.cfg", "Dolphin.ini", "settings.ini", "ppsspp.ini"]

    def document(*, enabled: bool, api_url: str) -> dict[str, object]:
        return {
            "files": {
                name: {
                    "format": "retroarch" if name == "retroarch.cfg" else "ini",
                    "keys": {},
                }
                for name in config_files
            },
            "retroachievements": {
                "api_url": api_url,
                "username_file": str(username_file),
                "password_file": str(password_file),
                "cache_file": str(cache_file),
                "hardcore": False,
                "enabled": enabled,
                "targets": [
                    plain_target("retroarch", "retroarch.cfg"),
                    ini_target("dolphin", "Dolphin.ini"),
                    duckstation_target(machine_id_file, "settings.ini"),
                    secret_file_target(token_file),
                ],
            },
        }

    with ra_server(_json_handler(200, {"Success": True, "Token": "tok-live"})) as url:
        values = tmp_path / "owned.json"
        values.write_text(json.dumps(document(enabled=True, api_url=url)))
        assert ep.main([str(values), ""]) == 0

        # Sanity: the credentials are genuinely on disk before disabling.
        assert 'cheevos_username = "alice"' in (appdata / "retroarch.cfg").read_text()
        assert "Username = alice" in (appdata / "Dolphin.ini").read_text()
        assert "Username = alice" in (appdata / "settings.ini").read_text()
        assert "LoginTimestamp" in (appdata / "settings.ini").read_text()
        assert token_file.read_text() == "tok-live"
        assert cache_file.exists()

        values.write_text(json.dumps(document(enabled=False, api_url=url)))
        assert ep.main([str(values), ""]) == 0

    retroarch_text = (appdata / "retroarch.cfg").read_text()
    assert "cheevos_username" not in retroarch_text
    assert "cheevos_token" not in retroarch_text
    dolphin_text = (appdata / "Dolphin.ini").read_text()
    assert "Username" not in dolphin_text
    assert "Token" not in dolphin_text
    duckstation_text = (appdata / "settings.ini").read_text()
    assert "Username" not in duckstation_text
    assert "Token" not in duckstation_text
    assert "LoginTimestamp" not in duckstation_text
    assert not token_file.exists()
    assert not cache_file.exists()

    # Idempotency: freeze every file this run touched (or removed), run the
    # same disabled document through `main` a second time, and confirm
    # nothing was rewritten and neither deleted file came back.
    for name in config_files:
        freeze(appdata / name)

    assert ep.main([str(values), ""]) == 0

    for name in config_files:
        assert unwritten(appdata / name), name
    assert not token_file.exists()
    assert not cache_file.exists()


# --- Reading a flat file through one INI library ---------------------------
#
# Both flat editors read every file through a synthetic section header that
# the dump strips again, so a headerless RetroArch config and an INI file
# whose first assignment sits above every header are both editable by a
# sectioned-INI library. The library's idea of an unparseable file is not
# this program's, and the gap goes both ways: a shape it accepts where this
# program recreated costs nothing, but a shape it *names differently* narrows
# the recreate path and strands a live bearer token on disk. The tests below
# pin each of those seams to the mechanism that closes it.

WRAPPER = ep._FLAT_WRAPPER_SECTION


def load(text: str, *, ini: bool = True) -> ep.ConfigUpdater:
    return ep._load_flat(text, ini=ini)


def round_trip(text: str, *, ini: bool = True) -> str:
    return ep._dump_flat(load(text, ini=ini))


def test_flat_round_trip_is_byte_identical_for_a_file_starting_with_a_header() -> None:
    # An unedited round trip is not the contract - an edited file promises
    # only that no unowned setting changed - but it is free, and it is what
    # says the synthetic header leaves no blank line where it stood.
    text = "# written by the emulator\n[Interface]\nLanguage = 0\n\n[Display]\nFullscreen = False\n"

    assert round_trip(text) == text


def test_flat_round_trip_is_byte_identical_for_a_file_with_a_preamble() -> None:
    # The shape the library rejects outright with MissingSectionHeaderError,
    # and the reason the wrapper exists at all for an INI file.
    text = "Token = stray\n; a comment\n[Achievements]\nUsername = alice\n"

    assert round_trip(text) == text


def test_flat_round_trip_keeps_a_trailing_run_of_blank_lines() -> None:
    text = '# RetroArch config\nvideo_fullscreen = "true"\n\n\n'

    assert round_trip(text, ini=False) == text


# A final line with no terminating newline.


def test_ini_appending_a_key_to_an_unterminated_file_keeps_the_last_line(
    tmp_path: Path,
) -> None:
    # The library stores each block's raw text including its terminator, so
    # an unterminated last option has none and a new option is written
    # straight onto the end of it: `Token = xNew = y`, which destroys the
    # unowned assignment and the owned key together and which the next run
    # reads back as a healthy setting. An unterminated last line is what a
    # power cut leaves.
    path = tmp_path / "settings.ini"
    path.write_text("[Achievements]\nToken = keepme")

    assert ep.set_ini_settings(path, {"Achievements": {"Username": "alice"}}) is True

    lines = path.read_text().split("\n")
    assert "Token = keepme" in lines
    assert "Username = alice" in lines


def test_retroarch_appending_a_key_to_an_unterminated_file_keeps_the_last_line(
    tmp_path: Path,
) -> None:
    path = tmp_path / "retroarch.cfg"
    path.write_text('cheevos_token = "keepme"')

    assert ep.set_retroarch_settings(path, {"cheevos_username": "alice"}) is True

    lines = path.read_text().split("\n")
    assert 'cheevos_token = "keepme"' in lines
    assert 'cheevos_username = "alice"' in lines


# An indented line, which a configparser-family parser reads as a
# continuation of the option above it and which therefore disappears on the
# next write. Each case changes an owned value in the same run, since that is
# when an unstripped helper destroys the line.


def test_ini_keeps_an_indented_comment_through_a_write(tmp_path: Path) -> None:
    path = tmp_path / "Dolphin.ini"
    path.write_text("[Interface]\nConfirmStop = True\n  # note\nKeepMe = 3\n")

    assert ep.set_ini_settings(path, INI_OWNED) is True

    text = path.read_text()
    assert "# note" in text
    assert "KeepMe = 3" in text
    assert "ConfirmStop = False" in text


def test_ini_keeps_an_indented_assignment_through_a_write(tmp_path: Path) -> None:
    path = tmp_path / "Dolphin.ini"
    path.write_text("[Interface]\nConfirmStop = True\n  Indented = 9\nKeepMe = 3\n")

    assert ep.set_ini_settings(path, INI_OWNED) is True

    text = path.read_text()
    assert "Indented = 9" in text
    assert "KeepMe = 3" in text
    assert "ConfirmStop = False" in text


def test_ini_keeps_an_indented_section_header_through_a_write(tmp_path: Path) -> None:
    # The header this program's own section grammar already accepts, since it
    # is anchored `^\s*\[`: the keys below it belong to `Later`, not to the
    # section above.
    path = tmp_path / "Dolphin.ini"
    path.write_text("[Interface]\nConfirmStop = True\n  [Later]\nKeepMe = 3\n")

    assert ep.set_ini_settings(path, INI_OWNED) is True

    text = path.read_text()
    assert "[Later]" in text
    assert "KeepMe = 3" in text.split("[Later]", 1)[1]
    assert "ConfirmStop = False" in text


def test_flat_documents_read_an_indented_line_as_a_value_continuation() -> None:
    # Why the stripping above exists, stated against the library rather than
    # against a file: left indented, this line is not a line at all but the
    # tail of the value above it, and writing that option renders the file
    # without it.
    document = ep._flat_document(ini=True)
    document.read_string(f"[{WRAPPER}]\n[A]\nkey = 1\n    continued\n")

    assert document["A"]["key"].value == "1\ncontinued"


@pytest.mark.parametrize("indent", [" ", "\t", "\x0b", "\x0c", "\xa0", "\u3000"])
def test_ini_keeps_a_line_indented_by_any_whitespace(
    tmp_path: Path, indent: str
) -> None:
    # Every whitespace character the parser counts as indentation, not just
    # the two an ASCII file uses. A gap here is not cosmetic: the parser
    # strips the whole line before deciding whether it is a section header,
    # so a character stripped there and kept here is one that hides a header
    # from the checks below while the library still reads one.
    path = tmp_path / "Dolphin.ini"
    path.write_text(f"[Interface]\nConfirmStop = True\n{indent}KeepMe = 3\n")

    assert ep.set_ini_settings(path, INI_OWNED) is True

    text = path.read_text()
    assert "KeepMe = 3" in text
    assert "ConfirmStop = False" in text


@pytest.mark.parametrize("indent", ["\x0c", "\xa0", "\u3000"])
def test_ini_removes_a_token_under_a_header_indented_by_exotic_whitespace(
    tmp_path: Path, indent: str
) -> None:
    # The credential path, through the same gap. The parser strips the whole
    # line before matching a section header, so a header indented by anything
    # this program does not strip is still a section to the library while the
    # bracket test never examines it - the removal sweeps a section the file
    # does not appear to have, the document parses cleanly so nothing is
    # recreated, and the token stays on disk on this launch and every launch
    # after it.
    path = tmp_path / "secrets.ini"
    path.write_text(f"{indent}[Achievements] ; was [Cheevos]\nToken = TOKENlive\n")

    assert ep.set_ini_settings(path, {"Achievements": {"Token": ep.REMOVE}}) is True

    assert "TOKENlive" not in path.read_text()


# A bracketed line the library names differently than this program
# does. This is the credential path: where the two grammars disagree about a
# section's *name*, a removal loop over the declared section finds nothing,
# the document parses cleanly so no recreation fires, and a live token
# survives every launch after.

RA_SECRET = {"Achievements": {"Token": ep.REMOVE}}


def test_ini_normalises_a_header_whose_trailing_comment_carries_a_bracket(
    tmp_path: Path,
) -> None:
    # The library's section grammar is greedy to the last `]`, so it names
    # this section `Achievements] ; was [Cheevos` while this program names it
    # `Achievements`. Refusing it would recreate a file this program can edit
    # and cost every unowned setting in it; normalising costs the header's
    # own trailing comment, which no emulator reads.
    path = tmp_path / "secrets.ini"
    path.write_text(
        "[Achievements] ; was [Cheevos]\nToken = TOKENlive\nUserPref = keepme\n"
    )

    assert ep.set_ini_settings(path, RA_SECRET) is True

    text = path.read_text()
    assert "TOKENlive" not in text
    assert "UserPref = keepme" in text


def test_ini_normalises_a_header_whose_hash_comment_carries_a_bracket(
    tmp_path: Path,
) -> None:
    path = tmp_path / "secrets.ini"
    path.write_text(
        "[Achievements] # old [name]\nToken = TOKENlive\nUserPref = keepme\n"
    )

    assert ep.set_ini_settings(path, RA_SECRET) is True

    text = path.read_text()
    assert "TOKENlive" not in text
    assert "UserPref = keepme" in text


@pytest.mark.parametrize(
    "header", ["[Achievements] [was Cheevos]", "[Achievements][x]"]
)
def test_ini_recreates_a_header_only_the_library_reads(
    tmp_path: Path, header: str
) -> None:
    # Both grammars read a header here, under names that cannot be reconciled
    # by normalising, so the file takes the recreate path - which is what it
    # does today, and which is what takes the token off the disk.
    path = tmp_path / "secrets.ini"
    path.write_text(f"{header}\nToken = TOKENlive\n")

    assert ep.set_ini_settings(path, RA_SECRET) is True

    assert "TOKENlive" not in path.read_text()


@pytest.mark.parametrize("header", ["[]", "[] ; c"])
def test_ini_recreates_a_file_with_an_empty_section_name(
    tmp_path: Path, header: str
) -> None:
    # The library reads no header here, so the line reaches the parser and
    # raises. Better than it used to fare: this program's own grammar matched
    # `[]` with an empty name that never equalled the owned section, so the
    # token stranded on disk through every launch.
    path = tmp_path / "secrets.ini"
    path.write_text(f"{header}\nToken = TOKENlive\n")

    assert ep.set_ini_settings(path, RA_SECRET) is True

    assert "TOKENlive" not in path.read_text()


def test_ini_keeps_a_bracketed_line_neither_grammar_reads_as_a_header(
    tmp_path: Path,
) -> None:
    # `[foo bar = baz` is an ordinary option named `[foo bar` to the library
    # and to this program alike, and it stays one. A guard that refused every
    # bracketed line would destroy a file this program preserves.
    path = tmp_path / "secrets.ini"
    path.write_text("[Achievements]\nToken = TOKENlive\n[foo bar = baz\n")

    assert ep.set_ini_settings(path, RA_SECRET) is True

    text = path.read_text()
    assert "TOKENlive" not in text
    assert "[foo bar = baz" in text


@pytest.mark.parametrize("header", ["[Achievements]", "[Achievements] ; plain comment"])
def test_ini_edits_an_ordinary_header_in_place(tmp_path: Path, header: str) -> None:
    path = tmp_path / "secrets.ini"
    path.write_text(f"{header}\nToken = TOKENlive\nUserPref = keepme\n")

    assert ep.set_ini_settings(path, RA_SECRET) is True

    text = path.read_text()
    assert "TOKENlive" not in text
    assert "UserPref = keepme" in text
    assert header in text


def test_retroarch_recreates_a_file_carrying_a_section_header(tmp_path: Path) -> None:
    # RetroArch's own parser rejects every line without an `=`, so its files
    # have no headers at all. Left alone, a bracketed line would partition
    # the file and make everything below it invisible to both the removal and
    # the write sweeps, so a stale token would survive while the editor
    # reported the file correct.
    path = tmp_path / "retroarch.cfg"
    path.write_text('video_fullscreen = "true"\n[Foo]\ncheevos_token = "TOKENlive"\n')

    assert ep.set_retroarch_settings(path, {"cheevos_token": ep.REMOVE}) is True

    assert "TOKENlive" not in path.read_text()


def test_retroarch_recreates_a_bracketed_line_carrying_an_assignment(
    tmp_path: Path,
) -> None:
    path = tmp_path / "retroarch.cfg"
    path.write_text('[something] = "x"\ncheevos_token = "TOKENlive"\n')

    assert ep.set_retroarch_settings(path, {"cheevos_token": ep.REMOVE}) is True

    assert "TOKENlive" not in path.read_text()


# A file already carrying the wrapper's own header. Two same-named
# sections, lookup resolves to the wrapper, the file's real keys go invisible
# and stripping the leading line leaves the other header standing in what is
# written. The sentinel cannot be made unspellable - every newline-free
# string is a legal header name - so refusing is the whole of the defence.

SENTINEL_SPELLINGS = [
    f"[{WRAPPER}]",
    f"  [{WRAPPER}]",
    f"[{WRAPPER}] ; a comment",
    f"[{WRAPPER}] extra",
    f"[{WRAPPER}] = 3",
    # The spelling only a check that runs *after* the header normalisation
    # catches: the library's greedy grammar names this `<wrapper>] ; [x` in
    # the source text, so a check over the raw text passes it, and the
    # normalisation then mints the exact canonical line this rule exists to
    # refuse.
    f"[{WRAPPER}] ; [x]",
]


@pytest.mark.parametrize("spelling", SENTINEL_SPELLINGS)
def test_ini_recreates_a_file_spelling_the_wrapper_header(
    tmp_path: Path, spelling: str
) -> None:
    path = tmp_path / "secrets.ini"
    path.write_text(f"{spelling}\nToken = TOKENlive\n")

    assert ep.set_ini_settings(path, RA_SECRET) is True

    text = path.read_text()
    assert "TOKENlive" not in text
    assert WRAPPER not in text


@pytest.mark.parametrize("spelling", SENTINEL_SPELLINGS)
def test_retroarch_recreates_a_file_spelling_the_wrapper_header(
    tmp_path: Path, spelling: str
) -> None:
    path = tmp_path / "retroarch.cfg"
    path.write_text(f'{spelling}\ncheevos_token = "TOKENlive"\n')

    assert ep.set_retroarch_settings(path, {"cheevos_token": ep.REMOVE}) is True

    text = path.read_text()
    assert "TOKENlive" not in text
    assert WRAPPER not in text


def test_a_naive_substring_check_would_not_catch_the_normalised_spelling() -> None:
    # What makes the ordering load-bearing rather than incidental: the
    # canonical wrapper line is absent from this source text and present
    # after the header normalisation runs.
    source = f"[{WRAPPER}] ; [x]\nToken = live\n"

    assert f"[{WRAPPER}]\n" not in source
    with pytest.raises(ep._Unparseable):
        load(source)


# An empty or whitespace-only file. INI only, matching RetroArch's
# own parser, which has never had an emptiness check. Reported *silently*, so
# `set_ini_settings` keeps its own deferred note and emits it only once a
# write is confirmed.


@pytest.mark.parametrize("text", ["", "\n", "   \n"])
def test_flat_reports_an_empty_ini_unparseable_without_a_word(
    text: str, capsys: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(ep._Unparseable) as refused:
        load(text)

    assert refused.value.reason is None
    assert capsys.readouterr().err == ""


@pytest.mark.parametrize("text", ["", "\n", "   \n"])
def test_ini_recreates_a_whitespace_only_file_with_its_own_note(
    tmp_path: Path, text: str, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "settings.ini"
    path.write_text(text)

    assert ep.set_ini_settings(path, INI_OWNED) is True

    assert "Fullscreen = True" in path.read_text()
    assert "is empty; recreating it" in capsys.readouterr().err


def test_flat_reads_an_empty_retroarch_file_as_a_document() -> None:
    assert ep._dump_flat(load("", ini=False)) == ""


# The library's own parse failures. `main`'s editor loop guards
# `except OSError` only and the kiosk session runs this program unguarded
# under `set -e` with an EXIT trap that ends at the greeter, so an escaping
# parse error would end the family's evening rather than recreate a file.
# Each case asserts the editor recreates the file carrying every owned value,
# not merely that it returned - a helper that swallowed the exception and
# gave up would satisfy the weaker claim while leaving the file valueless.


@pytest.mark.parametrize(
    "line",
    [
        # A `key: value` line, which the library's default delimiters would
        # have made an ordinary option.
        "Time: 12",
        "barekeywithnoassignment",
        "= value",
    ],
)
def test_ini_recreates_a_file_the_library_cannot_parse(
    tmp_path: Path, line: str, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "Dolphin.ini"
    path.write_text(f"[Interface]\nConfirmStop = True\n{line}\n")

    assert ep.set_ini_settings(path, INI_OWNED) is True

    text = path.read_text()
    assert "ConfirmStop = False" in text
    assert "Fullscreen = True" in text
    assert line not in text
    assert "not a setting" in capsys.readouterr().err


@pytest.mark.parametrize("line", ["Time: 12", "barekeywithnoassignment", "= value"])
def test_retroarch_recreates_a_file_the_library_cannot_parse(
    tmp_path: Path, line: str, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "retroarch.cfg"
    path.write_text(f'menu_driver = "rgui"\n{line}\n')

    assert ep.set_retroarch_settings(path, RA_OWNED) is True

    text = path.read_text()
    assert 'menu_driver = "ozone"' in text
    assert 'video_fullscreen = "true"' in text
    assert line not in text
    assert "not a setting" in capsys.readouterr().err


# --- The two library behaviours the editors are built around ---------------


def test_flat_lookup_does_not_fold_a_key_to_lower_case() -> None:
    # Left at the library's default, option names are lower-cased, and every
    # key this program owns is spelled with capitals. The consequence is a
    # lookup one: `"Username" in section` would be False for a file spelling
    # the key `Username` while `section["Username"]` resolved to the folded
    # option, so a sweep written as `while key in section` would never run
    # and the editor would append a second credential beside the stale one.
    # A written key's declared case is preserved either way, so rendering
    # pins nothing and is deliberately not the criterion here.
    section = load("[Achievements]\nUsername = capital\nusername = lower\n")[
        "Achievements"
    ]

    assert "Username" in section
    assert section["Username"].value == "capital"
    assert section["username"].value == "lower"
    assert section.options() == ["Username", "username"]


def test_flat_deleting_a_repeated_key_leaves_the_second_assignment() -> None:
    # Why both sweeps are loops. It reads as though it should be idempotent
    # and is not.
    section = load("[Achievements]\ntoken = one\ntoken = two\n")["Achievements"]

    del section["token"]

    assert "token" in section
    assert section["token"].value == "two"


# --- The wrapper header never reaches a file this program writes -----------


def ini_written(path: Path, source: str | None) -> str:
    if source is not None:
        path.write_text(source)
    ep.set_ini_settings(
        path, {"Achievements": {"Username": "alice", "Token": ep.REMOVE}}
    )
    return path.read_text()


def retroarch_written(path: Path, source: str | None) -> str:
    if source is not None:
        path.write_text(source)
    ep.set_retroarch_settings(
        path, {"cheevos_username": "alice", "cheevos_token": ep.REMOVE}
    )
    return path.read_text()


@pytest.mark.parametrize(
    "source",
    [
        # Fresh: no file at all.
        None,
        # Edited in place.
        "[Achievements]\nToken = TOKENlive\nUserPref = keepme\n",
        # Recreated, because the line is not a setting.
        "[Achievements]\ntorn\nToken = TOKENlive\n",
        # Recreated because the file already carries the wrapper's header...
        f"[{WRAPPER}]\nToken = TOKENlive\n",
        # ...including the spelling only the post-normalisation check sees.
        f"[{WRAPPER}] ; [x]\nToken = TOKENlive\n",
    ],
)
def test_no_ini_this_program_writes_carries_the_wrapper_header(
    tmp_path: Path, source: str | None
) -> None:
    assert WRAPPER not in ini_written(tmp_path / "settings.ini", source)


@pytest.mark.parametrize(
    "source",
    [
        None,
        'cheevos_token = "TOKENlive"\nvideo_fullscreen = "true"\n',
        'torn line with no separator\ncheevos_token = "TOKENlive"\n',
        f'[{WRAPPER}]\ncheevos_token = "TOKENlive"\n',
        f'[{WRAPPER}] ; [x]\ncheevos_token = "TOKENlive"\n',
    ],
)
def test_no_retroarch_file_this_program_writes_carries_the_wrapper_header(
    tmp_path: Path, source: str | None
) -> None:
    assert WRAPPER not in retroarch_written(tmp_path / "retroarch.cfg", source)


def test_an_all_removals_pass_writes_no_wrapper_header(tmp_path: Path) -> None:
    # The branch the parameterisations above cannot reach: every owned key is
    # a removal, so the recreation writes a file with nothing in it.
    path = tmp_path / "secrets.ini"
    path.write_text("[Achievements]\ntorn\nToken = TOKENlive\n")

    assert ep.set_ini_settings(path, RA_SECRET) is True

    text = path.read_text()
    assert "TOKENlive" not in text
    assert WRAPPER not in text


# --- What the editors promise about a file they did not write --------------
#
# The contract is semantic equivalence for the emulator that reads the file:
# every setting it reads keeps its key, its value and its section, and every
# one of its assignments where it repeats, except the keys the flake owns.
# Presentation the emulator cannot observe - the spacing around a delimiter,
# where a line sits within its section, whether a comment survives an edit to
# the line it trails - is deliberately not asserted below, because it is not
# promised and pinning it would buy back the line arithmetic these editors
# were written to stop carrying. Line terminators are not asserted either:
# `Path.read_text` folds CRLF to LF before any of this runs.


def ini_settings(path: Path) -> list[tuple[str | None, str, str]]:
    """Every (section, key, value) an INI reader sees, in file order."""
    section: str | None = None
    found: list[tuple[str | None, str, str]] = []
    for line in path.read_text().split("\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith(("#", ";")):
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped[1:-1]
            continue
        key, separator, value = line.partition("=")
        if separator:
            found.append((section, key.strip(), value.strip()))
    return found


def retroarch_settings(path: Path) -> list[tuple[str, str]]:
    """Every (key, value) a RetroArch reader sees, in file order."""
    found: list[tuple[str, str]] = []
    for line in path.read_text().split("\n"):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if separator:
            found.append((key.strip(), value.strip()))
    return found


def unowned_ini(
    path: Path, owned: set[tuple[str, str]]
) -> list[tuple[str | None, str, str]]:
    return [entry for entry in ini_settings(path) if entry[:2] not in owned]


# The shape of Azahar's `qt-config.ini`: the one genuinely QSettings-written
# file among the eight ini targets, so the only one whose spaceless
# assignments a rewrite would visibly renormalise - and QSettings rewrites
# the whole file whenever Azahar saves, so an unconditional assignment would
# mean the two of them taking turns before every launch, forever.
AZAHAR = (
    "[UI]\n"
    "firstStart=false\n"
    "fullscreen\\default=true\n"
    "confirmClose=true\n"
    "[Renderer]\n"
    "resolution_factor=1\n"
)
AZAHAR_OWNED: dict[str, dict[str, str | ep.Removal]] = {
    "UI": {"firstStart": "false", "fullscreen\\default": "true"}
}

# The shape of `scummvm.ini`, the other spaceless writer among the eight,
# transcribed from a file ScummVM itself wrote: a blank line between section
# blocks, spaceless assignments, no comments anywhere, and a value carrying
# trailing spaces, which the editor may not tidy away any more than it may
# tidy away the value itself.
SCUMMVM = (
    "[scummvm]\n"
    "versioninfo=2026.1.0\n"
    "gui_theme=scummmodern\n"
    "fullscreen=true\n"
    "\n"
    "[monkey2]\n"
    "gameid=monkey2\n"
    "description=Monkey Island 2: LeChuck's Revenge\n"
    "path=/data/roms/scummvm/monkey2\n"
    "guioptions=sndNoSpeech ega midiPCSpk midiAdLib vga  \n"
)
SCUMMVM_OWNED: dict[str, dict[str, str | ep.Removal]] = {
    "scummvm": {"fullscreen": "true"}
}


@pytest.mark.parametrize(
    ("source", "owned"), [(AZAHAR, AZAHAR_OWNED), (SCUMMVM, SCUMMVM_OWNED)]
)
def test_ini_leaves_a_spaceless_file_holding_the_flake_values_unwritten(
    tmp_path: Path,
    source: str,
    owned: dict[str, dict[str, str | ep.Removal]],
) -> None:
    # The flash-write guard, not a formatting one. Both runs must be silent:
    # a first run that rewrote the file to respace it would leave the second
    # with nothing to do and pass a weaker version of this test.
    path = tmp_path / "qt-config.ini"
    path.write_text(source)
    freeze(path)

    assert ep.set_ini_settings(path, owned) is False
    assert unwritten(path)

    assert ep.set_ini_settings(path, owned) is False
    assert unwritten(path)


def test_ini_reduces_a_key_repeated_inside_one_section_instance(
    tmp_path: Path,
) -> None:
    # The third shape a repeat takes, and the one the line arithmetic never
    # handled: assigning to a section that already carries the key twice
    # edits the first line and leaves the second standing, so the file held
    # the flake's value while the emulator read the stale copy below it.
    path = tmp_path / "settings.ini"
    path.write_text(
        "[Achievements]\nUsername = stale-one\nUsername = stale-two\nKeepMe = yes\n"
    )

    assert ep.set_ini_settings(path, {"Achievements": {"Username": "correct"}}) is True

    settings = ini_settings(path)
    assert [e for e in settings if e[1] == "Username"] == [
        ("Achievements", "Username", "correct")
    ]
    assert ("Achievements", "KeepMe", "yes") in settings

    freeze(path)
    assert ep.set_ini_settings(path, {"Achievements": {"Username": "correct"}}) is False
    assert unwritten(path)


def test_ini_reduces_a_preamble_twin_when_the_section_is_absent(
    tmp_path: Path,
) -> None:
    # The live edge in the shape between the headerless region and a section:
    # with the owned section absent from the file entirely, the old sweep
    # found no bounds and stopped, so a write appended the fresh section and
    # left the preamble twin standing. The emulator read the stale value for
    # one launch, and the next run swept the twin and wrote again.
    path = tmp_path / "settings.ini"
    path.write_text("Username = stale\nUnowned = keepme\n")

    assert ep.set_ini_settings(path, {"Achievements": {"Username": "correct"}}) is True

    settings = ini_settings(path)
    assert [entry for entry in settings if entry[1] == "Username"] == [
        ("Achievements", "Username", "correct")
    ]
    assert (None, "Unowned", "keepme") in settings

    freeze(path)
    assert ep.set_ini_settings(path, {"Achievements": {"Username": "correct"}}) is False
    assert unwritten(path)


def test_ini_keeps_every_assignment_of_a_key_the_flake_does_not_own(
    tmp_path: Path,
) -> None:
    # Which of a repeated unowned key's assignments the emulator obeys is not
    # this program's to decide; losing one of them is a setting disappearing,
    # which the contract does not permit. The owned-key sweeps are duplicate
    # aware by design, so the hazard is one of them reaching too far.
    path = tmp_path / "settings.ini"
    path.write_text(
        "[Achievements]\n"
        "Username = stale\n"
        "Unowned = first\n"
        "Unowned = second\n"
        "[Elsewhere]\n"
        "Unowned = third\n"
    )

    assert ep.set_ini_settings(path, {"Achievements": {"Username": "correct"}}) is True

    settings = ini_settings(path)
    assert [entry for entry in settings if entry[1] == "Unowned"] == [
        ("Achievements", "Unowned", "first"),
        ("Achievements", "Unowned", "second"),
        ("Elsewhere", "Unowned", "third"),
    ]


# A file that is merely awkward is still edited in place rather than
# recreated: recreation rewrites the file with only the owned keys in it, so
# it costs every unowned setting the emulator was reading.


def test_ini_edits_a_file_with_a_duplicated_section_header_in_place(
    tmp_path: Path,
) -> None:
    path = tmp_path / "Dolphin.ini"
    path.write_text(
        "[Interface]\nConfirmStop = True\nKeepMe = yes\n[Interface]\nAlso = kept\n"
    )

    assert ep.set_ini_settings(path, INI_OWNED) is True

    text = path.read_text()
    assert "KeepMe = yes" in text
    assert "Also = kept" in text


def test_ini_edits_a_file_with_a_headerless_preamble_in_place(tmp_path: Path) -> None:
    path = tmp_path / "Dolphin.ini"
    path.write_text("Orphan = kept\n[Interface]\nConfirmStop = True\n")

    assert ep.set_ini_settings(path, INI_OWNED) is True

    text = path.read_text()
    assert "Orphan = kept" in text
    assert "ConfirmStop = False" in text


# The mutate-and-serialise path itself, which nothing pinned before: an edit
# is where the library rewrites blocks, so it is where an unowned setting can
# be lost or reattributed.

MIXED = (
    "# written by the emulator\n"
    "Preamble = above\n"
    "[Interface]\n"
    "Language = 0\n"
    "ConfirmStop = True\n"
    "Repeated = one\n"
    "Repeated = two\n"
    "; a trailing comment\n"
    "[Display]\n"
    "RenderToMain = True\n"
    "[Other]\n"
    "Fullscreen = someone-elses\n"
)
MIXED_OWNED_NAMES = {("Interface", "ConfirmStop"), ("Display", "Fullscreen")}


@pytest.mark.parametrize(
    ("owned", "wrote"),
    [
        # Changing a value that is already in the file.
        ({"Interface": {"ConfirmStop": "False"}}, True),
        # Appending an owned key its section does not carry yet.
        ({"Display": {"Fullscreen": "True"}}, True),
        # The removal path, which runs the same machinery and is where a
        # credential comes off the box.
        ({"Interface": {"ConfirmStop": ep.REMOVE}}, True),
    ],
)
def test_ini_keeps_every_unowned_setting_through_an_edit(
    tmp_path: Path,
    owned: dict[str, dict[str, str | ep.Removal]],
    wrote: bool,
) -> None:
    path = tmp_path / "Dolphin.ini"
    path.write_text(MIXED)
    before = unowned_ini(path, MIXED_OWNED_NAMES)

    assert ep.set_ini_settings(path, owned) is wrote

    assert unowned_ini(path, MIXED_OWNED_NAMES) == before


def test_ini_keeps_the_previous_line_intact_when_seeding_into_an_unterminated_file(
    tmp_path: Path,
) -> None:
    path = tmp_path / "Dolphin.ini"
    path.write_text("[Interface]\nConfirmStop = False\n[Display]\nRenderToMain = True")

    assert ep.set_ini_settings(path, INI_OWNED) is True

    settings = ini_settings(path)
    assert ("Display", "RenderToMain", "True") in settings
    assert ("Display", "Fullscreen", "True") in settings


# --- The probe behind DuckStation's login timestamp ------------------------
#
# Not an editor: it reads one key to decide whether a newly encrypted token
# differs from the one on disk, so that an unchanged token does not rewrite
# `login_timestamp` on every launch. It runs before this program has decided
# to write anything, so every way it can fail to find a value has to be
# silent - a recreation notice here would announce something that is not
# happening.


def test_the_ini_probe_is_silent_about_a_missing_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert (
        ep._current_ini_value(tmp_path / "absent.ini", "Achievements", "Token") is None
    )
    assert capsys.readouterr().err == ""


def test_the_ini_probe_is_silent_about_an_unreadable_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "settings.ini"
    path.write_bytes(b"[Achievements]\nToken = \xff\xfe\n")

    assert ep._current_ini_value(path, "Achievements", "Token") is None
    assert capsys.readouterr().err == ""


def test_the_ini_probe_is_silent_about_an_unparseable_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # The fifth answer of None, gained because the shared load helper
    # validates where the old quiet read did not. It reads as "the token
    # changed" and rewrites `login_timestamp` once, which is right for a file
    # the editor is about to recreate anyway.
    path = tmp_path / "settings.ini"
    path.write_text("[Achievements]\ntorn\nToken = live\n")

    assert ep._current_ini_value(path, "Achievements", "Token") is None
    assert capsys.readouterr().err == ""


def test_the_ini_probe_is_silent_about_a_missing_section(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "settings.ini"
    path.write_text("[Elsewhere]\nToken = not-ours\n")

    assert ep._current_ini_value(path, "Achievements", "Token") is None
    assert capsys.readouterr().err == ""


def test_the_ini_probe_is_silent_about_a_missing_key(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "settings.ini"
    path.write_text("[Achievements]\nUsername = alice\n")

    assert ep._current_ini_value(path, "Achievements", "Token") is None
    assert capsys.readouterr().err == ""


def test_the_ini_probe_reads_the_value_that_is_there(tmp_path: Path) -> None:
    path = tmp_path / "settings.ini"
    path.write_text("[Achievements]\nToken=  spaced  \n")

    assert ep._current_ini_value(path, "Achievements", "Token") == "spaced"


# --- RetroArch's flat file, under the same contract ------------------------

RA_MIXED = (
    "# RetroArch config\n"
    'input_driver = "sdl"\n'
    'menu_driver = "rgui"\n'
    'repeated = "one"\n'
    'repeated = "two"\n'
)
RA_MIXED_OWNED_NAMES = {"menu_driver", "video_fullscreen"}


def test_retroarch_reduces_a_key_repeated_in_the_flat_file(tmp_path: Path) -> None:
    # The whole file is one section here, so there is no second instance and
    # no separate headerless region: a repeat is a repeated line and nothing
    # else. Iterating to absence would delete every copy and append one back,
    # leaving the bytes identical but the change flag set, so `retroarch.cfg`
    # would be written to flash before every launch, forever.
    path = tmp_path / "retroarch.cfg"
    path.write_text(
        'cheevos_username = "one"\nkeepme = "yes"\ncheevos_username = "two"\n'
    )

    assert ep.set_retroarch_settings(path, {"cheevos_username": "correct"}) is True

    settings = retroarch_settings(path)
    assert [v for k, v in settings if k == "cheevos_username"] == ['"correct"']
    assert ("keepme", '"yes"') in settings

    freeze(path)
    assert ep.set_retroarch_settings(path, {"cheevos_username": "correct"}) is False
    assert unwritten(path)


def test_retroarch_leaves_a_file_holding_the_flake_values_unwritten(
    tmp_path: Path,
) -> None:
    path = tmp_path / "retroarch.cfg"
    path.write_text('menu_driver = "ozone"\nvideo_fullscreen = "true"\nkeep = "me"\n')
    freeze(path)

    assert ep.set_retroarch_settings(path, RA_OWNED) is False
    assert unwritten(path)

    assert ep.set_retroarch_settings(path, RA_OWNED) is False
    assert unwritten(path)


@pytest.mark.parametrize(
    ("owned", "wrote"),
    [
        ({"menu_driver": "ozone"}, True),
        ({"video_fullscreen": "true"}, True),
        ({"menu_driver": ep.REMOVE}, True),
    ],
)
def test_retroarch_keeps_every_unowned_setting_through_an_edit(
    tmp_path: Path, owned: dict[str, str | ep.Removal], wrote: bool
) -> None:
    path = tmp_path / "retroarch.cfg"
    path.write_text(RA_MIXED)
    before = [
        entry
        for entry in retroarch_settings(path)
        if entry[0] not in RA_MIXED_OWNED_NAMES
    ]

    assert ep.set_retroarch_settings(path, owned) is wrote

    after = [
        entry
        for entry in retroarch_settings(path)
        if entry[0] not in RA_MIXED_OWNED_NAMES
    ]
    assert after == before


def test_retroarch_keeps_the_previous_line_intact_when_appending_a_key(
    tmp_path: Path,
) -> None:
    path = tmp_path / "retroarch.cfg"
    path.write_text('menu_driver = "ozone"\ninput_driver = "sdl"')

    assert ep.set_retroarch_settings(path, RA_OWNED) is True

    settings = retroarch_settings(path)
    assert ("input_driver", '"sdl"') in settings
    assert ("video_fullscreen", '"true"') in settings


def test_retroarch_recreates_a_file_with_a_semicolon_line_that_is_not_a_setting(
    tmp_path: Path,
) -> None:
    # RetroArch's own parser gives `;` no special meaning, so a `;`-prefixed
    # line carrying no `=` is not a comment in one of its files - it is a
    # line that is not a setting, and the file is not that format. Spelled
    # without an `=` deliberately: `;key = "v"` parses as an option named
    # `;key`, which is what this program has always done with it, so it would
    # pin nothing.
    path = tmp_path / "retroarch.cfg"
    path.write_text('menu_driver = "rgui"\n; a note with no assignment\n')

    assert ep.set_retroarch_settings(path, RA_OWNED) is True

    text = path.read_text()
    assert "a note with no assignment" not in text
    assert 'menu_driver = "ozone"' in text
    assert 'video_fullscreen = "true"' in text


def test_ini_keeps_a_semicolon_comment_because_ini_has_them(tmp_path: Path) -> None:
    # The other half of the per-format comment prefixes: `;` *is* a comment
    # in an INI file, so the same line there is not a reason to recreate.
    path = tmp_path / "Dolphin.ini"
    path.write_text("[Interface]\nConfirmStop = True\n; a note with no assignment\n")

    assert ep.set_ini_settings(path, INI_OWNED) is True

    assert "; a note with no assignment" in path.read_text()


def test_ini_keeps_every_setting_of_a_file_in_scummvms_own_shape(
    tmp_path: Path,
) -> None:
    # The survey that says the recreate path is not reachable for this file:
    # ScummVM's own writer emits canonical headers, no duplicates, no
    # headerless preamble, no indentation, no comments, no line that is not
    # an assignment, and no `:` delimiter, so the only awkward shapes this
    # program handles do not arise there at all. What is left to prove is
    # that an edit keeps every setting the emulator wrote, trailing spaces on
    # a value included.
    path = tmp_path / "scummvm.ini"
    path.write_text(SCUMMVM)
    before = unowned_ini(path, {("scummvm", "fullscreen")})

    assert ep.set_ini_settings(path, {"scummvm": {"fullscreen": "false"}}) is True

    assert unowned_ini(path, {("scummvm", "fullscreen")}) == before
    assert [e for e in ini_settings(path) if e[1] == "fullscreen"] == [
        ("scummvm", "fullscreen", "false")
    ]
    # Read raw rather than through the helper, which strips: an untouched
    # line keeps its bytes, trailing spaces included, and the helper's own
    # stripping would hide it if it did not.
    assert "vga  \n" in path.read_text()

    freeze(path)
    assert ep.set_ini_settings(path, {"scummvm": {"fullscreen": "false"}}) is False
    assert unwritten(path)


# --- An owned value that is not one line -----------------------------------


@pytest.mark.parametrize(
    "value", ["player\n", "player\ninjected = 1", "a\nb\nc", "a\rb", "player\r"]
)
def test_ini_refuses_an_owned_value_spanning_more_than_one_line(
    tmp_path: Path, value: str, capsys: pytest.CaptureFixture[str]
) -> None:
    # One line of a settings file holds one setting, so a value carrying a
    # newline is not a value: written, its tail becomes a line of its own,
    # which either parses as some other setting or fails the syntax check and
    # takes every unowned key in the file with it on the next launch. The
    # library refuses to store one on an option that already exists, and that
    # refusal is not an OSError, so nothing in the editor loop would have
    # caught it and the session would have ended at a greeter.
    path = tmp_path / "settings.ini"
    path.write_text("[Achievements]\nUsername = old\nKeepMe = yes\n")
    freeze(path)

    assert ep.set_ini_settings(path, {"Achievements": {"Username": value}}) is False

    assert unwritten(path)
    assert "Username = old" in path.read_text()
    assert "is not one line" in capsys.readouterr().err


def test_retroarch_refuses_an_owned_value_spanning_more_than_one_line(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "retroarch.cfg"
    path.write_text('cheevos_username = "old"\n')
    freeze(path)

    assert ep.set_retroarch_settings(path, {"cheevos_username": "a\nb"}) is False

    assert unwritten(path)
    assert "is not one line" in capsys.readouterr().err


def test_ini_refuses_a_multi_line_value_for_a_key_the_file_does_not_carry(
    tmp_path: Path,
) -> None:
    # The library accepts one here, because a brand new option is built
    # rather than assigned - so the crash appears only on the *second* run,
    # against the line the first run wrote. Refusing both ways is what keeps
    # the editor's behaviour the same on every launch.
    path = tmp_path / "settings.ini"
    path.write_text("[Achievements]\nKeepMe = yes\n")

    assert ep.set_ini_settings(path, {"Achievements": {"Username": "a\nb"}}) is False

    assert "a\nb" not in path.read_text()


def test_a_username_with_a_trailing_newline_does_not_end_the_session(
    tmp_path: Path,
) -> None:
    # How such a value actually reaches an editor: a secret file whose last
    # line is blank. `_read_secret` strips exactly one trailing newline, so
    # two of them leave one behind, and nothing validates the account name
    # the way the token is validated.
    secret = tmp_path / "username"
    secret.write_text("player\n\n")
    assert ep._read_secret(secret) == "player\n"

    path = tmp_path / "settings.ini"
    path.write_text("[Achievements]\nUsername = old\nHardcore = true\n")

    assert (
        ep.set_ini_settings(
            path, {"Achievements": {"Username": "player\n", "Hardcore": "false"}}
        )
        is True
    )

    # The bad value is skipped and the rest of the file's owned keys are
    # still asserted, which is the whole point of not raising.
    text = path.read_text()
    assert "Hardcore = false" in text
    assert "Username = old" in text


def test_ini_refuses_to_own_a_section_named_like_the_wrapper(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # A section actually spelled like the synthetic header cannot be told
    # apart from it on the next read, and appending one to a recreated file
    # raised out of an editor whose whole policy is not to raise.
    path = tmp_path / "settings.ini"
    path.write_text("[Achievements]\nUsername = old\n")

    assert (
        ep.set_ini_settings(
            path,
            {WRAPPER: {"Key": "value"}, "Achievements": {"Username": "correct"}},
        )
        is True
    )

    text = path.read_text()
    assert WRAPPER not in text
    assert "Username = correct" in text
    assert "reserved" in capsys.readouterr().err


def test_ini_recreating_a_file_that_owns_only_a_reserved_section_writes_nothing(
    tmp_path: Path,
) -> None:
    path = tmp_path / "settings.ini"
    path.write_text("[Achievements]\ntorn\n")
    freeze(path)

    assert ep.set_ini_settings(path, {WRAPPER: {"Key": "value"}}) is False

    assert unwritten(path)


def test_ini_recreating_a_file_never_writes_a_multi_line_value(
    tmp_path: Path,
) -> None:
    # The recreate branch builds options rather than assigning to them, and
    # the library objects only to the assignment - so a guard on the edit
    # path alone would let a recreation write the very line that makes the
    # next launch refuse the file. Here the tail is a whole second setting.
    path = tmp_path / "settings.ini"
    path.write_text("[Achievements]\ntorn line\nOther = x\n")

    assert (
        ep.set_ini_settings(
            path,
            {
                "Achievements": {
                    "Username": "player\nCheevos_evil = 1",
                    "Hardcore": "true",
                }
            },
        )
        is True
    )

    text = path.read_text()
    assert "Cheevos_evil" not in text
    assert "Username" not in text
    assert "Hardcore = true" in text


def test_ini_collapses_a_repeat_whose_live_assignment_is_already_right(
    tmp_path: Path,
) -> None:
    # The emulator was already reading the flake's value here, because every
    # reader resolves a repeat to the last assignment - but the file still
    # carries a stale line above it, and a later hand edit or torn write that
    # reordered them would put the stale value back in charge. So this run
    # does write, to collapse the repeat, and only the run after it is quiet.
    # Which of the two copies is the one left standing is not promised.
    path = tmp_path / "settings.ini"
    path.write_text("[Achievements]\nUsername = stale\nUsername = correct\n")
    freeze(path)

    assert ep.set_ini_settings(path, {"Achievements": {"Username": "correct"}}) is True

    assert ini_settings(path) == [("Achievements", "Username", "correct")]

    freeze(path)
    assert ep.set_ini_settings(path, {"Achievements": {"Username": "correct"}}) is False
    assert unwritten(path)


def test_a_library_failure_the_parser_does_not_own_still_recreates(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # `configupdater` raises four exceptions that are not `configparser.Error`
    # and its parser raises one of them from its own "cannot happen" branches.
    # Catching the `configparser` base alone would let those escape, and the
    # session runs this program unguarded: the editor loop above it guards
    # `OSError`, so an escaping library exception ends the evening at a
    # greeter instead of replacing one file. Driven through a patched parse
    # because the branches that raise it are unreachable by construction.
    real = ep.ConfigUpdater.read_string

    def explode(self: ep.ConfigUpdater, source: str) -> None:
        # Only the file's own text: the fresh document the recreation builds
        # parses a constant of this module's own and must still work.
        if source.strip() != ep._FLAT_WRAPPER_HEADER:
            raise ep.InconsistentStateError("simulated library failure")
        real(self, source)

    monkeypatch.setattr(ep.ConfigUpdater, "read_string", explode)

    path = tmp_path / "Dolphin.ini"
    path.write_text("[Interface]\nConfirmStop = True\nKeepMe = yes\n")

    assert ep.set_ini_settings(path, INI_OWNED) is True

    text = path.read_text()
    assert "ConfirmStop = False" in text
    assert "Fullscreen = True" in text


def test_ini_refuses_an_owned_value_carrying_a_carriage_return(
    tmp_path: Path,
) -> None:
    # A lone carriage return is written to disk verbatim but read back as a
    # line break, because this program reads in universal-newline mode. So it
    # destroys a file exactly as a newline does, just one launch later: the
    # first run writes it, and from the second the file no longer parses and
    # every unowned key in it is gone through the recreate path, forever.
    path = tmp_path / "settings.ini"
    path.write_text("[Achievements]\nUsername = old\nKeepMe = precious\n")
    owned: dict[str, dict[str, str | ep.Removal]] = {
        "Achievements": {"Username": "a\rb"}
    }

    assert ep.set_ini_settings(path, owned) is False
    assert ep.set_ini_settings(path, owned) is False

    settings = ini_settings(path)
    assert ("Achievements", "KeepMe", "precious") in settings
    assert ("Achievements", "Username", "old") in settings


def test_flat_refuses_a_value_the_parser_still_read_as_a_continuation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The backstop behind stripping every line's indentation. It is
    # unreachable while the strip and the parser agree on what whitespace is,
    # which they do today - so it is driven through a strip that has been
    # made to disagree, which is exactly the drift it exists to absorb. What
    # it must deliver is the recreate path, not a swallowed line.
    real = ep._flat_source

    def leaves_an_indent(text: str) -> str:
        # Indentation put back *after* the real stripping, which is what a
        # strip and a parser that disagreed about one whitespace character
        # would leave behind.
        return real(text).replace("\ncontinued", "\n continued")

    monkeypatch.setattr(ep, "_flat_source", leaves_an_indent)

    with pytest.raises(ep._Unparseable) as refused:
        ep._load_flat("[A]\nkey = 1\ncontinued\n", ini=True)

    assert refused.value.reason is not None
    assert "more than one line" in refused.value.reason


# --- A flat file as a line-oriented document --------------------------------
#
# The document model underneath both flat editors: dataclass nodes that each
# keep their source line verbatim, one per-line classifier per format, and
# rendering by concatenation. The grammar is this program's own statement of
# what the emulators' parsers read, so these tests pin each classifier rule
# and the refusal boundary directly, one rule per test.


def test_document_nodes_hold_their_source_lines_verbatim() -> None:
    blank = ep.Blank(raw="  ")
    comment = ep.Comment(raw="  # note")
    assignment = ep.Assignment(raw="Token =  x ", key="Token", value="x")
    preamble = ep.SectionNode(
        raw_header=None, name=None, children=[blank, comment, assignment]
    )
    section = ep.SectionNode(raw_header="[A] ; kept", name="A", children=[])
    document = ep.Document(sections=[preamble, section])

    assert document.sections[0].raw_header is None
    assert assignment.raw == "Token =  x "
    assert section.name == "A"
    assert section.raw_header == "[A] ; kept"


def test_classifier_reads_a_blank_line_as_blank() -> None:
    node = ep._classify_flat_line(" \t ", ini=True)

    assert isinstance(node, ep.Blank)
    assert node.raw == " \t "


def test_classifier_reads_comment_prefixes_per_format() -> None:
    # `#` and `;` are comments in INI; RetroArch's own parser gives `;` no
    # special meaning, so a `;`-prefixed line there is not a comment and a
    # file carrying one is not that format.
    assert isinstance(ep._classify_flat_line("# c", ini=True), ep.Comment)
    assert isinstance(ep._classify_flat_line("; c", ini=True), ep.Comment)
    assert isinstance(ep._classify_flat_line("# c", ini=False), ep.Comment)
    with pytest.raises(ep._Unparseable, match="not a setting"):
        ep._classify_flat_line("; c", ini=False)


def test_classifier_reads_a_header_in_an_ini_file() -> None:
    node = ep._classify_flat_line("[Interface]", ini=True)

    assert isinstance(node, ep.SectionNode)
    assert node.name == "Interface"
    assert node.raw_header == "[Interface]"
    assert node.children == []


def test_classifier_keeps_a_headers_trailing_comment_in_its_raw_line() -> None:
    node = ep._classify_flat_line("[Achievements] ; was [Cheevos]", ini=True)

    assert isinstance(node, ep.SectionNode)
    assert node.name == "Achievements"
    assert node.raw_header == "[Achievements] ; was [Cheevos]"


def test_classifier_refuses_a_header_in_a_retroarch_file() -> None:
    with pytest.raises(ep._Unparseable, match="has a section header") as refused:
        ep._classify_flat_line("[Foo]", ini=False)

    assert "Foo" in str(refused.value)


def test_classifier_does_not_read_an_empty_name_as_a_header() -> None:
    # `[]` is not a header - an empty name could never equal an owned
    # section's - and it has no `=`, so it is junk in both formats.
    for ini in (True, False):
        with pytest.raises(ep._Unparseable, match="not a setting"):
            ep._classify_flat_line("[]", ini=ini)


@pytest.mark.parametrize("line", ["[Name] = v", "[Name]x = y", "[]] = v"])
def test_classifier_junks_a_loose_header_shape_even_when_it_carries_an_equals(
    line: str,
) -> None:
    # The permissive `[anything]` grammar other INI readers use is greedy to
    # the last bracket, so each of these is a header to such a reader and
    # unreadable to this program's grammar. Keys below it could land under a
    # section the emulator reads differently, so the file is refused - the
    # junk rule outranks the assignment rule.
    for ini in (True, False):
        with pytest.raises(ep._Unparseable, match="not a setting"):
            ep._classify_flat_line(line, ini=ini)


@pytest.mark.parametrize(
    ("line", "key", "value"),
    [("[foo bar = baz", "[foo bar", "baz"), ("[] = y", "[]", "y")],
)
def test_classifier_keeps_a_bracketed_line_no_header_grammar_reads(
    line: str, key: str, value: str
) -> None:
    # No `]` past the second column, so no header grammar - strict or loose -
    # reads these; they are ordinary assignments and stay ones.
    node = ep._classify_flat_line(line, ini=True)

    assert isinstance(node, ep.Assignment)
    assert node.key == key
    assert node.value == value


def test_classifier_reads_an_assignment_and_strips_its_halves() -> None:
    node = ep._classify_flat_line("  Token =  live  ", ini=True)

    assert isinstance(node, ep.Assignment)
    assert node.raw == "  Token =  live  "
    assert node.key == "Token"
    assert node.value == "live"


def test_classifier_splits_an_assignment_on_the_first_equals() -> None:
    node = ep._classify_flat_line("key = a = b", ini=True)

    assert isinstance(node, ep.Assignment)
    assert node.key == "key"
    assert node.value == "a = b"


def test_classifier_junks_an_assignment_with_an_empty_key() -> None:
    for ini in (True, False):
        with pytest.raises(ep._Unparseable, match="not a setting"):
            ep._classify_flat_line("= v", ini=ini)


@pytest.mark.parametrize("line", ["barekeywithnoassignment", "Time: 12"])
def test_classifier_junks_a_line_with_no_equals(line: str) -> None:
    for ini in (True, False):
        with pytest.raises(ep._Unparseable, match="not a setting"):
            ep._classify_flat_line(line, ini=ini)


@pytest.mark.parametrize("indent", [" ", "\t", "\x0b", "\x0c", "\xa0", "　"])
def test_classifier_classifies_the_fully_stripped_line(indent: str) -> None:
    # Any Unicode whitespace: an indented assignment, comment or header is
    # still that line, and the node keeps the raw line so the indentation
    # survives a write.
    assignment = ep._classify_flat_line(f"{indent}KeepMe = 3", ini=True)
    comment = ep._classify_flat_line(f"{indent}# note", ini=True)
    header = ep._classify_flat_line(f"{indent}[Later]", ini=True)

    assert isinstance(assignment, ep.Assignment)
    assert assignment.raw == f"{indent}KeepMe = 3"
    assert isinstance(comment, ep.Comment)
    assert isinstance(header, ep.SectionNode)
    assert header.raw_header == f"{indent}[Later]"


def test_parse_splits_on_newlines_alone() -> None:
    # A value carrying U+2028 stays one line: `str.splitlines()` would cut
    # it into a fragment that fails to classify and refuse the whole file.
    document = ep._parse_flat("key = a b\n", ini=True)

    (node,) = document.sections[0].children
    assert isinstance(node, ep.Assignment)
    assert node.value == "a b"


def test_parse_attaches_lines_to_the_section_above_them() -> None:
    document = ep._parse_flat("stray = 1\n[A]\nx = 2\n\n[A]\ny = 3\n", ini=True)

    assert [section.name for section in document.sections] == [None, "A", "A"]
    preamble, first, second = document.sections
    assert [n.key for n in preamble.children if isinstance(n, ep.Assignment)] == [
        "stray"
    ]
    assert [n.key for n in first.children if isinstance(n, ep.Assignment)] == ["x"]
    assert [n.key for n in second.children if isinstance(n, ep.Assignment)] == ["y"]


# Parse-then-render must be byte-identical for every readable file, except
# the appended final newline when the source lacked one. The corpus is the
# suite's own flat-file fixtures plus the shapes the classifier rules argue
# about.

ROUND_TRIP_CORPUS: list[tuple[str, bool]] = [
    (
        "# written by the emulator\n[Interface]\nLanguage = 0\n\n[Display]\nFullscreen = False\n",
        True,
    ),
    ("Token = stray\n; a comment\n[Achievements]\nUsername = alice\n", True),
    ("[Achievements]\nToken = keepme", True),
    ("[Interface]\nConfirmStop = True\n  # note\nKeepMe = 3\n", True),
    ("[Interface]\nConfirmStop = True\n  Indented = 9\nKeepMe = 3\n", True),
    ("[Interface]\nConfirmStop = True\n  [Later]\nKeepMe = 3\n", True),
    ("　[Achievements] ; was [Cheevos]\nToken = live\n", True),
    ("[Achievements] # old [name]\nToken = live\nUserPref = keepme\n", True),
    ("[Achievements]\nToken = live\n[foo bar = baz\n", True),
    ("[] = y\nkey = a = b\n", True),
    (AZAHAR, True),
    (SCUMMVM, True),
    (
        "[Other]\nFullscreen = False\n[Display]\nFullscreen = False\n[Interface]\nConfirmStop = False\n",
        True,
    ),
    (
        "[Achievements]\nUsername = stale-one\nUsername = stale-two\nKeepMe = yes\n",
        True,
    ),
    ("", False),
    (
        '# RetroArch config\nmenu_driver = "rgui"\ninput_driver = "sdl"\nvideo_fullscreen = "false"\n',
        False,
    ),
    ('# RetroArch config\nvideo_fullscreen = "true"\n\n\n', False),
    ('cheevos_token = "keepme"', False),
    ('menu_driver = "ozone"\n', False),
]


@pytest.mark.parametrize(("text", "ini"), ROUND_TRIP_CORPUS)
def test_parse_then_render_is_byte_identical_plus_a_final_newline(
    text: str, ini: bool
) -> None:
    rendered = ep._render_flat(ep._parse_flat(text, ini=ini))

    expected = text if not text or text.endswith("\n") else text + "\n"
    assert rendered == expected


# The refusal path: what reaches the journal, and what stays silent.


@pytest.mark.parametrize("text", ["", "\n", "   \n"])
def test_parse_refuses_an_empty_ini_without_a_word(
    text: str, capsys: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(ep._Unparseable) as refused:
        ep._parse_flat(text, ini=True)

    assert refused.value.reason is None
    assert capsys.readouterr().err == ""


def test_read_document_notes_an_unreadable_file(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "settings.ini"
    path.write_bytes(b"[Interface]\n\xff\xfe not text\n")

    assert ep._read_document(path, ini=True) is None

    assert "is unreadable" in capsys.readouterr().err


@pytest.mark.parametrize(
    ("text", "ini", "reason"),
    [
        ("[Interface]\nthis line has no assignment\n", True, "not a setting"),
        ("[]\nToken = live\n", True, "not a setting"),
        ("[] ; c\nToken = live\n", True, "not a setting"),
        ("[Name] trailing junk\nToken = live\n", True, "not a setting"),
        ("[Name] = v\nToken = live\n", True, "not a setting"),
        ("[Name]x = y\nToken = live\n", True, "not a setting"),
        ("[]] = v\nToken = live\n", True, "not a setting"),
        ("= v\nToken = live\n", True, "not a setting"),
        ('video = "1"\n[Foo]\ntoken = "x"\n', False, "has a section header"),
        ('video = "1"\n; not a comment here\n', False, "not a setting"),
        ("key = 1\n    continued\n", True, "not a setting"),
    ],
)
def test_read_document_notes_every_other_refusal_with_its_reason(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    text: str,
    ini: bool,
    reason: str,
) -> None:
    path = tmp_path / ("settings.ini" if ini else "retroarch.cfg")
    path.write_text(text)

    assert ep._read_document(path, ini=ini) is None

    err = capsys.readouterr().err
    assert reason in err
    assert "recreating it" in err


def test_read_document_quietly_is_silent_about_every_refusal(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "settings.ini"
    path.write_text("[Interface]\nthis line has no assignment\n")
    unreadable = tmp_path / "junk.ini"
    unreadable.write_bytes(b"\xff\xfe")

    assert ep._read_document_quietly(path, ini=True) is None
    assert ep._read_document_quietly(unreadable, ini=True) is None
    assert ep._read_document_quietly(tmp_path / "absent.ini", ini=True) is None

    assert capsys.readouterr().err == ""


def test_read_document_reads_an_empty_retroarch_file_as_a_document() -> None:
    document = ep._parse_flat("", ini=False)

    assert ep._render_flat(document) == ""
    assert [section.raw_header for section in document.sections] == [None]


# --- Nothing stranded, in either direction ---------------------------------
#
# Replacing a parser leaves two kinds of wreckage and lint sees neither: a
# definition whose last caller went away, and a survivor still calling
# something that went away. Ruff does not flag an unused module-level
# assignment, so an orphaned constant is invisible to it, and a function
# reachable only from dead code looks used to any single-direction check.


def module_names() -> tuple[dict[str, int], dict[str, int], set[str]]:
    """What the module defines at its top level, what it loads, and what binds."""
    tree = ast.parse(Path(ep.__file__).read_text())

    defined: dict[str, int] = {}
    for node in tree.body:
        if isinstance(node, ast.FunctionDef | ast.AsyncFunctionDef | ast.ClassDef):
            defined[node.name] = node.lineno
        elif isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    defined[target.id] = node.lineno
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            defined[node.target.id] = node.lineno

    loaded: dict[str, int] = {}
    bound: set[str] = set(dir(builtins)) | {"__name__", "__file__", "__doc__"}
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
            loaded.setdefault(node.id, node.lineno)
        elif isinstance(node, ast.Name):
            bound.add(node.id)
        elif isinstance(node, ast.FunctionDef | ast.AsyncFunctionDef):
            bound.add(node.name)
            spec = node.args
            for arg in [
                *spec.posonlyargs,
                *spec.args,
                *spec.kwonlyargs,
                *([spec.vararg] if spec.vararg else []),
                *([spec.kwarg] if spec.kwarg else []),
            ]:
                bound.add(arg.arg)
        elif isinstance(node, ast.ClassDef):
            bound.add(node.name)
        elif isinstance(node, ast.ExceptHandler) and node.name:
            bound.add(node.name)
        elif isinstance(node, ast.Import | ast.ImportFrom):
            for alias in node.names:
                bound.add(alias.asname or alias.name.split(".")[0])
        elif isinstance(node, ast.Global | ast.Nonlocal):
            bound.update(node.names)

    return defined, loaded, bound


def test_the_module_leaves_no_definition_unreferenced() -> None:
    defined, loaded, _ = module_names()

    orphans = sorted(
        (line, name) for name, line in defined.items() if name not in loaded
    )

    assert orphans == []


def test_the_module_loads_no_name_that_nothing_binds() -> None:
    # Not the same check as the one above, and the reason both are here: a
    # function can be referenced only by a caller that is itself dead, which
    # leaves the pair invisible to the orphan pass and visible to this one.
    _, loaded, bound = module_names()

    dangling = sorted(
        (line, name) for name, line in loaded.items() if name not in bound
    )

    assert dangling == []


def test_the_section_regex_is_what_the_header_guard_compares_against() -> None:
    # The one module-level constant the rewrite kept rather than deleted, and
    # it is kept for one reason: it supplies the name the library's own
    # section grammar is reconciled against. If nothing loads it, that
    # reconciliation is not implemented and a header the two grammars name
    # differently would strand a live credential.
    _, loaded, _ = module_names()

    assert "_INI_SECTION_RE" in loaded
