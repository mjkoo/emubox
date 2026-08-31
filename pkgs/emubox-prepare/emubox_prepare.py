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

The owned-values JSON is an object with two keys (design D1):

    {
        "files": {"settings/es_settings.xml": {"format": "esde-xml", "keys": {...}}},
        "retroachievements": null
    }

`files` maps a settings file to the format of that file and the keys owned
in it, exactly as the bare map once did on its own. A relative path resolves
under the appdata root; an absolute one is used as written, which is how
later epics reach files outside it. The `keys` shape is the editor's:
`{name: {"type": ..., "value": ...}}` for `esde-xml`, `{section: {key:
value}}` for `ini`, `{key: value}` for `retroarch`.

`retroachievements` drives the shared RetroAchievements account (design
D2). Null - or absent - means this whole namespace is skipped: no login is
attempted and nothing under it - not even a stale credential - is ever
touched. Non-null, it carries `username_file`, `password_file` and
`cache_file` (paths, never contents: this JSON is a world-readable store
path), the `api_url`, the `hardcore` boolean, an `enabled` boolean
(absent defaults to true, for every call site written before this field
existed), and a `targets` array with one entry per supporting emulator. A
target names its `encoding` - `plain`, `duckstation` (the encrypted
at-rest form of design D3, which also needs a `machine_id_file`) or
`secret-file` (PPSSPP, whose token is a whole file named by `token_file`
rather than a key) - the `booleans` spelling that emulator uses for true
and false, and a `keys` table mapping this program's own vocabulary
(`enabled`, `hardcore`, `username`, `token`, and `login_timestamp` for
DuckStation) to a file in `files` and the key inside it.

What this program does with a non-null, `enabled` namespace: it logs in to
the API once per run under a wall-clock timeout, caches the token at mode
0600, falls back to that cache only when the API cannot be reached, and
drops it when the API rejects the credentials. The resulting values are
folded into `files` before any editor runs, so the editors never learn
that a key came from here rather than from the module that declared the
file. When no token resolves at all, the login keys are removed from
every target rather than left holding a stale account.

A non-null namespace with `enabled: false` is switched-off's own shape
(the module that renders this document always emits one of these two,
never null, once RetroAchievements is wired into a box at all): no login
is attempted - the spec's own requirement - and every credential this
program may ever have written is instead actively removed, the same
per-target `keys` table pointing at where each one lives: the account
name and token in every target's own config, PPSSPP's whole-file token,
and the cached login token. Switching the feature off used to leave a
stale username and token sitting in all of those places; this is what
actually takes the account's bearer token off the box, rather than merely
stopping its refresh.

That whole step is bounded: any runtime failure in it - no network, no
credentials, a full disk, an unforeseen exception - costs the achievements
and nothing else, because this program runs before every launch and the
alternative is a family staring at a greeter. A malformed
`retroachievements` document is the one exception, and it is not a runtime
failure: like an unreadable owned-values file it is a broken call site,
and it still ends the run non-zero.

Error policy: recreate, not fail. A file that is missing, unreadable or
malformed is replaced by a fresh one carrying the owned keys, and the
program goes on, because the frontend regenerates everything else it cares
about. The cost of recreating is a lost unowned preference in a file that
was already unreadable; the cost of failing is the family staring at a
greeter with no way back. Every recreation is noted on stderr so the journal
records it.
"""

from __future__ import annotations

import base64
import hashlib
import http.client
import json
import os
import re
import stat
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Literal, cast

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

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


def _write(path: Path, text: str, *, mode: int | None = None) -> None:
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

    `mode` overrides both the carried-over and the default mode, and is
    applied to the temporary file *before* the rename. That ordering is the
    whole reason it exists: chmod-ing after the rename publishes a
    credential at 0644 for the length of a syscall, and leaves it there for
    good if the chmod is the call that fails.
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
            temporary.chmod(0o644 if mode is None else mode)
            _inherit_owner(temporary)
        else:
            temporary.chmod(stat.S_IMODE(preserve.st_mode) if mode is None else mode)
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


def _read_quietly(path: Path) -> str | None:
    """The file's text, or None if it is absent, unreadable or not UTF-8.

    Silent where `_read_text` is loud, because the callers differ: this one
    is only ever asking "what is already on disk?" so it can decide whether
    a write is needed at all, and a file that cannot be read simply means
    "nothing to compare against". Printing a recreation notice here would
    put a line in the journal before this run has decided to write
    anything.

    `UnicodeDecodeError` is a `ValueError` subclass rather than an
    `OSError` one, so it has to be named: DuckStation copies ROM paths and
    memory card names into `settings.ini` verbatim, so a single latin-1
    byte off a FAT stick makes this file undecodable, and an escaping
    exception here would end every launch at the greeter forever - before
    the editors, so the recreate policy that exists to absorb exactly this
    would never get to run.
    """
    try:
        return path.read_text()
    except (OSError, UnicodeDecodeError):
        return None


# --- Removing an owned key ------------------------------------------------


class Removal:
    """The value that means "this key must not be in this file at all".

    Not the empty string: to an emulator a present key with an empty value
    is not the same thing as an absent one - RetroArch treats any
    `cheevos_token` it finds as a token to try logging in with. Not `None`
    either, so that a `null` finding its way into the owned-values JSON
    cannot silently delete a key; this sentinel has no JSON spelling at
    all, and the only thing that produces it is the retroachievements
    merge in this same file.

    "At all" is meant literally, and both flat-file editors implement it
    that way through `_sweep_key`: every assignment of the key, in every
    instance of its section, plus the file's headerless preamble - not the
    first match in the first matching section. The claim used to be looser
    than the code, which was tolerable while a removal only meant "do not
    leave a stale preference"; it is not now that a removal is also how a
    live bearer token comes off the box, and a duplicated `[Achievements]`
    header is exactly the shape a torn or hand-edited file can take.
    """

    __slots__ = ()

    def __repr__(self) -> str:
        return "REMOVE"


REMOVE = Removal()


def _without_removals(keys: Mapping[str, str | Removal]) -> dict[str, str]:
    """The keys that carry a value, for the branches that write a fresh file."""
    return {key: value for key, value in keys.items() if isinstance(value, str)}


def _holds_something(path: Path) -> bool:
    """Whether there is anything on disk here a recreation would drop.

    The question the all-removals branch of both flat-file editors has to
    ask before deciding to write nothing at all. A parser answers None for
    "absent" and for "present but unparseable" alike, and the difference
    between those two is a security one: PCSX2's `secrets.ini` is the one
    owned file whose only owned key on the disabled path is a removal, so
    reading None as "there is nothing to remove from" left `Token = <live
    token>` on disk through every launch, forever, for a file the box had
    only to tear one line of - and this appliance is switched off at the
    wall, so a torn line is routine rather than exotic. The same goes for a
    non-UTF-8 byte or a mode that forbids reading it.

    A `stat` that fails is not evidence of absence either - a directory in
    the way, a parent that cannot be searched - so the fallback asks
    `exists()`, which answers False only for the genuinely absent. Being
    wrong in this direction costs one recreation of a file that turns out
    to be empty; being wrong in the other costs the credential.
    """
    try:
        return path.stat().st_size > 0
    except OSError:
        return path.exists()


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

    A file with no owned keys at all is left alone, the same rule as the
    other two editors: see `set_ini_settings` for why that is not merely a
    shortcut.
    """
    if not keys:
        return False

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
        # Not noted here, unlike the ES-DE case this comment used to draw
        # the same parallel to: an empty file yields no lines and would
        # otherwise look like a healthy document missing every key, but
        # whether that actually means a recreation follows depends on
        # whether anything is left to write once REMOVE-valued keys drop
        # out - which only `set_ini_settings` knows, since a file whose
        # only owned key is a pending removal (secrets.ini before any
        # token has ever resolved, or every target's login keys once
        # RetroAchievements is switched off) writes nothing even after
        # this "recreate" branch is taken. Noting it here unconditionally
        # used to fire on every single launch for exactly that file, every
        # time, for a recreation that never happened; `set_ini_settings`
        # carries the note now, only once it has confirmed one does.
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


def set_ini_settings(
    path: Path, sections: Mapping[str, Mapping[str, str | Removal]]
) -> bool:
    """Assert owned keys in an INI file with sections. Returns whether it wrote.

    Comments, blank lines, key order and every key the flake does not own are
    kept as they were. A key missing from a section it belongs to is appended
    to that section; a missing section is appended to the file.

    A key whose value is `REMOVE` is deleted from the file instead, with the
    same properties: everything around it survives, and removing a key that
    is not there is a no-op that reports no write. Every occurrence of it
    goes - in every instance of its section, and in the headerless preamble
    - because that is what `Removal` promises; a same-named key under some
    other section is left alone.

    A file in which nothing at all is owned is left alone entirely - not
    parsed, not recreated, not mentioned. PCSX2 declares `secrets.ini` with
    no keys of its own, so a document carrying no retroachievements
    namespace (design D1's null) never touches that file. Without this
    guard `_render_ini({})` wrote a lone newline, which the parser read
    back as an empty file, so the box rewrote it and logged "is empty;
    recreating it" before every single launch, forever.

    A file whose owned keys are *all* removals is a different case, and one
    `secrets.ini` reaches on every launch that resolves no token and every
    launch of a box with RetroAchievements switched off: it is parsed, and
    if it turns out to be present but unparseable it is recreated, since a
    recreation is the only way a removal can be kept against a file no
    parser can see into. See `_holds_something`.
    """
    if not any(sections.values()):
        return False

    lines = _parse_ini(path)
    if lines is None:
        fresh = {section: _without_removals(keys) for section, keys in sections.items()}
        if not any(fresh.values()) and not _holds_something(path):
            # Every owned key in this file is a removal and there is
            # genuinely nothing on disk to remove them from: creating a
            # file to hold nothing would only be recreated on the next
            # launch. A file that is present but unparseable does *not*
            # take this branch (see `_holds_something`): it falls through
            # to the recreation below, which is what takes the credential
            # off the disk - and what makes the note about to be printed
            # true rather than a lie repeated before every launch.
            return False
        # The empty-file note, deferred from `_parse_ini` (see its own
        # comment): only worth telling the journal once a write is
        # actually about to happen, which the branch above has just
        # confirmed. `_read_quietly`, not `_parse_ini` again, so this
        # probe stays silent about anything other than emptiness - an
        # unreadable or malformed file already noted its own reason inside
        # `_parse_ini`/`_read_text`.
        probe = _read_quietly(path)
        if probe is not None and not probe.strip():
            note(f"{path} is empty; recreating it")
        _write(path, _render_ini(fresh))
        return True

    changed = False

    # Removals sweep the whole file first, in a pass of their own. First
    # because a removal is not confined to one section's bounds (see
    # `_sweep_key`) and deleting a line shifts every index after it, so
    # doing this alongside the writes below would invalidate the bounds
    # they are holding; a pass that finishes before the next one starts
    # cannot.
    for section, keys in sections.items():
        for key, value in keys.items():
            if isinstance(value, Removal) and _sweep_key(lines, key, section):
                changed = True

    for section, keys in sections.items():
        writes = _without_removals(keys)
        if not writes:
            continue  # every owned key here was a removal, already swept
        bounds = _ini_section_bounds(lines, section)
        if bounds is None:
            lines.extend(_render_ini({section: writes}).splitlines())
            changed = True
            continue
        start, end = bounds
        for key, value in writes.items():
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


def _sweep_key(lines: list[str], key: str, section: str | None) -> bool:
    """Delete every assignment of `key` this file's owner could mean. In place.

    What `REMOVE` promises (see `Removal`), rather than what a single
    index lookup can deliver. For an INI file `section` names the one the
    key belongs to and the sweep covers every instance of it - two
    `[Achievements]` headers in one file is a shape a torn or hand-edited
    file can take - plus the headerless preamble above the first header,
    since an assignment there belongs to no section and so no other
    section's owner can claim it. Assignments under a *different* section
    are left alone: those genuinely belong to somebody else.

    `section=None` is RetroArch's flat file, which has no sections at all,
    so every line is a candidate.

    Indices are collected in one forward pass and deleted in reverse, so no
    deletion invalidates an index still to be used; callers must run this
    to completion before computing any section bounds of their own.
    """
    doomed: list[int] = []
    current: str | None = None  # the preamble, until the first header
    for index, line in enumerate(lines):
        if section is not None:
            match = _INI_SECTION_RE.match(line)
            if match is not None:
                current = match.group("name")
                continue
            if current is not None and current != section:
                continue
        assignment = _split_ini_assignment(line)
        if assignment is not None and assignment[1] == key:
            doomed.append(index)
    for index in reversed(doomed):
        del lines[index]
    return bool(doomed)


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


def set_retroarch_settings(path: Path, keys: Mapping[str, str | Removal]) -> bool:
    """Assert owned keys in RetroArch's flat config. Returns whether it wrote.

    Same properties as the INI editor: comments, order and unowned keys are
    preserved, a missing key is appended, every assignment of a key valued
    `REMOVE` is deleted, an unreadable file is recreated carrying the owned
    keys, and a file with no owned keys is left alone.
    """
    if not keys:
        return False

    lines = _parse_retroarch(path)
    if lines is None:
        fresh = _without_removals(keys)
        if not fresh and not _holds_something(path):
            # The INI editor's guard, with the same reasoning: absent means
            # write nothing, unparseable means recreate, because only the
            # recreation drops a credential a parser cannot see. Unreachable
            # in this configuration - RetroArch's target owns static keys
            # too, so `fresh` is never empty - but the two editors keep the
            # same rule so a later target cannot inherit the bug back.
            return False
        _write(path, _render_retroarch(fresh))
        return True

    changed = False
    # Removals first and file-wide, the INI editor's rule for the same
    # reasons: `REMOVE` promises absence, and a deletion moves every index
    # after it.
    for key, value in keys.items():
        if isinstance(value, Removal) and _sweep_key(lines, key, None):
            changed = True

    for key, value in _without_removals(keys).items():
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


# --- RetroAchievements: login and the token cache (design D2) ------------

# Bound on the in-path login2 call. A module-level constant rather than a
# JSON field: the JSON already carries the API URL, and a slow-or-flaky
# network is exactly what this timeout exists to cap, not something a host
# should be tuning per box. Kept overridable per call so tests can exercise
# the timeout path itself without the suite paying 5 seconds for it.
LOGIN_TIMEOUT = 5.0

# The three outcomes of a login attempt, spelled as a type so a typo in a
# comparison against one of them is a checker error rather than a branch
# that silently never runs.
LoginOutcome = Literal["success", "rejected", "unreachable"]

# The most of a login2 response body this program will read. RA's is a few
# hundred bytes; a bare `read()` would let a server that never stops sending
# fill the box's memory instead.
_MAX_LOGIN_BODY = 65536

# The cache is a bearer credential like the secrets it is derived from, so
# it gets their mode regardless of what a previous run - or an admin's `chmod`
# - left it at. `_write` preserves an existing file's mode for ordinary
# owned config, which is the wrong policy here on purpose.
_CACHE_MODE = 0o600


def _is_usable_token(token: str) -> bool:
    """Whether a token is a single line of characters safe to write to a config.

    The value arrives from an HTTP response body and flows straight into
    every supporting emulator's configuration, so a newline in it is an
    injection with two shapes, both of them reproduced:

    - `"tok\nCheevos_evil = 1"`: the injected line parses as a setting, so
      the assert-and-compare never matches, so the file is rewritten and
      grows by one line before every launch, forever.
    - `"tok\nJUST-GARBAGE"`: the injected line fails the syntax check, so
      from the second run the file goes through the recreate path and every
      unowned preference in it is destroyed - real data loss, on every
      launch, from one field of a response body.

    RA's tokens are short printable ASCII, so demanding a non-empty
    printable string with no whitespace costs nothing real and turns the
    whole class into an ordinary "no token this run". `str.isprintable` is
    already False for a newline or any other control character but True
    for a plain space, which is what the second half covers.
    """
    return bool(token) and token.isprintable() and not any(c.isspace() for c in token)


def _write_credential(path: Path, content: str) -> bool:
    """Write a bearer credential at mode 0600. Returns whether it wrote.

    Read and compare first, like every editor in this file. Two reasons,
    both about this appliance rather than tidiness: the file lives on
    flash, and this program runs on the critical path before every single
    launch of the frontend, so writing identical content again costs a
    fresh inode plus two fsyncs per launch for nothing.

    The mode is still corrected when the content matches, because a box
    that is offline for months may never take the write branch again and
    this is a bearer token, not a preference.

    An `OSError` is noted and swallowed: a cache that cannot be refreshed
    must not cost the caller the token it just obtained, and nothing under
    this namespace may cost the session (design D2).
    """
    try:
        if _read_quietly(path) == content:
            if stat.S_IMODE(path.stat().st_mode) != _CACHE_MODE:
                path.chmod(_CACHE_MODE)
            return False
        _write(path, content, mode=_CACHE_MODE)
    except OSError as error:
        note(f"{path} could not be written ({error}); continuing without it")
        return False
    return True


def _remove_credential(path: Path, *, prune_empty_parent: bool = False) -> None:
    """Delete a credential file if there is one, noting a refusal.

    `unlink` on a directory, or in a directory that is not writable, is an
    `OSError` - and on the rejected-login path that exception would
    otherwise escape a step that must never cost more than the
    achievements.

    `prune_empty_parent` is for the token cache, and only for it: the cache
    has a directory of its own (`retroachievements/` under the appdata
    root), so removing the file otherwise leaves an empty directory sitting
    there on a box that has switched the feature off, which is meant to
    look like a box that never had it on. `rmdir` removes an empty
    directory and nothing else, so it cannot take a neighbour with it, and
    it stays silent because a directory that is not empty - or not there -
    is the ordinary case rather than a refusal worth a journal line. Not
    passed for the emulators' own token files, which live in directories
    the emulator owns.
    """
    try:
        path.unlink(missing_ok=True)
    except OSError as error:
        note(f"{path} could not be removed ({error}); continuing")
        return
    if prune_empty_parent:
        try:
            path.parent.rmdir()
        except OSError:
            pass


def _resolve_path(root: Path, value: str) -> Path:
    """A path from the retroachievements namespace, resolved like `files`.

    Same convention as the file map's paths (module docstring): relative
    resolves under the appdata root, absolute is used as written. `Path.
    __truediv__` already implements exactly this rule - joining an absolute
    path onto another discards the left side - which is also why `main`'s
    own `root / relative` needs no such check; this is a named alias for
    the same behaviour so every call site in this namespace reads the same
    way. The secrets store paths are always absolute in practice, but one
    rule for every path in the namespace is one less thing to get wrong.
    """
    return root / value


def _read_secret(path: Path) -> str | None:
    """A credential file's content, less the single trailing newline sops adds.

    Exactly that one newline, never `.strip()`: a RetroAchievements password
    may begin or end with a space, and stripping it made such an account
    impossible to log in with while the failure looked like an ordinary
    rejection - the box would drop its cache and start every session with
    achievements absent, with nothing in the journal pointing at the cause.

    None on any read failure - missing, a directory, permission denied, or
    bytes that are not valid UTF-8. `UnicodeDecodeError` is a `ValueError`
    subclass, not an `OSError` one, so it needs its own except clause -
    `_read_text` a screen away already gets this right, and a credential
    file or cache is exactly the kind of thing a power cut at the wall (the
    module docstring's routine failure mode on this appliance) can leave
    mid-write. Every case is a configuration problem rather than a broken
    call site (behaviour step 1), so it is noted and the login for this run
    is simply skipped; the program does not fail and does not exit non-zero.
    """
    try:
        text = path.read_text()
    except (OSError, UnicodeDecodeError) as error:
        note(f"{path} could not be read ({error})")
        return None
    return text[:-1] if text.endswith("\n") else text


def _read_cached_token(path: Path) -> str | None:
    """The cached token, or None if there is no usable one.

    A missing file is the ordinary state before any login has ever
    succeeded - silent, not noted. Anything else (permission denied, a
    directory where the cache should be, or bytes that are not valid UTF-8
    - a `UnicodeDecodeError`, a `ValueError` subclass rather than an
    `OSError` one, and just as plausible for a cache as for a credential
    file after a power cut) is noted, because that is a cache that should
    have been usable and was not.
    """
    try:
        cached = path.read_text().strip()
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError) as error:
        note(f"{path} could not be read ({error})")
        return None
    if not cached:
        return None
    if not _is_usable_token(cached):
        # The other route a hostile or corrupted token takes into the
        # configs, and the one a bad login leaves behind on disk for every
        # later run: validated here as well as at the login, or one
        # scrambled cache file poisons every boot until someone deletes it.
        note(f"{path} holds a token this program will not write to a config")
        return None
    return cached


def _login2(
    api_url: str, username: str, password: str, timeout: float
) -> tuple[LoginOutcome, str | None]:
    """The login2 call of `_login2_request`, under a wall-clock deadline.

    `urlopen`'s own `timeout` is a per-socket-operation deadline, not a
    total one: a server dribbling one byte every two seconds resets it on
    every byte and blocks forever, and `socket.getaddrinfo` does not honour
    it at all, so a blackholed DNS server costs the resolver's own budget -
    tens of seconds - before the timeout is even armed. Either one strands
    the box on a black screen, which is exactly what the spec's "the
    network never blocks the session" and design D2's "worst case adds 5 s
    before the frontend" forbid. Only a deadline around the whole call
    delivers them.

    A daemon thread joined with the timeout, rather than
    `signal.setitimer`/SIGALRM: signals only work on the main thread of the
    main interpreter, which is true of prepare today but stops being true
    the moment anything calls this from a worker (the test suite already
    drives it from several), and the signal route would also have to save
    and restore whatever handler was installed. The abandoned work is one
    socket read on a thread nobody joins: it is a daemon, so it cannot hold
    the process open past `main` returning, and the per-socket timeout is
    still passed down so it does not sit there forever in the ordinary
    case. Nothing it could still append is read after the deadline.
    """
    outcome: list[tuple[LoginOutcome, str | None]] = []

    def attempt() -> None:
        try:
            outcome.append(_login2_request(api_url, username, password, timeout))
        except Exception as error:
            # A thread that dies with an exception would otherwise print a
            # bare traceback through threading's excepthook and leave the
            # caller to infer the failure from an empty list. The RA step
            # costs the achievements and nothing else (design D2), so it
            # gets a journal line and the catch-all outcome.
            note(f"the RetroAchievements login failed unexpectedly ({error!r})")
            outcome.append(("unreachable", None))

    worker = threading.Thread(target=attempt, daemon=True, name="emubox-ra-login2")
    worker.start()
    worker.join(timeout)
    if not outcome:
        return "unreachable", None
    return outcome[0]


def _login2_request(
    api_url: str, username: str, password: str, timeout: float
) -> tuple[LoginOutcome, str | None]:
    """POST RetroAchievements' login2 API, form-encoded per the RA docs.

    Returns exactly one of three outcomes, matching design D2's
    three-way classification:

    - ("success", token): the service answered with valid JSON,
      `Success: true` and a token.
    - ("rejected", None): the service answered and said no - explicit
      `Success: false`, or HTTP 401/403 without even inspecting a body,
      since those codes are RA's documented way of saying the same thing.
    - ("unreachable", None): anything else - a transport error, a timeout,
      a 5xx, or a 200 whose body does not parse as the expected JSON. This
      is deliberately the catch-all: a response this program cannot make
      sense of must never be mistaken for a rejection, or a working
      account could have its cached token deleted by a service hiccup.
    """
    body = urllib.parse.urlencode(
        {"r": "login2", "u": username, "p": password}
    ).encode()
    try:
        # Inside the try, not above it: `Request` raises
        # `ValueError("unknown url type")` for a URL whose scheme it does not
        # recognise, and a malformed `api_url` has to cost the achievements
        # like every other login failure rather than the whole session.
        request = urllib.request.Request(api_url, data=body, method="POST")
        # S310 flags urlopen for an unbounded scheme (file://, etc.), which
        # matters when the URL comes from somewhere untrusted. Here it comes
        # from the retroachievements namespace's `api_url`, which - like
        # every other path in the owned-values document - is a store path
        # the module rendered, not anything a user or the network supplies;
        # the same trust boundary the rest of this program already assumes.
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
            raw = response.read(_MAX_LOGIN_BODY)
    except urllib.error.HTTPError as error:
        # HTTPError is also an OSError (it subclasses URLError), so it must
        # be caught ahead of the broad except below to read its status code.
        if error.code in (401, 403):
            return "rejected", None
        return "unreachable", None
    except (OSError, ValueError, http.client.HTTPException, RecursionError):
        # Four families, none of which may reach `main`:
        #
        # - OSError: connection refused, DNS failure, and a timeout, which
        #   surfaces as TimeoutError - itself an OSError, not wrapped in
        #   HTTPError since no response was ever received to have a status.
        # - ValueError: the unrecognised URL scheme above.
        # - http.client.HTTPException: a listener that answers with
        #   something that is not HTTP at all - BadStatusLine, LineTooLong.
        #   It is *not* an OSError, so it needs naming; anything on the
        #   network can produce it.
        # - RecursionError: raised rather than returned by the redirect
        #   handling, and not an OSError either.
        return "unreachable", None

    try:
        payload = json.loads(raw)
    except (ValueError, RecursionError):
        # RecursionError beside ValueError because a deeply nested array is
        # how `json.loads` fails on a hostile or corrupted body, and it is
        # not a ValueError subclass.
        return "unreachable", None
    if isinstance(payload, dict) and payload.get("Success") is True:
        token = payload.get("Token")
        if isinstance(token, str) and _is_usable_token(token):
            return "success", token
        if isinstance(token, str) and token:
            note(
                "the RetroAchievements API returned a token this program will not write to a config"
            )
            # Falls through to "unreachable" rather than "rejected": the
            # credentials were fine, so nothing may drop the cache, and an
            # offline-shaped outcome is exactly what this is.
    if isinstance(payload, dict) and payload.get("Success") is False:
        return "rejected", None
    return "unreachable", None


def resolve_retroachievements_token(
    ra: Mapping[str, object], root: Path, *, timeout: float = LOGIN_TIMEOUT
) -> tuple[str, str] | None:
    """The (username, token) pair to fold into the owned tables, or None.

    None is step 4's no-token outcome: the caller still writes `enabled` and
    `hardcore`, but leaves `username` and `token` out of every table rather
    than write an absent or stale account.

    A reachable API is always consulted first - the cache is an
    offline-only fallback, never a shortcut that pre-empts a working
    network - which is what lets a token revoked by a password change heal
    on the next boot with no manual step (design D2).
    """
    username_file = _resolve_path(root, str(ra["username_file"]))
    password_file = _resolve_path(root, str(ra["password_file"]))
    cache_file = _resolve_path(root, str(ra["cache_file"]))

    username = _read_secret(username_file)
    password = _read_secret(password_file)
    if username is None or password is None:
        # Already noted by _read_secret above. No login is attempted at
        # all: the cache stands in only for a reachable-but-failing
        # network, never for credentials this program could not even read.
        return None

    outcome, token = _login2(str(ra["api_url"]), username, password, timeout)

    if outcome == "success":
        assert token is not None  # "success" always carries one
        _write_credential(cache_file, token)
        return username, token

    if outcome == "rejected":
        note("the RetroAchievements API rejected the login; dropping any cached token")
        _remove_credential(cache_file, prune_empty_parent=True)
        return None

    # outcome == "unreachable": fall back to the cache if one is readable;
    # otherwise this run continues with no token (behaviour steps 2-3). Two
    # distinct messages, not one worded as if a fallback always happens: the
    # exact no-network-no-cache case the spec calls out must not read in the
    # journal as though a cached token were used when there was none.
    cached = _read_cached_token(cache_file)
    if cached is not None:
        note(
            "could not reach the RetroAchievements API; falling back to the cached token"
        )
        return username, cached
    note("could not reach the RetroAchievements API and no cached token exists")
    return None


# --- DuckStation's encrypted token (design D3) ----------------------------


def _duckstation_key_iv(machine_id: bytes, username: str) -> tuple[bytes, bytes]:
    """The AES-128-CBC key and IV DuckStation v0.1-11752 derives for one account.

    SHA-256 over the machine id file's raw bytes followed by the username's
    UTF-8 bytes gives a seed digest; "100 further rounds" (design D3, and
    the Context section's verified reading of `achievements.cpp`) then
    re-hashes that seed 100 more times. That is 101 SHA-256 calls in total,
    not 100 - the seed digest is the *result* of the first call, and the
    100 further rounds start from it rather than being counted from zero.
    Getting this off by one silently produces a token DuckStation rejects,
    since the whole scheme has no error signal of its own; only a fixed
    test vector catches a regression here.
    """
    digest = hashlib.sha256(machine_id + username.encode()).digest()
    for _ in range(100):
        digest = hashlib.sha256(digest).digest()
    return digest[:16], digest[16:32]


def encrypt_duckstation_token(machine_id: bytes, username: str, token: str) -> str:
    """The base64 ciphertext DuckStation v0.1-11752 stores as `Cheevos.Token`.

    AES-128-CBC over the token's UTF-8 bytes, zero-padded up to the next
    16-byte block boundary (not PKCS#7 - DuckStation pads with zero bytes,
    and a token that already lands on a block boundary gets no padding at
    all). The scheme has no randomness: the same three inputs always
    produce the same string, which is what lets the write path treat it
    like any other owned value under the ordinary assert-and-compare flow.
    """
    key, iv = _duckstation_key_iv(machine_id, username)
    plaintext = token.encode()
    plaintext += b"\x00" * ((-len(plaintext)) % 16)
    encryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    ciphertext = encryptor.update(plaintext) + encryptor.finalize()
    return base64.b64encode(ciphertext).decode()


def _current_ini_value(path: Path, section: str, key: str) -> str | None:
    """The value already on disk for one INI key, read quietly.

    Deliberately not the editors' `_parse_ini`: that parser's job is to
    decide whether a file is healthy enough to edit in place, and it notes
    ("recreating it") whenever it is not. Calling it here - purely to see
    what a key currently holds - would print a spurious recreation notice
    before this run has decided to write anything. A missing file, an
    unreadable one or a key that is not there all mean the same thing here:
    there is nothing to compare against, so treat it as changed.
    """
    text = _read_quietly(path)
    if text is None:
        return None
    lines = _lines(text.rstrip("\n"))
    bounds = _ini_section_bounds(lines, section)
    if bounds is None:
        return None
    index = _ini_key_index(lines, *bounds, key)
    if index is None:
        return None
    assignment = _split_ini_assignment(lines[index])
    assert assignment is not None  # _ini_key_index only matches these
    return assignment[2].strip()


def duckstation_login_values(
    root: Path, target: Mapping[str, object], username: str, token: str
) -> dict[str, str]:
    """The username/token/login_timestamp values for one duckstation target.

    Returns "username" and "token" (already encrypted, ready to write
    verbatim) unconditionally, and "login_timestamp" only when the target
    declares that key and the newly encrypted token differs from what the
    ini file already holds - design D3's change-gating, without which an
    unchanged token would still rewrite the file, and its timestamp, on
    every single run. An unreadable machine-id file notes the failure and
    returns an empty mapping, so the caller folds in no username or token
    for this target while still writing its enabled and hardcore keys.
    """
    machine_id_file = _resolve_path(root, str(target["machine_id_file"]))
    try:
        machine_id = machine_id_file.read_bytes()
    except OSError as error:
        note(f"{machine_id_file} could not be read ({error}); skipping its RA login")
        return {}

    encrypted = encrypt_duckstation_token(machine_id, username, token)
    values = {"username": username, "token": encrypted}

    keys_value = target.get("keys")
    if isinstance(keys_value, dict) and "login_timestamp" in keys_value:
        # `cast`, not the `isinstance` narrowing alone, because a checker
        # narrows `isinstance(x, dict)` on an `object` to an unparameterized
        # `dict` that cannot then be subscripted by a `str` key (dict is
        # invariant in its type parameters). The owned-values document's
        # shape is validated at the top of `main` before any target is
        # built, so treating this as `Mapping[str, object]` here is a
        # checker accommodation, not a real type hazard.
        keys = cast("Mapping[str, object]", keys_value)
        token_entry = cast("Mapping[str, object]", keys["token"])
        current = _current_ini_value(
            _resolve_path(root, str(token_entry["file"])),
            str(token_entry["section"]),
            str(token_entry["key"]),
        )
        if current != encrypted:
            values["login_timestamp"] = str(int(time.time()))

    return values


# --- RetroAchievements: the owned-table merge (design D1, D2) -------------
#
# The only emulator-specific spelling this program tolerates is the
# `encoding` discriminator below - which at-rest form a target's token
# takes - never a key name or a file path, which arrive from the JSON.

# The keys a resolved login fills in, and exactly the set removed when none
# resolves. Names in this namespace's own vocabulary, not any emulator's:
# each target maps them to its own spellings in its `keys` table.
_LOGIN_KEYS = ("username", "token", "login_timestamp")


def _target_validation_error(
    files: Mapping[str, object], target: Mapping[str, object]
) -> str | None:
    """Why a target's declared shape is a broken call site, or None if sound.

    Every check is about the document a module rendered - a key naming a
    file `files` does not declare, an ini key missing its `section`, a
    retroarch key carrying one it must not, an encoding declaring the wrong
    set of keys - never about anything read at runtime. A target that fails
    here means `main` returns 1, the same policy as an unreadable
    owned-values document. A runtime failure (network, credentials, a
    missing machine id) degrades the tables written instead, and never
    reaches this function.
    """
    name = target.get("name", "<unnamed>")
    encoding = target.get("encoding")
    keys = target.get("keys")
    if not isinstance(keys, dict):
        return f"retroachievements target {name!r}: expected 'keys' to be an object"

    # enabled/hardcore/username are written for every encoding (design D2);
    # token is only for the two encodings that keep it in a `files` key at
    # all - secret-file's token lives in `token_file` instead, checked below.
    required = {"enabled", "hardcore", "username"}
    if encoding in ("plain", "duckstation"):
        required.add("token")
    missing = sorted(required - keys.keys())
    if missing:
        return f"retroachievements target {name!r}: missing key(s) {missing}"

    for key_name, raw_entry in keys.items():
        if not isinstance(raw_entry, dict):
            return f"retroachievements target {name!r}.{key_name}: expected an object"
        entry = cast("Mapping[str, object]", raw_entry)
        key_spelling = entry.get("key")
        if not isinstance(key_spelling, str) or not key_spelling:
            # Subscripted bare by `_merge_target_key`, so an entry that
            # carries a `file` but no `key` used to pass validation and then
            # die with `KeyError 'key'` several screens later.
            return (
                f"retroachievements target {name!r}.{key_name}: "
                "expected a non-empty 'key'"
            )
        file_name = entry.get("file")
        raw_file_table = files.get(file_name) if isinstance(file_name, str) else None
        if not isinstance(raw_file_table, dict):
            return (
                f"retroachievements target {name!r}.{key_name}: "
                f"{file_name!r} is not declared in 'files'"
            )
        # `cast`, not the bare `isinstance` narrowing above, because a
        # checker narrows `isinstance(x, dict)` on an `object` to an
        # unparameterized `dict` that cannot then be subscripted or `.get`
        # by a `str` key (dict is invariant in its type parameters).
        file_table = cast("Mapping[str, object]", raw_file_table)
        file_format = file_table.get("format")
        if not isinstance(file_format, str):
            return (
                f"retroachievements target {name!r}.{key_name}: "
                f"{file_name!r} is not declared in 'files'"
            )
        if file_format not in ("ini", "retroarch"):
            # Covers esde-xml explicitly and any other format the files map
            # might one day carry: neither shape below is one this merge
            # knows how to fold a key into.
            return (
                f"retroachievements target {name!r}.{key_name}: "
                f"{file_name!r} has format {file_format!r}, which cannot "
                "carry a retroachievements key"
            )
        if file_format == "ini" and "section" not in entry:
            return (
                f"retroachievements target {name!r}.{key_name}: "
                f"{file_name!r} is an ini file and needs a 'section'"
            )
        if file_format == "retroarch" and "section" in entry:
            return (
                f"retroachievements target {name!r}.{key_name}: "
                f"{file_name!r} is a retroarch file and must not carry a 'section'"
            )

    booleans = target.get("booleans")
    if (
        not isinstance(booleans, dict)
        or "true" not in booleans
        or "false" not in booleans
    ):
        return f"retroachievements target {name!r}: expected 'booleans' with 'true' and 'false'"

    if encoding == "secret-file":
        if "token" in keys:
            return f"retroachievements target {name!r}: secret-file must not declare 'token'"
        if not target.get("token_file"):
            return f"retroachievements target {name!r}: secret-file needs 'token_file'"
    elif encoding in ("plain", "duckstation"):
        if target.get("token_file"):
            return f"retroachievements target {name!r}: {encoding} must not carry 'token_file'"
        if encoding == "duckstation" and not target.get("machine_id_file"):
            # `duckstation_login_values` subscripts it bare, and the whole
            # scheme is derived from that file (design D3), so a target
            # declaring the encoding without it is a broken call site.
            return f"retroachievements target {name!r}: duckstation needs 'machine_id_file'"
    else:
        return f"retroachievements target {name!r}: unknown encoding {encoding!r}"

    return None


def _merge_target_key(
    files: dict[str, object], entry: Mapping[str, object], value: str | Removal
) -> None:
    """Fold one key entry's value into its file's own keys table, in place.

    The file's format decides the shape - ini's `{section: {key: value}}`,
    retroarch's flat `{key: value}` - so the unmodified editors write it.
    Only ever called after `_target_validation_error` has confirmed the
    file is declared and the entry's shape matches its format.
    """
    file_table = cast("dict[str, object]", files[str(entry["file"])])
    file_keys = cast("dict[str, object]", file_table.setdefault("keys", {}))
    if file_table.get("format") == "ini":
        section = cast(
            "dict[str, object]", file_keys.setdefault(str(entry["section"]), {})
        )
        section[str(entry["key"])] = value
    else:  # "retroarch" - the only other format a validated entry can name
        file_keys[str(entry["key"])] = value


def _apply_secret_file_token(
    root: Path, target: Mapping[str, object], resolved: tuple[str, str] | None
) -> None:
    """Write or remove a secret-file target's whole-file token (PPSSPP).

    The file IS the token - no section, no key framing - so it is written
    directly rather than through the `files` map's editors, with the same
    mode-0600 treatment as the login cache: it is a credential, not an
    ordinary preference. No token resolved this run - offline with no
    cache, a rejection, unreadable credentials - removes any file a
    previous run left, so no stale token survives; the spec's offline
    scenario is explicit that no configuration may carry one.
    """
    token_file = _resolve_path(root, str(target["token_file"]))
    if resolved is None:
        _remove_credential(token_file)
        return
    _, token = resolved
    # No trailing newline: PPSSPP's login path reads the file's raw bytes
    # as the token with no line-oriented parsing shown to tolerate one, so
    # the conservative choice, absent a way to confirm otherwise, is none.
    _write_credential(token_file, token)


def _apply_retroachievements_disabled_cleanup(
    files: dict[str, object],
    targets: Sequence[Mapping[str, object]],
    root: Path,
    cache_file: Path,
) -> None:
    """Remove every credential this program may have written, with no login.

    Called instead of the ordinary login flow whenever the namespace's own
    `enabled` field is false. `raDisabledFiles` (modules/emulators) already
    forces `enabled`/`hardcore` off as ordinary static owned keys the
    moment the option is flipped, with no runtime step involved - so this
    function's whole job is the credentials those two keys don't touch:
    the account name and token in every target's own config file (the same
    `keys` table the enabled path writes them through), PPSSPP's
    whole-file token, and the cached login token under the appdata root.
    Before this existed, switching the feature off left a stale username
    and a live bearer token sitting in every one of those places - `enable
    = false` did not mean the account's credentials came off the box.

    Every operation here is a `REMOVE` of a key that may already be absent
    or an `unlink(missing_ok=True)` of a file that may already be gone -
    exactly the two primitives the ordinary no-token-resolved path already
    uses below - so a box that never had the feature enabled, or one
    already switched off, changes nothing and logs nothing on a later run:
    the same idempotency every other step in this program keeps.
    """
    for target in targets:
        keys = cast("Mapping[str, object]", target["keys"])
        for login_key in _LOGIN_KEYS:
            entry = keys.get(login_key)
            if isinstance(entry, dict):
                _merge_target_key(files, cast("Mapping[str, object]", entry), REMOVE)
        token_file = target.get("token_file")
        if token_file:
            _remove_credential(_resolve_path(root, str(token_file)))
    _remove_credential(cache_file, prune_empty_parent=True)


def apply_retroachievements(
    files: dict[str, object], retroachievements: Mapping[str, object], root: Path
) -> int:
    """Fold every retroachievements target's values into `files`, in place.

    Returns 0 on success, 1 on a broken call site (already noted) - a
    target whose declared shape does not match its file's format, or that
    mixes an encoding with the wrong token declaration. Runtime failures
    (network, credentials, a missing machine id) are never call-site
    failures: they degrade to fewer keys written - enabled and hardcore
    always, username and token only when a login actually resolved one -
    never a non-zero return (design D2's whole point).

    The namespace's own `enabled` field (default true, for every call site
    that predates it) picks which of two things happens once every target
    validates: true runs the login and writes its result as usual; false
    skips the login entirely and instead removes every credential this
    program may have written, through `_apply_retroachievements_disabled_cleanup`
    above.
    """
    # The namespace's own fields, checked before anything reads them. Each
    # is subscripted bare further down - `ra["username_file"]` and the rest
    # in the login - so a document missing one produced a `KeyError`
    # traceback rather than the journal line an admin reading `journalctl`
    # needs, which is the very thing this validation exists to give them.
    for field in ("username_file", "password_file", "cache_file", "api_url"):
        field_value = retroachievements.get(field)
        if not isinstance(field_value, str) or not field_value:
            note(f"retroachievements: expected {field!r} to be a non-empty string")
            return 1

    # A JSON string like "false" is truthy under plain `bool(...)`, so this
    # field gets the same call-site policy as everything else in the
    # namespace instead of silently doing the wrong thing.
    hardcore_value = retroachievements.get("hardcore", False)
    if not isinstance(hardcore_value, bool):
        note(
            "retroachievements: expected 'hardcore' to be a boolean, got "
            f"{type(hardcore_value).__name__}"
        )
        return 1

    # Absent defaults to true rather than being required: every call site
    # written before this field existed - this program's own test suite
    # included - has no opinion on it, and true is what keeps every one of
    # them exercising the ordinary login flow unchanged. False has to be
    # spelled out on purpose.
    enabled_value = retroachievements.get("enabled", True)
    if not isinstance(enabled_value, bool):
        note(
            "retroachievements: expected 'enabled' to be a boolean, got "
            f"{type(enabled_value).__name__}"
        )
        return 1

    targets = retroachievements.get("targets", [])
    if not isinstance(targets, list):
        note("retroachievements: expected 'targets' to be an array")
        return 1

    validated: list[Mapping[str, object]] = []
    for raw_target in targets:
        if not isinstance(raw_target, dict):
            note("retroachievements: expected each target to be an object")
            return 1
        target = cast("Mapping[str, object]", raw_target)
        error = _target_validation_error(files, target)
        if error is not None:
            note(error)
            return 1
        validated.append(target)

    if not enabled_value:
        # No login attempted at all - the spec's own requirement for the
        # disabled case - and the cache_file field was already confirmed a
        # non-empty string above, so subscripting it bare here is safe.
        cache_file = _resolve_path(root, str(retroachievements["cache_file"]))
        _apply_retroachievements_disabled_cleanup(files, validated, root, cache_file)
        return 0

    # The login happens once per run, ahead of every target, rather than
    # once per target: one account serves every supporting emulator.
    resolved = resolve_retroachievements_token(retroachievements, root)
    hardcore = hardcore_value

    # Every mutation the loop below makes - `_merge_target_key` and
    # `_apply_secret_file_token` - runs against a `target` that
    # `_target_validation_error` has already confirmed matches its file's
    # format, so the only way any of it could raise is a bug in that
    # validation itself, not a runtime condition (network, credentials, a
    # missing machine id) this loop's own callers already degrade
    # gracefully instead of raising. `files` is mutated in place rather
    # than built into a copy and swapped in on success for exactly that
    # reason: a raise partway through would leave `files` holding a mix of
    # targets already merged and targets not yet reached, but nothing left
    # in this loop is reachably capable of raising once validation has
    # passed, so that partial state is not a real failure mode to guard
    # against - and `main`'s own blanket `except Exception` around this
    # whole call exists for the unforeseen case anyway (design D2: any
    # runtime failure here costs the achievements and nothing else).
    for target in validated:
        booleans = cast("Mapping[str, object]", target["booleans"])
        keys = cast("Mapping[str, object]", target["keys"])
        encoding = target["encoding"]

        # enabled and hardcore are written unconditionally: this loop only
        # runs once the `enabled_value` check above has already selected
        # the login path over the cleanup one, and the emulators fail
        # their own login harmlessly with no token.
        values: dict[str, str | Removal] = {
            "enabled": str(booleans["true"]),
            "hardcore": str(booleans["true"] if hardcore else booleans["false"]),
        }

        login_values: dict[str, str] = {}
        if encoding == "duckstation":
            if resolved is not None:
                username, token = resolved
                login_values = duckstation_login_values(root, target, username, token)
        elif encoding == "plain":
            if resolved is not None:
                username, token = resolved
                login_values = {"username": username, "token": token}
        elif encoding == "secret-file":
            if resolved is not None:
                username, _token = resolved
                login_values = {"username": username}
            _apply_secret_file_token(root, target, resolved)

        if login_values:
            values.update(login_values)
        else:
            # No login this run - offline with no cache, a rejection,
            # credentials that could not be read, a machine id that could
            # not be read. Every login-derived key is *removed*, not left
            # and not blanked: the spec says a rejected login and an
            # offline boot with no cached token both start the session with
            # achievements absent, and a config still carrying yesterday's
            # username and token does not. An empty string would not do
            # either - RetroArch treats any `cheevos_token` it finds as a
            # token to log in with. PPSSPP's whole-file token already had
            # exactly this treatment; the other four now match it.
            #
            # `login_timestamp` is only ever *written* by the duckstation
            # encoding, and only when the token changed (design D3), so it
            # is removed here rather than in that branch: removing a key
            # that is not there is a no-op, so one set serves every shape,
            # and an unchanged token still leaves the file untouched.
            for login_key in _LOGIN_KEYS:
                values[login_key] = REMOVE

        for key_name, value in values.items():
            entry = keys.get(key_name)
            if isinstance(entry, dict):
                _merge_target_key(files, cast("Mapping[str, object]", entry), value)

    return 0


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
    ending the session at the greeter.

    Two failures do still raise out of here, and they are not the same kind
    of thing. An unreadable *source* raises `SystemExit`, because the source
    is a store path the module rendered and nothing but a broken call site
    can make it unreadable; that one ends the session on purpose. Everything
    the write itself can fail with - a full or read-only `/data`, a target
    that is a directory and so cannot be replaced - raises `OSError`, which
    `main` catches and degrades to a journal line, the same as it does for
    every owned file. Keeping the raise here rather than swallowing it
    inside means a caller that is not the session - a test, or an admin
    running `emubox-prepare` by hand - still learns that the write failed.

    `os.path.lexists` rather than `Path.exists` on the removal branch,
    because the latter follows a symlink and would leave a dangling one in
    place - exactly the stale entry this branch exists to clear.
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


def _owned_keys_error(table: Mapping[str, object]) -> str | None:
    """Why this file's `keys` would crash its editor, or None if it will not.

    Shape checking that belongs to `main` rather than to the editors,
    because `main` is what owes the journal a line instead of a stack
    trace (module docstring). Everything below is an `AttributeError` or a
    `TypeError` inside an editor, and the loop that calls the editors
    catches `OSError` and nothing else - deliberately, so that a bug is
    never mistaken for a full disk - so each of these would reach the top
    of the program as a traceback an admin has to read.

    Reachable from a module rather than only from a hand-written document:
    the Nix side types `ownedFiles.<file>.keys` as `attrsOf anything`, so a
    module written later that spells an ES-DE key `value = 5` or
    `value = true` renders a JSON number or boolean right here.

    Only what an editor subscripts or iterates is checked. An `ini` or
    `retroarch` value that is not a string is left alone on purpose:
    `_without_removals` keeps only the strings, so such a key is quietly
    skipped rather than written - a poor answer, but not a traceback, and
    tightening it here would reject documents that work on boxes today.
    """
    raw = table["keys"]
    if not isinstance(raw, dict):
        return f"expected 'keys' to be an object, got {type(raw).__name__}"
    # Cast rather than narrow: `isinstance` gives an empty dict type here,
    # and every lookup below would be a type error against it.
    keys = cast("dict[str, object]", raw)
    if table["format"] == "ini":
        # The INI editor iterates each section's own table.
        for section, entries in keys.items():
            if not isinstance(entries, dict):
                return (
                    f"expected section {section!r} to be an object, "
                    f"got {type(entries).__name__}"
                )
        return None
    if table["format"] != "esde-xml":
        return None
    for name, spec in keys.items():
        # `ET.Element.set` stores whatever it is handed and `ET.tostring`
        # is where a non-string finally raises, which is a long way from
        # the document that carried it.
        if not isinstance(spec, dict):
            return (
                f"expected key {name!r} to be an object with 'type' and "
                f"'value', got {type(spec).__name__}"
            )
        typed = cast("dict[str, object]", spec)
        for field in ("type", "value"):
            if not isinstance(typed.get(field), str):
                return (
                    f"expected key {name!r} to carry a string {field!r}, "
                    f"got {type(typed.get(field)).__name__}"
                )
    return None


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
        document = json.loads(Path(owned_values).read_text())
    except (OSError, ValueError, RecursionError) as error:
        # RecursionError joins the two obvious ones because `json.loads`
        # raises it rather than a ValueError on a deeply nested document,
        # and this branch's whole promise is a journal line instead of a
        # traceback.
        note(f"{owned_values} is not readable owned-values JSON ({error})")
        return 1
    if not isinstance(document, dict):
        note(
            f"{owned_values}: expected an object with 'files' and "
            f"'retroachievements', got {type(document).__name__}"
        )
        return 1
    tables = document.get("files")
    if not isinstance(tables, dict):
        note(
            f"{owned_values}: expected 'files' to be an object, "
            f"got {type(tables).__name__}"
        )
        return 1
    # Shape only, here: the namespace's own fields and every target are
    # validated by `apply_retroachievements` below, which owns them. A
    # missing key is equivalent to null (design D1) and disables the
    # feature.
    retroachievements = document.get("retroachievements")
    if retroachievements is not None and not isinstance(retroachievements, dict):
        note(
            f"{owned_values}: expected 'retroachievements' to be an object or "
            f"null, got {type(retroachievements).__name__}"
        )
        return 1
    for relative, table in tables.items():
        if not isinstance(table, dict) or "format" not in table or "keys" not in table:
            note(f"{relative}: expected an object with 'format' and 'keys'")
            return 1
        if table["format"] not in _EDITORS:
            note(f"{relative}: unknown format {table['format']!r}")
            return 1
        problem = _owned_keys_error(table)
        if problem is not None:
            note(f"{relative}: {problem}")
            return 1

    # Folded into `tables` before any editor runs, so the editors themselves
    # stay unaware that a key came from the retroachievements namespace
    # rather than the module that declared the file (design D1).
    if retroachievements is not None:
        try:
            status = apply_retroachievements(tables, retroachievements, root)
        except Exception as error:
            # The subsystem's entire contract (design D2) is that any
            # failure costs the achievements and nothing else: this program
            # runs before every launch, so an exception escaping here ends
            # the session at a greeter and nobody in the family can play.
            # `/data` full or remounted read-only after a power cut is the
            # most plausible way in, but the guard is deliberately blanket -
            # an unforeseen failure in the newest, most exposed part of the
            # program must not be able to take the frontend down with it.
            #
            # Distinct from the non-zero return below on purpose: a value of
            # 1 means the owned-values document itself is malformed, which
            # is a broken call site the greeter is the correct answer to.
            note(
                "the RetroAchievements step failed unexpectedly "
                f"({error!r}); continuing without achievements"
            )
            status = 0
        if status != 0:
            return status

    for relative, table in tables.items():
        editor = _EDITORS[table["format"]]
        try:
            editor(root / relative, table["keys"])
        except OSError as error:
            # The recreate-not-fail policy this program applies everywhere
            # else, applied to the write itself. `/data` full, remounted
            # read-only after a power cut, or a directory that cannot be
            # written are runtime conditions, not broken call sites: a file
            # that cannot be written costs that file's keys, not the
            # family's evening at the greeter (design D2).
            #
            # This loop is where the RetroAchievements credential removals
            # actually reach the disk - `apply_retroachievements` only
            # stages them into `tables`, so its own blanket guard above
            # stops short of them - which is what made this hole reachable
            # on a disabled box, the configuration nearly every real box is
            # in. Deliberately narrower than that guard: `OSError` only,
            # and only around one file, so the loop carries on to the rest.
            # The `return 1` paths above stay where they are, because a
            # malformed owned-values document is a broken call site the
            # greeter is still the correct answer to.
            note(f"{relative} could not be updated ({error}); continuing")

    try:
        install_custom_systems(
            root / "custom_systems" / "es_systems.xml", custom_systems
        )
    except OSError as error:
        # The editor loop's guard, extended to the step that follows it,
        # because this one reaches the disk through the very same `_write`
        # and so meets the very same runtime conditions: `/data` full, or
        # remounted read-only after a power cut - which is what btrfs does
        # on ENOSPC. A custom systems file that cannot be written costs the
        # extra systems it declares, not the family's evening at the greeter
        # (design D2).
        #
        # Live only since the box began shipping a real custom systems
        # document (design D5): with an empty source this call takes the
        # removal branch and never writes, which is why the editor loop got
        # its guard first.
        #
        # This deliberately swallows the target-is-a-directory case too,
        # which `install_custom_systems` still raises for. Nothing about a
        # directory in the way is more recoverable at a greeter than a full
        # disk is, and the recreate-not-fail policy this program applies
        # everywhere else says the box keeps going and says so in the
        # journal. The function keeps raising so that a caller that is not
        # the session - a test, or an admin running `emubox-prepare` by
        # hand - still sees it; it is only the session that is protected
        # from it. `SystemExit` for an unreadable *source* store path is
        # not an OSError and so still ends the session, which is correct:
        # that is a broken call site, not a broken configuration.
        note(f"the custom systems file could not be updated ({error}); continuing")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
