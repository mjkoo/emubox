"""Shared, unprivileged state and process handling for the game library."""

from __future__ import annotations

import argparse
import configparser
import contextlib
import copy
import fcntl
import functools
import json
import os
import pwd
import re
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
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

PER_FOLDER_SECONDS = 600
ALL_FOLDERS_SECONDS = 1800
REPORT_SECONDS = 45
# The work copy of the live gamelist carries this time, so any write replaces it.
SENTINEL_MTIME_NS = 0
CONFIG_PATH = Path("/etc/emubox/library.json")
VECTORS_PATH = Path(__file__).with_name("vectors.json")
IONICE = "@IONICE@"
PLACEHOLDER_MARKER = "REPLACE-BEFORE-INSTALL"
FAMILY_FIELDS = (
    "favorite",
    "hidden",
    "kidgame",
    "lastplayed",
    "playcount",
    "sortname",
    "altemulator",
    "completed",
    "broken",
    "controller",
    "collectionsortname",
    "hidemetadata",
    "nogamecount",
    "nomultiscrape",
)


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
        """Raises ValueError naming the file for any missing, malformed or incomplete config."""
        try:
            return cls._parse(json.loads(path.read_text()))
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            raise ValueError(
                f"Cannot use the library configuration {path}: {type(error).__name__}: {error}"
            ) from error

    @classmethod
    def _parse(cls, data: dict[str, Any]) -> Config:
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


def read_mapping(path: Path) -> dict[str, Any]:
    """A state file the library itself writes; unusable contents read as empty."""
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def read_pending(config: Config) -> list[str]:
    try:
        return list(dict.fromkeys(config.pending_path.read_text().splitlines()))
    except FileNotFoundError:
        return []


def write_pending(config: Config, folders: list[str]) -> None:
    atomic_write(
        config.pending_path, "".join(f"{item}\n" for item in dict.fromkeys(folders)).encode()
    )


def _sweep_temporaries(config: Config) -> None:
    """Remove state-file temporaries a killed writer left behind; only a claim holder writes."""
    names = "|".join(
        re.escape(path.name)
        for path in (config.pending_path, config.revision_path, config.record_path, config.log_path)
    )
    # The shape tempfile.mkstemp gives atomic_write's prefix: eight name characters.
    pattern = re.compile(rf"\.(?:{names})\.[a-z0-9_]{{8}}")
    with contextlib.suppress(OSError):
        for entry in config.cache_root.iterdir():
            if pattern.fullmatch(entry.name):
                with contextlib.suppress(OSError):
                    entry.unlink()


def lock(config: Config) -> int | None:
    config.cache_root.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(config.lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(descriptor)
        return None
    _sweep_temporaries(config)
    return descriptor


def system_extensions(config: Config) -> dict[str, set[str]]:
    result: dict[str, set[str]] = {}
    for source in (config.bundled_systems, config.custom_systems):
        if source is None:
            continue
        try:
            systems = ET.parse(source).getroot().findall("system")
        except ET.ParseError as error:
            raise ValueError(f"Cannot parse the systems document {source}: {error}") from error
        for system in systems:
            name = system.findtext("name")
            extension = system.findtext("extension")
            if name and extension:
                result[name] = {item.casefold() for item in extension.split()}
    return result


def _regular_file(entry: Path) -> bool:
    """A regular file, or a symbolic link to one, as the frontend follows links."""
    info = entry.lstat()
    if stat.S_ISLNK(info.st_mode):
        try:
            info = entry.stat()
        except OSError:
            # A broken or looping link names no ROM.
            return False
    return stat.S_ISREG(info.st_mode)


def rom_files(directory: Path, extensions: set[str] | None) -> list[Path]:
    return sorted(
        entry
        for entry in directory.iterdir()
        if (extensions is None or entry.suffix.casefold() in extensions) and _regular_file(entry)
    )


def discover(config: Config, extensions: dict[str, set[str]]) -> dict[str, list[Path] | None]:
    """Folders holding ROM files; a directory that cannot be listed maps to None."""
    if not config.rom_root.exists():
        return {}
    result: dict[str, list[Path] | None] = {}
    for directory in sorted(config.rom_root.iterdir()):
        if directory.is_dir():
            try:
                files = rom_files(directory, extensions.get(directory.name))
            except OSError:
                result[directory.name] = None
                continue
            if files:
                result[directory.name] = files
    return result


@functools.cache
def _vectors() -> dict[str, list[str]]:
    return json.loads(VECTORS_PATH.read_text())


def vector(kind: str, **values: str) -> list[str]:
    return [part.format_map(values) for part in _vectors()[kind]]


def fetch_vector(config: Config, folder: str, platform: str) -> list[str]:
    return vector(
        "fetch",
        platform=platform,
        config=str(config.scraper_config),
        rom_dir=str(config.rom_root / folder),
        cache_dir=str(config.cache_root / folder),
        extensions=" ".join(sorted(system_extensions(config).get(folder, set()))),
    )


def generate_vector(
    config: Config, folder: str, platform: str, work: Path, extensions: set[str]
) -> list[str]:
    return vector(
        "generate",
        platform=platform,
        config=str(config.scraper_config),
        rom_dir=str(config.rom_root / folder),
        cache_dir=str(config.cache_root / folder),
        work_dir=str(work),
        media_dir=str(config.media_root / folder),
        extensions=" ".join(sorted(extensions)),
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


class Interrupted(Exception):
    """A termination request; deliberately not an OSError, so no file-error handler absorbs it."""

    def __init__(self, number: int) -> None:
        super().__init__(f"library command interrupted by signal {number}")
        self.number = number


TERMINATIONS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
_interrupt_armed = True


def _arm_interrupt() -> None:
    global _interrupt_armed
    _interrupt_armed = True


def _disarm_interrupt() -> None:
    """Ignore any later termination request: the run's outcome is settled."""
    global _interrupt_armed
    _interrupt_armed = False


def _interrupt(number: int, _frame: object) -> None:
    # A later signal must not unwind the cleanup the first one started.
    global _interrupt_armed
    if _interrupt_armed:
        _interrupt_armed = False
        raise Interrupted(number)


@contextlib.contextmanager
def _terminations() -> Iterator[None]:
    """Turn a termination signal anywhere in the enclosed section into Interrupted."""
    previous: dict[int, Any] = {}
    try:
        _arm_interrupt()
        for number in TERMINATIONS:
            previous[number] = signal.signal(number, _interrupt)
        yield
    finally:
        mask = signal.pthread_sigmask(signal.SIG_BLOCK, TERMINATIONS)
        try:
            # Once the outcome is recorded, a request still pending is ignored rather
            # than left to end the process after the handlers are restored.
            while not _interrupt_armed and signal.sigpending() & set(TERMINATIONS):
                signal.sigwait(TERMINATIONS)
            for number, handler in previous.items():
                signal.signal(number, handler)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)


def run_skyscraper(
    config: Config, argv: list[str], lock_fd: int, deadline: float | None = None
) -> tuple[int, bytes]:
    """Run and stream one scraper child; the inherited descriptor pins its claim."""
    account = pwd.getpwnam(config.session_user)
    environment = dict(os.environ, HOME=account.pw_dir)
    signals = set(TERMINATIONS)
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
    _arm_interrupt()
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
                    return 124, bytes(output)
                if not selector.select(remaining):
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
        # Nested so a signal raised before the mask takes hold still ends the group.
        try:
            signal.pthread_sigmask(signal.SIG_BLOCK, signals)
        finally:
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
    # Skyscraper ignores credentials that do not split into exactly two parts.
    if not username.strip() or not password.strip() or ":" in password:
        return "missing ScreenScraper credentials"
    # The committed secrets file's marker, as the install guard checks it.
    if any(PLACEHOLDER_MARKER in part.upper() for part in (username, password)):
        return "placeholder ScreenScraper credentials"
    return None


def timestamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def write_record(config: Config, result: str, outcomes: dict[str, str], cause: str = "") -> None:
    record: dict[str, object] = {"result": result, "time": timestamp(), "folders": outcomes}
    if cause:
        record["cause"] = cause
    atomic_json(config.record_path, record)


def show(line: str) -> bytes:
    """Print one line to the terminal and return it for the run's log."""
    data = f"{line}\n".encode()
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
    return data


def journal(config: Config, message: str) -> None:
    """Best effort: a missing or stuck journal never changes a library outcome."""
    with contextlib.suppress(OSError, subprocess.TimeoutExpired):
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


def _fetch_folders(
    config: Config,
    invoke: Callable[..., tuple[int, bytes]],
    claim: int,
    extensions: dict[str, set[str]],
    platforms: dict[str, str],
    outcomes: dict[str, str],
    transcript: bytearray,
) -> None:
    """Fetch each mapped folder, recording outcomes and output as each one finishes."""
    for folder, roms in discover(config, extensions).items():
        # Classification comes before listing: an unlistable folder the frontend does not
        # know stays without an outcome, and an unlistable unmapped one stays unmapped.
        if folder not in extensions:
            continue
        platform = platforms.get(folder)
        if platform is None:
            outcomes[folder] = "unmapped"
            continue
        transcript.extend(show(f"Fetching {folder}"))
        if roms is None:
            status, output = 1, show(f"Cannot list {folder}")
        else:
            try:
                status, output = invoke(config, fetch_vector(config, folder, platform), claim)
            except OSError as error:
                status, output = 1, show(f"Could not start the scraper for {folder}: {error}")
        transcript.extend(output)
        if status == 0:
            revisions = read_mapping(config.revision_path)
            revisions[folder] = uuid.uuid4().hex
            atomic_json(config.revision_path, revisions)
            pending = read_pending(config)
            if folder not in pending:
                write_pending(config, [*pending, folder])
            outcomes[folder] = "fetched"
        else:
            outcomes[folder] = "fetch-failed"


def scrape(config: Config, invoke: Callable[..., tuple[int, bytes]] = run_skyscraper) -> int:
    if not correct_account(config):
        return 1
    # Blocked until the handlers are in place: a request that arrives once the claim is
    # taken reaches them, and one that arrives without a claim still ends the process.
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, TERMINATIONS)
    try:
        claim = lock(config)
        if claim is None:
            print("A scrape or generation run is in progress", file=sys.stderr)
            return 1
        outcomes: dict[str, str] = {}
        transcript = bytearray()
        try:
            # A termination signal anywhere under the claim, not only while the scraper
            # runs, ends the run as interrupted.
            with _terminations():
                try:
                    signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
                    return _scrape_claimed(config, invoke, claim, outcomes, transcript)
                except Interrupted:
                    _record_interrupted(config, outcomes, transcript)
                    raise
        finally:
            os.close(claim)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)


def _folder_exists(config: Config, name: str) -> bool:
    """Whether a ROM folder of that name exists; a path that cannot be checked counts as absent."""
    if name in ("", ".", "..") or "/" in name:
        return False
    try:
        return stat.S_ISDIR((config.rom_root / name).stat().st_mode)
    except (OSError, ValueError):
        return False


def _carried_outcomes(config: Config) -> dict[str, Any]:
    """The previous record's outcomes for folders whose directory still exists."""
    previous = read_mapping(config.record_path).get("folders")
    if not isinstance(previous, dict):
        return {}
    return {name: outcome for name, outcome in previous.items() if _folder_exists(config, name)}


def _record_interrupted(config: Config, outcomes: dict[str, str], transcript: bytearray) -> None:
    # A failed write must not replace the interruption's exit status, and the
    # record is still attempted when the log cannot be written.
    with contextlib.suppress(OSError):
        atomic_write(config.log_path, bytes(transcript))
    with contextlib.suppress(OSError):
        # Folders the run did not reach keep what the previous record said of them.
        carried = _carried_outcomes(config)
        carried.update(outcomes)
        write_record(config, "interrupted", carried)


def _scrape_claimed(
    config: Config,
    invoke: Callable[..., tuple[int, bytes]],
    claim: int,
    outcomes: dict[str, str],
    transcript: bytearray,
) -> int:
    error = credentials_error(config)
    if error:
        print(error, file=sys.stderr)
        atomic_write(config.log_path, (error + "\n").encode())
        # From here the refusal is the outcome, so a late request cannot relabel it.
        _disarm_interrupt()
        # Nothing was attempted, so earlier outcomes still describe the folders.
        write_record(config, "refused", _carried_outcomes(config), error)
        return 1
    with contextlib.suppress(OSError):
        os.nice(19)
    if IONICE and not IONICE.startswith("@"):
        try:
            subprocess.run([IONICE, "-c", "3", "-p", str(os.getpid())], check=True)
        except (OSError, subprocess.CalledProcessError) as error:
            raise ValueError(f"Cannot lower the scrape's disk priority: {error}") from error
    extensions = system_extensions(config)
    platforms = read_json(config.platform_map, {})
    _fetch_folders(config, invoke, claim, extensions, platforms, outcomes, transcript)
    fetched = sum(value == "fetched" for value in outcomes.values())
    failed = sum(value == "fetch-failed" for value in outcomes.values())
    unmapped = sum(value == "unmapped" for value in outcomes.values())
    result = "partial" if fetched and failed else "failed" if failed else "complete"
    transcript.extend(
        show(f"Scrape result: {result} ({fetched} fetched, {failed} failed, {unmapped} unmapped)")
    )
    atomic_write(config.log_path, bytes(transcript))
    # Every folder is finished, so a late request cannot relabel the run as interrupted.
    _disarm_interrupt()
    write_record(config, result, outcomes)
    return 0 if result == "complete" else 1


def _record_generation(config: Config, folder: str, outcome: str, reason: str = "") -> None:
    # Without an earlier record there is no run result to report, only outcomes.
    record: dict[str, Any] = read_mapping(config.record_path)
    folders = record.get("folders")
    if not isinstance(folders, dict):
        folders = record["folders"] = {}
    folders[folder] = outcome
    atomic_json(config.record_path, record)
    if outcome == "generation-failed":
        journal(config, f"Generation failed for {folder}" + (f": {reason}" if reason else ""))


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


def _read_gamelist(path: Path) -> ET.Element:
    root = ET.parse(path).getroot()
    if root.tag != "gameList":
        raise ValueError("Expected a gameList root")
    return root


def _written(path: Path) -> bool:
    """Whether the scraper left a gamelist that is not the untouched sentinel copy."""
    try:
        info = path.stat()
    except FileNotFoundError:
        return False
    return stat.S_ISREG(info.st_mode) and info.st_mtime_ns != SENTINEL_MTIME_NS


def _reconcile_gamelist(
    config: Config,
    folder: str,
    previous: ET.Element,
    candidate: ET.Element,
    extensions: set[str],
) -> None:
    """Keep existing games, family metadata and system settings the scraper did not emit."""
    # Keys stay lexical: a symlinked alias is a game of its own, not a duplicate of its target.
    directory = Path(os.path.normpath(config.rom_root / folder))
    bases = (directory, directory.resolve())

    def contained(entry: ET.Element) -> Path | None:
        """The entry's path relative to the folder, or None when it names nothing inside it."""
        value = entry.findtext("path")
        if not value:
            return None
        path = Path(os.path.normpath(value))
        if path.is_absolute():
            base = next((base for base in bases if path.is_relative_to(base)), None)
            if base is None:
                return None
            path = path.relative_to(base)
        # Lexical on purpose: a linked subdirectory inside the folder is followed, as the
        # frontend follows it.
        if not path.parts or path.parts[0] == "..":
            return None
        return path

    def identity(entry: ET.Element) -> Path | None:
        path = contained(entry)
        if path is None or path.suffix.casefold() not in extensions:
            return None
        return path if (directory / path).is_file() else None

    def carried(child: ET.Element) -> bool:
        if child.tag == "game" or child.tag in present:
            return False
        if child.tag != "folder":
            return True
        path = contained(child)
        return path is not None and (directory / path).is_dir()

    # The frontend keeps system-wide settings, such as its alternative emulator, at the root.
    present = {child.tag for child in candidate}
    settings = [child for child in previous if carried(child)]
    for index, child in enumerate(settings):
        candidate.insert(index, copy.deepcopy(child))

    entries: dict[Path, ET.Element] = {}
    for entry in candidate.findall("game"):
        key = identity(entry)
        if key is not None:
            if key in entries:
                raise ValueError("Duplicate game path in generated gamelist")
            entries[key] = entry
    for old in previous.findall("game"):
        key = identity(old)
        if key is None:
            continue
        current = entries.get(key)
        if current is None:
            current = copy.deepcopy(old)
            candidate.append(current)
            entries[key] = current
        else:
            for field in FAMILY_FIELDS:
                saved = old.find(field)
                if saved is not None:
                    for generated in current.findall(field):
                        current.remove(generated)
                    current.append(copy.deepcopy(saved))
    if directory.exists():
        for rom in rom_files(directory, extensions):
            if rom.relative_to(directory) not in entries:
                entry = ET.SubElement(candidate, "game")
                ET.SubElement(entry, "path").text = f"./{rom.name}"
                ET.SubElement(entry, "name").text = rom.stem


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
        # Parsed once per run; an unreadable document fails every pending folder with its cause.
        known: dict[str, set[str]] | None = None
        unknown = ""
        try:
            known = system_extensions(config)
        except (OSError, ValueError) as error:
            unknown = str(error)
        for folder in pending:
            if folder not in read_pending(config):
                continue
            reason = unknown
            if time.monotonic() >= end or folder not in platforms or known is None:
                outcome = "generation-failed"
            elif folder not in known:
                outcome = "generation-failed"
                reason = f"the frontend lists no system named {folder}"
            else:
                show(f"Generating {folder}")
                parent = config.gamelist_root / folder
                live = parent / "gamelist.xml"
                work: Path | None = None
                try:
                    parent.mkdir(parents=True, exist_ok=True)
                    _discard_work(parent)
                    work = Path(tempfile.mkdtemp(prefix=".emubox-library-work-", dir=parent))
                    source = work / "gamelist.xml"
                    previous = ET.Element("gameList")
                    if live.exists():
                        try:
                            shutil.copy2(live, source)
                            os.utime(source, ns=(SENTINEL_MTIME_NS, SENTINEL_MTIME_NS))
                            previous = _read_gamelist(source)
                        except (OSError, ValueError, ET.ParseError):
                            reason = "its gamelist is unreadable; repair it or move it aside"
                            raise
                    limit = min(end, time.monotonic() + PER_FOLDER_SECONDS)
                    status, _ = invoke(
                        config,
                        generate_vector(config, folder, platforms[folder], work, known[folder]),
                        claim,
                        limit,
                    )
                    if status == 0 and time.monotonic() < limit and _written(source):
                        candidate = _read_gamelist(source)
                        _reconcile_gamelist(config, folder, previous, candidate, known[folder])
                        merged = ET.tostring(candidate, encoding="utf-8")
                        # A value XML cannot carry would publish a file nothing can read.
                        ET.fromstring(merged)
                        source.write_bytes(merged)
                        if time.monotonic() >= limit:
                            raise ValueError("Generation deadline expired before publication")
                        _publish_gamelist(work, live)
                        outcome = "generated"
                    else:
                        outcome = "generation-failed"
                except (OSError, ValueError, ET.ParseError):
                    outcome = "generation-failed"
                finally:
                    if work is not None:
                        shutil.rmtree(work, ignore_errors=True)
            _record_generation(config, folder, outcome, reason)
            write_pending(config, [item for item in read_pending(config) if item != folder])
        return 0
    except (OSError, ValueError) as error:
        journal(config, f"Generation could not read or write state: {error}")
        return 0
    finally:
        os.close(claim)


def capture(config: Config) -> tuple[int, dict[str, str | None]]:
    if not correct_account(config):
        return 1, {}
    claim = lock(config)
    if claim is None:
        journal(config, "A fetch was running; generation deferred")
        return 75, {}
    try:
        revisions = read_mapping(config.revision_path)
        # A folder with no identity is still attempted; cleanup retires it only while
        # it still has none.
        return 0, {folder: revisions.get(folder) for folder in read_pending(config)}
    finally:
        os.close(claim)


def cleanup(config: Config, batch: dict[str, str | None]) -> int:
    if not correct_account(config):
        return 1
    claim = lock(config)
    if claim is None:
        journal(config, "Generation failure cleanup deferred; the library claim was held")
        return 1
    try:
        revisions = read_mapping(config.revision_path)
        failed = False
        for folder, revision in batch.items():
            # A folder captured without a revision is retired only while it still has none:
            # every fetch stores a revision before it marks the folder pending.
            if folder not in read_pending(config) or revisions.get(folder) != revision:
                continue
            _record_generation(config, folder, "generation-failed")
            write_pending(config, [item for item in read_pending(config) if item != folder])
            failed = True
        if failed:
            journal(config, "Generation could not finish with a progress window; frontend starting")
        return 0
    except OSError:
        journal(config, "Generation failure cleanup deferred; records could not be written")
        return 1
    finally:
        os.close(claim)


def _gamelist_counts(config: Config, folder: str, roms: list[Path]) -> tuple[int, int] | None:
    """Entry and unscraped counts, or None when the gamelist cannot be read as one."""
    path = config.gamelist_root / folder / "gamelist.xml"
    try:
        games = _read_gamelist(path).findall("game")
    except FileNotFoundError:
        games = []
    except (OSError, ValueError, ET.ParseError):
        return None
    directory = config.rom_root / folder
    described = set()
    for game in games:
        path = Path(game.findtext("path") or "")
        if (game.findtext("desc") or "").strip() and path.parts:
            if path.is_absolute():
                if not path.is_relative_to(directory):
                    continue
                path = path.relative_to(directory)
            described.add(os.path.normpath(path))
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
        try:
            record = read_json(config.record_path, None)
        except (OSError, ValueError):
            record = "unavailable"
        sender.put(("record", record))
        try:
            pending = read_pending(config)
        except (OSError, ValueError):
            pending = None
        sender.put(("pending", pending))
        extensions = system_extensions(config)
        platforms = read_json(config.platform_map, {})
        folders = discover(config, extensions)
        sender.put(("folders", list(folders)))
        for name, roms in folders.items():
            if roms is None:
                continue
            counts = _gamelist_counts(config, name, roms)
            note = (
                "unknown system"
                if name not in extensions
                else "unmapped"
                if name not in platforms
                else ""
            )
            sender.put(("count", name, len(roms), counts, note))
        sender.put(("done",))
    except Exception as error:
        sender.put(("error", str(error)))


def report(config: Config | Path, deadline_seconds: float = REPORT_SECONDS) -> tuple[int, str]:
    read_fd, write_fd = os.pipe()
    worker_pid = os.fork()
    if worker_pid == 0:
        # The forked worker must never return into the caller's code.
        try:
            os.close(read_fd)
            _scan(config, _PipeSender(write_fd))
        finally:
            os._exit(0)
    os.close(write_fd)
    deadline = time.monotonic() + deadline_seconds
    record: dict[str, Any] | None = None
    record_loaded = False
    pending: list[str] | None = None
    folders: list[str] | None = None
    counts: dict[str, tuple[int, list[int] | None, str]] = {}
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
                        record = message[1] if isinstance(message[1], dict) else None
                        record_loaded = message[1] is None or record is not None
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
                roms, gamelist, note = counts[folder]
                suffix = f" ({note})" if note else ""
                if gamelist is None:
                    lines.append(f"{folder}: {roms} ROMs, gamelist unreadable{suffix}")
                else:
                    entries, unscraped = gamelist
                    lines.append(
                        f"{folder}: {roms} ROMs, {entries} gamelist entries, "
                        f"{unscraped} unscraped{suffix}"
                    )
    if record is None:
        lines.append("No scrape has run" if record_loaded else "Run record unavailable")
    else:
        lines.append(
            f"Last run: {record['result']} at {record.get('time', 'unknown time')}"
            if "result" in record
            else "No completed fetch recorded"
        )
        outcomes = record.get("folders")
        failures = [
            name
            for name, result in (outcomes.items() if isinstance(outcomes, dict) else ())
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
    counted = complete and all(folder in counts for folder in folders or ())
    return (0 if counted else 1), "\n".join(lines) + "\n"


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=CONFIG_PATH)
    return parser


def _fail(error: Exception) -> int:
    """An expected failure is one line naming its cause, never a traceback."""
    print(str(error).replace("\n", " "), file=sys.stderr)
    return 1


def scrape_main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        return scrape(Config.read(args.config))
    except Interrupted as interrupted:
        return 128 + interrupted.number
    except (OSError, ValueError) as error:
        return _fail(error)


def generate_main(argv: list[str] | None = None) -> int:
    parser = _parser()
    parser.add_argument("action", nargs="?", choices=("capture", "cleanup"))
    parser.add_argument("--batch", default="{}")
    args = parser.parse_args(argv)
    try:
        config = Config.read(args.config)
    except ValueError as error:
        return _fail(error)
    if args.action == "capture":
        status, batch = capture(config)
        if status == 0:
            print(json.dumps(batch, sort_keys=True))
        return status
    if args.action == "cleanup":
        return cleanup(config, json.loads(args.batch))
    try:
        return generate(config)
    except Interrupted as interrupted:
        # Unfinished folders stay pending for the session's failure cleanup.
        return 128 + interrupted.number


def report_main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    status, output = report(args.config)
    print(output, end="")
    return status
