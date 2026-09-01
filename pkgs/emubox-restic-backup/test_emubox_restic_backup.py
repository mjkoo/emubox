from pathlib import Path
import subprocess
from typing import Sequence

import pytest

import emubox_restic_backup as erb


def spec() -> dict[str, object]:
    return {
        "roots": ["/data/saves", "/data/es-de", "/data/bios", "/data/home/player"],
        "homeCacheExclusions": ["/data/home/player/.cache", "/data/home/player/.local/cache"],
        "retryLock": "3h15m",
        "host": "emubox",
        "tag": "emubox-save",
    }


def tree(tmp_path: Path) -> Path:
    source = tmp_path / "source"
    for path in ["saves", "es-de", "bios", "home/player/.cache", "home/player/.local/cache"]:
        (source / path).mkdir(parents=True, exist_ok=True)
    return source


def test_unlisted_home_path_is_not_an_exclusion(tmp_path: Path) -> None:
    source = tree(tmp_path)
    (source / "home/player/keep-me").write_text("save")
    assert erb.validate_exclusions(spec(), source) == [
        (source / "home/player/.cache").resolve(),
        (source / "home/player/.local/cache").resolve(),
    ]


def test_symlink_escape_fails_before_restic(tmp_path: Path) -> None:
    source = tree(tmp_path)
    outside = tmp_path / "outside"
    outside.mkdir()
    candidate = source / "home/player/escape"
    candidate.symlink_to(outside, target_is_directory=True)
    bad_spec = spec() | {"homeCacheExclusions": ["/data/home/player/escape"]}
    with pytest.raises(erb.InvalidBackupPath, match="escapes player home"):
        erb.validate_exclusions(bad_spec, source)


def test_exclusions_alias_each_other_fails(tmp_path: Path) -> None:
    source = tree(tmp_path)
    candidate = source / "home/player/cache-alias"
    candidate.symlink_to(source / "home/player/.cache", target_is_directory=True)
    bad_spec = spec() | {
        "homeCacheExclusions": [
            "/data/home/player/.cache",
            "/data/home/player/cache-alias",
        ]
    }
    with pytest.raises(erb.InvalidBackupPath, match="exclusions alias each other"):
        erb.validate_exclusions(bad_spec, source)


def test_backup_finally_removes_mount_snapshot_and_exclude_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    data = tmp_path / "data"
    data.mkdir()
    snapshots = tmp_path / "snapshots"
    mountpoint = tmp_path / "run/source"
    excludes = tmp_path / "run/excludes"
    calls: list[list[str]] = []

    monkeypatch.setattr(Path, "is_mount", lambda _: False)

    def run(command: Sequence[str]) -> None:
        command = list(command)
        calls.append(command)
        if command[:4] == ["btrfs", "subvolume", "snapshot", "-r"]:
            Path(command[-1]).mkdir()
        if command[:3] == ["btrfs", "subvolume", "delete"]:
            Path(command[-1]).rmdir()
        if command[0] == "restic":
            raise RuntimeError("injected restic failure")

    with pytest.raises(RuntimeError, match="injected"):
        erb.backup(
            spec(),
            data=data,
            snapshot_dir=snapshots,
            mountpoint=mountpoint,
            exclusion_file=excludes,
            run=run,
        )

    assert not (snapshots / "restic-current").exists()
    assert not excludes.exists()
    assert ["restic", "backup"] == calls[-2][:2]
    assert calls[-1][:3] == ["btrfs", "subvolume", "delete"]


def test_timeout_uses_the_same_final_cleanup_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    data = tmp_path / "data"
    data.mkdir()
    snapshots = tmp_path / "snapshots"
    mountpoint = tmp_path / "run/source"
    excludes = tmp_path / "run/excludes"

    monkeypatch.setattr(Path, "is_mount", lambda _: False)

    def run(command: Sequence[str]) -> None:
        command = list(command)
        if command[:4] == ["btrfs", "subvolume", "snapshot", "-r"]:
            Path(command[-1]).mkdir()
        if command[:3] == ["btrfs", "subvolume", "delete"]:
            Path(command[-1]).rmdir()
        if command[0] == "restic":
            raise subprocess.TimeoutExpired(command, timeout=1)

    with pytest.raises(subprocess.TimeoutExpired):
        erb.backup(
            spec(),
            data=data,
            snapshot_dir=snapshots,
            mountpoint=mountpoint,
            exclusion_file=excludes,
            run=run,
        )

    assert not (snapshots / "restic-current").exists()
    assert not excludes.exists()


def test_read_only_remount_failure_unmounts_the_just_created_bind(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    data = tmp_path / "data"
    data.mkdir()
    snapshots = tmp_path / "snapshots"
    mountpoint = tmp_path / "run/source"
    excludes = tmp_path / "run/excludes"
    calls: list[list[str]] = []
    mount_state = {"mounted": False}

    monkeypatch.setattr(Path, "is_mount", lambda _: mount_state["mounted"])

    def run(command: Sequence[str]) -> None:
        command = list(command)
        calls.append(command)
        if command[:4] == ["btrfs", "subvolume", "snapshot", "-r"]:
            Path(command[-1]).mkdir()
        elif command[:3] == ["btrfs", "subvolume", "delete"]:
            Path(command[-1]).rmdir()
        elif command[:2] == ["mount", "--bind"]:
            mount_state["mounted"] = True
        elif command[:3] == ["mount", "-o", "remount,bind,ro"]:
            raise RuntimeError("injected read-only remount failure")
        elif command[0] == "umount":
            mount_state["mounted"] = False

    with pytest.raises(RuntimeError, match="read-only remount"):
        erb.backup(
            spec(),
            data=data,
            snapshot_dir=snapshots,
            mountpoint=mountpoint,
            exclusion_file=excludes,
            run=run,
        )

    assert ["umount", "--", str(mountpoint)] in calls
    assert not (snapshots / "restic-current").exists()


def test_backup_uses_read_only_source_and_native_lock_retry(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    data = tmp_path / "data"
    data.mkdir()
    snapshots = tmp_path / "snapshots"
    mountpoint = tmp_path / "run/source"
    excludes = tmp_path / "run/excludes"
    calls: list[list[str]] = []

    monkeypatch.setattr(Path, "is_mount", lambda _: False)

    def run(command: Sequence[str]) -> None:
        command = list(command)
        calls.append(command)
        if command[:4] == ["btrfs", "subvolume", "snapshot", "-r"]:
            Path(command[-1]).mkdir()
        if command[:3] == ["btrfs", "subvolume", "delete"]:
            Path(command[-1]).rmdir()

    erb.backup(
        spec(),
        data=data,
        snapshot_dir=snapshots,
        mountpoint=mountpoint,
        exclusion_file=excludes,
        run=run,
    )

    assert ["mount", "-o", "remount,bind,ro", "--", str(mountpoint)] in calls
    command = next(command for command in calls if command[:2] == ["restic", "backup"])
    assert command[2:4] == ["--retry-lock", "3h15m"]


def test_reconciliation_removes_an_interrupted_source_before_next_snapshot(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    data = tmp_path / "data"
    data.mkdir()
    snapshots = tmp_path / "snapshots"
    snapshots.mkdir()
    interrupted = snapshots / "restic-interrupted"
    interrupted.mkdir()
    mountpoint = tmp_path / "run/source"
    excludes = tmp_path / "run/excludes"
    calls: list[list[str]] = []
    monkeypatch.setattr(Path, "is_mount", lambda _: False)

    def run(command: Sequence[str]) -> None:
        command = list(command)
        calls.append(command)
        if command[:3] == ["btrfs", "subvolume", "delete"]:
            Path(command[-1]).rmdir()
        if command[:4] == ["btrfs", "subvolume", "snapshot", "-r"]:
            Path(command[-1]).mkdir()

    erb.backup(
        spec(),
        data=data,
        snapshot_dir=snapshots,
        mountpoint=mountpoint,
        exclusion_file=excludes,
        run=run,
    )

    delete = ["btrfs", "subvolume", "delete", "--", str(interrupted)]
    create = [
        "btrfs",
        "subvolume",
        "snapshot",
        "-r",
        "--",
        str(data),
        str(snapshots / "restic-current"),
    ]
    assert calls.index(delete) < calls.index(create)


def test_scaled_timeout_budget_preserves_post_lock_work() -> None:
    assert erb.timeout_budget_is_valid(3 * 60, 3 * 60 + 15, 10, 4 * 60, 7 * 60 + 25)
    assert not erb.timeout_budget_is_valid(3 * 60, 3 * 60, 10, 4 * 60, 7 * 60 + 25)
    assert not erb.timeout_budget_is_valid(3 * 60, 3 * 60 + 15, 10, 4 * 60, 7 * 60 + 24)


def test_missed_timer_activation_is_not_queued_and_future_activation_runs() -> None:
    # At a scaled four-minute cadence, a seven-minute activation consumes the
    # middle tick but the following one starts normally.
    assert erb.timer_starts(
        cadence_seconds=4 * 60, activation_seconds=7 * 60 + 25, until_seconds=12 * 60
    ) == [
        0,
        8 * 60,
    ]


def test_init_only_creates_a_precisely_absent_repository() -> None:
    calls: list[list[str]] = []

    def absent(command: Sequence[str]) -> None:
        command = list(command)
        calls.append(command)
        if command == ["restic", "cat", "config"]:
            raise subprocess.CalledProcessError(10, command)

    erb.initialize(absent)
    assert calls == [["restic", "cat", "config"], ["restic", "init"]]


@pytest.mark.parametrize("result", [1, 11, 12])
def test_init_fails_closed_for_any_non_absent_error(result: int) -> None:
    def failed(command: Sequence[str]) -> None:
        raise subprocess.CalledProcessError(result, command)

    with pytest.raises(subprocess.CalledProcessError):
        erb.initialize(failed)


def test_init_is_idempotent_for_an_existing_repository() -> None:
    calls: list[list[str]] = []

    def existing(command: Sequence[str]) -> None:
        calls.append(list(command))

    erb.initialize(existing)
    erb.initialize(existing)
    assert calls == [["restic", "cat", "config"], ["restic", "cat", "config"]]
