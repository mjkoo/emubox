#!/usr/bin/env python3
"""Report whether `/data/bios` holds the firmware the flake declares.

Invocation contract (design D6):

    emubox-check-bios <inventory-json> <bios-directory>

Exactly two positional arguments, mirroring `emubox-prepare`'s own shape
(design D3) rather than a `--flag` style: this is a report-only tool with
nothing to configure beyond which inventory and which directory to read, so
there is no option parser to keep in sync with anything. Both arguments are
always required - the second is what lets a unit test point the checker at a
scratch directory instead of the real `/data/bios`.

The inventory JSON is an object mapping an arbitrary short id to an entry:

    {"psx": {"path": "scph5501.bin", "sha256": "...", "name": "PS1 BIOS (SCPH-5501, NA)"}}

`path` is relative to `<bios-directory>`; `sha256` is the checksum of a
correct copy of that file; `name` is what the report prints. The id itself
is never shown - it exists only so the module that renders the JSON can key
the attrset by something readable in `modules/emulators` without repeating
the path.

Error policy: the opposite of `emubox-prepare`'s. Prepare recreates a file
it cannot make sense of because failing would strand the family at the
greeter with no game they can start; this tool exists only to tell an admin
the truth about firmware nobody can ship, so it never writes, never
recreates and never guesses - a file it cannot read is reported as missing,
not silently skipped, and a malformed inventory is a hard error rather than
an empty report that would look like a clean bill of health.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import TypedDict


class Entry(TypedDict):
    path: str
    sha256: str
    name: str


def note(message: str) -> None:
    print(f"emubox-check-bios: {message}", file=sys.stderr)


def sha256_of(path: Path) -> str | None:
    """The file's sha256, or None if it cannot be read at all.

    A directory, a dangling symlink, or a file the process lacks permission
    for are all read failures here, and every one of them is reported the
    same way a plain absence is - "missing" is the honest description of a
    declared file this tool cannot verify, whatever the underlying reason.
    """
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError:
        return None
    return digest.hexdigest()


def load_inventory(path: str) -> dict[str, Entry] | None:
    try:
        document = json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        note(f"{path} is not readable inventory JSON ({error})")
        return None
    if not isinstance(document, dict):
        note(
            f"{path}: expected an object mapping id to entry, got {type(document).__name__}"
        )
        return None
    inventory: dict[str, Entry] = {}
    for entry_id, entry in document.items():
        if (
            not isinstance(entry, dict)
            or not isinstance(entry.get("path"), str)
            or not isinstance(entry.get("sha256"), str)
            or not isinstance(entry.get("name"), str)
        ):
            note(
                f"{path}: entry {entry_id!r} is not an object with path, sha256 and name"
            )
            return None
        inventory[entry_id] = {
            "path": entry["path"],
            "sha256": entry["sha256"],
            "name": entry["name"],
        }
    return inventory


def check(inventory: dict[str, Entry], bios_dir: Path) -> tuple[list[str], bool]:
    """The report lines and whether every declared file matched.

    Declared files are reported in a stable order (sorted by their relative
    path) so two runs against the same inventory and directory produce the
    same report byte-for-byte, which is what makes this tool's output usable
    in a script or diffed by an admin across visits. Extras are reported
    after every declared entry, also sorted, and never affect the returned
    success flag - the spec's own words are that they are "informational".
    """
    lines: list[str] = []
    ok = True
    declared_paths: set[str] = set()

    for entry in sorted(inventory.values(), key=lambda e: e["path"]):
        declared_paths.add(entry["path"])
        target = bios_dir / entry["path"]
        digest = sha256_of(target)
        if digest is None:
            lines.append(f"MISSING  {entry['name']} ({entry['path']})")
            ok = False
        elif digest != entry["sha256"]:
            lines.append(
                f"MISMATCH {entry['name']} ({entry['path']}): "
                f"expected {entry['sha256']}, got {digest}"
            )
            ok = False
        else:
            lines.append(f"OK       {entry['name']} ({entry['path']})")

    # Only plain files are walked, not directories: a subdirectory under
    # /data/bios is not itself an undeclared file, and reporting one as an
    # "extra" alongside real firmware files would misdescribe it.
    if bios_dir.is_dir():
        for candidate in sorted(bios_dir.rglob("*")):
            if not candidate.is_file():
                continue
            relative = str(candidate.relative_to(bios_dir))
            if relative not in declared_paths:
                lines.append(f"EXTRA    {relative} (not declared)")

    return lines, ok


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        note("usage: emubox-check-bios <inventory-json> <bios-directory>")
        return 2

    inventory_path, bios_dir_arg = argv
    inventory = load_inventory(inventory_path)
    if inventory is None:
        return 1

    bios_dir = Path(bios_dir_arg)
    lines, ok = check(inventory, bios_dir)
    for line in lines:
        print(line)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
