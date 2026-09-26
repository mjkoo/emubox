#!/usr/bin/env python3
"""Exercise the rendered session with deterministic frontend process boundaries.

This needs no virtual machine, so it is the local pre-CI gate for the restart
counting the library VM test also checks, and it alone checks the prepare,
step and frontend ordering on every relaunch.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


def executable(path, text):
    path.write_text(f"#!{shutil.which('bash')}\nset -euo pipefail\n" + text)
    path.chmod(0o755)


def main():
    source = Path(sys.argv[1]).read_text()
    # Keep the rendered control flow; prepend mocks after the generated PATH.
    source, count = re.subn(
        r"(?m)^(export PATH=.*)$", r'\1\nexport PATH="$TEST_BIN:$PATH"', source
    )
    assert count == 1, "the session wrapper PATH boundary changed"
    for sequence in (
        ["crash"] * 3,
        ["request"] * 3 + ["crash"] * 3,
        ["crash", "crash", "request", "crash", "crash", "crash"],
        # A request older than the window when the frontend exits has lapsed,
        # so each of these exits counts as a crash.
        ["stale"] * 3,
        ["request", "crash", "stale", "crash"],
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            commands = root / "bin"
            commands.mkdir()
            runtime = root / "runtime"
            runtime.mkdir()
            (root / "sequence").write_text("\n".join(sequence) + "\n")
            (root / "session").write_text(source)
            executable(
                commands / "emubox-prepare", 'echo prepare >> "$TEST_ROOT/events"\n'
            )
            executable(commands / "systemd-cat", "cat >/dev/null\n")
            executable(commands / "sleep", "true\n")
            executable(
                commands / "cage",
                """
count=$(cat "$TEST_ROOT/count" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$TEST_ROOT/count"
echo frontend >> "$TEST_ROOT/events"
case "$(sed -n "${count}p" "$TEST_ROOT/sequence")" in
  request) touch "$XDG_RUNTIME_DIR/emubox-frontend-restart" ;;
  stale) touch -d "@$(( $(date +%s) - 120 ))" "$XDG_RUNTIME_DIR/emubox-frontend-restart" ;;
  crash) ;;
  *) echo 'unexpected extra frontend launch' >&2; exit 99 ;;
esac
exit 1
""",
            )
            env = os.environ | {
                "TEST_ROOT": str(root),
                "TEST_BIN": str(commands),
                "XDG_RUNTIME_DIR": str(runtime),
                "EMUBOX_CRASH_WINDOW": "60",
            }
            result = subprocess.run(
                ["bash", str(root / "session")],
                env=env,
                capture_output=True,
                text=True,
                timeout=20,
            )
            assert result.returncode == 0, result.stderr
            assert (root / "count").exists(), result.stderr
            assert int((root / "count").read_text()) == len(sequence), result.stderr
            assert (root / "events").read_text().splitlines() == [
                item for _ in sequence for item in ("prepare", "step", "frontend")
            ]
            assert not (runtime / "emubox-frontend-restart").exists()
            assert "three short runs" in result.stderr
    systems = ET.parse(sys.argv[2]).getroot().findall("system")
    tools = next(
        system for system in systems if system.findtext("name") == "emubox-tools"
    )
    entry = Path(tools.findtext("path", "")) / "Update game art.sh"
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        commands = root / "bin"
        commands.mkdir()
        runtime = root / "runtime"
        runtime.mkdir()
        executable(commands / "foot", "exit 1\n")
        executable(commands / "pgrep", "echo 999999999\n")
        script = entry.read_text()
        assert sys.argv[3] in script
        script = script.replace(sys.argv[3], str(commands / "foot"))
        script, count = re.subn(
            r"(?m)^(export PATH=.*)$", r'\1\nexport PATH="$TEST_BIN:$PATH"', script
        )
        assert count == 1
        (root / "entry").write_text(script)
        result = subprocess.run(
            ["bash", str(root / "entry")],
            env=os.environ
            | {"TEST_BIN": str(commands), "XDG_RUNTIME_DIR": str(runtime)},
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode != 0
        assert "No such process" in result.stderr, result.stderr
        assert not (runtime / "emubox-frontend-restart").exists()
    print("A failed frontend termination clears its restart request")
    print("Session step ordering and requested-restart crash accounting passed")


if __name__ == "__main__":
    main()
