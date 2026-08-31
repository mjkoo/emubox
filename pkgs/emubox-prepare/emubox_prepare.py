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
value}}` for `ini`, `{key: value}` for `retroarch`. `retroachievements`,
when not null, carries the tables a later epic uses to drive the
RetroAchievements integration; a null value means the feature is disabled,
and there is no separate enabled flag inside the namespace. This program
does not yet read `retroachievements` beyond checking its shape. Later
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
    """A credential file's content, trailing whitespace stripped.

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
        return path.read_text().strip()
    except (OSError, UnicodeDecodeError) as error:
        note(f"{path} could not be read ({error})")
        return None


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
        cached_text = path.read_text().strip()
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError) as error:
        note(f"{path} could not be read ({error})")
        return None
    return cached_text or None


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
        if isinstance(token, str) and token:
            return "success", token
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
        _write(cache_file, token)
        cache_file.chmod(_CACHE_MODE)
        return username, token

    if outcome == "rejected":
        note("the RetroAchievements API rejected the login; dropping any cached token")
        cache_file.unlink(missing_ok=True)
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
    else:
        return f"retroachievements target {name!r}: unknown encoding {encoding!r}"

    return None


def _merge_target_key(
    files: dict[str, object], entry: Mapping[str, object], value: str
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
        token_file.unlink(missing_ok=True)
        return
    _, token = resolved
    # No trailing newline: PPSSPP's login path reads the file's raw bytes
    # as the token with no line-oriented parsing shown to tolerate one, so
    # the conservative choice, absent a way to confirm otherwise, is none.
    _write(token_file, token)
    token_file.chmod(_CACHE_MODE)


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
    """
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

    # The login happens once per run, ahead of every target, rather than
    # once per target: one account serves every supporting emulator.
    resolved = resolve_retroachievements_token(retroachievements, root)
    hardcore = hardcore_value

    for target in validated:
        booleans = cast("Mapping[str, object]", target["booleans"])
        keys = cast("Mapping[str, object]", target["keys"])
        encoding = target["encoding"]

        # enabled and hardcore are written unconditionally: the namespace
        # being non-null already means the feature is enabled (design D1),
        # and the emulators fail their own login harmlessly with no token.
        values: dict[str, str] = {
            "enabled": str(booleans["true"]),
            "hardcore": str(booleans["true"] if hardcore else booleans["false"]),
        }

        if encoding == "duckstation":
            if resolved is not None:
                username, token = resolved
                values.update(duckstation_login_values(root, target, username, token))
        elif encoding == "plain":
            if resolved is not None:
                username, token = resolved
                values["username"] = username
                values["token"] = token
        elif encoding == "secret-file":
            if resolved is not None:
                username, _token = resolved
                values["username"] = username
            _apply_secret_file_token(root, target, resolved)

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
    # `retroachievements` is not read yet - this group only owns the shape - but
    # a document a later epic will produce must already be rejected here if it
    # is malformed, rather than passing this program only to fail the one that
    # reads it (design D1: missing is equivalent to null).
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
        editor(root / relative, table["keys"])

    install_custom_systems(root / "custom_systems" / "es_systems.xml", custom_systems)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
