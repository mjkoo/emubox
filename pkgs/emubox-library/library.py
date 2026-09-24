"""Shared, unprivileged state and process handling for the game library."""

from __future__ import annotations

import argparse
import configparser
import contextlib
import fcntl
import json
import os
import pwd
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

PER_FOLDER_SECONDS = 600
ALL_FOLDERS_SECONDS = 1800
REPORT_SECONDS = 45
CONFIG_PATH = Path("/etc/emubox/library.json")
VECTORS_PATH = Path(__file__).with_name("vectors.json")
IONICE = "@IONICE@"


@dataclass(frozen=True)
class Config:
    rom_root: Path
    cache_root: Path
    gamelist_root: Path
    media_root: Path
    scraper_config: Path
    bundled_systems: Path
    custom_systems: Path | None
    platform_map: Path
    skyscraper: str
    systemd_cat: str
    session_user: str = "player"

    @classmethod
    def read(cls, path: Path) -> Config:
        data = json.loads(path.read_text())
        return cls(
            rom_root=Path(data["rom_root"]),
            cache_root=Path(data["cache_root"]),
            gamelist_root=Path(data["gamelist_root"]),
            media_root=Path(data["media_root"]),
            scraper_config=Path(data["scraper_config"]),
            bundled_systems=Path(data["bundled_systems"]),
            custom_systems=Path(data["custom_systems"]) if data.get("custom_systems") else None,
            platform_map=Path(data["platform_map"]),
            skyscraper=data["skyscraper"],
            systemd_cat=data["systemd_cat"],
            session_user=data.get("session_user", "player"),
        )

    @property
    def lock_path(self) -> Path:
        return self.cache_root / "lock"

    @property
    def pending_path(self) -> Path:
        return self.cache_root / "pending"

    @property
    def revision_path(self) -> Path:
        return self.cache_root / "revisions.json"

    @property
    def record_path(self) -> Path:
        return self.cache_root / "last-run.json"

    @property
    def log_path(self) -> Path:
        return self.cache_root / "last-run.log"


def atomic_write(path: Path, content: bytes) -> None:
    """Replace a readable state file without exposing a partial write."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def atomic_json(path: Path, value: object) -> None:
    atomic_write(path, (json.dumps(value, sort_keys=True, indent=2) + "\n").encode())


def read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def read_pending(config: Config) -> list[str]:
    try:
        return list(dict.fromkeys(config.pending_path.read_text().splitlines()))
    except FileNotFoundError:
        return []


def write_pending(config: Config, folders: list[str]) -> None:
    atomic_write(
        config.pending_path, "".join(f"{item}\n" for item in dict.fromkeys(folders)).encode()
    )


def lock(config: Config) -> int | None:
    config.cache_root.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(config.lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(descriptor)
        return None
    return descriptor


def system_extensions(config: Config) -> dict[str, set[str]]:
    result: dict[str, set[str]] = {}
    for source in (config.bundled_systems, config.custom_systems):
        if source is None:
            continue
        for system in ET.parse(source).getroot().findall("system"):
            name = system.findtext("name")
            extension = system.findtext("extension")
            if name and extension:
                result[name] = {item.casefold() for item in extension.split()}
    return result


def rom_files(directory: Path, extensions: set[str] | None) -> list[Path]:
    return sorted(
        entry
        for entry in directory.iterdir()
        if stat.S_ISREG(entry.lstat().st_mode)
        and (extensions is None or entry.suffix.casefold() in extensions)
    )


def discover(config: Config, extensions: dict[str, set[str]]) -> dict[str, list[Path]]:
    if not config.rom_root.exists():
        return {}
    result = {}
    for directory in sorted(config.rom_root.iterdir()):
        if directory.is_dir():
            files = rom_files(directory, extensions.get(directory.name))
            if files:
                result[directory.name] = files
    return result


def vector(kind: str, **values: str) -> list[str]:
    vectors = json.loads(VECTORS_PATH.read_text())
    return [part.format_map(values) for part in vectors[kind]]


def fetch_vector(config: Config, folder: str, platform: str) -> list[str]:
    return vector(
        "fetch",
        platform=platform,
        config=str(config.scraper_config),
        rom_dir=str(config.rom_root / folder),
        cache_dir=str(config.cache_root / folder),
    )


def generate_vector(config: Config, folder: str, platform: str, work: Path) -> list[str]:
    return vector(
        "generate",
        platform=platform,
        config=str(config.scraper_config),
        rom_dir=str(config.rom_root / folder),
        cache_dir=str(config.cache_root / folder),
        work_dir=str(work),
        media_dir=str(config.media_root / folder),
    )


def terminate_group(child: subprocess.Popen[bytes]) -> None:
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(child.pid, signal.SIGTERM)
    if child.poll() is None:
        with contextlib.suppress(subprocess.TimeoutExpired):
            child.wait(timeout=2)
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(child.pid, signal.SIGKILL)
    child.wait()


def _interrupt(_number: int, _frame: object) -> None:
    raise InterruptedError("library command interrupted")


def run_skyscraper(
    config: Config, argv: list[str], lock_fd: int, deadline: float | None = None
) -> tuple[int, bytes]:
    """Run and stream one scraper child; the inherited descriptor pins its claim."""
    account = pwd.getpwnam(config.session_user)
    environment = dict(os.environ, HOME=account.pw_dir)
    signals = {signal.SIGTERM, signal.SIGINT, signal.SIGHUP}
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
    previous_term = signal.signal(signal.SIGTERM, _interrupt)
    previous_int = signal.signal(signal.SIGINT, _interrupt)
    previous_hup = signal.signal(signal.SIGHUP, _interrupt)
    child: subprocess.Popen[bytes] | None = None
    output = bytearray()
    try:
        child = subprocess.Popen(
            [config.skyscraper, *argv],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            pass_fds=(lock_fd,),
            preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, old_mask),
        )
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        assert child.stdout is not None
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            while selector.get_map():
                remaining = None if deadline is None else deadline - time.monotonic()
                if remaining is not None and remaining <= 0:
                    terminate_group(child)
                    return 124, bytes(output)
                if not selector.select(remaining):
                    terminate_group(child)
                    return 124, bytes(output)
                chunk = os.read(child.stdout.fileno(), 65536)
                if not chunk:
                    selector.unregister(child.stdout)
                    break
                output.extend(chunk)
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
        if deadline is None:
            return child.wait(), bytes(output)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return 124, bytes(output)
        try:
            return child.wait(timeout=remaining), bytes(output)
        except subprocess.TimeoutExpired:
            return 124, bytes(output)
    finally:
        signal.pthread_sigmask(signal.SIG_BLOCK, signals)
        if child is not None:
            terminate_group(child)
        signal.signal(signal.SIGTERM, previous_term)
        signal.signal(signal.SIGINT, previous_int)
        signal.signal(signal.SIGHUP, previous_hup)
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)


def credentials_error(config: Config) -> str | None:
    try:
        content = config.scraper_config.read_text()
    except FileNotFoundError:
        return "missing ScreenScraper credentials"
    except OSError:
        return "unreadable ScreenScraper credentials"
    # Skyscraper's QSettings format stores userCreds inside literal quotes.
    # Interpolation is not part of that format and would reject valid '%' passwords.
    parser = configparser.ConfigParser(interpolation=None)
    try:
        parser.read_string(content)
        value = parser["screenscraper"]["usercreds"].strip()
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        elif value.startswith('"') or value.endswith('"'):
            return "missing ScreenScraper credentials"
        username, password = value.split(":", 1)
    except (KeyError, ValueError, configparser.Error):
        return "missing ScreenScraper credentials"
    if not username.strip() or not password.strip():
        return "missing ScreenScraper credentials"
    if any(
        marker in part.lower()
        for part in (username, password)
        for marker in (
            "placeholder",
            "changeme",
            "change-me",
            "replace-me",
            "replace-before-install",
            "your_",
        )
    ):
        return "placeholder ScreenScraper credentials"
    return None


def timestamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def write_record(config: Config, result: str, outcomes: dict[str, str], cause: str = "") -> None:
    record: dict[str, object] = {"result": result, "time": timestamp(), "folders": outcomes}
    if cause:
        record["cause"] = cause
    atomic_json(config.record_path, record)


def journal(config: Config, message: str) -> None:
    subprocess.run(
        [config.systemd_cat, "-t", "emubox-library"],
        input=(message + "\n").encode(),
        check=False,
        timeout=2,
    )


def correct_account(config: Config) -> bool:
    if os.geteuid() == pwd.getpwnam(config.session_user).pw_uid:
        return True
    print(f"Run sudo -u {config.session_user} emubox-scrape instead", file=sys.stderr)
    return False


def scrape(config: Config, invoke: Callable[..., tuple[int, bytes]] = run_skyscraper) -> int:
    if not correct_account(config):
        return 1
    claim = lock(config)
    if claim is None:
        print("A scrape or generation run is in progress", file=sys.stderr)
        return 1
    try:
        error = credentials_error(config)
        if error:
            print(error, file=sys.stderr)
            write_record(config, "refused", {}, error)
            atomic_write(config.log_path, (error + "\n").encode())
            return 1
        with contextlib.suppress(OSError):
            os.nice(19)
        if IONICE and not IONICE.startswith("@"):
            subprocess.run([IONICE, "-c", "3", "-p", str(os.getpid())], check=True)
        extensions = system_extensions(config)
        platforms = read_json(config.platform_map, {})
        outcomes: dict[str, str] = {}
        transcript = bytearray()
        for folder in discover(config, extensions):
            if folder not in extensions:
                continue
            platform = platforms.get(folder)
            if platform is None:
                outcomes[folder] = "unmapped"
                continue
            heading = f"Fetching {folder}\n".encode()
            sys.stdout.buffer.write(heading)
            sys.stdout.buffer.flush()
            transcript.extend(heading)
            status, output = invoke(config, fetch_vector(config, folder, platform), claim)
            transcript.extend(output)
            if status == 0:
                revisions = read_json(config.revision_path, {})
                revisions[folder] = uuid.uuid4().hex
                atomic_json(config.revision_path, revisions)
                pending = read_pending(config)
                if folder not in pending:
                    write_pending(config, [*pending, folder])
                outcomes[folder] = "fetched"
            else:
                outcomes[folder] = "fetch-failed"
        fetched = sum(value == "fetched" for value in outcomes.values())
        failed = sum(value == "fetch-failed" for value in outcomes.values())
        result = "partial" if fetched and failed else "failed" if failed else "complete"
        atomic_write(config.log_path, bytes(transcript))
        write_record(config, result, outcomes)
        return 0 if result == "complete" else 1
    finally:
        os.close(claim)


def _record_generation(config: Config, folder: str, outcome: str) -> None:
    record = read_json(
        config.record_path, {"result": "complete", "time": timestamp(), "folders": {}}
    )
    record.setdefault("folders", {})[folder] = outcome
    atomic_json(config.record_path, record)
    if outcome == "generation-failed":
        journal(config, f"Generation failed for {folder}")


def _discard_work(parent: Path) -> None:
    for entry in parent.glob(".emubox-library-work-*"):
        if entry.is_dir() and not entry.is_symlink():
            shutil.rmtree(entry)


def _publish_gamelist(work: Path, live: Path) -> None:
    source = work / "gamelist.xml"
    with source.open("rb") as stream:
        os.fsync(stream.fileno())
    os.replace(source, live)
    directory = os.open(live.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def generate(config: Config, invoke: Callable[..., tuple[int, bytes]] = run_skyscraper) -> int:
    if not correct_account(config):
        return 1
    claim = lock(config)
    if claim is None:
        journal(config, "A fetch was running; generation deferred")
        return 75
    try:
        pending = read_pending(config)
        platforms = read_json(config.platform_map, {})
        end = time.monotonic() + ALL_FOLDERS_SECONDS
        for folder in pending:
            if folder not in read_pending(config):
                continue
            if time.monotonic() >= end or folder not in platforms:
                outcome = "generation-failed"
            else:
                parent = config.gamelist_root / folder
                live = parent / "gamelist.xml"
                work: Path | None = None
                try:
                    parent.mkdir(parents=True, exist_ok=True)
                    _discard_work(parent)
                    work = Path(tempfile.mkdtemp(prefix=".emubox-library-work-", dir=parent))
                    if live.exists():
                        shutil.copy2(live, work / "gamelist.xml")
                    limit = min(end, time.monotonic() + PER_FOLDER_SECONDS)
                    status, _ = invoke(
                        config,
                        generate_vector(config, folder, platforms[folder], work),
                        claim,
                        limit,
                    )
                    if (
                        status == 0
                        and time.monotonic() < limit
                        and (work / "gamelist.xml").is_file()
                    ):
                        _publish_gamelist(work, live)
                        outcome = "generated"
                    else:
                        outcome = "generation-failed"
                except OSError:
                    outcome = "generation-failed"
                finally:
                    if work is not None:
                        shutil.rmtree(work, ignore_errors=True)
            _record_generation(config, folder, outcome)
            write_pending(config, [item for item in read_pending(config) if item != folder])
        return 0
    except (OSError, ValueError) as error:
        journal(config, f"Generation could not read or write state: {error}")
        return 0
    finally:
        os.close(claim)


def capture(config: Config) -> tuple[int, dict[str, str]]:
    if not correct_account(config):
        return 1, {}
    claim = lock(config)
    if claim is None:
        journal(config, "A fetch was running; generation deferred")
        return 75, {}
    try:
        revisions = read_json(config.revision_path, {})
        return 0, {
            folder: revisions[folder] for folder in read_pending(config) if folder in revisions
        }
    finally:
        os.close(claim)


def cleanup(config: Config, batch: dict[str, str]) -> int:
    if not correct_account(config):
        return 1
    claim = lock(config)
    if claim is None:
        journal(config, "Generation failure cleanup deferred; a fetch was running")
        return 1
    try:
        revisions = read_json(config.revision_path, {})
        for folder, revision in batch.items():
            if folder not in read_pending(config) or revisions.get(folder) != revision:
                continue
            _record_generation(config, folder, "generation-failed")
            write_pending(config, [item for item in read_pending(config) if item != folder])
        journal(config, "Generation could not finish with a progress window; frontend starting")
        return 0
    except OSError:
        journal(config, "Generation failure cleanup deferred; records could not be written")
        return 1
    finally:
        os.close(claim)


def _gamelist_counts(config: Config, folder: str, roms: list[Path]) -> tuple[int, int]:
    path = config.gamelist_root / folder / "gamelist.xml"
    try:
        games = ET.parse(path).getroot().findall("game")
    except FileNotFoundError:
        games = []
    described = {
        Path(game.findtext("path") or "").name
        for game in games
        if (game.findtext("desc") or "").strip()
    }
    return len(games), sum(rom.name not in described for rom in roms)


class _PipeSender:
    def __init__(self, descriptor: int) -> None:
        self.descriptor = descriptor

    def put(self, message: tuple[object, ...]) -> None:
        data = (json.dumps(message) + "\n").encode()
        while data:
            data = data[os.write(self.descriptor, data) :]


def _scan(config_source: Config | Path, sender: _PipeSender) -> None:
    try:
        config = Config.read(config_source) if isinstance(config_source, Path) else config_source
        record = read_json(config.record_path, None)
        sender.put(("record", record))
        pending = read_pending(config)
        sender.put(("pending", pending))
        extensions = system_extensions(config)
        platforms = read_json(config.platform_map, {})
        folders = discover(config, extensions)
        sender.put(("folders", list(folders)))
        for name, roms in folders.items():
            count, unscraped = _gamelist_counts(config, name, roms)
            note = (
                "unknown system"
                if name not in extensions
                else "unmapped"
                if name not in platforms
                else ""
            )
            sender.put(("count", name, len(roms), count, unscraped, note))
        sender.put(("done",))
    except (OSError, ValueError, ET.ParseError) as error:
        sender.put(("error", str(error)))


def report(config: Config | Path, deadline_seconds: float = REPORT_SECONDS) -> tuple[int, str]:
    read_fd, write_fd = os.pipe()
    worker_pid = os.fork()
    if worker_pid == 0:
        os.close(read_fd)
        try:
            _scan(config, _PipeSender(write_fd))
        finally:
            os.close(write_fd)
        os._exit(0)
    os.close(write_fd)
    deadline = time.monotonic() + deadline_seconds
    record: dict[str, Any] | None = None
    record_loaded = False
    pending: list[str] | None = None
    folders: list[str] | None = None
    counts: dict[str, tuple[int, int, int, str]] = {}
    complete = False
    error = ""
    buffer = bytearray()
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(read_fd, selectors.EVENT_READ)
            while time.monotonic() < deadline and not complete and not error:
                remaining = deadline - time.monotonic()
                if not selector.select(remaining):
                    break
                chunk = os.read(read_fd, 65536)
                if not chunk:
                    break
                buffer.extend(chunk)
                while b"\n" in buffer:
                    line, _, rest = buffer.partition(b"\n")
                    buffer = bytearray(rest)
                    message = json.loads(line)
                    kind = message[0]
                    if kind == "record":
                        record = message[1]
                        record_loaded = True
                    elif kind == "pending":
                        pending = message[1]
                    elif kind == "folders":
                        folders = message[1]
                    elif kind == "count":
                        counts[message[1]] = tuple(message[2:])
                    elif kind == "done":
                        complete = True
                    elif kind == "error":
                        error = message[1]
    finally:
        with contextlib.suppress(ProcessLookupError):
            os.kill(worker_pid, signal.SIGKILL)
        with contextlib.suppress(ChildProcessError):
            os.waitpid(worker_pid, os.WNOHANG)
        os.close(read_fd)
    lines = []
    if folders is None:
        lines.append("Folder counts unavailable (discovery incomplete)")
    else:
        for folder in folders:
            if folder not in counts:
                lines.append(f"{folder}: counts unavailable")
            else:
                roms, entries, unscraped, note = counts[folder]
                suffix = f" ({note})" if note else ""
                lines.append(
                    f"{folder}: {roms} ROMs, {entries} gamelist entries, "
                    f"{unscraped} unscraped{suffix}"
                )
    if record is None:
        lines.append("No scrape has run" if record_loaded else "Run record unavailable")
    else:
        lines.append(f"Last run: {record['result']} at {record['time']}")
        failures = [
            name
            for name, result in record.get("folders", {}).items()
            if result in ("fetch-failed", "generation-failed")
        ]
        if failures:
            lines.append("Failed folders: " + ", ".join(sorted(failures)))
    lines.append(
        "Generation pending: " + (", ".join(pending) if pending else "none")
        if pending is not None
        else "Pending state unavailable"
    )
    if not complete:
        lines.append(
            "Library scan incomplete; counts unavailable" + (f": {error}" if error else "")
        )
    return (0 if complete else 1), "\n".join(lines) + "\n"


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=CONFIG_PATH)
    return parser


def scrape_main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    return scrape(Config.read(args.config))


def generate_main(argv: list[str] | None = None) -> int:
    parser = _parser()
    parser.add_argument("action", nargs="?", choices=("capture", "cleanup"))
    parser.add_argument("--batch", default="{}")
    args = parser.parse_args(argv)
    config = Config.read(args.config)
    if args.action == "capture":
        status, batch = capture(config)
        if status == 0:
            print(json.dumps(batch, sort_keys=True))
        return status
    if args.action == "cleanup":
        return cleanup(config, json.loads(args.batch))
    return generate(config)


def report_main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    status, output = report(args.config)
    print(output, end="")
    return status
