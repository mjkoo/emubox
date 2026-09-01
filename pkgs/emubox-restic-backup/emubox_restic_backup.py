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
import os
from pathlib import Path
import subprocess
import sys
from datetime import UTC, datetime
from typing import Any, Callable, Sequence


class InvalidBackupPath(RuntimeError):
    """A configured cache exclusion aliases protected data in the snapshot."""


Run = Callable[[Sequence[str]], None]

MARKER_PREFIX = "EMUBOX_MARKER="


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


def marker_line(kind: str, payload: dict[str, str], invocation_id: str | None = None) -> str:
    """Create the one parseable journal record used as success evidence.

    The record intentionally lives only in the journal.  Systemd's invocation
    ID is the authority for the run, so keeping a second result file would
    create a competing job-state database.
    """

    invocation = invocation_id or os.environ.get("INVOCATION_ID")
    if not invocation:
        raise RuntimeError("emubox marker requires systemd INVOCATION_ID")
    return MARKER_PREFIX + json.dumps(
        {"kind": kind, "invocationId": invocation, **payload},
        sort_keys=True,
        separators=(",", ":"),
    )


def parse_marker(line: str, *, kind: str, invocation_id: str) -> dict[str, str] | None:
    """Accept only a complete marker belonging to the requested invocation."""

    if not line.startswith(MARKER_PREFIX):
        return None
    try:
        marker = json.loads(line.removeprefix(MARKER_PREFIX))
    except json.JSONDecodeError:
        return None
    if not isinstance(marker, dict):
        return None
    if marker.get("kind") != kind or marker.get("invocationId") != invocation_id:
        return None
    if not all(isinstance(key, str) and isinstance(value, str) for key, value in marker.items()):
        return None
    return marker


def _now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _restic_json(command: Sequence[str]) -> Any:
    output = subprocess.check_output(["restic", *command], text=True)
    return json.loads(output)


def _repository_id() -> str:
    config = _restic_json(["cat", "config"])
    repository_id = config.get("id") if isinstance(config, dict) else None
    if not isinstance(repository_id, str) or not repository_id:
        raise RuntimeError("restic config did not contain a repository ID")
    return repository_id


def _latest_snapshot(spec: dict[str, Any]) -> str:
    snapshots = _restic_json(
        [
            "snapshots",
            "--json",
            "--host",
            str(spec["host"]),
            "--tag",
            str(spec["tag"]),
            "--latest",
            "1",
        ]
    )
    if not isinstance(snapshots, list) or len(snapshots) != 1 or not isinstance(snapshots[0], dict):
        raise RuntimeError("restic did not return one protected EmuBox snapshot")
    snapshot_id = snapshots[0].get("short_id") or snapshots[0].get("id")
    if not isinstance(snapshot_id, str) or not snapshot_id:
        raise RuntimeError("restic snapshot did not contain an ID")
    return snapshot_id


def emit_backup_marker(spec: dict[str, Any]) -> None:
    """Emit success evidence after a completed backup, in that unit's journal."""

    print(
        marker_line(
            "backup",
            {
                "repositoryId": _repository_id(),
                "snapshotId": _latest_snapshot(spec),
                "host": str(spec["host"]),
                "tag": str(spec["tag"]),
                "timestamp": _now(),
            },
        )
    )


def emit_maintenance_marker(spec: dict[str, Any]) -> None:
    """Emit maintenance success only after retention, prune and check all pass."""

    print(
        marker_line(
            "maintenance",
            {
                "repositoryId": _repository_id(),
                "newestProtectedSnapshotId": _latest_snapshot(spec),
                "timestamp": _now(),
            },
        )
    )


def emit_local_marker(snapshot_dir: Path) -> None:
    """Emit the newest canonical read-only btrbk source as local evidence."""

    snapshots = sorted(
        path for path in snapshot_dir.iterdir() if path.is_dir() and path.name.startswith("data.")
    )
    if not snapshots:
        raise RuntimeError("btrbk completed without a local snapshot")
    snapshot = snapshots[-1].resolve()
    if not _inside(snapshot, snapshot_dir.resolve()):
        raise RuntimeError("local snapshot resolved outside the snapshot directory")
    readonly = subprocess.check_output(
        ["btrfs", "property", "get", "-ts", str(snapshot), "ro"], text=True
    ).strip()
    if readonly != "ro=true":
        raise RuntimeError("btrbk completed without a read-only local snapshot")
    print(
        marker_line(
            "local",
            {"path": str(snapshot), "timestamp": _now()},
        )
    )


def layer_health(
    *,
    result: str,
    invocation_id: str,
    journal_lines: Sequence[str],
    kind: str,
    required_fields: Sequence[str],
) -> tuple[bool, str]:
    """Return health for exactly the latest systemd invocation.

    This small pure seam is deliberately testable without a live journal.
    Older success records are never considered when the newest invocation
    failed or lacks matching evidence.
    """

    if not invocation_id:
        return False, "never run"
    if result != "success":
        return False, f"latest invocation failed ({result})"
    markers = [
        marker
        for line in journal_lines
        if (marker := parse_marker(line, kind=kind, invocation_id=invocation_id)) is not None
    ]
    if len(markers) != 1:
        return False, "missing, malformed, or ambiguous success marker"
    if any(not markers[0].get(field) for field in required_fields):
        return False, "success marker is incomplete"
    return True, "success"


def _unit_property(unit: str, property_name: str) -> str:
    return subprocess.check_output(
        ["systemctl", "show", "--value", f"--property={property_name}", unit], text=True
    ).strip()


def _invocation_journal(unit: str, invocation_id: str) -> list[str]:
    output = subprocess.check_output(
        [
            "journalctl",
            f"--unit={unit}",
            "--output=cat",
            "--no-pager",
            "--quiet",
            f"_SYSTEMD_INVOCATION_ID={invocation_id}",
        ],
        text=True,
    )
    return output.splitlines()


def _fresh(timestamp: str, maximum_age_seconds: int, *, now: datetime | None = None) -> bool:
    try:
        instant = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError:
        return False
    return ((now or datetime.now(UTC)) - instant).total_seconds() <= maximum_age_seconds


def status_layer(
    *,
    unit: str,
    kind: str,
    required_fields: Sequence[str],
    maximum_age_seconds: int,
    now: datetime | None = None,
) -> tuple[bool, str]:
    """Read current systemd evidence, never a historical result database."""

    invocation_id = _unit_property(unit, "InvocationID")
    result = _unit_property(unit, "Result")
    try:
        journal = _invocation_journal(unit, invocation_id) if invocation_id else []
    except subprocess.CalledProcessError:
        journal = []
    healthy, reason = layer_health(
        result=result,
        invocation_id=invocation_id,
        journal_lines=journal,
        kind=kind,
        required_fields=required_fields,
    )
    if not healthy:
        return False, f"{unit}: {reason}; inspect journalctl -u {unit}"
    marker = next(
        parse_marker(line, kind=kind, invocation_id=invocation_id)
        for line in journal
        if parse_marker(line, kind=kind, invocation_id=invocation_id) is not None
    )
    assert marker is not None
    timestamp = marker["timestamp"]
    if not _fresh(timestamp, maximum_age_seconds, now=now):
        return False, f"{unit}: success marker is stale ({timestamp})"
    recovery = (
        marker.get("snapshotId") or marker.get("newestProtectedSnapshotId") or marker.get("path")
    )
    return True, f"{unit}: success at {timestamp}; recovery point {recovery}"


def print_status() -> int:
    """Print one authoritative status line for local, backup and maintenance."""

    layers = [
        ("btrbk-local.service", "local", ["path", "timestamp"], 2 * 60 * 60),
        (
            "emubox-restic-backup.service",
            "backup",
            ["snapshotId", "repositoryId", "host", "tag", "timestamp"],
            8 * 60 * 60,
        ),
        (
            "emubox-restic-maintenance.service",
            "maintenance",
            ["repositoryId", "newestProtectedSnapshotId", "timestamp"],
            14 * 24 * 60 * 60,
        ),
    ]
    healthy = True
    for unit, kind, fields, age in layers:
        current, line = status_layer(
            unit=unit, kind=kind, required_fields=fields, maximum_age_seconds=age
        )
        print(("OK " if current else "WARN ") + line)
        healthy = healthy and current
    return 0 if healthy else 1


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
    parser.add_argument("--source-spec", type=Path)
    parser.add_argument("--data", type=Path, default=Path("/data"))
    parser.add_argument("--snapshot-dir", type=Path, default=Path("/data/.snapshots/restic"))
    parser.add_argument("--mountpoint", type=Path, default=Path("/run/emubox/restic-source"))
    parser.add_argument("--exclusion-file", type=Path, default=Path("/run/emubox/restic-excludes"))
    parser.add_argument("--reconcile", action="store_true")
    parser.add_argument("--init", action="store_true")
    parser.add_argument("--emit-backup-marker", action="store_true")
    parser.add_argument("--emit-maintenance-marker", action="store_true")
    parser.add_argument("--emit-local-marker", action="store_true")
    parser.add_argument("--status", action="store_true")
    args = parser.parse_args(argv)
    if Path(sys.argv[0]).name == "emubox-status":
        args.status = True
    source_actions = (
        args.init or args.reconcile or args.emit_backup_marker or args.emit_maintenance_marker
    )
    if source_actions and args.source_spec is None:
        parser.error("--source-spec is required for this action")
    if (
        not source_actions
        and not args.emit_local_marker
        and not args.status
        and args.source_spec is None
    ):
        parser.error("--source-spec is required for backup")
    spec = (
        json.loads(args.source_spec.read_text(encoding="utf-8"))
        if args.source_spec is not None
        else None
    )
    if args.init:
        initialize()
    elif args.reconcile:
        reconcile(args.snapshot_dir, args.mountpoint)
    elif args.emit_backup_marker:
        assert spec is not None
        emit_backup_marker(spec)
    elif args.emit_maintenance_marker:
        assert spec is not None
        emit_maintenance_marker(spec)
    elif args.emit_local_marker:
        emit_local_marker(args.snapshot_dir)
    elif args.status:
        return print_status()
    else:
        assert spec is not None
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
