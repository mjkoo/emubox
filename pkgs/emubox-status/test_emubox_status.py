import io
import json
import os
import stat
from pathlib import Path

import pytest

import emubox_status as es


def script(tmp_path: Path, name: str, body: str, *, executable: bool = True) -> Path:
    path = tmp_path / name
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755 if executable else 0o644)
    return path


def reporters_file(tmp_path: Path, entries: list[dict[str, object]]) -> Path:
    path = tmp_path / "status-reporters.json"
    path.write_text(json.dumps(entries), encoding="utf-8")
    return path


def run(reporters: list[es.Reporter]) -> tuple[int, str]:
    out = io.StringIO()
    code = es.run_all(reporters, out=out)
    return code, out.getvalue()


def test_every_report_ok_exits_successfully(tmp_path: Path) -> None:
    ok = script(tmp_path, "ok.sh", "#!/bin/sh\necho all good\nexit 0\n")
    code, output = run([es.Reporter("alpha", [str(ok)])])
    assert code == 0
    assert "alpha: ok" in output
    assert "all good" in output


def test_warn_report_exits_one(tmp_path: Path) -> None:
    warn = script(tmp_path, "warn.sh", "#!/bin/sh\necho needs attention\nexit 1\n")
    code, output = run([es.Reporter("backups", [str(warn)])])
    assert code == 1
    assert "backups: warn" in output
    assert "needs attention" in output


def test_fail_report_exits_two(tmp_path: Path) -> None:
    fail = script(tmp_path, "fail.sh", "#!/bin/sh\necho broken\nexit 2\n")
    code, output = run([es.Reporter("saves", [str(fail)])])
    assert code == 2
    assert "saves: fail" in output


def test_missing_command_is_detected_before_invocation(tmp_path: Path) -> None:
    missing = tmp_path / "does-not-exist"
    code, output = run([es.Reporter("ghost", [str(missing)])])
    assert code == 2
    assert "ghost: did not run" in output


def test_non_executable_command_is_detected_before_invocation(tmp_path: Path) -> None:
    unexecutable = script(tmp_path, "not-executable.sh", "#!/bin/sh\nexit 0\n", executable=False)
    assert not os.access(unexecutable, os.X_OK)
    code, output = run([es.Reporter("locked", [str(unexecutable)])])
    assert code == 2
    assert "locked: did not run" in output


def test_out_of_range_exit_status_counts_as_did_not_run(tmp_path: Path) -> None:
    """An exit status outside 0, 1 and 2 says nothing translatable.

    Distinct from the missing-command case: this command exists, is
    executable and is actually invoked, and only its exit status is out of
    range.
    """

    wild = script(tmp_path, "wild.sh", "#!/bin/sh\nexit 7\n")
    code, output = run([es.Reporter("wild", [str(wild)])])
    assert code == 2
    assert "wild: did not run" in output


def test_a_reporter_that_cannot_run_does_not_suppress_the_others(tmp_path: Path) -> None:
    missing = tmp_path / "does-not-exist"
    ok = script(tmp_path, "ok.sh", "#!/bin/sh\necho fine\nexit 0\n")
    warn = script(tmp_path, "warn.sh", "#!/bin/sh\necho attention\nexit 1\n")
    code, output = run(
        [
            es.Reporter("broken", [str(missing)]),
            es.Reporter("healthy", [str(ok)]),
            es.Reporter("warning", [str(warn)]),
        ]
    )
    assert code == 2
    assert "broken: did not run" in output
    assert "healthy: ok" in output
    assert "fine" in output
    assert "warning: warn" in output
    assert "attention" in output


def test_the_aggregate_exit_status_is_the_worst_reported(tmp_path: Path) -> None:
    ok = script(tmp_path, "ok.sh", "#!/bin/sh\nexit 0\n")
    warn = script(tmp_path, "warn.sh", "#!/bin/sh\nexit 1\n")
    fail = script(tmp_path, "fail.sh", "#!/bin/sh\nexit 2\n")
    code, _ = run(
        [
            es.Reporter("a", [str(ok)]),
            es.Reporter("b", [str(warn)]),
            es.Reporter("c", [str(fail)]),
        ]
    )
    assert code == 2


def test_sections_appear_in_declared_order(tmp_path: Path) -> None:
    ok = script(tmp_path, "ok.sh", "#!/bin/sh\nexit 0\n")
    _, output = run(
        [
            es.Reporter("zzz-last", [str(ok)]),
            es.Reporter("aaa-first", [str(ok)]),
        ]
    )
    assert output.index("zzz-last:") < output.index("aaa-first:")


def test_each_section_is_labelled_with_its_capability_name(tmp_path: Path) -> None:
    ok = script(tmp_path, "ok.sh", "#!/bin/sh\nexit 0\n")
    _, output = run([es.Reporter("controllers", [str(ok)])])
    assert "controllers: ok" in output


def test_no_reporters_at_all_exits_successfully() -> None:
    code, output = run([])
    assert code == 0
    assert output == ""


def test_program_search_path_is_neither_extended_nor_rewritten(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The reporter runs with exactly the inherited PATH, unmodified."""

    printer = script(tmp_path, "print-path.sh", '#!/bin/sh\nprintf %s "$PATH"\nexit 0\n')
    restricted_path = str(tmp_path)
    monkeypatch.setenv("PATH", restricted_path)

    code, output = run([es.Reporter("path-probe", [str(printer)])])

    assert code == 0
    lines = output.splitlines()
    assert lines[0] == "path-probe: ok"
    # The exact restricted value, byte for byte: nothing this program's own
    # location could plausibly add - its own store directory, a bin/
    # sibling - was prepended, appended or otherwise rewritten in.
    assert lines[1] == restricted_path


def test_a_reporter_shelling_out_to_a_program_the_path_lacks_reports_its_own_status(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The aggregator neither supplies the missing program nor rewrites PATH.

    The reporter here plays the part of ``emubox-restic-backup``: it exists,
    is executable, and shells out to a program of its own - one the
    inherited PATH does not carry - and chooses a status for that failure
    itself. The aggregator's job is only to relay it unchanged.
    """

    monkeypatch.setenv("PATH", str(tmp_path))
    reporter_script = script(
        tmp_path,
        "shells-out.sh",
        "#!/bin/sh\n"
        "if command -v emubox-test-missing-program >/dev/null 2>&1; then\n"
        '  echo "unexpectedly found the missing program on PATH"\n'
        "  exit 2\n"
        "fi\n"
        'echo "emubox-test-missing-program: not on PATH"\n'
        "exit 1\n",
    )

    code, output = run([es.Reporter("backups", [str(reporter_script)])])

    assert code == 1
    assert "backups: warn" in output
    assert "not on PATH" in output
    assert "unexpectedly found" not in output


def test_main_reads_the_reporter_list_from_the_path_given_on_the_command_line(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    ok = script(tmp_path, "ok.sh", "#!/bin/sh\necho present\nexit 0\n")
    path = reporters_file(tmp_path, [{"name": "controllers", "command": [str(ok)]}])

    assert es.main([str(path)]) == 0
    captured = capsys.readouterr()
    assert "controllers: ok" in captured.out
    assert "present" in captured.out


def test_load_reporters_preserves_declared_order(tmp_path: Path) -> None:
    path = reporters_file(
        tmp_path,
        [
            {"name": "one", "command": ["/bin/true"]},
            {"name": "two", "command": ["/bin/true", "--flag"]},
        ],
    )
    assert es.load_reporters(path) == [
        es.Reporter("one", ["/bin/true"]),
        es.Reporter("two", ["/bin/true", "--flag"]),
    ]


def test_non_executable_file_permission_bits_confirm_the_fixture(tmp_path: Path) -> None:
    """Sanity-check the fixture helper itself, not the aggregator's logic."""

    unexecutable = script(tmp_path, "check.sh", "#!/bin/sh\nexit 0\n", executable=False)
    mode = unexecutable.stat().st_mode
    assert not (mode & stat.S_IXUSR)
