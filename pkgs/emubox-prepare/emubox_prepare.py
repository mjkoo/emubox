#!/usr/bin/env python3
"""Seed and assert the configuration keys the flake owns, and nothing else.

The kiosk session runs this before every launch of the frontend, each
relaunch included. Its whole promise is that the keys the flake declares
hold the flake's values and every other key is left exactly as the program
that owns the file last wrote it, so a preference the family changed in the
frontend's own menus survives a reboot.

Invocation contract:

    emubox-prepare <owned-values-json> <custom-systems-path>

Exactly two positional arguments, always both. `<custom-systems-path>` is
the empty string when no custom systems are configured, which is what
selects the removal branch - never an omitted argument, so the call site has
one shape. The appdata root comes from `ESDE_APPDATA_DIR`, the same variable
the frontend itself reads; if it is unset or empty this program writes
nothing and exits non-zero, because that is a broken call site rather than a
broken configuration and the session ending at the greeter is the point.

The owned-values JSON is an object with two keys:

    {
        "files": {
            "settings/es_settings.xml": {
                "format": "esde-xml",
                "enforce": {...},
                "seed": {...}
            }
        },
        "retroachievements": null
    }

`files` maps a settings file to the format of that file and the keys owned
in it. A relative path resolves under the appdata root; an absolute one is
used as written, which is how later epics reach files outside it. A per-file
table carries exactly `format`, `enforce` and `seed` - no other field, and no
alias for either - because a misspelled map (`enforced`, `seedKeys`) beside
the two correctly-spelled ones would otherwise pass silently and its keys
would never be written at all.

Both maps share one shape per format: `{name: {"type": ..., "value": ...}}`
for `esde-xml`, `{section: {key: value}}` for `ini`, `{key: value}` for
`retroarch`. What differs is when each is written and what happens to it
afterwards:

- `enforce` is the flake's own opinion. Corrected back to the declared value
  on drift, swept to one assignment when a key repeats, and removed outright
  when the value is a removal (see `Removal` below) - on every single launch.
- `seed` is only ever a starting point: written once, the first launch that
  finds no assignment of the key anywhere it could belong, and never touched
  again after that - not corrected, not swept, not removed, no matter what
  the family changes it to from inside the frontend's own menus. A key
  present with an empty value is present, and is left alone exactly like a
  key present with any other value.

One key may never be declared in both maps of the same file: which of the
two tiers it belongs to has to be a fact about the key, not something that
depends on which map a reader happens to check first. A RetroAchievements
target's login key is the one case this arises from a source other than the
document's own two maps, and it is refused for the identical reason - see
`_target_validation_error`.

`retroachievements` drives the shared RetroAchievements account. Null -
or absent - means this whole namespace is skipped: no login is
attempted and nothing under it - not even a stale credential - is ever
touched. Non-null, it carries `username_file`, `password_file` and
`cache_file` (paths, never contents: this JSON is a world-readable store
path), the `api_url`, the `hardcore` boolean, an `enabled` boolean
(absent defaults to true, for every call site written before this field
existed), and a `targets` array with one entry per supporting emulator. A
target names its `encoding` - `plain`, `duckstation` (the encrypted
at-rest form DuckStation itself keeps, which also needs a `machine_id_file`) or
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

The three editors, and what each is built on:

- ES-DE's settings file is a rootless sequence of typed XML elements, read
  through `xml.etree.ElementTree` under a wrapper element.
- Sectioned INI and RetroArch's headerless `key = "value"` file are both
  read into a line-oriented document model of this module's own: every
  line is classified as blank, comment, section header or assignment, each
  node keeps its source line verbatim, and rendering is concatenation -
  which keeps comments, ordering, indentation and every key the flake does
  not own. The grammar is this program's own statement of what the
  emulators' parsers read, stated once in the per-line classifier. A file
  may lead with a UTF-8 byte order mark - PPSSPP's own writer puts one
  there on every save - and exactly one, at the very start of the file, is
  set aside before any line is classified and written back first whenever
  the loaded document is written; a recreated file carries no mark, and a
  file holding only the mark is an empty file. A U+FEFF anywhere
  else gets no special treatment: it is content like any other codepoint,
  and the line carrying it keeps whatever behavior these rules already
  give it.

What the flat editors promise is semantic equivalence for the emulator that
reads the file: every setting it reads keeps its key, its value and its
section, and every one of its assignments where a key repeats, except the
keys the flake owns. Presentation no emulator can observe - the spacing
around a delimiter, where a line sits within its section, whether a comment
survives an edit to the line it trails - is outside that promise, and buying
it back would mean the line arithmetic this program used to carry.

An owned key ends as exactly one assignment holding the flake's value, or as
none at all when the flake declares it for removal. That matters because
every reader here resolves a repeated key to one entry, so a stale copy left
standing is the one the emulator obeys while the file does hold the flake's
value somewhere - which makes the next launch report nothing to do, forever.
For the RetroAchievements account name and token the stale copy is a bearer
credential rather than a preference.
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
from dataclasses import dataclass
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
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
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
        return path.read_text(encoding="utf-8")
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
        return path.read_text(encoding="utf-8")
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
    that way: every assignment of the key, in every instance of its section,
    plus the file's headerless preamble - not the
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
    """The keys that carry a string value.

    Two uses, one filter. On the enforce tier this is what the fresh-file
    branches build from, and its name is about the sentinel it drops: a
    `Removal` names a key to delete, never one to write. On the seed tier
    there is no sentinel to drop - a seeded value is never `REMOVE` - but
    the same call still has to run there, because `ini` and `retroarch`
    values in either tier can carry a JSON type this program never
    validates (`_owned_keys_error`'s own docstring records that decision).
    Applying the identical filter to both tiers is what keeps a wrong-typed
    seed value quietly unwritten rather than coerced to a string or handed
    to `_seed_key`'s backstop assert.
    """
    return {key: value for key, value in keys.items() if isinstance(value, str)}


def _read_back(rendered: str) -> str:
    """`rendered`, as a later read would hand it to a parser - pessimistically.

    `_read_text` reads in universal-newline mode, so a lone carriage
    return written to disk verbatim comes back as a line break; the
    round-trip checks below have to model that translation, or a `\r` in
    an owned name or value would read back fine here and destroy the file
    one launch later. Every `\r` becomes a break of its own, deliberately
    *not* collapsing `\r\n` the way universal-newline mode does: a value
    ending in `\r` folds into this program's line terminator and reads
    back clean here, but the emulator's own parser may hand that byte to
    the value instead, so the two readers would disagree about what the
    file says. A shape the readers can disagree over is refused outright
    rather than modeled away.
    """
    return rendered.replace("\r", "\n")


def _reads_back_alone(key: str, value: str, *, ini: bool) -> bool:
    """Whether `key = value` parses back as exactly that single assignment.

    The rule every owned name and value has to satisfy: the line the
    renderer would write, pushed back through this program's own parser,
    must come back as one assignment carrying the declared key and value.
    Anything else means the next launch reads the file differently than
    this one wrote it, and every such divergence is a standing failure: a
    key carrying `=` reads back as a shorter key, so the probe never finds
    it and appends a fresh copy before every launch, forever; a name with a
    comment prefix or a header shape, or either half carrying a line break,
    makes a line some later classification refuses, which sends the whole
    file - every unowned key in it - through the recreate path instead.
    """
    try:
        document = _parse_flat(_read_back(f"{key} = {value}\n"), ini=ini)
    except _Unparseable:
        return False
    if len(document.sections) != 1:
        return False
    children = document.sections[0].children
    if len(children) != 1:
        return False
    node = children[0]
    return (
        isinstance(node, Assignment) and node.key == key and node.value == value.strip()
    )


def _header_reads_back(name: str) -> bool:
    """Whether `[name]` parses back as exactly that one empty section.

    The section-name half of `_reads_back_alone`'s rule. A name carrying
    `]` is the standing case: the header grammar stops at the first closing
    bracket, so the rendered header reads back under a shorter name - or
    refuses outright as a header two plausible readers would name
    differently - and either way the next launch sends the whole file
    through the recreate path, forever.
    """
    try:
        document = _parse_flat(_read_back(f"[{name}]\n"), ini=True)
    except _Unparseable:
        return False
    return (
        len(document.sections) == 2
        and not document.sections[0].children
        and document.sections[1].name == name
        and not document.sections[1].children
    )


def _writable(
    path: Path, keys: Mapping[str, str | Removal], *, ini: bool
) -> dict[str, str | Removal]:
    """The owned keys minus any whose name or value would not read back as itself.

    `_reads_back_alone` states the rule; this applies it and owns the note.
    A multi-line value is the sharpest instance - a token of
    `"tok\nCheevos_evil = 1"` writes that second setting into the file -
    but a key name carries every hazard its value does and more, because
    the classifier reads the front of the line first: a `=`, a comment
    prefix, a bracket or surrounding whitespace in the name all make a line
    that reads back as something other than the declared setting.

    Both `\n` and `\r` break a name or value, because `_read_text` reads in
    universal-newline mode: a lone carriage return is written to disk
    verbatim and read back as a line break by this program's own reader, so
    it destroys a file exactly as a newline does, one launch later.

    `_is_usable_token` rejects the multi-line shape where a token arrives
    from a response body. This is the other end of the same path, and it is
    wider: an account name arrives from a secret file, which yields
    `"player\n"` for a file whose last line is blank, and an owned key or
    value can be declared in the flake carrying anything at all. Neither is
    validated anywhere else.

    Dropped rather than raised, and dropped for *every* branch rather than
    only at the edit path: the recreate branches build fresh assignment
    nodes without passing the edit path, so a guard there alone would let
    a recreation write the very line that destroys the file one launch
    later. The renderer's own assertion is the backstop, not the policy;
    this drop, with its note, is the policy.
    """
    writable: dict[str, str | Removal] = {}
    for key, value in keys.items():
        # A fixed probe value first, so a broken key is named as the key's
        # fault even when the declared value is a removal or broken too.
        # repr, not the bare key, because the key may be the very thing
        # carrying a line break: printed bare it would tear across lines
        # in the journal, and repr's own escaping keeps it on one.
        if not _reads_back_alone(key, "probe", ini=ini):
            note(
                f"{path}: the key {key!r} does not read back as itself; not writing it"
            )
            continue
        if isinstance(value, str) and not _reads_back_alone(key, value, ini=ini):
            # Named with the file: one key name is owned in several files at
            # once, so the key alone does not say which one was left alone.
            note(
                f"{path}: the value for {key} does not read back as one setting;"
                " not writing it"
            )
            continue
        writable[key] = value
    return writable


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
    `exists()`. Being wrong towards True costs one recreation of a file
    that turns out to be empty; being wrong towards False costs the
    credential, so the generous answer is the right one to fall back to.

    `exists()` is not the perfect answer to "is it genuinely absent",
    though, and this comment carries a security argument so it must not
    claim that it is: `Path.exists()` swallows its own `OSError` and so
    says False for a file whose parent this process cannot search as well
    as for one that is not there. That particular False costs nothing
    extra - a parent that cannot be searched is a parent the recreation
    could not have written into either - but it means "cannot tell", not
    "not there".

    A file holding nothing but a leading byte order mark holds nothing a
    recreation would drop - the flat readers set that mark aside, so it is
    an empty file to them - which is why size alone is not the answer for
    a non-empty file: the content has to be read. A read that fails on a
    file that is there keeps the generous answer, True, for the same
    fail-direction reason as above: only the recreation can take a
    credential off a disk no parser can see into.
    """
    try:
        if path.stat().st_size == 0:
            return False
    except OSError:
        return path.exists()
    text = _read_quietly(path)
    if text is None:
        return True
    return bool(text.removeprefix(_BOM))


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
        # S314 wants defusedxml here. Declined, with a reason rather than a
        # shrug: the classic attacks it defends against are entity
        # expansion, and stdlib ElementTree does not expand custom entities
        # at all - it raises `ParseError: undefined entity`, which the
        # handler below already turns into a recreation. External entities
        # and DTD retrieval are likewise off by default. What is left is a
        # dependency in the appliance's closure buying nothing, against an
        # input the frontend itself writes as `player` on a single-user box.
        root = ET.fromstring(f"<{_WRAPPER}>{body}</{_WRAPPER}>")  # noqa: S314
    except ET.ParseError as error:
        note(f"{path} does not parse ({error}); recreating it")
        return None
    return list(root)


def set_esde_settings(
    path: Path,
    enforce: Mapping[str, Mapping[str, str]],
    seed: Mapping[str, Mapping[str, str]],
) -> bool:
    """Assert the owned keys in an ES-DE settings file. Returns whether it wrote.

    Every element the flake does not own keeps its type, its value and its
    position; an enforced key that is absent is appended, and one that
    drifted - in value or in element type - is set back to what the flake
    declares. A seeded key is appended only the first time no element carries
    its name at all; once one does, whatever its value, the key is left
    alone for good - never corrected, never collapsed if it repeats.

    A file with no owned keys at all - enforced or seeded - is left alone,
    the same rule as the other two editors: see `set_ini_settings` for why
    that is not merely a shortcut.
    """
    if not enforce and not seed:
        return False

    elements = _parse_esde(path)
    recreating = elements is None
    if elements is None:
        elements = []

    # Collapse repeats of an *enforced* name to the first element carrying
    # it, the same invariant the other two editors keep: exactly one
    # assignment of an enforced key survives, holding the flake's value. A
    # dict comprehension over `elements` used to do this lookup and silently
    # kept the *last* repeat instead, so the earlier one stayed behind at
    # whatever it said - the mirror image of the bug the other two editors
    # had, and worth removing for the same reason. A seeded or unowned name
    # that repeats is left exactly as it is: not this program's to collapse.
    by_name: dict[str | None, ET.Element] = {}
    superseded: set[int] = set()
    for element in elements:
        name = element.attrib.get("name")
        if name in by_name:
            if name in enforce:
                superseded.add(id(element))
            continue
        by_name[name] = element
    changed = recreating
    if superseded:
        elements = [e for e in elements if id(e) not in superseded]
        changed = True
    for name, spec in enforce.items():
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

    # `by_name` still reflects the file as it was read, before the loop
    # above appended or corrected anything - which is exactly the question a
    # seeded key has to ask: did *this file* already carry an assignment of
    # it, not "does it hold the value after this run has touched it".
    for name, spec in seed.items():
        if name in by_name:
            continue
        element = ET.SubElement(ET.Element(_WRAPPER), spec["type"])
        element.set("name", name)
        element.set("value", spec["value"])
        elements.append(element)
        changed = True

    if changed:
        _write(path, _render_esde(elements))
    return changed


# --- A flat file as a line-oriented document -------------------------------
#
# Sectioned INI and RetroArch's headerless `key = "value"` file are close
# enough to share one document model: every line is blank, a comment, a
# section header or a `key = value` assignment, and nothing nests. The
# grammar is this program's own statement of what the emulators' parsers
# read - RetroArch rejects any line without an `=` and has no sections; the
# Qt-family INI writers emit `[Name]` headers, `#`/`;` comments and
# `key = value` lines - so the boundary between "edited in place" and
# "recreated, unowned settings lost" is stated in the classifier below
# rather than inherited from a parsing library's internals, where a version
# bump could move it silently.
#
# The model is lossless by construction: every node keeps its source line
# verbatim in `raw`, and rendering is concatenation. A document nobody
# edited renders byte-identical to what was read, except that a final line
# missing its terminator gains one - an unterminated last line is what a
# power cut leaves, and writing a new assignment straight onto the end of
# it would destroy the unowned line and the owned key together. There is no
# index arithmetic anywhere: an edit replaces a node, sections own their
# children, and deletion invalidates nothing.

# The one leading byte order mark a flat file may carry (module docstring).
# Every site that judges a flat file's emptiness or leading content - the
# set-aside in `_parse_flat`, the re-emission in `_render_flat`, the probe
# in `set_ini_settings`, and `_holds_something` - has to agree on exactly
# one, leading, and this constant is what keeps them agreeing.
_BOM = "\ufeff"


@dataclass
class Blank:
    """A line that is empty or whitespace only."""

    raw: str


@dataclass
class Comment:
    """A line whose stripped text starts with a comment prefix."""

    raw: str


@dataclass
class Assignment:
    """A `key = value` line. `raw` is the line verbatim.

    `key` and `value` are the stripped halves around the first `=`, which is
    what every reader this box writes for compares; `raw` keeps the
    spacing, the indentation and any quoting exactly as the file spelled
    them. An edit replaces the whole node with one whose `raw` is
    re-rendered as `key = value`, so only edited lines are ever normalised.
    """

    raw: str
    key: str
    value: str


@dataclass
class SectionNode:
    """A header line plus every line below it until the next header.

    `raw_header` is None for the preamble - the region above the file's
    first header, which is first-class here rather than smuggled in under a
    synthetic name: an assignment there belongs to no section, so no other
    section's owner can claim it. For RetroArch the whole file is the
    preamble.
    """

    raw_header: str | None
    name: str | None
    children: list[Blank | Comment | Assignment]


@dataclass
class Document:
    """The whole file; `sections[0]` is always the preamble.

    `bom` remembers whether the file led with a UTF-8 byte order mark, set
    aside before any line was classified; rendering re-emits it first, so
    the byte the emulator wrote survives a write like every other byte the
    flake does not own. Recreated documents leave it False: the recreate
    path writes only the owned values.
    """

    sections: list[SectionNode]
    bom: bool = False


def _make_assignment(key: str, value: str) -> Assignment:
    """An edited line, re-rendered as `key = value`."""
    return Assignment(raw=f"{key} = {value}", key=key, value=value)


def _make_section(name: str) -> SectionNode:
    """A fresh, empty section header for `name`, with no children yet."""
    return SectionNode(raw_header=f"[{name}]", name=name, children=[])


class _Unparseable(Exception):
    """A flat file that has to be recreated rather than edited in place.

    `reason` is what the journal is told, or None where the caller owns the
    note instead. Only one refusal is silent - an empty file - because the
    INI editor defers that note until it has confirmed a write actually
    follows: a file whose owned keys are all removals is "recreated" into
    nothing at all, and announcing that before every launch was a lie
    repeated forever.
    """

    def __init__(self, reason: str | None) -> None:
        super().__init__(reason or "")
        self.reason = reason


# This program's section grammar: a non-empty bracketed name that cannot
# itself contain `]`, then nothing but an optional trailing comment. A
# trailing comment after a header is legal INI and accepted by the Qt-family
# readers alike; rejecting one would send the whole file through the
# recreate path and lose every unowned key in it. `[]` is deliberately not a
# header: an empty name could never equal an owned section's, so a removal
# sweeping the declared section would walk past whatever sits below it.
# Taking the first `]` rather than the last is deliberate, not incidental:
# the readers this grammar is written for - the Qt-family INI writers and
# the emulators' own C++ ini parsers - stop at the first closing bracket
# too, so a section name may never actually contain one either.
# Applied with `fullmatch`, not `match`: only `fullmatch` makes this a
# strict end-to-end grammar, since the pattern has no `$` of its own to
# anchor its end.
_FLAT_HEADER_RE = re.compile(r"\[(?P<name>[^]]+)\][ \t]*(?:[;#].*)?")

# The permissive header shape configparser-family readers accept: `[`, at
# least one character of any kind, then a closing `]` - greedy to the last
# bracket, so `]` may sit inside the name. A line this shape matches while
# the strict grammar above does not - `[Name] trailing junk`, `[Name] = v`,
# `[]] = v` - is a line two plausible readers of the file name differently,
# so keys below it could be attributed to a section the emulator reads
# under another name, and a removal sweeping the declared section would
# walk past a live token. Such a line refuses the whole file, `=` or not.
# A line with no `]` past its second column never matches, so `[foo bar =
# baz` stays an assignment named `[foo bar` and `[] = y` one named `[]`.
# Applied with `match`, not `fullmatch`: `match` alone is what keeps this
# anchored to a line that begins with `[`, since the pattern has no `^` of
# its own to anchor its start.
_LOOSE_HEADER_RE = re.compile(r"\[.+\]")


def _junk_reason(line: str) -> str:
    """The refusal reason for a line no rule reads, bounded for the journal.

    The bound caps how much of the line reaches the journal, not which
    part: a torn write can put a credential fragment on a line that fails
    to classify, and the note has always been able to carry one. Keeping
    the reason at all is what makes the recreation diagnosable at 8pm on a
    Friday.
    """
    return f"has a line that is not a setting ({line[:200]!r})"


def _classify_flat_line(
    raw: str, *, ini: bool
) -> Blank | Comment | Assignment | SectionNode:
    """One source line as one node, or `_Unparseable` for a line that is none.

    Classification runs on the line stripped of all leading and trailing
    whitespace - the node keeps the raw line - so an indented comment,
    assignment or header is still that line under any Unicode whitespace,
    and keeps its indentation through a write: there is no continuation
    concept for indentation to trigger.

    The per-format differences are data, not code paths: RetroArch's own
    parser gives `;` no special meaning, so a `;`-prefixed line there is
    not a comment, and its files have no headers at all, so a line this
    program's header grammar reads refuses the file - left alone it would
    partition the file and hide everything below it from both the removal
    and the write sweeps.
    """
    line = raw.strip()
    if not line:
        return Blank(raw)
    if line.startswith(("#", ";") if ini else ("#",)):
        return Comment(raw)
    header = _FLAT_HEADER_RE.fullmatch(line)
    if header is not None:
        if not ini:
            raise _Unparseable(f"has a section header ({header.group('name')!r})")
        return SectionNode(raw_header=raw, name=header.group("name"), children=[])
    if _LOOSE_HEADER_RE.match(line):
        raise _Unparseable(_junk_reason(line))
    key, delimiter, value = line.partition("=")
    key = key.rstrip()
    if delimiter and key:
        return Assignment(raw=raw, key=key, value=value.strip())
    # `=` with nothing before it, or no `=` at all: not a setting, so the
    # file is not this format and takes the recreate path.
    raise _Unparseable(_junk_reason(line))


def _parse_flat(text: str, *, ini: bool) -> Document:
    """`text` as a document, or `_Unparseable` where it must be recreated.

    Lines are split on `\\n` alone, never `str.splitlines()`: that also
    breaks on U+2028, form feed and the other exotic separators, so a value
    carrying one would be cut into a fragment that fails to classify and
    take the whole file into the recreate path with it.

    An empty INI file is refused silently (`reason` None): it is not a
    healthy document missing every key, but `set_ini_settings` owns that
    note and emits it only once it knows a write follows. INI only,
    matching RetroArch's own parser, which has never had an emptiness
    check.

    Exactly one leading U+FEFF is set aside before any other rule runs -
    PPSSPP's own writer prefixes its file with a UTF-8 byte order mark on
    every save, and decoded to the first line's content it made the file
    unreadable and recreated on every launch. After the set-aside the
    residual text takes these rules verbatim: a mark-only file is an empty
    file, a second mark leads the residual's first line and that line's
    shape decides, and a mark anywhere later is ordinary content.
    """
    bom = text.startswith(_BOM)
    text = text.removeprefix(_BOM)
    if ini and not text.strip():
        raise _Unparseable(None)
    lines = text.split("\n")
    if lines and lines[-1] == "":
        # The empty piece after a terminated final line, not a line of the
        # file; rendering restores the terminator. A genuinely blank final
        # line arrives as two pieces and keeps its node.
        lines.pop()
    preamble = SectionNode(raw_header=None, name=None, children=[])
    document = Document(sections=[preamble], bom=bom)
    current = preamble
    for raw in lines:
        node = _classify_flat_line(raw, ini=ini)
        if isinstance(node, SectionNode):
            document.sections.append(node)
            current = node
        else:
            current.children.append(node)
    return document


def _render_flat(document: Document) -> str:
    """The document's text: every node's raw line, terminated.

    A remembered byte order mark is re-emitted first, before any line, so
    it lands byte-for-byte where the emulator put it: position zero.
    """
    parts: list[str] = []
    for section in document.sections:
        if section.raw_header is not None:
            # One line of a settings file holds one section header. `_writable`
            # is not what guards this one - a section name never reaches it -
            # so it is `_header_reads_back`, applied by `set_ini_settings`,
            # that establishes the invariant this asserts; parsing cannot
            # build a multi-line header either. Not raised: this states an
            # invariant the module's own code establishes elsewhere, rather
            # than enforcing one here.
            assert "\n" not in section.raw_header and "\r" not in section.raw_header, (
                f"section header is not one line: {section.raw_header!r}"
            )
            parts.append(section.raw_header)
        for child in section.children:
            if isinstance(child, Assignment):
                # One line of a settings file holds one setting. `_writable`
                # is what establishes this invariant for both halves of an
                # owned assignment - it drops a key name or a value that
                # does not read back as itself before either ever reaches a
                # node - and parsing cannot build a multi-line assignment
                # either. Not raised, for the same reason as the header
                # assert above.
                assert "\n" not in child.raw and "\r" not in child.raw, (
                    f"assignment is not one line: {child.raw!r}"
                )
            parts.append(child.raw)
    mark = _BOM if document.bom else ""
    return mark + "".join(part + "\n" for part in parts)


def _read_document(path: Path, *, ini: bool) -> Document | None:
    """The file as a document, or None if it must be recreated."""
    text = _read_text(path)
    if text is None:
        return None
    try:
        return _parse_flat(text, ini=ini)
    except _Unparseable as refusal:
        if refusal.reason is not None:
            note(f"{path} {refusal.reason}; recreating it")
        return None


def _read_document_quietly(path: Path, *, ini: bool) -> Document | None:
    """The same, for a caller that is only asking what is already on disk.

    Silent where `_read_document` is loud, and for the same reason
    `_read_quietly` is: this one runs before the program has decided to
    write anything, so a note here would announce a recreation that is not
    happening.
    """
    text = _read_quietly(path)
    if text is None:
        return None
    try:
        return _parse_flat(text, ini=ini)
    except _Unparseable:
        return None


def _document_places(document: Document, section: str | None) -> list[SectionNode]:
    """Every place in the document an owned key of `section` can be assigned.

    Each instance of the declared section - a header written twice is a
    shape a torn or hand-edited file takes - plus the preamble, which holds
    the region above the file's first header. An assignment there belongs
    to no section, so no other section's owner can claim it. `section=None`
    is RetroArch's flat file, whose whole content is the preamble.

    An assignment under a *different* section is not in this list: it
    genuinely belongs to somebody else.
    """
    return [
        candidate
        for candidate in document.sections
        if candidate.raw_header is None
        or (section is not None and candidate.name == section)
    ]


def _document_write_target(document: Document, section: str | None) -> SectionNode:
    """The one place an owned key's surviving assignment is left standing.

    The first instance of the declared section, or the preamble for a file
    with no sections at all. Appends the section when the file has none,
    which is what seeds a key whose section the emulator has never written.
    """
    if section is None:
        return document.sections[0]
    for candidate in document.sections:
        if candidate.name == section:
            return candidate
    created = _make_section(section)
    document.sections.append(created)
    return created


def _delete_key(place: SectionNode, key: str) -> bool:
    """Delete every assignment of `key` in one section; whether any went."""
    kept = [
        child
        for child in place.children
        if not (isinstance(child, Assignment) and child.key == key)
    ]
    if len(kept) == len(place.children):
        return False
    place.children[:] = kept
    return True


def _sweep_key(document: Document, key: str, section: str | None) -> bool:
    """Delete every assignment of an owned key, everywhere it belongs.

    What `REMOVE` promises, rather than what a single lookup delivers:
    every copy, in every instance of the section, plus the preamble.
    """
    swept = False
    for place in _document_places(document, section):
        if _delete_key(place, key):
            swept = True
    return swept


def _write_key(document: Document, key: str, value: str, section: str | None) -> bool:
    """Leave exactly one assignment of an owned key, holding the flake's value.

    A repeat takes three shapes and all three end the same way: across
    instances of a repeated section header, between the headerless region
    and the section, and twice inside one section instance. Every reader
    this box writes for resolves a repeat to one entry, so a copy left
    holding an older value is the one the emulator obeys - and because the
    file does carry the flake's value somewhere, the next launch finds
    nothing to do and the discrepancy never surfaces. For the account name
    and token that survivor is a bearer credential rather than a
    preference.

    Deletion iterates to *one* here, never to absence: absence in every
    place but the one being written, and inside that one down to a single
    survivor - the last copy, whose bytes are the ones least likely to need
    rewriting - which then takes the value only if it does not already hold
    it. Deleting every copy and assigning afterwards would be simpler and
    wrong: it makes the editor write on every launch, which is the flash
    wear the comparison below exists to prevent. Only the edited line is
    ever re-rendered; an untouched assignment keeps its bytes.
    """
    target = _document_write_target(document, section)
    changed = False

    for place in _document_places(document, section):
        # Identity, not equality: two instances of a repeated header
        # carrying the same assignments compare equal as dataclasses, and
        # the twin the sweep exists to clear is exactly the one that would
        # be skipped.
        if place is target:
            continue
        if _delete_key(place, key):
            changed = True

    copies = [
        child
        for child in target.children
        if isinstance(child, Assignment) and child.key == key
    ]
    survivor = copies[-1] if copies else None
    if len(copies) > 1:
        target.children[:] = [
            child
            for child in target.children
            if not (
                isinstance(child, Assignment)
                and child.key == key
                and child is not survivor
            )
        ]
        changed = True

    if survivor is None:
        target.children.append(_make_assignment(key, value))
        return True

    # Compared stripped: the node's value is stripped at classification
    # (`_classify_flat_line`), so an owned value declared with leading or
    # trailing whitespace would otherwise never equal what is read back and
    # would rewrite the file on every launch even though the bytes settle.
    # The written `raw` below still keeps `value` verbatim - only this
    # comparison strips.
    if survivor.value != value.strip():
        for index, child in enumerate(target.children):
            # Identity, not equality: a duplicate declaring the same key and
            # value would compare equal as a dataclass, and the survivor
            # being replaced here is exactly the one that must not be
            # confused with such a twin.
            if child is survivor:
                target.children[index] = _make_assignment(key, value)
                break
        changed = True
    return changed


def _seed_key(document: Document, key: str, value: str, section: str | None) -> bool:
    """Append a seeded key only where no assignment of it exists at all.

    "Exists" means anywhere `_document_places` would let an enforced key of
    this section be found - every instance of the declared section, plus the
    headerless preamble - and it is a presence check only: whatever value an
    existing assignment holds, even the empty string, it is left exactly as
    is. Unlike `_write_key` there is no sweep of other copies and no
    replacement of the survivor: a seeded key is asserted once and never
    corrected again, so there is nothing here for a later launch to put
    right.

    A sectioned key whose only assignment sits in the preamble - above the
    file's first section header - counts as present under this same rule,
    and so is never additionally seeded into its declared section. That
    reads like a miss at first glance, but it is the stated contract applied
    consistently: the preamble is one of the places that belongs to a
    sectioned key for every other purpose this module has (the enforced
    sweep and write both cross that boundary too), and a seed check that drew
    the line differently there would be its own, undocumented rule.
    """
    for place in _document_places(document, section):
        for child in place.children:
            if isinstance(child, Assignment) and child.key == key:
                return False
    # Never reachable with a real document: nothing in this module ever asks
    # to remove a seeded key (the two validations that keep a
    # RetroAchievements target's key out of a file's seed map exist for
    # exactly that reason - see `_target_validation_error` and the per-file
    # shape check in `main`), and every seed map reaching an editor has
    # already been filtered to strings the same way `_without_removals`
    # filters the enforce maps (`set_ini_settings`, `set_retroarch_settings`),
    # so this is a backstop against a future bug in one of those, not a path
    # any caller today can reach.
    assert isinstance(value, str), (
        f"seed key {key!r} does not carry a string value, which the seed "
        "tier never accepts"
    )
    target = _document_write_target(document, section)
    target.children.append(_make_assignment(key, value))
    return True


# --- INI with sections ----------------------------------------------------


def set_ini_settings(
    path: Path,
    enforce: Mapping[str, Mapping[str, str | Removal]],
    seed: Mapping[str, Mapping[str, str]],
) -> bool:
    """Assert owned keys in an INI file with sections. Returns whether it wrote.

    Every setting the flake does not own keeps its key, its value and its
    section, and keeps every one of its assignments where it repeats. An
    enforced key missing from a section it belongs to is appended to that
    section; a missing section is appended to the file. Presentation the
    emulator does not read - the spacing around a delimiter, where a line
    sits inside its section, whether a comment survives an edit to the line
    it trails - is not part of that promise, and buying it back would mean
    the line arithmetic this editor was written to stop carrying.

    A seeded key is appended the same way, but only the first time no
    assignment of it exists anywhere in its section's places (see
    `_seed_key`); once one does, it is left alone for good, drift and
    repeats included. A seeded value that is not a string is dropped before
    it ever reaches an editor - `_without_removals` filters both tiers
    identically - so a wrong-typed seed value is quietly left unwritten
    exactly as a wrong-typed enforced one already was, never coerced and
    never a call that reaches `_seed_key`'s own backstop assert.

    An enforced key whose value is `REMOVE` is deleted from the file
    instead, with the same properties: everything around it survives, and
    removing a key that is not there is a no-op that reports no write. Every
    occurrence of it goes - in every instance of its section, and in the
    headerless preamble - because that is what `Removal` promises; a
    same-named key under some other section is left alone. A seeded key is
    never a removal - see `_seed_key`.

    A file in which nothing at all is owned is left alone entirely - not
    parsed, not recreated, not mentioned. PCSX2 declares `secrets.ini` with
    no keys of its own, so a document carrying no retroachievements
    namespace (the JSON's null) never touches that file. Without this guard
    the recreation below wrote a lone newline, which came back as an empty
    file, so the box rewrote it and logged "is empty; recreating it" before
    every single launch, forever.

    A file whose owned keys are *all* removals is a different case, and one
    `secrets.ini` reaches on every launch that resolves no token and every
    launch of a box with RetroAchievements switched off: it is parsed, and
    if it turns out to be present but unparseable it is recreated, since a
    recreation is the only way a removal can be kept against a file no
    parser can see into. See `_holds_something`.
    """
    enforce = {name: _writable(path, keys, ini=True) for name, keys in enforce.items()}
    seed = {
        name: _without_removals(_writable(path, keys, ini=True))
        for name, keys in seed.items()
    }

    # The same read-back rule `_writable` applies to a key name or value,
    # applied to a section name - dropped here, before the document is even
    # read, rather than inside either write branch below, because both the
    # edit path and the recreate path build a `SectionNode` from these same
    # mappings and neither may ever see a broken name. Both tiers go through
    # the identical check: a section name is a section name regardless of
    # which map claims a key inside it.
    writable_enforce: dict[str, dict[str, str | Removal]] = {}
    for name, keys in enforce.items():
        if not _header_reads_back(name):
            note(
                f"{path}: the section {name!r} does not read back as itself;"
                " not writing it"
            )
            continue
        writable_enforce[name] = keys
    enforce = writable_enforce

    writable_seed: dict[str, dict[str, str]] = {}
    for name, keys in seed.items():
        if not _header_reads_back(name):
            note(
                f"{path}: the section {name!r} does not read back as itself;"
                " not writing it"
            )
            continue
        writable_seed[name] = keys
    seed = writable_seed

    if not any(enforce.values()) and not any(seed.values()):
        return False

    document = _read_document(path, ini=True)
    if document is None:
        fresh = {section: _without_removals(keys) for section, keys in enforce.items()}
        if (
            not any(fresh.values())
            and not any(seed.values())
            and not _holds_something(path)
        ):
            # Every enforced key in this file is a removal, nothing is
            # seeded, and there is genuinely nothing on disk to remove them
            # from: creating a file to hold nothing would only be recreated
            # on the next launch. A file that is present but unparseable
            # does *not* take this branch (see `_holds_something`): it falls
            # through to the recreation below, which is what takes the
            # credential off the disk - and what makes the note about to be
            # printed true rather than a lie repeated before every launch.
            return False
        # The empty-file note, deferred from the parse helper, which stays
        # silent about emptiness for exactly this reason: it is only worth
        # telling the journal once a write is actually about to happen,
        # which the branch above has just confirmed. `_read_quietly`, so
        # this probe stays silent about anything other than emptiness - an
        # unreadable or malformed file has already noted its own reason.
        # A leading byte order mark is set aside first, the same set-aside
        # the parser applies: a mark-only file is an empty file, and the
        # note has to fire for it too.
        probe = _read_quietly(path)
        if probe is not None and not probe.removeprefix(_BOM).strip():
            note(f"{path} is empty; recreating it")
        recreated = Document(
            sections=[SectionNode(raw_header=None, name=None, children=[])]
        )
        # A recreated file is missing every key, enforced and seeded alike,
        # so recreation is the one place both tiers are written together -
        # each section is made once, whichever map names it first.
        for section in dict.fromkeys([*fresh, *seed]):
            node = _make_section(section)
            recreated.sections.append(node)
            for key, value in fresh.get(section, {}).items():
                node.children.append(_make_assignment(key, value))
            for key, value in seed.get(section, {}).items():
                node.children.append(_make_assignment(key, value))
        _write(path, _render_flat(recreated))
        return True

    changed = False

    # Removals sweep the whole file first, in a pass of their own, because a
    # removal is not confined to one section's bounds and a key this pass
    # deletes must not be one the writing pass then finds and compares
    # against.
    for section, keys in enforce.items():
        for key, value in keys.items():
            if isinstance(value, Removal) and _sweep_key(document, key, section):
                changed = True

    for section, keys in enforce.items():
        for key, value in _without_removals(keys).items():
            if _write_key(document, key, value, section):
                changed = True

    # Seeding runs last and is excluded from every sweep above: a seeded key
    # is never a removal and never a duplicate this program collapses, so
    # nothing about it belongs in either of those passes.
    for section, keys in seed.items():
        for key, value in keys.items():
            if _seed_key(document, key, value, section):
                changed = True

    if changed:
        _write(path, _render_flat(document))
    return changed


# --- RetroArch's flat `key = "value"` file --------------------------------


def set_retroarch_settings(
    path: Path,
    enforce: Mapping[str, str | Removal],
    seed: Mapping[str, str],
) -> bool:
    """Assert owned keys in RetroArch's flat config. Returns whether it wrote.

    Same properties as the INI editor: unowned keys keep their keys and their
    values, a repeated unowned key keeps every assignment, a missing enforced
    key is appended, every assignment of an enforced key valued `REMOVE` is
    deleted, an unreadable file is recreated carrying every owned key -
    enforced and seeded alike - and a file with no owned keys at all is left
    alone. A seeded key is appended only the first time no assignment of it
    exists anywhere in the file, and is then left alone for good, drift and
    repeats included - see `_seed_key`. The whole file is one section here,
    so a repeated key repeats outright rather than under a second header. A
    seeded value that is not a string is dropped before it is ever quoted
    for the file - `_without_removals` filters both tiers identically - so
    it is left unwritten rather than wrapped in quotes and coerced to
    `str()`.
    """
    enforce = _writable(path, enforce, ini=False)
    seed = _without_removals(_writable(path, seed, ini=False))
    if not enforce and not seed:
        return False

    document = _read_document(path, ini=False)
    if document is None:
        fresh = _without_removals(enforce)
        if not fresh and not seed and not _holds_something(path):
            # The INI editor's guard, with the same reasoning: absent means
            # write nothing, unparseable means recreate, because only the
            # recreation drops a credential a parser cannot see. Unreachable
            # in this configuration - RetroArch's target owns static keys
            # too, so `fresh` is never empty - but the two editors keep the
            # same rule so a later target cannot inherit the bug back.
            return False
        preamble = SectionNode(raw_header=None, name=None, children=[])
        # A recreated file is missing every key, so both tiers are written
        # together here, the same as the INI editor's recreate branch.
        for key, value in fresh.items():
            preamble.children.append(_make_assignment(key, f'"{value}"'))
        for key, value in seed.items():
            preamble.children.append(_make_assignment(key, f'"{value}"'))
        _write(path, _render_flat(Document(sections=[preamble])))
        return True

    changed = False
    # Removals first and file-wide, the INI editor's rule for the same
    # reasons. `None` for the section because this file has none.
    for key, value in enforce.items():
        if isinstance(value, Removal) and _sweep_key(document, key, None):
            changed = True

    for key, value in _without_removals(enforce).items():
        if _write_key(document, key, f'"{value}"', None):
            changed = True

    # Seeding runs last, excluded from every sweep above for the same reason
    # it is in the INI editor: never a removal, never a duplicate this
    # program collapses.
    for key, value in seed.items():
        if _seed_key(document, key, f'"{value}"', None):
            changed = True

    if changed:
        _write(path, _render_flat(document))
    return changed


# --- RetroAchievements: login and the token cache -------------------------

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
    this namespace may cost the session.
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


def _remove_credential(
    path: Path, *, prune_empty_parent_under: Path | None = None
) -> None:
    """Delete a credential file if there is one, noting a refusal.

    `unlink` on a directory, or in a directory that is not writable, is an
    `OSError` - and on the rejected-login path that exception would
    otherwise escape a step that must never cost more than the
    achievements.

    `prune_empty_parent_under` is for the token cache, and only for it: the
    cache has a directory of its own (`retroachievements/` under the
    appdata root), so removing the file otherwise leaves an empty directory
    sitting there on a box that has switched the feature off, which is
    meant to look like a box that never had it on. `rmdir` removes an empty
    directory and nothing else, so it cannot take a neighbour with it, and
    it stays silent because a directory that is not empty - or not there -
    is the ordinary case rather than a refusal worth a journal line. Not
    passed for the emulators' own token files, which live in directories
    the emulator owns.

    It takes the appdata root rather than a boolean because `cache_file` is
    configuration, and only a directory strictly beneath that root can be
    one the cache had to itself. A `cache_file` of `token-cache` - a bare
    filename, which the field's type permits - would otherwise aim the
    `rmdir` at the whole of `/data/es-de`, and an absolute `cache_file`
    somewhere else entirely would aim it at a directory this program has no
    business in. The root's own emptiness is the only thing standing
    between that and a removal, which is not a guarantee worth resting on.
    """
    try:
        path.unlink(missing_ok=True)
    except OSError as error:
        note(f"{path} could not be removed ({error}); continuing")
        return
    if prune_empty_parent_under is None:
        return
    if prune_empty_parent_under not in path.parent.parents:
        return
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
        text = path.read_text(encoding="utf-8")
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
        cached = path.read_text(encoding="utf-8").strip()
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
    network never blocks the session" and this subsystem's own "worst case
    adds 5 s before the frontend" promise forbid. Only a deadline around the whole call
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
            # costs the achievements and nothing else, so it
            # gets a journal line and the catch-all outcome.
            #
            # The type's name rather than `{error!r}`: this is the one
            # thread in the program that has the plaintext password in
            # scope, and several standard exceptions - UnicodeEncodeError
            # above all - carry the string that offended them into their
            # repr. Everything `_login2_request` can fail with in the
            # ordinary way it already handles inside itself, so reaching
            # here at all means a bug, and the name of the exception plus
            # the fact that it was the login is what points at it.
            note(
                "the RetroAchievements login failed unexpectedly "
                f"({type(error).__name__})"
            )
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

    Returns exactly one of three outcomes - the three-way classification
    the caller's cache-fallback policy is built on:

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
    try:
        # Inside the try, not above it, and this matters twice over.
        #
        # `urlencode` is the only call in this program that holds the
        # plaintext password, and a string it cannot encode raises
        # `UnicodeEncodeError` - a `ValueError` - whose repr embeds the
        # offending string. Outside the try that exception climbed to the
        # worker thread's catch-all, which put the password into the
        # journal. Not reachable from a sops secret today, because
        # `_read_secret` decodes strict UTF-8, but the secret's one call
        # site is the last place to rely on a guarantee made elsewhere.
        #
        # `Request` raises `ValueError("unknown url type")` for a URL whose
        # scheme it does not recognise, and a malformed `api_url` has to
        # cost the achievements like every other login failure rather than
        # the whole session.
        body = urllib.parse.urlencode(
            {"r": "login2", "u": username, "p": password}
        ).encode()
        # S310 flags an unbounded URL scheme (file://, and custom ones) on
        # both halves of this call, the `Request` and the `urlopen`. It
        # matters when the URL comes from somewhere untrusted. Here it comes
        # from the retroachievements namespace's `api_url`, which - like
        # every other path in the owned-values document - is a store path
        # the module rendered, not anything a user or the network supplies;
        # the same trust boundary the rest of this program already assumes.
        #
        # Only the `urlopen` half carried a suppression until the bandit
        # rules were actually turned on, because a `noqa` for an unselected
        # rule silences nothing and so nothing said the other half was
        # unmarked. `RUF100` is on now to keep that from recurring.
        request = urllib.request.Request(api_url, data=body, method="POST")  # noqa: S310
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
    on the next boot with no manual step.
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
        _remove_credential(cache_file, prune_empty_parent_under=root)
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


# --- DuckStation's encrypted token -----------------------------------------


def _duckstation_key_iv(machine_id: bytes, username: str) -> tuple[bytes, bytes]:
    """The AES-128-CBC key and IV DuckStation v0.1-11752 derives for one account.

    SHA-256 over the machine id file's raw bytes followed by the username's
    UTF-8 bytes gives a seed digest; "100 further rounds", as verified
    against `achievements.cpp` itself, then re-hash that seed 100 more
    times. That is 101 SHA-256 calls in total,
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

    `_read_document_quietly`, deliberately, rather than its loud pair
    `_read_document`: the loud one decides whether a file is healthy enough
    to edit in place, and it notes ("recreating it") whenever it is not.
    Calling it here - purely to see what a key currently holds - would print
    a recreation notice before this run had decided to write anything.

    Five things mean the same thing here, because none of them gives a value
    to compare against: the file is missing, it is unreadable, it cannot be
    parsed at all, it has no such section, or that section has no such key.
    All five read as "the token changed", which on a file about to be
    recreated anyway is the right answer.
    """
    document = _read_document_quietly(path, ini=True)
    if document is None:
        return None
    for place in document.sections:
        if place.name != section:
            continue
        # The first instance of the section, which is also the one the
        # editor writes into and leaves a single assignment in.
        for child in place.children:
            if isinstance(child, Assignment) and child.key == key:
                return child.value
        return None
    return None


def duckstation_login_values(
    root: Path, target: Mapping[str, object], username: str, token: str
) -> dict[str, str]:
    """The username/token/login_timestamp values for one duckstation target.

    Returns "username" and "token" (already encrypted, ready to write
    verbatim) unconditionally, and "login_timestamp" only when the target
    declares that key and the newly encrypted token differs from what the
    ini file already holds - change-gating, without which an
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


# --- RetroAchievements: the owned-table merge ------------------------------
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

    # enabled/hardcore/username are written for every encoding;
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
        # Whether an entry carries a `section` is validated here as a JSON
        # entry's shape; the identical fact is re-derived twice more in the
        # Nix modules that render this document - `raDisabledFiles`'s `off`
        # helper in modules/emulators/default.nix and
        # `raTargetSeedOverlaps`'s path construction in
        # modules/kiosk/default.nix - each into a differently shaped value
        # of its own. A field added alongside `section`/`key` in a later
        # encoding has to be taught to all three.
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

        # `_merge_target_key` writes this key's value into the file's
        # `enforce` map, so a target that names a key the file already seeds
        # would enforce and seed the same key - the module-side twin of the
        # static overlap check `main` runs over the document's own two maps.
        # Checked here, before the login, because both the plain value the
        # enabled path would write and the `REMOVE` the disabled path merges
        # instead are refused by the identical rule: neither may ever reach
        # a seeded key.
        seed_map = file_table.get("seed")
        if file_format == "ini":
            section_map = (
                cast("Mapping[str, object]", seed_map).get(str(entry.get("section")))
                if isinstance(seed_map, dict)
                else None
            )
            if isinstance(section_map, dict) and key_spelling in section_map:
                return (
                    f"retroachievements target {name!r}.{key_name}: "
                    f"{file_name!r} already seeds {entry['section']}.{key_spelling}"
                )
        elif isinstance(seed_map, dict) and key_spelling in seed_map:
            return (
                f"retroachievements target {name!r}.{key_name}: "
                f"{file_name!r} already seeds {key_spelling}"
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
            # scheme is derived from that file, so a target
            # declaring the encoding without it is a broken call site.
            return f"retroachievements target {name!r}: duckstation needs 'machine_id_file'"
    else:
        return f"retroachievements target {name!r}: unknown encoding {encoding!r}"

    return None


def _merge_target_key(
    files: dict[str, object], entry: Mapping[str, object], value: str | Removal
) -> None:
    """Fold one key entry's value into its file's own `enforce` map, in place.

    Always `enforce`, never `seed`: a RetroAchievements login key is
    corrected on drift and swept clean on every launch exactly like any
    other enforced key, and `_target_validation_error` has already refused
    any target whose key would otherwise land on a name the file's own
    `seed` map claims. The file's format decides the shape - ini's
    `{section: {key: value}}`, retroarch's flat `{key: value}` - so the
    unmodified editors write it. Only ever called after
    `_target_validation_error` has confirmed the file is declared and the
    entry's shape matches its format.
    """
    file_table = cast("dict[str, object]", files[str(entry["file"])])
    file_keys = cast("dict[str, object]", file_table.setdefault("enforce", {}))
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
    _remove_credential(cache_file, prune_empty_parent_under=root)


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
    never a non-zero return - the subsystem's whole point.

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
    # whole call exists for the unforeseen case anyway (any
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
            # encoding, and only when the token changed, so it
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
        # recreate policy deliberately does not cover.
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

# The exact fields a per-file table may carry - no more, no fewer, and no
# alias for either. `keys`, the old single-map spelling, is deliberately not
# here: there is no migration path from it, only a refusal, because a table
# carrying it is a call site nothing in this program has understood since
# the seed tier was added.
_TABLE_FIELDS = frozenset({"format", "enforce", "seed"})


def _owned_keys_error(table: Mapping[str, object]) -> str | None:
    """Why this file's `enforce` or `seed` map would crash its editor.

    None if neither will. Shape checking that belongs to `main` rather than
    to the editors, because `main` is what owes the journal a line instead
    of a stack trace (module docstring). Everything below is an
    `AttributeError` or a `TypeError` inside an editor, and the loop that
    calls the editors catches `OSError` and nothing else - deliberately, so
    that a bug is never mistaken for a full disk - so each of these would
    reach the top of the program as a traceback an admin has to read.

    Both tiers are checked, and by the identical rule: an editor subscripts
    or iterates a seeded entry exactly as it does an enforced one (see
    `set_esde_settings`'s and `set_ini_settings`'s seed branches), so a
    malformed seeded entry crashes the same way a malformed enforced one
    always has.

    Reachable from a module rather than only from a hand-written document:
    the Nix side types `ownedFiles.<file>.enforce` and `.seed` as `attrsOf
    anything`, so a module written later that spells an ES-DE key
    `value = 5` or `value = true` renders a JSON number or boolean right
    here.

    Only what an editor subscripts or iterates is checked. An `ini` or
    `retroarch` value that is not a string is left alone on purpose, in
    either tier: `_without_removals` keeps only the strings, applied to the
    enforce map and the seed map alike, so such a key is quietly skipped
    rather than written - a poor answer, but not a traceback, and
    tightening it here would reject documents that work on boxes today.
    """
    fmt = table["format"]
    for tier in ("enforce", "seed"):
        raw = table[tier]
        if not isinstance(raw, dict):
            return f"expected {tier!r} to be an object, got {type(raw).__name__}"
        # Cast rather than narrow: `isinstance` gives an empty dict type here,
        # and every lookup below would be a type error against it.
        keys = cast("dict[str, object]", raw)
        if fmt == "ini":
            # The INI editor iterates each section's own table.
            for section, entries in keys.items():
                if not isinstance(entries, dict):
                    return (
                        f"expected section {section!r} to be an object, "
                        f"got {type(entries).__name__}"
                    )
            continue
        if fmt != "esde-xml":
            continue
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


def _seed_enforce_overlap_error(table: Mapping[str, object]) -> str | None:
    """Why one key owned in both tiers of one file is a broken call site.

    None if no key is. Which tier a key belongs to has to be a fact about
    the key, not something that depends on which map a reader checks first,
    so a name declared in both is refused rather than resolved by a rule
    (enforce wins, seed wins, whichever is scanned last) that would only
    hide the module's own mistake. Checked statically, straight off the
    parsed document, because the overlap is visible without merging
    anything - unlike the RetroAchievements case (`_target_validation_error`),
    where a target's key has to be checked against the file it names before
    anything is merged into it.

    Sectioned (`ini`) and flat (`esde-xml`, `retroarch`) formats disagree on
    what "the same key" means - a section and a name together, or a name
    alone - so each is checked its own way rather than through one shared
    shape.
    """
    enforce = cast("dict[str, object]", table["enforce"])
    seed = cast("dict[str, object]", table["seed"])
    if table["format"] == "ini":
        for section, seed_entries in seed.items():
            enforce_entries = enforce.get(section)
            if not isinstance(enforce_entries, dict) or not isinstance(
                seed_entries, dict
            ):
                # Already reported by `_owned_keys_error`, called ahead of
                # this in `main`; nothing to add here.
                continue
            overlap = sorted(set(enforce_entries) & set(seed_entries))
            if overlap:
                return (
                    f"{section}.{overlap[0]} is declared under both "
                    "'enforce' and 'seed'"
                )
        return None
    overlap = sorted(set(enforce) & set(seed))
    if overlap:
        return f"{overlap[0]} is declared under both 'enforce' and 'seed'"
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
        document = json.loads(Path(owned_values).read_text(encoding="utf-8"))
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
    # missing key is equivalent to null and disables the feature.
    retroachievements = document.get("retroachievements")
    if retroachievements is not None and not isinstance(retroachievements, dict):
        note(
            f"{owned_values}: expected 'retroachievements' to be an object or "
            f"null, got {type(retroachievements).__name__}"
        )
        return 1
    for relative, table in tables.items():
        if not isinstance(table, dict):
            note(f"{relative}: expected an object with 'format', 'enforce' and 'seed'")
            return 1
        missing = sorted(_TABLE_FIELDS - table.keys())
        extra = sorted(table.keys() - _TABLE_FIELDS)
        if missing or extra:
            # Named separately, because a table carrying the old `keys` map
            # is both at once - missing `enforce` and `seed`, carrying
            # `keys` as its one unexpected field - and an admin fixing a
            # broken module needs to see all of it, not just whichever the
            # check happened to notice first.
            problems = []
            if missing:
                problems.append(f"missing {missing}")
            if extra:
                problems.append(f"unexpected field(s) {extra}")
            note(f"{relative}: {'; '.join(problems)}")
            return 1
        if table["format"] not in _EDITORS:
            note(f"{relative}: unknown format {table['format']!r}")
            return 1
        problem = _owned_keys_error(table)
        if problem is not None:
            note(f"{relative}: {problem}")
            return 1
        overlap = _seed_enforce_overlap_error(table)
        if overlap is not None:
            note(f"{relative}: {overlap}")
            return 1

    # Folded into `tables` before any editor runs, so the editors themselves
    # stay unaware that a key came from the retroachievements namespace
    # rather than the module that declared the file.
    if retroachievements is not None:
        try:
            status = apply_retroachievements(tables, retroachievements, root)
        except Exception as error:
            # The subsystem's entire contract is that any
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
            editor(root / relative, table["enforce"], table["seed"])
        except OSError as error:
            # The recreate-not-fail policy this program applies everywhere
            # else, applied to the write itself. `/data` full, remounted
            # read-only after a power cut, or a directory that cannot be
            # written are runtime conditions, not broken call sites: a file
            # that cannot be written costs that file's keys, not the
            # family's evening at the greeter.
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
        # extra systems it declares, not the family's evening at the greeter.
        #
        # Live only since the box began shipping a real custom systems
        # document: with an empty source this call takes the
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
