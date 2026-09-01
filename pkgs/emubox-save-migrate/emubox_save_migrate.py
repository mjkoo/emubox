#!/usr/bin/env python3
"""Move legacy save trees to their declared destinations without data loss."""

from __future__ import annotations

import argparse
import filecmp
import json
import os
from pathlib import Path
import shutil
import sys
from typing import Any


class MigrationConflict(RuntimeError):
    """A legacy and destination file differ at the same relative path."""


def _same_file(source: Path, destination: Path) -> bool:
    return (
        source.is_file()
        and destination.is_file()
        and filecmp.cmp(source, destination, shallow=False)
    )


def migrate_tree(source: Path, destination: Path) -> None:
    """Merge *source* into *destination*, rejecting every destructive conflict.

    The preflight runs before any rename. That makes a failed migration safe to
    retry: it neither overwrites a destination nor leaves half a legacy tree
    hidden by a soon-to-be-created bind mount.
    """
    if not source.exists() and not source.is_symlink():
        return
    destination.mkdir(parents=True, exist_ok=True)

    conflicts: list[tuple[Path, Path]] = []
    for root, dirs, files in os.walk(source):
        root_path = Path(root)
        relative_root = root_path.relative_to(source)
        for name in [*dirs, *files]:
            old = root_path / name
            new = destination / relative_root / name
            if new.exists() or new.is_symlink():
                if old.is_dir() and not old.is_symlink() and new.is_dir() and not new.is_symlink():
                    continue
                if _same_file(old, new):
                    continue
                conflicts.append((old, new))
    if conflicts:
        pairs = "\n".join(f"{old} conflicts with {new}" for old, new in conflicts)
        raise MigrationConflict(f"emubox-save-migrate: refusing to overwrite save data:\n{pairs}")

    for root, dirs, files in os.walk(source, topdown=False):
        root_path = Path(root)
        relative_root = root_path.relative_to(source)
        for name in files:
            old = root_path / name
            new = destination / relative_root / name
            new.parent.mkdir(parents=True, exist_ok=True)
            if new.exists() or new.is_symlink():
                old.unlink()
            else:
                shutil.move(str(old), str(new))
        for name in dirs:
            old = root_path / name
            new = destination / relative_root / name
            new.mkdir(parents=True, exist_ok=True)
            if old.exists() and not any(old.iterdir()):
                old.rmdir()
    # Keep the route root. Bind-mounted routes require that mountpoint after
    # migration, and an empty legacy directory is harmless for settings.


def migrate_routes(routes: list[dict[str, Any]]) -> None:
    for route in routes:
        destination = Path(route["destination"])
        destination.mkdir(parents=True, exist_ok=True)
        for legacy in route["legacyPaths"]:
            migrate_tree(Path(legacy), destination)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("routes", type=Path)
    args = parser.parse_args(argv)
    try:
        migrate_routes(json.loads(args.routes.read_text()))
    except MigrationConflict as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
