import io
import json
import os
from pathlib import Path
from typing import Iterator

import pytest

import emubox_status as es


def script(tmp_path: Path, name: str, body: str, *, executable: bool = True) -> Path:
    path = tmp_path / name
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755 if executable else 0o644)
    return path


def reporters_file(tmp_path: Path, entries: object) -> Path:
    path = tmp_path / "status-reporters.json"
    path.write_text(json.dumps(entries), encoding="utf-8")
    return path


def run(reporters: list[es.Reporter], **kwargs: float) -> tuple[int, str]:
    out = io.StringIO()
    code = es.run_all(reporters, out=out, **kwargs)
    return code, out.getvalue()


def sections(output: str) -> dict[str, list[str]]:
    """Every section keyed by name: a header at the left margin, then the
    indented or blank lines beneath it until the next header."""

    parsed: dict[str, list[str]] = {}
    current: list[str] | None = None
    for line in output.splitlines():
        if line and not line[0].isspace():
            current = parsed.setdefault(line.split(":", 1)[0], [])
            current.append(line)
        elif current is not None:
            current.append(line)
    return parsed


def refuse_invocation(monkeypatch: pytest.MonkeyPatch) -> None:
    def fail(*_args: object, **_kwargs: object) -> None:
        pytest.fail("the reporter was invoked instead of being refused beforehand")

    monkeypatch.setattr(es.subprocess, "run", fail)


def test_every_report_ok_exits_successfully(tmp_path: Path) -> None:
    ok = script(tmp_path, "ok.sh", "#!/bin/sh\necho all good\nexit 0\n")
    code, output = run([es.Reporter("alpha", [str(ok)])])
    assert code == 0
    assert output.splitlines()[:2] == ["alpha: ok", "  all good"]


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


def test_missing_command_is_detected_before_invocation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    refuse_invocation(monkeypatch)
    missing = tmp_path / "does-not-exist"
    code, output = run([es.Reporter("ghost", [str(missing)])])
    assert code == 2
    assert "ghost: did not run" in output


def test_non_executable_command_is_detected_before_invocation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    refuse_invocation(monkeypatch)
    unexecutable = script(tmp_path, "not-executable.sh", "#!/bin/sh\nexit 0\n", executable=False)
    assert not os.access(unexecutable, os.X_OK)
    code, output = run([es.Reporter("locked", [str(unexecutable)])])
    assert code == 2
    assert "locked: did not run" in output


def test_out_of_range_exit_status_counts_as_did_not_run(tmp_path: Path) -> None:
    """An exit status outside 0, 1 and 2 says nothing translatable.

    Distinct from the missing-command case: this command exists, is
    executable and is actually invoked, and only its exit status is out of
    range. What it printed on either stream is kept, since an administrator
    reading this section has nothing else to go on.
    """

    wild = script(
        tmp_path,
        "wild.sh",
        "#!/bin/sh\necho partial report\necho something broke >&2\nexit 7\n",
    )
    code, output = run([es.Reporter("wild", [str(wild)])])
    assert code == 2
    body = sections(output)["wild"]
    assert body[0] == "wild: did not run"
    assert f"  {wild} exited 7" in body
    assert "  partial report" in body
    assert "  stderr:" in body
    assert "    something broke" in body


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
    """Worst first, so a status that merely kept the last report's code
    would read 1 here rather than 2."""

    ok = script(tmp_path, "ok.sh", "#!/bin/sh\nexit 0\n")
    warn = script(tmp_path, "warn.sh", "#!/bin/sh\nexit 1\n")
    fail = script(tmp_path, "fail.sh", "#!/bin/sh\nexit 2\n")
    code, _ = run(
        [
            es.Reporter("a", [str(fail)]),
            es.Reporter("b", [str(ok)]),
            es.Reporter("c", [str(warn)]),
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


def test_no_reporters_at_all_exits_successfully() -> None:
    code, output = run([])
    assert code == 0
    assert output == ""


def test_a_reporters_own_blank_lines_and_unindented_text_stay_inside_its_section(
    tmp_path: Path,
) -> None:
    """Each body is indented under a header at the left margin, so a
    reporter printing a blank line - or a line that looks like a header -
    can never be read as the start of another section."""

    chatty = script(
        tmp_path,
        "chatty.sh",
        "#!/bin/sh\necho first\necho\necho 'impostor: ok'\nexit 1\n",
    )
    ok = script(tmp_path, "ok.sh", "#!/bin/sh\necho fine\nexit 0\n")
    _, output = run([es.Reporter("chatty", [str(chatty)]), es.Reporter("after", [str(ok)])])
    parsed = sections(output)
    assert set(parsed) == {"chatty", "after"}, output
    assert parsed["chatty"][:4] == ["chatty: warn", "  first", "", "  impostor: ok"]
    assert parsed["after"][:2] == ["after: ok", "  fine"]


def test_stderr_is_shown_under_a_warn_section(tmp_path: Path) -> None:
    warn = script(tmp_path, "warn.sh", "#!/bin/sh\necho finding\necho detail >&2\nexit 1\n")
    _, output = run([es.Reporter("backups", [str(warn)])])
    assert sections(output)["backups"][:4] == [
        "backups: warn",
        "  finding",
        "  stderr:",
        "    detail",
    ]


def test_stderr_is_shown_under_a_fail_section(tmp_path: Path) -> None:
    fail = script(
        tmp_path, "fail.sh", "#!/bin/sh\necho 'Traceback (most recent call last):' >&2\nexit 2\n"
    )
    _, output = run([es.Reporter("saves", [str(fail)])])
    body = sections(output)["saves"]
    assert body[0] == "saves: fail"
    assert "    Traceback (most recent call last):" in body


def test_stderr_is_not_shown_under_an_ok_section(tmp_path: Path) -> None:
    ok = script(tmp_path, "ok.sh", "#!/bin/sh\necho fine\necho chatter >&2\nexit 0\n")
    _, output = run([es.Reporter("alpha", [str(ok)])])
    assert "chatter" not in output
    assert "stderr:" not in output


def test_a_hanging_reporter_times_out_and_does_not_suppress_the_others(tmp_path: Path) -> None:
    hang = script(
        tmp_path,
        "hang.sh",
        "#!/bin/sh\necho started\necho still going >&2\nexec sleep 30\n",
    )
    ok = script(tmp_path, "ok.sh", "#!/bin/sh\necho fine\nexit 0\n")
    code, output = run(
        [es.Reporter("stuck", [str(hang)]), es.Reporter("after", [str(ok)])], timeout=1
    )
    assert code == 2
    parsed = sections(output)
    assert parsed["stuck"][0] == "stuck: did not run"
    assert f"  {hang} timed out after 1 s" in parsed["stuck"]
    assert "  started" in parsed["stuck"]
    assert "    still going" in parsed["stuck"]
    assert parsed["after"][:2] == ["after: ok", "  fine"]


def test_the_default_timeout_is_sixty_seconds() -> None:
    assert es.DEFAULT_TIMEOUT_SECONDS == 60


@pytest.fixture
def stdin_that_never_ends() -> Iterator[None]:
    """Point this process's own standard input at a pipe nobody writes to,
    so a reporter that inherited it would block reading it."""

    read_end, write_end = os.pipe()
    saved = os.dup(0)
    os.dup2(read_end, 0)
    try:
        yield
    finally:
        os.dup2(saved, 0)
        for fd in (saved, read_end, write_end):
            os.close(fd)


@pytest.mark.usefixtures("stdin_that_never_ends")
def test_a_reporter_reading_stdin_reads_nothing_rather_than_blocking(tmp_path: Path) -> None:
    reader = script(
        tmp_path,
        "reader.sh",
        "#!/bin/sh\nif read -r line; then echo got input; exit 2; fi\necho stdin closed\nexit 0\n",
    )
    code, output = run([es.Reporter("reader", [str(reader)])], timeout=5)
    assert code == 0, output
    assert sections(output)["reader"][:2] == ["reader: ok", "  stdin closed"]


def test_undecodable_output_is_replaced_rather_than_ending_the_command(tmp_path: Path) -> None:
    garbled = script(tmp_path, "garbled.sh", "#!/bin/sh\nprintf 'bad \\377 byte\\n'\nexit 0\n")
    ok = script(tmp_path, "ok.sh", "#!/bin/sh\necho fine\nexit 0\n")
    code, output = run([es.Reporter("garbled", [str(garbled)]), es.Reporter("after", [str(ok)])])
    assert code == 0
    parsed = sections(output)
    assert parsed["garbled"][:2] == ["garbled: ok", "  bad � byte"]
    assert parsed["after"][:2] == ["after: ok", "  fine"]


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
    assert lines[1] == f"  {restricted_path}"


def test_a_reporter_shelling_out_to_a_program_the_path_lacks_reports_its_own_status(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The aggregator neither supplies the missing program nor rewrites PATH.

    The reporter here plays the part of ``emubox-restic-backup``: it exists,
    is executable, and shells out to a program of its own - one the
    inherited PATH does not carry - and chooses a status for that failure
    itself. The program does exist beside the aggregator's own source, the
    one directory this program could most plausibly add to the search path
    for its reporters, so the reporter reaching it would mean exactly that
    had happened. The aggregator's job is only to relay the status unchanged.
    """

    program_name = "emubox-test-program-beside-the-aggregator"
    beside_aggregator = Path(es.__file__).resolve().parent / program_name
    beside_aggregator.write_text("#!/bin/sh\necho reached\nexit 0\n", encoding="utf-8")
    beside_aggregator.chmod(0o755)
    try:
        monkeypatch.setenv("PATH", str(tmp_path))
        reporter_script = script(
            tmp_path,
            "shells-out.sh",
            "#!/bin/sh\n"
            f"if command -v {program_name} >/dev/null 2>&1; then\n"
            '  echo "unexpectedly found the program on PATH"\n'
            "  exit 2\n"
            "fi\n"
            f'echo "{program_name}: not on PATH"\n'
            "exit 1\n",
        )

        code, output = run([es.Reporter("backups", [str(reporter_script)])])
    finally:
        beside_aggregator.unlink()

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


def test_a_missing_reporter_list_is_one_line_and_exit_two(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    missing = tmp_path / "no-such-list"
    assert es.main([str(missing)]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    lines = captured.err.splitlines()
    assert len(lines) == 1, captured.err
    assert str(missing) in lines[0]


@pytest.mark.parametrize(
    "contents",
    [
        "not json at all",
        json.dumps({"name": "alpha", "command": ["/bin/true"]}),
        json.dumps([{"command": ["/bin/true"]}]),
        json.dumps([{"name": "alpha", "command": "/bin/true"}]),
        json.dumps([{"name": "alpha", "command": []}]),
        json.dumps([{"name": "alpha", "command": ["/bin/true", 3]}]),
        json.dumps([{"name": "", "command": ["/bin/true"]}]),
    ],
)
def test_a_malformed_reporter_list_is_one_line_and_exit_two(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], contents: str
) -> None:
    path = tmp_path / "status-reporters.json"
    path.write_text(contents, encoding="utf-8")
    assert es.main([str(path)]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    lines = captured.err.splitlines()
    assert len(lines) == 1, captured.err
    assert str(path) in lines[0]


def test_an_unexpected_failure_of_the_aggregator_itself_is_one_line_and_exit_two(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    path = reporters_file(tmp_path, [])

    def explode(*_args: object, **_kwargs: object) -> int:
        raise RuntimeError("the aggregator itself broke")

    monkeypatch.setattr(es, "run_all", explode)
    assert es.main([str(path)]) == 2
    lines = capsys.readouterr().err.splitlines()
    assert len(lines) == 1
    assert "the aggregator itself broke" in lines[0]
