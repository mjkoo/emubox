#!/usr/bin/env python3
"""Aggregate the health reports capabilities register with the box.

This program carries no knowledge of what any capability considers
healthy. It reads a list of registered reporters - a name and a complete
argv each - from the path given on its command line, runs every one of
them in the order they were registered, and prints a section per reporter:
a header at the left margin naming the reporter and its state, then
everything the reporter said indented beneath it, so nothing a reporter
prints - a blank line, or a line shaped like a header - can be read as the
start of another section. Each reporter's own runtime closure is that
reporter's registering module's responsibility: this program neither
extends nor rewrites the program search path it inherited, so whatever a
reporter shells out to has to be reachable through the reporter's own
packaging.

One broken reporter costs its own section, never the whole command: a
reporter that cannot be started, hangs past its time limit, exits outside
the status alphabet or prints undecodable bytes is reported as such in its
own section, and every later section still prints. A failure of this
program itself - its reporter list missing or malformed included - prints
one line naming it and exits with the same status a report that did not
run counts as.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import IO, NamedTuple, Sequence, cast

# The whole alphabet a reporter's exit status can mean. Any status outside
# this map says nothing translatable, so it is read as the reporter having
# failed to run rather than as a fourth kind of finding.
STATUS_BY_EXIT_CODE = {0: "ok", 1: "warn", 2: "fail"}

# Both "fail" and "did not run" cost the aggregate exit status the same:
# a reporter that could not run is unhealthy for its own section and never
# suppresses another's.
EXIT_CODE_BY_STATUS = {"ok": 0, "warn": 1, "fail": 2, "did not run": 2}

# How long one reporter may run before it counts as not having run at all.
DEFAULT_TIMEOUT_SECONDS = 60

INDENT = "  "


class Reporter(NamedTuple):
    name: str
    command: list[str]


class Report(NamedTuple):
    name: str
    status: str
    output: str
    # What the reporter wrote to its error stream, kept for every state but
    # `ok`: a crashed reporter's traceback is what an administrator told to
    # look at this section needs to see.
    errors: str = ""


class ReporterListError(Exception):
    """The reporter list could not be read, or is not the shape it must be."""


def load_reporters(path: Path) -> list[Reporter]:
    try:
        entries = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ReporterListError(f"cannot read the reporter list {path}: {error}") from error
    if not isinstance(entries, list):
        raise ReporterListError(f"the reporter list {path} is not a list")
    reporters = []
    for index, entry in enumerate(entries):
        fields = cast("dict[str, object]", entry) if isinstance(entry, dict) else {}
        name = fields.get("name")
        command = fields.get("command")
        if not isinstance(name, str) or not name:
            raise ReporterListError(f"entry {index} of the reporter list {path} has no name")
        if (
            not isinstance(command, list)
            or not command
            or not all(isinstance(part, str) for part in command)
        ):
            raise ReporterListError(
                f"entry {index} ({name}) of the reporter list {path} has no argv of strings"
            )
        reporters.append(Reporter(name=name, command=[str(part) for part in command]))
    return reporters


def _runnable(command: Sequence[str]) -> bool:
    """Whether ``command[0]`` names an executable, before it is ever invoked.

    ``shutil.which`` resolves a bare name against the inherited ``PATH``
    exactly as exec would and accepts an absolute path outright; either way
    it consults only the search path already in the environment, never one
    this program builds or extends.
    """

    return bool(command) and shutil.which(command[0]) is not None


def _decoded(captured: str | bytes | None) -> str:
    """A timed-out run's partial output, which arrives undecoded."""

    if captured is None:
        return ""
    if isinstance(captured, bytes):
        return captured.decode("utf-8", errors="replace")
    return captured


def _joined(first: str, rest: str) -> str:
    return f"{first}\n{rest}" if rest.strip() else first


def run_reporter(reporter: Reporter, *, timeout: float = DEFAULT_TIMEOUT_SECONDS) -> Report:
    command = reporter.command
    if not _runnable(command):
        culprit = command[0] if command else "<empty command>"
        return Report(reporter.name, "did not run", f"could not run {culprit}")
    try:
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as expired:
        return Report(
            reporter.name,
            "did not run",
            _joined(f"{command[0]} timed out after {timeout:g} s", _decoded(expired.stdout)),
            _decoded(expired.stderr),
        )
    except OSError as error:
        return Report(reporter.name, "did not run", f"could not run {command[0]}: {error}")
    status = STATUS_BY_EXIT_CODE.get(result.returncode)
    if status is None:
        return Report(
            reporter.name,
            "did not run",
            _joined(f"{command[0]} exited {result.returncode}", result.stdout),
            result.stderr,
        )
    return Report(reporter.name, status, result.stdout, "" if status == "ok" else result.stderr)


def _indented(text: str, indent: str) -> list[str]:
    lines = text.rstrip().splitlines()
    while lines and not lines[0].strip():
        lines.pop(0)
    return [f"{indent}{line}" if line.strip() else "" for line in lines]


def render_report(report: Report) -> str:
    lines = [f"{report.name}: {report.status}", *_indented(report.output, INDENT)]
    if report.errors.strip():
        lines.append(f"{INDENT}stderr:")
        lines.extend(_indented(report.errors, INDENT * 2))
    return "\n".join(lines)


def run_all(
    reporters: Sequence[Reporter],
    *,
    out: IO[str] | None = None,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
) -> int:
    stream = out if out is not None else sys.stdout
    worst = "ok"
    for reporter in reporters:
        report = run_reporter(reporter, timeout=timeout)
        print(render_report(report), file=stream)
        print(file=stream)
        if EXIT_CODE_BY_STATUS[report.status] > EXIT_CODE_BY_STATUS[worst]:
            worst = report.status
    return EXIT_CODE_BY_STATUS[worst]


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Aggregate the health reports capabilities register with emubox-status."
    )
    parser.add_argument(
        "reporters",
        type=Path,
        help="Path to the rendered reporter list (name and command per entry).",
    )
    args = parser.parse_args(argv)
    try:
        return run_all(load_reporters(args.reporters))
    except Exception as error:  # noqa: BLE001 - this program's own failure, reported once
        message = (
            str(error)
            if isinstance(error, ReporterListError)
            else f"unexpected {type(error).__name__}: {error}"
        )
        print(f"emubox-status: {' '.join(message.split())}", file=sys.stderr)
        return EXIT_CODE_BY_STATUS["did not run"]


if __name__ == "__main__":
    raise SystemExit(main())
