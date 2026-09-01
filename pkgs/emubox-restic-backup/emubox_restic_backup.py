#!/usr/bin/env python3
"""Create a short-lived read-only btrfs source for one restic backup.

The Nix module owns scheduling, secrets, and the static path model. This
program is deliberately small: it owns only the filesystem transaction that
cannot be expressed declaratively. Its cleanup is safe to run repeatedly, so
both boot and every backup invocation reconcile an interrupted earlier run.
"""

from __future__ import annotations

import argparse
import fcntl
import json
from pathlib import Path
import subprocess
import sys
from typing import Any, Callable, Sequence


class InvalidBackupPath(RuntimeError):
    """A configured cache exclusion aliases protected data in the snapshot."""


Run = Callable[[Sequence[str]], None]


def _default_run(command: Sequence[str]) -> None:
    subprocess.run(command, check=True)


def _inside(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def timeout_budget_is_valid(
    maintenance_seconds: int,
    retry_lock_seconds: int,
    pre_restic_seconds: int,
    post_lock_seconds: int,
    activation_seconds: int,
) -> bool:
    """Return whether the declared native-lock timing inequalities hold."""

    return (
        maintenance_seconds < retry_lock_seconds
        and activation_seconds >= pre_restic_seconds + retry_lock_seconds + post_lock_seconds
    )


def timer_starts(cadence_seconds: int, activation_seconds: int, until_seconds: int) -> list[int]:
    """Model systemd's no-overlap handling for a non-persistent oneshot timer."""

    starts: list[int] = []
    active_until = -1
    for elapsed in range(0, until_seconds + 1, cadence_seconds):
        if elapsed >= active_until:
            starts.append(elapsed)
            active_until = elapsed + activation_seconds
    return starts


def validate_exclusions(spec: dict[str, Any], source: Path) -> list[Path]:
    """Resolve exclusions in *source* and reject escapes and protected aliases.

    Evaluation has already checked lexical structure. ``resolve`` is deferred
    until the fresh source exists because it is the only point where symlink
    identity is meaningful and race-free with respect to restic's input.
    """

    home = source / "home/player"
    protected = [(source / root.removeprefix("/data/")).resolve() for root in spec["roots"]]
    resolved: list[Path] = []
    for declared in spec["homeCacheExclusions"]:
        relative = Path(declared).relative_to("/data")
        candidate = source / relative
        # A missing cache path is harmless. An existing ancestor or path is
        # resolved to detect an escape even when the leaf has not been made.
        target = candidate.resolve(strict=False)
        if not _inside(target, home.resolve()):
            raise InvalidBackupPath(
                f"emubox-restic-backup: exclusion escapes player home: {declared}"
            )
        if any(target == item for item in protected):
            raise InvalidBackupPath(
                f"emubox-restic-backup: exclusion aliases protected root: {declared}"
            )
        if any(target == item for item in resolved):
            raise InvalidBackupPath(
                f"emubox-restic-backup: exclusions alias each other: {declared}"
            )
        resolved.append(target)
    return resolved


def reconcile(snapshot_dir: Path, mountpoint: Path, run: Run = _default_run) -> None:
    """Unmount and delete only EmuBox's named transient artifacts."""

    if mountpoint.is_mount():
        run(["umount", "--", str(mountpoint)])
    mountpoint.rmdir() if mountpoint.exists() and not any(mountpoint.iterdir()) else None
    if snapshot_dir.exists():
        for candidate in snapshot_dir.glob("restic-*"):
            run(["btrfs", "subvolume", "delete", "--", str(candidate)])


def initialize(run: Run = _default_run) -> None:
    """Open an existing repository or initialize only restic's absent result."""

    try:
        run(["restic", "cat", "config"])
    except subprocess.CalledProcessError as error:
        if error.returncode == 10:
            run(["restic", "init"])
            return
        raise


def backup(
    spec: dict[str, Any],
    *,
    data: Path,
    snapshot_dir: Path,
    mountpoint: Path,
    exclusion_file: Path,
    run: Run = _default_run,
) -> None:
    """Back up one read-only btrfs snapshot, always attempting cleanup."""

    snapshot_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    mountpoint.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = mountpoint.parent / "restic-source.lock"
    with lock_path.open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        reconcile(snapshot_dir, mountpoint, run)
        snapshot = snapshot_dir / "restic-current"
        mounted = False
        try:
            run(["btrfs", "subvolume", "snapshot", "-r", "--", str(data), str(snapshot)])
            mountpoint.mkdir(mode=0o700)
            run(["mount", "--bind", "--", str(snapshot), str(mountpoint)])
            # A bind mount exists before the read-only remount. Record it
            # immediately so a remount failure cannot strand the writable
            # bind or its transient snapshot.
            mounted = True
            run(["mount", "-o", "remount,bind,ro", "--", str(mountpoint)])
            exclusions = validate_exclusions(spec, mountpoint)
            exclusion_file.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            exclusion_file.write_text("".join(f"{path}\n" for path in exclusions), encoding="utf-8")
            roots = [str(mountpoint / root.removeprefix("/data/")) for root in spec["roots"]]
            run(
                [
                    "restic",
                    "backup",
                    "--retry-lock",
                    spec["retryLock"],
                    "--host",
                    spec["host"],
                    "--tag",
                    spec["tag"],
                    "--exclude-file",
                    str(exclusion_file),
                    *roots,
                ]
            )
        finally:
            # Cleanup deliberately has no relation to systemd's backup
            # activation timeout. ExecStopPost invokes --reconcile too if a
            # SIGKILL bypasses this finally block.
            if mounted and mountpoint.is_mount():
                run(["umount", "--", str(mountpoint)])
            if snapshot.exists():
                run(["btrfs", "subvolume", "delete", "--", str(snapshot)])
            exclusion_file.unlink(missing_ok=True)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-spec", type=Path, required=True)
    parser.add_argument("--data", type=Path, default=Path("/data"))
    parser.add_argument("--snapshot-dir", type=Path, default=Path("/data/.snapshots/restic"))
    parser.add_argument("--mountpoint", type=Path, default=Path("/run/emubox/restic-source"))
    parser.add_argument("--exclusion-file", type=Path, default=Path("/run/emubox/restic-excludes"))
    parser.add_argument("--reconcile", action="store_true")
    parser.add_argument("--init", action="store_true")
    args = parser.parse_args(argv)
    spec = json.loads(args.source_spec.read_text(encoding="utf-8"))
    if args.init:
        initialize()
    elif args.reconcile:
        reconcile(args.snapshot_dir, args.mountpoint)
    else:
        backup(
            spec,
            data=args.data,
            snapshot_dir=args.snapshot_dir,
            mountpoint=args.mountpoint,
            exclusion_file=args.exclusion_file,
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (InvalidBackupPath, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
