#!/usr/bin/env python3
"""Aggregate the health reports capabilities register with the box.

This program carries no knowledge of what any capability considers
healthy. It reads a list of registered reporters - a name and a complete
argv each - from the path given on its command line, runs every one of
them in the order they were registered, and prints a labelled section per
reporter. Each reporter's own runtime closure is that reporter's
registering module's responsibility: this program neither extends nor
rewrites the program search path it inherited, so whatever a reporter
shells out to has to be reachable through the reporter's own packaging.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import IO, NamedTuple, Sequence

# The whole alphabet a reporter's exit status can mean. Any status outside
# this map says nothing translatable, so it is read as the reporter having
# failed to run rather than as a fourth kind of finding.
STATUS_BY_EXIT_CODE = {0: "ok", 1: "warn", 2: "fail"}

# Both "fail" and "did not run" cost the aggregate exit status the same:
# a reporter that could not run is unhealthy for its own section and never
# suppresses another's.
EXIT_CODE_BY_STATUS = {"ok": 0, "warn": 1, "fail": 2, "did not run": 2}


class Reporter(NamedTuple):
    name: str
    command: list[str]


class Report(NamedTuple):
    name: str
    status: str
    output: str


def load_reporters(path: Path) -> list[Reporter]:
    entries = json.loads(path.read_text(encoding="utf-8"))
    return [Reporter(name=entry["name"], command=list(entry["command"])) for entry in entries]


def _runnable(command: Sequence[str]) -> bool:
    """Whether ``command[0]`` names an executable, before it is ever invoked.

    ``shutil.which`` resolves a bare name against the inherited ``PATH``
    exactly as exec would and accepts an absolute path outright; either way
    it consults only the search path already in the environment, never one
    this program builds or extends.
    """

    return bool(command) and shutil.which(command[0]) is not None


def run_reporter(reporter: Reporter) -> Report:
    command = reporter.command
    if not _runnable(command):
        culprit = command[0] if command else "<empty command>"
        return Report(reporter.name, "did not run", f"could not run {culprit}")
    try:
        result = subprocess.run(command, capture_output=True, text=True)
    except OSError as error:
        return Report(reporter.name, "did not run", f"could not run {command[0]}: {error}")
    status = STATUS_BY_EXIT_CODE.get(result.returncode)
    if status is None:
        return Report(reporter.name, "did not run", f"{command[0]} exited {result.returncode}")
    return Report(reporter.name, status, result.stdout.strip())


def render_report(report: Report) -> str:
    header = f"{report.name}: {report.status}"
    return f"{header}\n{report.output}" if report.output else header


def run_all(reporters: Sequence[Reporter], *, out: IO[str] | None = None) -> int:
    stream = out if out is not None else sys.stdout
    worst = "ok"
    for reporter in reporters:
        report = run_reporter(reporter)
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
    return run_all(load_reporters(args.reporters))


if __name__ == "__main__":
    raise SystemExit(main())
