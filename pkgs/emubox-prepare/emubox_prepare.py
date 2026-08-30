#!/usr/bin/env python3
"""Seed and assert the configuration keys the flake owns, and nothing else.

The kiosk session runs this before every launch of the frontend, each
relaunch included. Its whole promise is that the keys the flake declares
hold the flake's values and every other key is left exactly as the program
that owns the file last wrote it, so a preference the family changed in the
frontend's own menus survives a reboot.

Invocation contract (design D3):

    emubox-prepare <owned-values-json> <custom-systems-path>

Exactly two positional arguments, always both. `<custom-systems-path>` is
the empty string when no custom systems are configured, which is what
selects the removal branch - never an omitted argument, so the call site has
one shape. The appdata root comes from `ESDE_APPDATA_DIR`, the same variable
the frontend itself reads; if it is unset or empty this program writes
nothing and exits non-zero, because that is a broken call site rather than a
broken configuration and the session ending at the greeter is the point.

The owned-values JSON maps a settings file to the format of that file and
the keys owned in it:

    {"settings/es_settings.xml": {"format": "esde-xml", "keys": {...}}}

A relative path resolves under the appdata root; an absolute one is used as
written, which is how later epics reach files outside it. The `keys` shape
is the editor's: `{name: {"type": ..., "value": ...}}` for `esde-xml`,
`{section: {key: value}}` for `ini`, `{key: value}` for `retroarch`. Later
epics extend the tables, not the editors.

Error policy: recreate, not fail. A file that is missing, unreadable or
malformed is replaced by a fresh one carrying the owned keys, and the
program goes on, because the frontend regenerates everything else it cares
about. The cost of recreating is a lost unowned preference in a file that
was already unreadable; the cost of failing is the family staring at a
greeter with no way back. Every recreation is noted on stderr so the journal
records it.
"""

from __future__ import annotations

import json
import os
import re
import stat
import sys
import tempfile
import xml.etree.ElementTree as ET
from collections.abc import Mapping, Sequence
from pathlib import Path

# ES-DE writes its settings as a rootless sequence of typed elements - pugixml
# appends them straight to the document - so the file has no single root and
# a plain parse of it raises "junk after document element". Reading wraps the
# body in this element and writing drops it again.
_WRAPPER = "emubox-settings-forest"
_XML_DECLARATION = '<?xml version="1.0"?>'
_DECLARATION_RE = re.compile(r"^\s*<\?xml[^>]*\?>\s*")
# A trailing comment after a section header is legal INI and is accepted by
# configparser and Qt alike; rejecting one would send the whole file through
# the recreate path and lose every unowned key in it.
_INI_SECTION_RE = re.compile(r"^\s*\[(?P<name>[^]]*)\][ \t]*(?:[;#].*)?$")


def note(message: str) -> None:
    """Record a recreation or a refusal where the journal will keep it."""
    print(f"emubox-prepare: {message}", file=sys.stderr)


def strip_xml_declaration(text: str) -> str:
    """Drop a leading `<?xml ...?>`, which cannot appear inside an element."""
    return _DECLARATION_RE.sub("", text, count=1)


def _ensure_parent(path: Path) -> None:
    """Create the file's parent directories, mode 0755.

    tmpfiles creates `/data/es-de` but neither `settings/` nor
    `custom_systems/` under it, so this is what makes them on a first boot.
    Only the directories actually created are chmod-ed, so an existing
    directory keeps whatever mode its owner gave it.
    """
    missing = [p for p in reversed(path.parent.parents) if not p.exists()]
    if not path.parent.exists():
        missing.append(path.parent)
    for directory in missing:
        directory.mkdir(exist_ok=True)
        directory.chmod(0o755)
        _inherit_owner(directory)


def _inherit_owner(path: Path) -> None:
    """Give a newly created path its parent directory's owner.

    Only meaningful as root. tmpfiles creates `/data/es-de` owned by
    `player`, so a run by an admin from the greeter would otherwise leave the
    `settings/` directory and the file inside it owned by root - and then the
    frontend, which runs as `player`, could not write there at all and every
    later launch would end back at the greeter.
    """
    if os.getuid() != 0:
        return
    try:
        parent = path.parent.stat()
        os.chown(path, parent.st_uid, parent.st_gid)
    except OSError as error:  # pragma: no cover - needs root to reach
        note(f"{path}: could not set the owner ({error})")


def _write(path: Path, text: str) -> None:
    """Replace the file's contents in one step.

    Through a temporary file and `os.replace` so that a reader - the frontend,
    or the next run of this program - never sees a half-written document. A
    torn write is exactly the failure the recreate policy exists to absorb;
    not creating more of them is cheap.

    Three details that are not decoration:

    - The temporary name is unique (`mkstemp`), not `<name>.emubox-tmp`. The
      module puts `emubox-prepare` on the system path precisely so it can be
      run by hand, so two runs against one file are a supported scenario; a
      shared temp name lets them open the same inode and publish a document
      interleaved from both.
    - An existing file's owner and mode are carried onto the replacement.
      `os.replace` installs a *new* inode, so without this a run as root -
      an admin's, from the greeter - would leave `es_settings.xml` owned by
      root and the frontend, which runs as `player`, could never save again.
    - The data is fsynced before the rename and the directory after it, since
      `os.replace` is atomic against other processes but not against the
      power cut this appliance gets every time it is switched off at the wall.
    """
    _ensure_parent(path)
    try:
        preserve = path.stat()
    except OSError:
        preserve = None

    handle, name = tempfile.mkstemp(
        dir=path.parent, prefix=path.name + ".", suffix=".emubox-tmp"
    )
    temporary = Path(name)
    try:
        with os.fdopen(handle, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        if preserve is None:
            temporary.chmod(0o644)
            _inherit_owner(temporary)
        else:
            temporary.chmod(stat.S_IMODE(preserve.st_mode))
            if os.getuid() == 0:
                os.chown(temporary, preserve.st_uid, preserve.st_gid)
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    _fsync_directory(path.parent)


def _fsync_directory(directory: Path) -> None:
    """Persist a rename, so the replacement survives a power cut."""
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _read_text(path: Path) -> str | None:
    """The file's text, or None if it is absent or not readable as text."""
    try:
        return path.read_text()
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError) as error:
        note(f"{path} is unreadable ({error}); recreating it")
        return None


# --- ES-DE settings XML ---------------------------------------------------


def _render_esde(elements: Sequence[ET.Element]) -> str:
    # `.strip()` because a parsed element carries its own tail whitespace, and
    # appending a newline to that would add one blank line per element on
    # every write - unbounded growth in a file rewritten before each launch.
    body = "".join(ET.tostring(e, encoding="unicode").strip() + "\n" for e in elements)
    return f"{_XML_DECLARATION}\n{body}"


def _parse_esde(path: Path) -> list[ET.Element] | None:
    text = _read_text(path)
    if text is None:
        return None
    body = strip_xml_declaration(text)
    if not body.strip():
        # An empty or declaration-only file is what a power cut leaves behind,
        # which on this appliance is every switch-off at the wall. It parses
        # to zero elements, so without this it would look like a healthy
        # document that merely lacks every owned key, and the journal would
        # record no recreation.
        note(f"{path} is empty; recreating it")
        return None
    try:
        root = ET.fromstring(f"<{_WRAPPER}>{body}</{_WRAPPER}>")
    except ET.ParseError as error:
        note(f"{path} does not parse ({error}); recreating it")
        return None
    return list(root)


def set_esde_settings(path: Path, keys: Mapping[str, Mapping[str, str]]) -> bool:
    """Assert the owned keys in an ES-DE settings file. Returns whether it wrote.

    Every element the flake does not own keeps its type, its value and its
    position; an owned key that is absent is appended, and one that drifted -
    in value or in element type - is set back to what the flake declares.
    """
    elements = _parse_esde(path)
    recreating = elements is None
    if elements is None:
        elements = []

    by_name = {e.attrib.get("name"): e for e in elements}
    changed = recreating
    for name, spec in keys.items():
        element = by_name.get(name)
        if element is None:
            element = ET.SubElement(ET.Element(_WRAPPER), spec["type"])
            element.set("name", name)
            element.set("value", spec["value"])
            elements.append(element)
            changed = True
        elif (
            element.tag != spec["type"] or element.attrib.get("value") != spec["value"]
        ):
            element.tag = spec["type"]
            element.set("value", spec["value"])
            changed = True

    if changed:
        _write(path, _render_esde(elements))
    return changed


# --- INI with sections ----------------------------------------------------


def _lines(text: str) -> list[str]:
    """The file's lines, split only on newlines.

    Not `str.splitlines()`, which also breaks on U+2028, form feed and the
    other exotic separators - a value containing one would be split into a
    fragment that fails the syntax check below and take the whole file
    through the recreate path with it. No CRLF handling is needed here:
    `Path.read_text` already translates universal newlines, so only `\n`
    ever reaches this.
    """
    if not text:
        return []
    return text.split("\n")


def _split_ini_assignment(line: str) -> tuple[str, str, str] | None:
    """A line's (prefix through `=`, key, value), or None if it is not one."""
    head, separator, value = line.partition("=")
    if not separator:
        return None
    return head + separator, head.strip(), value


def _parse_ini(path: Path) -> list[str] | None:
    text = _read_text(path)
    if text is None:
        return None
    if not text.strip():
        # Recorded, like the ES-DE case: an empty file yields no lines and
        # would otherwise look like a healthy document missing every key.
        note(f"{path} is empty; recreating it")
        return None
    if not text.strip():
        # Recorded, like the ES-DE case: an empty file yields no lines and
        # would otherwise look like a healthy document missing every key.
        note(f"{path} is empty; recreating it")
        return None
    lines = _lines(text.rstrip("\n"))
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith(("#", ";")):
            continue
        if _INI_SECTION_RE.match(line):
            continue
        if _split_ini_assignment(line) is None:
            note(f"{path} has a line that is not a setting ({line!r}); recreating it")
            return None
    return lines


def _render_ini(sections: Mapping[str, Mapping[str, str]]) -> str:
    blocks = [
        "\n".join([f"[{section}]"] + [f"{k} = {v}" for k, v in keys.items()])
        for section, keys in sections.items()
    ]
    return "\n".join(blocks) + "\n"


def set_ini_settings(path: Path, sections: Mapping[str, Mapping[str, str]]) -> bool:
    """Assert owned keys in an INI file with sections. Returns whether it wrote.

    Comments, blank lines, key order and every key the flake does not own are
    kept as they were. A key missing from a section it belongs to is appended
    to that section; a missing section is appended to the file.
    """
    lines = _parse_ini(path)
    if lines is None:
        _write(path, _render_ini(sections))
        return True

    changed = False
    for section, keys in sections.items():
        bounds = _ini_section_bounds(lines, section)
        if bounds is None:
            lines.extend(_render_ini({section: keys}).splitlines())
            changed = True
            continue
        start, end = bounds
        for key, value in keys.items():
            index = _ini_key_index(lines, start, end, key)
            if index is None:
                # After the section's last setting, so a following comment
                # block stays attached to whatever it was written under.
                insert_at = _ini_insert_point(lines, start, end)
                lines.insert(insert_at, f"{key} = {value}")
                end += 1
                changed = True
                continue
            assignment = _split_ini_assignment(lines[index])
            assert assignment is not None  # _ini_key_index only matches these
            prefix, _, current = assignment
            if current.strip() != value:
                lines[index] = f"{prefix}{_matching_space(current)}{value}"
                changed = True

    if changed:
        _write(path, "\n".join(lines) + "\n")
    return changed


def _matching_space(current: str) -> str:
    """The spacing that stood after `=`, so a rewrite keeps the file's style."""
    return current[: len(current) - len(current.lstrip())] or ""


def _ini_section_bounds(lines: Sequence[str], section: str) -> tuple[int, int] | None:
    """The half-open line range holding a section's body, or None if absent."""
    start = None
    for index, line in enumerate(lines):
        match = _INI_SECTION_RE.match(line)
        if match is None:
            continue
        if start is not None:
            return start, index
        if match.group("name") == section:
            start = index + 1
    return None if start is None else (start, len(lines))


def _ini_key_index(lines: Sequence[str], start: int, end: int, key: str) -> int | None:
    for index in range(start, end):
        assignment = _split_ini_assignment(lines[index])
        if assignment is not None and assignment[1] == key:
            return index
    return None


def _ini_insert_point(lines: Sequence[str], start: int, end: int) -> int:
    for index in range(end - 1, start - 1, -1):
        if _split_ini_assignment(lines[index]) is not None:
            return index + 1
    return start


# --- RetroArch's flat `key = "value"` file --------------------------------


def _parse_retroarch(path: Path) -> list[str] | None:
    text = _read_text(path)
    if text is None:
        return None
    lines = _lines(text.rstrip("\n"))
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if _split_ini_assignment(line) is None:
            note(f"{path} has a line that is not a setting ({line!r}); recreating it")
            return None
    return lines


def _render_retroarch(keys: Mapping[str, str]) -> str:
    return "".join(f'{key} = "{value}"\n' for key, value in keys.items())


def set_retroarch_settings(path: Path, keys: Mapping[str, str]) -> bool:
    """Assert owned keys in RetroArch's flat config. Returns whether it wrote.

    Same properties as the INI editor: comments, order and unowned keys are
    preserved, a missing key is appended, and an unreadable file is recreated
    carrying the owned keys.
    """
    lines = _parse_retroarch(path)
    if lines is None:
        _write(path, _render_retroarch(keys))
        return True

    changed = False
    for key, value in keys.items():
        index = _ini_key_index(lines, 0, len(lines), key)
        quoted = f'"{value}"'
        if index is None:
            lines.append(f"{key} = {quoted}")
            changed = True
            continue
        assignment = _split_ini_assignment(lines[index])
        assert assignment is not None  # _ini_key_index only matches these
        prefix, _, current = assignment
        if current.strip() != quoted:
            lines[index] = f"{prefix}{_matching_space(current)}{quoted}"
            changed = True

    if changed:
        _write(path, "\n".join(lines) + "\n")
    return changed


# --- The custom systems step ----------------------------------------------


def install_custom_systems(target: Path, source: str) -> bool:
    """Install or remove the custom systems file. Returns whether it changed.

    Copied rather than linked: the frontend and, later, the scraper treat the
    directory as theirs, and a link into the store would survive a
    configuration that no longer defines it. An empty `source` is the removal
    branch, and removing what is not there is a no-op rather than an error -
    that is every launch of the frontend on the box as shipped.

    This step carries the editors' error policy too, and reaches the target
    only through `_read_text`: a target that is unreadable or not UTF-8 is
    treated as "not what we want" and rewritten, rather than raising and
    ending the session at the greeter. A target that is a *directory* is the
    one case still left to raise, deliberately - it cannot be replaced, and
    like an unwritable `/data` it is the kind of breakage that should stop at
    a greeter an admin can log into. `os.path.lexists` rather
    than `Path.exists` on the removal branch, because the latter follows a
    symlink and would leave a dangling one in place - exactly the stale entry
    this branch exists to clear.
    """
    if not source:
        if not os.path.lexists(target):
            return False
        try:
            target.unlink()
        except OSError as error:
            note(f"{target} could not be removed ({error}); leaving it")
            return False
        return True

    wanted = _read_text(Path(source))
    if wanted is None:
        # The source is a store path the module rendered, so this is a broken
        # call site rather than a broken configuration - the one case the
        # recreate policy deliberately does not cover (design D3).
        note(f"{source} is unreadable; refusing to install custom systems")
        raise SystemExit(1)
    if _read_text(target) == wanted:
        return False
    _write(target, wanted)
    return True


# --- Entry point ----------------------------------------------------------

_EDITORS = {
    "esde-xml": set_esde_settings,
    "ini": set_ini_settings,
    "retroarch": set_retroarch_settings,
}


def main(argv: Sequence[str]) -> int:
    if len(argv) != 2:
        note("usage: emubox-prepare <owned-values-json> <custom-systems-path>")
        return 2

    owned_values, custom_systems = argv

    appdata = os.environ.get("ESDE_APPDATA_DIR", "")
    if not appdata:
        note("ESDE_APPDATA_DIR is unset or empty; refusing to write anything")
        return 1

    root = Path(appdata)
    # The owned-values file is a store path the module renders, so anything
    # wrong with it is a broken call site, not a broken configuration: the
    # recreate policy deliberately does not cover it and the session should
    # end at the greeter. It still ends with a line in the journal rather
    # than a stack trace, which is what an admin reading `journalctl` needs.
    try:
        tables = json.loads(Path(owned_values).read_text())
    except (OSError, ValueError) as error:
        note(f"{owned_values} is not readable owned-values JSON ({error})")
        return 1
    if not isinstance(tables, dict):
        note(
            f"{owned_values}: expected an object of files, got {type(tables).__name__}"
        )
        return 1
    for relative, table in tables.items():
        if not isinstance(table, dict) or "format" not in table or "keys" not in table:
            note(f"{relative}: expected an object with 'format' and 'keys'")
            return 1
        editor = _EDITORS.get(table["format"])
        if editor is None:
            note(f"{relative}: unknown format {table['format']!r}")
            return 1
        editor(root / relative, table["keys"])

    install_custom_systems(root / "custom_systems" / "es_systems.xml", custom_systems)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
