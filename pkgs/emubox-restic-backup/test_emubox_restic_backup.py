from datetime import UTC, datetime, timedelta
from pathlib import Path
import subprocess
from typing import Callable, Sequence

import pytest

import emubox_restic_backup as erb


NOW = datetime(2026, 8, 31, 12, 0, tzinfo=UTC)


def _timestamp(age_seconds: int) -> str:
    return (NOW - timedelta(seconds=age_seconds)).isoformat().replace("+00:00", "Z")


def _status_marker(kind: str, invocation_id: str, timestamp: str) -> str:
    payloads = {
        "local": {"path": "/data/.snapshots/data.20260831T1200", "timestamp": timestamp},
        "backup": {
            "snapshotId": "snapshot",
            "repositoryId": "repository",
            "host": "emubox",
            "tag": "emubox-save",
            "timestamp": timestamp,
        },
        "maintenance": {
            "repositoryId": "repository",
            "newestProtectedSnapshotId": "snapshot",
            "timestamp": timestamp,
        },
    }
    return erb.marker_line(kind, payloads[kind], invocation_id=invocation_id)


def _mock_status_sources(
    monkeypatch: pytest.MonkeyPatch,
    *,
    result: str,
    invocation_id: str,
    journal: list[str],
) -> list[tuple[str, str]]:
    journal_calls: list[tuple[str, str]] = []

    def property_value(_unit: str, property_name: str) -> str:
        return {"Result": result, "InvocationID": invocation_id}[property_name]

    def invocation_journal(unit: str, actual_invocation_id: str) -> list[str]:
        journal_calls.append((unit, actual_invocation_id))
        return journal

    monkeypatch.setattr(erb, "_unit_property", property_value)
    monkeypatch.setattr(erb, "_invocation_journal", invocation_journal)
    return journal_calls


@pytest.mark.parametrize("maximum_age_seconds", [2 * 60 * 60, 8 * 60 * 60, 14 * 24 * 60 * 60])
def test_freshness_boundaries_are_current_at_limit_and_warn_after(
    maximum_age_seconds: int,
) -> None:
    assert erb._fresh(_timestamp(maximum_age_seconds), maximum_age_seconds, now=NOW)
    assert not erb._fresh(_timestamp(maximum_age_seconds + 1), maximum_age_seconds, now=NOW)


@pytest.mark.parametrize(
    ("kind", "required_fields", "maximum_age_seconds"),
    [
        ("local", ["path", "timestamp"], 2 * 60 * 60),
        ("backup", ["snapshotId", "repositoryId", "host", "tag", "timestamp"], 8 * 60 * 60),
        (
            "maintenance",
            ["repositoryId", "newestProtectedSnapshotId", "timestamp"],
            14 * 24 * 60 * 60,
        ),
    ],
)
def test_status_layer_applies_the_layer_freshness_threshold(
    monkeypatch: pytest.MonkeyPatch,
    kind: str,
    required_fields: list[str],
    maximum_age_seconds: int,
) -> None:
    current_invocation = "current-invocation"
    journal_calls = _mock_status_sources(
        monkeypatch,
        result="success",
        invocation_id=current_invocation,
        journal=[_status_marker(kind, current_invocation, _timestamp(maximum_age_seconds + 1))],
    )

    healthy, output = erb.status_layer(
        unit="example.service",
        kind=kind,
        required_fields=required_fields,
        maximum_age_seconds=maximum_age_seconds,
        now=NOW,
    )

    assert not healthy
    assert "stale" in output
    assert journal_calls == [("example.service", current_invocation)]


@pytest.mark.parametrize("journal", [[], ["EMUBOX_MARKER={not json}"]])
def test_status_layer_rejects_missing_or_malformed_current_marker(
    monkeypatch: pytest.MonkeyPatch, journal: list[str]
) -> None:
    _mock_status_sources(
        monkeypatch,
        result="success",
        invocation_id="current",
        journal=journal,
    )

    healthy, output = erb.status_layer(
        unit="backup.service",
        kind="backup",
        required_fields=["snapshotId", "repositoryId", "host", "tag", "timestamp"],
        maximum_age_seconds=8 * 60 * 60,
        now=NOW,
    )

    assert not healthy
    assert "missing, malformed" in output


def test_status_layer_warns_when_the_unit_never_ran(monkeypatch: pytest.MonkeyPatch) -> None:
    journal_calls = _mock_status_sources(
        monkeypatch,
        result="success",
        invocation_id="",
        journal=[],
    )

    healthy, output = erb.status_layer(
        unit="backup.service",
        kind="backup",
        required_fields=["snapshotId", "repositoryId", "host", "tag", "timestamp"],
        maximum_age_seconds=8 * 60 * 60,
        now=NOW,
    )

    assert not healthy
    assert "never run" in output
    assert journal_calls == []


def test_status_layer_filters_journal_to_current_invocation_and_failure_wins(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    current_invocation = "current"
    old_success = _status_marker("backup", "older", _timestamp(1))
    journal_calls = _mock_status_sources(
        monkeypatch,
        result="exit-code",
        invocation_id=current_invocation,
        journal=[old_success],
    )

    healthy, output = erb.status_layer(
        unit="backup.service",
        kind="backup",
        required_fields=["snapshotId", "repositoryId", "host", "tag", "timestamp"],
        maximum_age_seconds=8 * 60 * 60,
        now=NOW,
    )

    assert not healthy
    assert "latest invocation failed (exit-code)" in output
    assert journal_calls == [("backup.service", current_invocation)]


def test_status_systemd_and_journal_queries_are_bound_to_one_invocation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []

    def check_output(command: list[str], *, text: bool) -> str:
        assert text
        calls.append(command)
        if command[0] == "systemctl":
            return "current-invocation\n"
        return "journal line\n"

    monkeypatch.setattr(subprocess, "check_output", check_output)

    assert erb._unit_property("backup.service", "InvocationID") == "current-invocation"
    assert erb._invocation_journal("backup.service", "current-invocation") == ["journal line"]
    assert calls == [
        ["systemctl", "show", "--value", "--property=InvocationID", "backup.service"],
        [
            "journalctl",
            "--unit=backup.service",
            "--output=cat",
            "--no-pager",
            "--quiet",
            "_SYSTEMD_INVOCATION_ID=current-invocation",
        ],
    ]


def test_marker_requires_the_systemd_invocation_identity() -> None:
    with pytest.raises(RuntimeError, match="INVOCATION_ID"):
        erb.marker_line("backup", {}, invocation_id="")


def test_marker_is_parseable_only_for_its_own_invocation() -> None:
    line = erb.marker_line(
        "backup",
        {"snapshotId": "abc", "repositoryId": "repo"},
        invocation_id="run-1",
    )
    assert erb.parse_marker(line, kind="backup", invocation_id="run-1") == {
        "kind": "backup",
        "invocationId": "run-1",
        "repositoryId": "repo",
        "snapshotId": "abc",
    }
    assert erb.parse_marker(line, kind="backup", invocation_id="run-2") is None
    assert erb.parse_marker("EMUBOX_MARKER=not-json", kind="backup", invocation_id="run-1") is None


def test_latest_invocation_failure_cannot_use_an_older_success_marker() -> None:
    old = erb.marker_line(
        "backup",
        {
            "snapshotId": "abc",
            "repositoryId": "repo",
            "timestamp": "now",
            "host": "box",
            "tag": "save",
        },
        invocation_id="old",
    )
    assert erb.layer_health(
        result="exit-code",
        invocation_id="new",
        journal_lines=[old],
        kind="backup",
        required_fields=["snapshotId", "repositoryId", "timestamp", "host", "tag"],
    ) == (False, "latest invocation failed (exit-code)")


def test_success_requires_one_complete_marker_for_the_latest_invocation() -> None:
    marker = erb.marker_line(
        "maintenance",
        {"repositoryId": "repo", "newestProtectedSnapshotId": "abc", "timestamp": "now"},
        invocation_id="new",
    )
    assert erb.layer_health(
        result="success",
        invocation_id="new",
        journal_lines=[marker],
        kind="maintenance",
        required_fields=["repositoryId", "newestProtectedSnapshotId", "timestamp"],
    ) == (True, "success")
    assert erb.layer_health(
        result="success",
        invocation_id="new",
        journal_lines=[],
        kind="maintenance",
        required_fields=["repositoryId", "newestProtectedSnapshotId", "timestamp"],
    ) == (False, "missing, malformed, or ambiguous success marker")


def test_local_marker_selects_a_read_only_btrbk_snapshot_not_restic_transients(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    snapshot_dir = tmp_path / "snapshots"
    (snapshot_dir / "data.20260831T1200").mkdir(parents=True)
    (snapshot_dir / "restic").mkdir()
    monkeypatch.setenv("INVOCATION_ID", "local-run")
    monkeypatch.setattr(subprocess, "check_output", lambda *_args, **_kwargs: "ro=true\n")

    erb.emit_local_marker(snapshot_dir)

    marker = erb.parse_marker(
        capsys.readouterr().out.strip(), kind="local", invocation_id="local-run"
    )
    assert marker is not None
    assert marker["path"] == str((snapshot_dir / "data.20260831T1200").resolve())


def test_local_marker_rejects_a_writable_snapshot(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    snapshot_dir = tmp_path / "snapshots"
    (snapshot_dir / "data.20260831T1200").mkdir(parents=True)
    monkeypatch.setenv("INVOCATION_ID", "local-run")
    monkeypatch.setattr(subprocess, "check_output", lambda *_args, **_kwargs: "ro=false\n")

    with pytest.raises(RuntimeError, match="read-only"):
        erb.emit_local_marker(snapshot_dir)


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


def _transaction_run(
    calls: list[list[str]], mount_state: dict[str, bool] | None = None
) -> Callable[[Sequence[str]], None]:
    """A `run` double that keeps the on-disk effects the transaction relies on."""

    def run(command: Sequence[str]) -> None:
        command = list(command)
        calls.append(command)
        if command[:4] == ["btrfs", "subvolume", "snapshot", "-r"]:
            Path(command[-1]).mkdir()
        elif command[:3] == ["btrfs", "subvolume", "delete"]:
            Path(command[-1]).rmdir()
        elif command[:2] == ["mount", "--bind"] and mount_state is not None:
            mount_state["mounted"] = True
        elif command[0] == "umount" and mount_state is not None:
            mount_state["mounted"] = False

    return run


def test_prepare_opens_the_repository_before_taking_a_snapshot(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An unreachable repository must cost no snapshot.

    The gate is the first thing `--prepare` does, so a repository that cannot
    be opened fails the backup's activation before any filesystem state exists
    to clean up.
    """

    data = tmp_path / "data"
    data.mkdir()
    snapshots = tmp_path / "snapshots"
    calls: list[list[str]] = []
    monkeypatch.setattr(Path, "is_mount", lambda _: False)

    def run(command: Sequence[str]) -> None:
        command = list(command)
        calls.append(command)
        if command[1:3] == ["cat", "config"]:
            raise subprocess.CalledProcessError(12, command)

    with pytest.raises(subprocess.CalledProcessError):
        erb.prepare(
            spec(),
            data=data,
            snapshot_dir=snapshots,
            mountpoint=tmp_path / "run/source",
            exclusion_file=tmp_path / "run/excludes",
            run=run,
        )

    assert calls == [["restic", "cat", "config"]]
    assert not snapshots.exists()


def test_prepare_exposes_a_read_only_source_and_resolved_exclusions(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    data = tmp_path / "data"
    data.mkdir()
    snapshots = tmp_path / "snapshots"
    mountpoint = tmp_path / "run/source"
    excludes = tmp_path / "run/excludes"
    calls: list[list[str]] = []
    monkeypatch.setattr(Path, "is_mount", lambda _: False)

    erb.prepare(
        spec(),
        data=data,
        snapshot_dir=snapshots,
        mountpoint=mountpoint,
        exclusion_file=excludes,
        run=_transaction_run(calls),
    )

    assert ["mount", "-o", "remount,bind,ro", "--", str(mountpoint)] in calls
    assert (snapshots / "restic-current").exists()
    # restic reads these; the module passes the file with --exclude-file.
    assert excludes.read_text(encoding="utf-8").splitlines() == [
        str(mountpoint / "home/player/.cache"),
        str(mountpoint / "home/player/.local/cache"),
    ]
    # The restic command line itself is the Nix module's, asserted in
    # tests/backups.nix; nothing here shells out to restic but the gate.
    assert [command for command in calls if command[:2] == ["restic", "backup"]] == []


def test_prepare_unwinds_its_own_mount_and_snapshot_on_failure(
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
    inner = _transaction_run(calls, mount_state)

    def run(command: Sequence[str]) -> None:
        inner(command)
        if list(command)[:3] == ["mount", "-o", "remount,bind,ro"]:
            raise RuntimeError("injected read-only remount failure")

    with pytest.raises(RuntimeError, match="read-only remount"):
        erb.prepare(
            spec(),
            data=data,
            snapshot_dir=snapshots,
            mountpoint=mountpoint,
            exclusion_file=excludes,
            run=run,
        )

    assert ["umount", "--", str(mountpoint)] in calls
    assert not (snapshots / "restic-current").exists()
    assert not excludes.exists()


def test_cleanup_removes_the_transient_source_whatever_restic_did(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """`backupCleanupCommand` runs from ExecStopPost on success and failure."""

    data = tmp_path / "data"
    data.mkdir()
    snapshots = tmp_path / "snapshots"
    mountpoint = tmp_path / "run/source"
    excludes = tmp_path / "run/excludes"
    calls: list[list[str]] = []
    monkeypatch.setattr(Path, "is_mount", lambda _: False)

    erb.prepare(
        spec(),
        data=data,
        snapshot_dir=snapshots,
        mountpoint=mountpoint,
        exclusion_file=excludes,
        run=_transaction_run(calls),
    )
    assert (snapshots / "restic-current").exists()

    erb.cleanup(
        snapshot_dir=snapshots,
        mountpoint=mountpoint,
        exclusion_file=excludes,
        run=_transaction_run(calls),
    )

    assert not (snapshots / "restic-current").exists()
    assert not excludes.exists()

    # Idempotent: a signal that bypassed ExecStopPost leaves the boot
    # reconciler to run the very same path over an already-clean tree.
    erb.cleanup(
        snapshot_dir=snapshots,
        mountpoint=mountpoint,
        exclusion_file=excludes,
        run=_transaction_run(calls),
    )


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
    calls: list[list[str]] = []
    monkeypatch.setattr(Path, "is_mount", lambda _: False)

    erb.prepare(
        spec(),
        data=data,
        snapshot_dir=snapshots,
        mountpoint=mountpoint,
        exclusion_file=tmp_path / "run/excludes",
        run=_transaction_run(calls),
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


def test_init_cli_does_not_require_a_backup_source_spec(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls = 0

    def initialize() -> None:
        nonlocal calls
        calls += 1

    monkeypatch.setattr(erb, "initialize", initialize)

    assert erb.main(["--init"]) == 0
    assert calls == 1


def test_init_uses_the_explicit_restic_executable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []
    monkeypatch.setenv("EMUBOX_RESTIC", "/test/bin/restic")

    erb.initialize(lambda command: calls.append(list(command)))

    assert calls == [["/test/bin/restic", "cat", "config"]]


def test_status_reads_the_unit_names_it_is_given(monkeypatch: pytest.MonkeyPatch) -> None:
    """`services.restic` derives the unit names, so the module passes them in.

    Hardcoding them here would couple this program to a string the Nix module
    owns, and a rename would report on a unit that does not exist rather than
    failing.
    """

    queried: list[str] = []

    def status_layer(*, unit: str, **_: object) -> tuple[bool, str]:
        queried.append(unit)
        return True, f"{unit}: success"

    monkeypatch.setattr(erb, "status_layer", status_layer)

    assert erb.print_status("backup.service", "maintenance.service") == 0
    assert queried == ["btrbk-local.service", "backup.service", "maintenance.service"]


def test_status_cli_defaults_to_the_units_the_module_generates(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The defaults must stay in step with `services.restic`'s unit names."""

    queried: list[str] = []

    def status_layer(*, unit: str, **_: object) -> tuple[bool, str]:
        queried.append(unit)
        return True, f"{unit}: success"

    monkeypatch.setattr(erb, "status_layer", status_layer)

    assert erb.main(["--status"]) == 0
    assert queried[1:] == [
        "restic-backups-emubox.service",
        "restic-backups-emubox-maintenance.service",
    ]
