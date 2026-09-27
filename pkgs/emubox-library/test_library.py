"""Behavioral checks for library state, process claims, and reports."""

from __future__ import annotations

import contextlib
import json
import os
import pwd
import shutil
import signal
import stat
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from collections.abc import Callable
from dataclasses import asdict, replace
from pathlib import Path

import pytest

import library


@pytest.fixture
def config(tmp_path: Path) -> library.Config:
    bundled = tmp_path / "bundled.xml"
    bundled.write_text(
        "<systemList><system><name>nes</name><extension>.nes .NES</extension></system>"
        "<system><name>psx</name><extension>.cue .bin</extension></system>"
        "<system><name>genesis</name><extension>.md</extension></system></systemList>"
    )
    custom = tmp_path / "custom.xml"
    custom.write_text(
        "<systemList><system><name>psx</name><extension>.cue</extension></system></systemList>"
    )
    mapping = tmp_path / "map.json"
    mapping.write_text(json.dumps({"nes": "nes", "psx": "psx"}))
    credentials = tmp_path / "skyscraper.ini"
    credentials.write_text('[screenscraper]\nuserCreds="person:secret"\n')
    cat = tmp_path / "cat"
    cat.write_text("#!/bin/sh\ncat >/dev/null\n")
    cat.chmod(0o755)
    return library.Config(
        rom_root=tmp_path / "roms",
        cache_root=tmp_path / "cache",
        gamelist_root=tmp_path / "gamelists",
        media_root=tmp_path / "media",
        scraper_config=credentials,
        bundled_systems=bundled,
        custom_systems=custom,
        platform_map=mapping,
        skyscraper="/nonexistent/Skyscraper",
        systemd_cat=str(cat),
        session_user=pwd.getpwuid(os.geteuid()).pw_name,
    )


def game(config: library.Config, folder: str, name: str) -> None:
    directory = config.rom_root / folder
    directory.mkdir(parents=True, exist_ok=True)
    (directory / name).write_text("ROM")


def held_lock(config: library.Config) -> int:
    descriptor = library.lock(config)
    assert descriptor is not None
    return descriptor


def cli_config(config: library.Config, path: Path) -> Path:
    path.write_text(
        json.dumps(
            {
                key: str(value) if isinstance(value, Path) else value
                for key, value in asdict(config).items()
            }
        )
    )
    return path


def wait_for(path: Path) -> None:
    end = time.monotonic() + 10
    while not path.exists() and time.monotonic() < end:
        time.sleep(0.02)
    assert path.exists(), path


def journal_log(config: library.Config) -> tuple[library.Config, Path]:
    log = config.cache_root.parent / "journal.log"
    cat = config.cache_root.parent / "journal-cat"
    cat.write_text(f"#!/bin/sh\ncat >> {log}\n")
    cat.chmod(0o755)
    return replace(config, systemd_cat=str(cat)), log


needs_permissions = pytest.mark.skipif(os.geteuid() == 0, reason="root ignores file modes")


def test_discovery_uses_frontend_extensions_and_ignores_empty_directories(
    config: library.Config,
) -> None:
    game(config, "nes", "readme.txt")
    (config.rom_root / "nes" / "nested").mkdir()
    game(config, "psx", "disc.cue")
    game(config, "psx", "disc.bin")
    game(config, "unknown", "anything.txt")
    (config.rom_root / "empty").mkdir()
    found = library.discover(config, library.system_extensions(config))
    assert list(found) == ["psx", "unknown"]
    assert [file.name for file in found["psx"] or ()] == ["disc.cue"]


def test_wrong_account_refuses_without_creating_state(
    config: library.Config, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(library.os, "geteuid", lambda: 987654)
    assert library.scrape(config) == 1
    assert "sudo -u" in capsys.readouterr().err
    assert not config.cache_root.exists()


@pytest.mark.parametrize("uid", [0, 987654])
def test_wrong_account_preserves_existing_state(
    config: library.Config, uid: int, monkeypatch: pytest.MonkeyPatch
) -> None:
    config = replace(config, session_user="player")
    monkeypatch.setattr(library.os, "geteuid", lambda: uid)
    monkeypatch.setattr(
        library.pwd,
        "getpwnam",
        lambda _name: pwd.struct_passwd(("player", "*", 123456, 123456, "", "/player", "/bin/sh")),
    )
    library.write_record(config, "complete", {"nes": "fetched"})
    library.atomic_write(config.log_path, b"previous scrape\n")
    library.atomic_json(config.revision_path, {"nes": "previous"})
    library.write_pending(config, ["nes"])
    before = {path: path.read_bytes() for path in config.cache_root.iterdir()}
    assert library.scrape(config, lambda *args: pytest.fail("unexpected scraper")) == 1
    assert {path: path.read_bytes() for path in config.cache_root.iterdir()} == before


def test_scraper_child_uses_account_home_instead_of_inherited_home(
    config: library.Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    expected = pwd.getpwnam(config.session_user).pw_dir
    monkeypatch.setenv("HOME", "/home/admin")
    config = replace(config, skyscraper=sys.executable)
    claim = held_lock(config)
    try:
        status, output = library.run_skyscraper(
            config, ["-c", "import os; print(os.environ['HOME'])"], claim
        )
    finally:
        os.close(claim)
    assert status == 0
    assert output == (expected + "\n").encode()
    assert os.environ["HOME"] == "/home/admin"


def test_fetch_sets_background_priorities_before_scraper(
    config: library.Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    game(config, "nes", "a.nes")
    calls: list[object] = []
    monkeypatch.setattr(library.os, "nice", lambda amount: calls.append(("nice", amount)))
    monkeypatch.setattr(library, "IONICE", "/fixture/ionice")

    def run(argv: list[str], *, check: bool) -> subprocess.CompletedProcess[bytes]:
        calls.append((argv, check))
        return subprocess.CompletedProcess(argv, 0)

    monkeypatch.setattr(library.subprocess, "run", run)

    def invoke(*args: object) -> tuple[int, bytes]:
        calls.append("scraper")
        return 0, b""

    assert library.scrape(config, invoke) == 0
    assert calls == [
        ("nice", 19),
        (["/fixture/ionice", "-c", "3", "-p", str(os.getpid())], True),
        "scraper",
    ]


def test_fetch_log_matches_streamed_terminal_output(
    config: library.Config, capsysbinary: pytest.CaptureFixture[bytes]
) -> None:
    game(config, "nes", "a.nes")
    scraper = config.rom_root.parent / "scraper"
    scraper.write_text(
        f"#!{sys.executable}\n"
        "import sys\n"
        "print('scraper stdout', flush=True)\n"
        "print('scraper stderr', file=sys.stderr, flush=True)\n"
    )
    scraper.chmod(0o755)
    assert library.scrape(replace(config, skyscraper=str(scraper))) == 0
    terminal = capsysbinary.readouterr().out
    assert terminal == (
        b"Fetching nes\nscraper stdout\nscraper stderr\n"
        b"Scrape result: complete (1 fetched, 0 failed, 0 unmapped)\n"
    )
    assert config.log_path.read_bytes() == terminal


@pytest.mark.parametrize("cause", ["missing", "unreadable", "placeholder"])
def test_credentials_replace_record_keeping_outcomes_without_touching_pending(
    config: library.Config, cause: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    game(config, "psx", "a.cue")
    library.atomic_json(
        config.record_path,
        {
            "result": "complete",
            "time": "old",
            "folders": {"psx": "generation-failed", "gone": "fetched"},
        },
    )
    library.write_pending(config, ["nes"])
    before = config.pending_path.read_bytes()
    if cause == "missing":
        config.scraper_config.unlink()
    elif cause == "unreadable":
        monkeypatch.setattr(
            Path,
            "read_text",
            lambda path, *args, **kwargs: (
                (_ for _ in ()).throw(PermissionError())
                if path == config.scraper_config
                else Path.open(path).read()
            ),
        )
    else:
        config.scraper_config.write_text(
            '[screenscraper]\nuserCreds="REPLACE-BEFORE-INSTALL-SCREENSCRAPER-USERNAME:secret"\n'
        )
    called = []

    def invoke(*args: object) -> tuple[int, bytes]:
        called.append(args)
        return 0, b""

    assert library.scrape(config, invoke) == 1
    assert called == []
    record = json.loads(config.record_path.read_text())
    assert record["result"] == "refused"
    assert record["time"] != "old"
    assert cause in record["cause"]
    assert record["folders"] == {"psx": "generation-failed"}
    assert config.pending_path.read_bytes() == before


# Skyscraper drops credentials that do not split into exactly two parts.
@pytest.mark.parametrize("value", ['":secret"', '"person:"', '"person:pa:ss"'])
def test_unusable_credential_value_refuses_before_scraper(
    config: library.Config, value: str
) -> None:
    game(config, "nes", "a.nes")
    library.write_record(config, "complete", {"nes": "fetched"})
    library.write_pending(config, ["nes"])
    before = config.pending_path.read_bytes()
    config.scraper_config.write_text(f"[screenscraper]\nuserCreds={value}\n")
    invoked = []

    def stub(*args: object) -> tuple[int, bytes]:
        invoked.append(args)
        return 0, b""

    assert library.scrape(config, stub) == 1
    assert invoked == []
    record = json.loads(config.record_path.read_text())
    assert record["result"] == "refused"
    assert "missing" in record["cause"]
    assert record["folders"] == {"nes": "fetched"}
    assert config.pending_path.read_bytes() == before


@pytest.mark.parametrize("password", ["your_secret", "changeme42", "placeholder!"])
def test_credentials_resembling_placeholders_are_accepted(
    config: library.Config, password: str
) -> None:
    config.scraper_config.write_text(f'[screenscraper]\nuserCreds="person:{password}"\n')
    assert library.credentials_error(config) is None


@pytest.mark.parametrize(
    "value",
    [
        "REPLACE-BEFORE-INSTALL-SCREENSCRAPER-USERNAME:secret",
        "person:replace-before-install-screenscraper-password",
    ],
)
def test_committed_placeholder_in_either_component_refuses(
    config: library.Config, value: str
) -> None:
    config.scraper_config.write_text(f'[screenscraper]\nuserCreds="{value}"\n')
    assert library.credentials_error(config) == "placeholder ScreenScraper credentials"


def test_percent_in_valid_credentials_allows_fetch(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    config.scraper_config.write_text('[screenscraper]\nuserCreds="person:pa%ss"\n')
    seen: list[list[str]] = []

    def stub(_config: library.Config, argv: list[str], _claim: int) -> tuple[int, bytes]:
        seen.append(argv)
        return 0, b"ok\n"

    assert library.scrape(config, stub) == 0
    assert seen == [library.fetch_vector(config, "nes", "nes", {".nes"})]
    assert json.loads(config.record_path.read_text())["result"] == "complete"


def test_fetch_outcomes_vectors_revision_and_modes(config: library.Config) -> None:
    for folder, name in (
        ("nes", "a.nes"),
        ("psx", "a.cue"),
        ("genesis", "a.md"),
        ("unknown", "a.bin"),
    ):
        game(config, folder, name)
    seen: list[list[str]] = []

    def invoke(_config: library.Config, argv: list[str], _claim: int) -> tuple[int, bytes]:
        seen.append(argv)
        return (1 if "psx" in argv else 0), b"scraper output\n"

    old_umask = os.umask(0o077)
    try:
        assert library.scrape(config, invoke) == 1
    finally:
        os.umask(old_umask)
    assert seen == [
        library.fetch_vector(config, "nes", "nes", {".nes"}),
        library.fetch_vector(config, "psx", "psx", {".cue"}),
    ]
    record = json.loads(config.record_path.read_text())
    assert record["result"] == "partial"
    assert record["folders"] == {"nes": "fetched", "psx": "fetch-failed", "genesis": "unmapped"}
    assert library.read_pending(config) == ["nes"]
    first_revision = json.loads(config.revision_path.read_text())["nes"]
    assert library.scrape(config, invoke) == 1
    assert library.read_pending(config) == ["nes"]
    assert json.loads(config.revision_path.read_text())["nes"] != first_revision
    for path in (config.record_path, config.log_path, config.revision_path, config.pending_path):
        assert stat.S_IMODE(path.stat().st_mode) == 0o644
    assert b"Fetching nes" in config.log_path.read_bytes()
    assert b"scraper output" in config.log_path.read_bytes()


@pytest.mark.parametrize(
    ("status", "expected_result", "expected_outcome", "expected_pending"),
    [
        (0, "complete", "fetched", ["nes", "psx"]),
        (1, "failed", "fetch-failed", []),
    ],
)
def test_all_mapped_fetches_have_exact_run_result(
    config: library.Config,
    status: int,
    expected_result: str,
    expected_outcome: str,
    expected_pending: list[str],
) -> None:
    game(config, "nes", "a.nes")
    game(config, "psx", "a.cue")
    seen: list[list[str]] = []

    def stub(_config: library.Config, argv: list[str], _claim: int) -> tuple[int, bytes]:
        seen.append(argv)
        return status, b"done\n"

    assert library.scrape(config, stub) == (0 if status == 0 else 1)
    assert seen == [
        library.fetch_vector(config, "nes", "nes", {".nes"}),
        library.fetch_vector(config, "psx", "psx", {".cue"}),
    ]
    record = json.loads(config.record_path.read_text())
    assert record["result"] == expected_result
    assert record["folders"] == {"nes": expected_outcome, "psx": expected_outcome}
    assert library.read_pending(config) == expected_pending


def test_no_mapped_folder_is_complete_and_held_lock_preserves_records(
    config: library.Config,
) -> None:
    game(config, "genesis", "a.md")
    assert library.scrape(config, lambda *args: pytest.fail("unexpected scraper")) == 0
    assert json.loads(config.record_path.read_text())["result"] == "complete"
    before = config.record_path.read_bytes()
    claim = held_lock(config)
    try:
        assert library.scrape(config) == 1
        assert config.record_path.read_bytes() == before
        assert library.generate(config) == 75
        assert library.capture(config) == (75, {})
    finally:
        os.close(claim)


def test_generation_uses_fresh_work_and_renames_only_success(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    library.write_pending(config, ["nes"])
    parent = config.gamelist_root / "nes"
    parent.mkdir(parents=True)
    live = parent / "gamelist.xml"
    live.write_text("<gameList><game><path>./a.nes</path></game></gameList>")
    old = live.read_bytes()
    stale = parent / ".emubox-library-work-stale"
    stale.mkdir()
    (stale / "gamelist.xml").write_text("TRUNCATED")
    seen = []

    def failure(
        _config: library.Config, argv: list[str], _claim: int, _limit: float
    ) -> tuple[int, bytes]:
        work = Path(argv[argv.index("-g") + 1])
        seen.append((work / "gamelist.xml").read_bytes())
        (work / "gamelist.xml").write_text("BROKEN")
        return 1, b""

    assert library.generate(config, failure) == 0
    assert seen == [old]
    assert live.read_bytes() == old
    assert not stale.exists()
    assert library.read_pending(config) == []
    assert json.loads(config.record_path.read_text())["folders"]["nes"] == "generation-failed"
    library.write_pending(config, ["nes"])

    def success(
        _config: library.Config, argv: list[str], _claim: int, _limit: float
    ) -> tuple[int, bytes]:
        work = Path(argv[argv.index("-g") + 1])
        assert (work / "gamelist.xml").read_bytes() == old
        (work / "gamelist.xml").write_text(
            "<gameList><game><path>./a.nes</path><name>NEW</name></game></gameList>"
        )
        return 0, b""

    assert library.generate(config, success) == 0
    assert (
        live.read_text() == "<gameList><game><path>./a.nes</path><name>NEW</name></game></gameList>"
    )
    assert library.read_pending(config) == []
    assert not list(parent.glob(".emubox-library-work-*"))


def test_vectors_include_frontend_extensions(config: library.Config) -> None:
    for argv in (
        library.fetch_vector(config, "psx", "psx", {".cue"}),
        library.generate_vector(config, "psx", "psx", config.cache_root / "work", {".cue"}),
    ):
        assert argv[argv.index("--addext") + 1] == ".cue"
    argv = library.fetch_vector(config, "nes", "nes", {".nes"})
    assert argv[argv.index("--addext") + 1] == ".nes"


@pytest.mark.parametrize("output", [None, "", "<gameList><game>", "<wrong />", "missing"])
def test_unsuccessful_output_never_replaces_live_gamelist(
    config: library.Config, output: str | None
) -> None:
    game(config, "nes", "a.nes")
    live = config.gamelist_root / "nes" / "gamelist.xml"
    live.parent.mkdir(parents=True)
    old = b"<gameList><game><path>./a.nes</path><favorite>true</favorite></game></gameList>"
    live.write_bytes(old)
    library.write_pending(config, ["nes"])

    def invoke(_config: library.Config, argv: list[str], *_args: object) -> tuple[int, bytes]:
        source = Path(argv[argv.index("-g") + 1]) / "gamelist.xml"
        if output == "missing":
            source.unlink()
        elif output is not None:
            source.write_text(output)
        return 0, b""

    assert library.generate(config, invoke) == 0
    assert live.read_bytes() == old
    assert json.loads(config.record_path.read_text())["folders"]["nes"] == "generation-failed"
    assert library.read_pending(config) == []
    assert not list(live.parent.glob(".emubox-library-work-*"))


def test_identical_rewrite_is_successful(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    live = config.gamelist_root / "nes" / "gamelist.xml"
    live.parent.mkdir(parents=True)
    old = b"<gameList><game><path>./a.nes</path><name>A</name></game></gameList>"
    live.write_bytes(old)
    library.write_pending(config, ["nes"])

    def invoke(_config: library.Config, argv: list[str], *_args: object) -> tuple[int, bytes]:
        (Path(argv[argv.index("-g") + 1]) / "gamelist.xml").write_bytes(old)
        return 0, b""

    assert library.generate(config, invoke) == 0
    assert live.read_bytes() == old
    assert json.loads(config.record_path.read_text())["folders"]["nes"] == "generated"


class _CoarseStat:
    """A stat result from a file system that keeps whole thousands of seconds."""

    def __init__(self, result: os.stat_result) -> None:
        self._result = result
        self.st_mtime_ns = result.st_mtime_ns // 10**12 * 10**12
        self.st_ctime_ns = result.st_ctime_ns // 10**12 * 10**12

    def __getattr__(self, name: str) -> object:
        return getattr(self._result, name)


def test_rewrite_is_detected_on_coarse_timestamps(
    config: library.Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    game(config, "nes", "a.nes")
    live = config.gamelist_root / "nes" / "gamelist.xml"
    live.parent.mkdir(parents=True)
    old = b"<gameList><game><path>./a.nes</path><name>A</name></game></gameList>"
    live.write_bytes(old)
    now = time.time_ns()
    os.utime(live, ns=(now, now))
    library.write_pending(config, ["nes"])
    original = Path.stat

    def coarse(path: Path, *, follow_symlinks: bool = True) -> object:
        return _CoarseStat(original(path, follow_symlinks=follow_symlinks))

    def invoke(_config: library.Config, argv: list[str], *_args: object) -> tuple[int, bytes]:
        (Path(argv[argv.index("-g") + 1]) / "gamelist.xml").write_bytes(old)
        return 0, b""

    monkeypatch.setattr(Path, "stat", coarse)
    assert library.generate(config, invoke) == 0
    monkeypatch.undo()
    assert live.read_bytes() == old
    assert json.loads(config.record_path.read_text())["folders"]["nes"] == "generated"


@pytest.mark.parametrize("name", ["control\x01.nes", b"undecodable\xff.nes"])
def test_merged_gamelist_that_does_not_read_back_is_not_published(
    config: library.Config, name: str | bytes
) -> None:
    directory = config.rom_root / "nes"
    directory.mkdir(parents=True)
    try:
        if isinstance(name, bytes):
            with open(os.path.join(os.fsencode(directory), name), "wb") as stream:
                stream.write(b"ROM")
        else:
            (directory / name).write_text("ROM")
    except (OSError, ValueError):
        pytest.skip("the file system rejects this name")
    live = config.gamelist_root / "nes" / "gamelist.xml"
    live.parent.mkdir(parents=True)
    old = b"<gameList><game><path>./other.nes</path><favorite>true</favorite></game></gameList>"
    live.write_bytes(old)
    library.write_pending(config, ["nes"])

    def invoke(_config: library.Config, argv: list[str], *_args: object) -> tuple[int, bytes]:
        (Path(argv[argv.index("-g") + 1]) / "gamelist.xml").write_text("<gameList />")
        return 0, b""

    assert library.generate(config, invoke) == 0
    assert live.read_bytes() == old
    assert json.loads(config.record_path.read_text())["folders"]["nes"] == "generation-failed"
    assert library.read_pending(config) == []


@pytest.mark.parametrize("old", ["<gameList><game>", "<wrong />"])
def test_invalid_previous_gamelist_prevents_generation(config: library.Config, old: str) -> None:
    config, log = journal_log(config)
    live = config.gamelist_root / "nes" / "gamelist.xml"
    live.parent.mkdir(parents=True)
    live.write_text(old)
    library.write_pending(config, ["nes"])
    assert library.generate(config, lambda *args: pytest.fail("unexpected scraper")) == 0
    assert live.read_text() == old
    assert json.loads(config.record_path.read_text())["folders"]["nes"] == "generation-failed"
    line = log.read_text()
    assert "Generation failed for nes" in line
    assert "gamelist is unreadable" in line
    assert "move it aside" in line
    assert library.read_pending(config) == []


def test_uncopyable_previous_gamelist_names_the_remedy(config: library.Config) -> None:
    config, log = journal_log(config)
    live = config.gamelist_root / "nes" / "gamelist.xml"
    live.mkdir(parents=True)
    library.write_pending(config, ["nes"])
    assert library.generate(config, lambda *args: pytest.fail("unexpected scraper")) == 0
    assert live.is_dir()
    assert json.loads(config.record_path.read_text())["folders"]["nes"] == "generation-failed"
    assert "gamelist is unreadable" in log.read_text()


def test_reconciliation_preserves_distinct_paths_and_omitted_games(config: library.Config) -> None:
    for name in ("same.nes", "nested/same.nes", "omitted.nes", "new.nes"):
        path = config.rom_root / "nes" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("ROM")
    outside = config.rom_root / "outside.nes"
    outside.write_text("ROM")
    game(config, "nes", "sidecar.txt")
    live = config.gamelist_root / "nes" / "gamelist.xml"
    live.parent.mkdir(parents=True)
    previous = ET.Element("gameList")
    for name, count in (
        ("same.nes", "1"),
        ("nested/same.nes", "2"),
        ("omitted.nes", "3"),
        ("deleted.nes", "4"),
        ("../outside.nes", "5"),
        ("sidecar.txt", "6"),
    ):
        entry = ET.SubElement(previous, "game")
        ET.SubElement(entry, "path").text = f"./{name}"
        ET.SubElement(entry, "playcount").text = count
        ET.SubElement(entry, "favorite").text = "true"
        ET.SubElement(entry, "altemulator").text = f"emulator-{count}"
        ET.SubElement(entry, "custom", {"keep": "yes"}).text = count
    ET.ElementTree(previous).write(live)
    library.write_pending(config, ["nes"])

    def invoke(_config: library.Config, argv: list[str], *_args: object) -> tuple[int, bytes]:
        candidate = ET.Element("gameList")
        for path in (str(config.rom_root / "nes" / "same.nes"), "./nested/../nested/same.nes"):
            entry = ET.SubElement(candidate, "game")
            ET.SubElement(entry, "path").text = path
            ET.SubElement(entry, "playcount").text = "0"
            ET.SubElement(entry, "desc").text = "New description"
        ET.ElementTree(candidate).write(Path(argv[argv.index("-g") + 1]) / "gamelist.xml")
        return 0, b""

    assert library.generate(config, invoke) == 0
    entries = ET.parse(live).getroot().findall("game")
    games = {
        (config.rom_root / "nes" / entry.findtext("path", ""))
        .resolve()
        .relative_to(config.rom_root / "nes")
        .as_posix(): entry
        for entry in entries
    }
    assert set(games) == {"same.nes", "nested/same.nes", "omitted.nes", "new.nes"}
    assert len(entries) == len(games)
    for name, count in (("same.nes", "1"), ("nested/same.nes", "2"), ("omitted.nes", "3")):
        assert games[name].findtext("playcount") == count
        assert games[name].findtext("favorite") == "true"
        assert games[name].findtext("altemulator") == f"emulator-{count}"
    assert games["same.nes"].findtext("desc") == "New description"
    assert ET.tostring(games["omitted.nes"]) == ET.tostring(previous.findall("game")[2])
    assert games["new.nes"].findtext("name") == "new"
    assert games["new.nes"].find("desc") is None


def test_carried_folder_entries_need_their_directory(config: library.Config) -> None:
    (config.rom_root / "nes" / "kept").mkdir(parents=True)
    game(config, "nes", "a.nes")
    (config.rom_root / "outside").mkdir()
    live = config.gamelist_root / "nes" / "gamelist.xml"
    live.parent.mkdir(parents=True)
    live.write_text(
        "<gameList>"
        "<folder><path>./kept</path><name>Kept</name></folder>"
        "<folder><path>./gone</path><name>Gone</name></folder>"
        "<folder><path>../outside</path><name>Outside</name></folder>"
        "<folder><path>./a.nes</path><name>File</name></folder>"
        "<alternativeEmulator><label>Chosen</label></alternativeEmulator>"
        "<game><path>./a.nes</path></game></gameList>"
    )
    library.write_pending(config, ["nes"])

    def invoke(_config: library.Config, argv: list[str], *_args: object) -> tuple[int, bytes]:
        (Path(argv[argv.index("-g") + 1]) / "gamelist.xml").write_text(
            "<gameList><game><path>./a.nes</path><desc>New</desc></game></gameList>"
        )
        return 0, b""

    assert library.generate(config, invoke) == 0
    root = ET.parse(live).getroot()
    assert [child.findtext("name") for child in root.findall("folder")] == ["Kept"]
    assert root.findtext("alternativeEmulator/label") == "Chosen"


def test_symlinked_alias_is_its_own_game(config: library.Config) -> None:
    real = config.rom_root.parent / "real-roms"
    (real / "nes").mkdir(parents=True)
    (real / "nes" / "a.nes").write_text("ROM")
    (real / "nes" / "alias.nes").symlink_to("a.nes")
    config.rom_root.symlink_to(real)
    library.write_pending(config, ["nes"])

    def invoke(_config: library.Config, argv: list[str], *_args: object) -> tuple[int, bytes]:
        (Path(argv[argv.index("-g") + 1]) / "gamelist.xml").write_text(
            f"<gameList><game><path>{real.resolve() / 'nes' / 'a.nes'}</path><desc>A</desc></game>"
            f"<game><path>{config.rom_root / 'nes' / 'alias.nes'}</path><desc>B</desc></game>"
            "</gameList>"
        )
        return 0, b""

    assert library.generate(config, invoke) == 0
    assert json.loads(config.record_path.read_text())["folders"] == {"nes": "generated"}
    live = ET.parse(config.gamelist_root / "nes" / "gamelist.xml").getroot()
    assert [game.findtext("desc") for game in live.findall("game")] == ["A", "B"]


def test_publication_failure_keeps_live_file(
    config: library.Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    live = config.gamelist_root / "nes" / "gamelist.xml"
    live.parent.mkdir(parents=True)
    live.write_bytes(b"<gameList />")
    library.write_pending(config, ["nes"])

    def invoke(_config: library.Config, argv: list[str], *_args: object) -> tuple[int, bytes]:
        (Path(argv[argv.index("-g") + 1]) / "gamelist.xml").write_text("<gameList />")
        return 0, b""

    def fail(_work: Path, _live: Path) -> None:
        raise OSError("No space left")

    monkeypatch.setattr(library, "_publish_gamelist", fail)
    assert library.generate(config, invoke) == 0
    assert live.read_bytes() == b"<gameList />"
    assert json.loads(config.record_path.read_text())["folders"]["nes"] == "generation-failed"


def test_zero_exit_with_service_diagnostic_retains_upstream_semantics(
    config: library.Config,
) -> None:
    game(config, "nes", "a.nes")
    assert (
        library.scrape(
            config, lambda *args: (0, b"Your daily ScreenScraper request limit has been reached\n")
        )
        == 0
    )
    record = json.loads(config.record_path.read_text())
    assert record["result"] == "complete"
    assert record["folders"] == {"nes": "fetched"}
    assert library.read_pending(config) == ["nes"]


def test_reconciliation_expiry_does_not_publish(
    config: library.Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    live = config.gamelist_root / "nes" / "gamelist.xml"
    live.parent.mkdir(parents=True)
    live.write_bytes(b"<gameList />")
    library.write_pending(config, ["nes"])
    now = [0.0]
    monkeypatch.setattr(library.time, "monotonic", lambda: now[0])

    def invoke(_config: library.Config, argv: list[str], *_args: object) -> tuple[int, bytes]:
        (Path(argv[argv.index("-g") + 1]) / "gamelist.xml").write_text("<gameList />")
        return 0, b""

    def expire(*args: object) -> None:
        now[0] = library.PER_FOLDER_SECONDS + 1

    monkeypatch.setattr(library, "_reconcile_gamelist", expire)
    assert library.generate(config, invoke) == 0
    assert live.read_bytes() == b"<gameList />"
    assert json.loads(config.record_path.read_text())["folders"]["nes"] == "generation-failed"


def test_reconciliation_keeps_all_family_fields(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    fields = {
        "favorite": "true",
        "hidden": "true",
        "kidgame": "false",
        "lastplayed": "20260925T120000",
        "playcount": "12",
        "sortname": "Sorted",
        "altemulator": "Custom",
        "completed": "true",
        "broken": "false",
        "controller": "gamepad",
        "collectionsortname": "Collected",
        "hidemetadata": "true",
        "nogamecount": "true",
        "nomultiscrape": "true",
    }
    previous = ET.fromstring("<gameList><game><path>./a.nes</path></game></gameList>")
    old = previous.find("game")
    assert old is not None
    for name, value in fields.items():
        ET.SubElement(old, name).text = value
    candidate = ET.fromstring(
        "<gameList><game><path>./a.nes</path><desc>New metadata</desc>"
        "<favorite>false</favorite></game></gameList>"
    )
    library._reconcile_gamelist(config, "nes", previous, candidate, {".nes"})
    assert len(candidate.findall("game")) == 1
    for name, value in fields.items():
        assert candidate.findtext(f"game/{name}") == value
    assert len(candidate.findall("game/favorite")) == 1
    assert candidate.findtext("game/desc") == "New metadata"


@pytest.mark.parametrize("generated", [None, "Generated"])
def test_regeneration_keeps_the_system_alternative_emulator(
    config: library.Config, generated: str | None
) -> None:
    game(config, "nes", "a.nes")
    live = config.gamelist_root / "nes" / "gamelist.xml"
    live.parent.mkdir(parents=True)
    live.write_text(
        "<gameList><alternativeEmulator><label>Chosen</label></alternativeEmulator>"
        "<game><path>./a.nes</path></game></gameList>"
    )
    library.write_pending(config, ["nes"])
    output = (
        ""
        if generated is None
        else f"<alternativeEmulator><label>{generated}</label></alternativeEmulator>"
    )

    def invoke(_config: library.Config, argv: list[str], *_args: object) -> tuple[int, bytes]:
        (Path(argv[argv.index("-g") + 1]) / "gamelist.xml").write_text(
            f"<gameList>{output}<game><path>./a.nes</path><desc>New</desc></game></gameList>"
        )
        return 0, b""

    assert library.generate(config, invoke) == 0
    root = ET.parse(live).getroot()
    assert [child.tag for child in root] == ["alternativeEmulator", "game"]
    assert root.findtext("alternativeEmulator/label") == (generated or "Chosen")
    assert root.findtext("game/desc") == "New"


def test_generation_creates_missing_parent_and_keeps_appended_pending(
    config: library.Config,
) -> None:
    library.write_pending(config, ["nes"])

    def invoke(
        _config: library.Config, argv: list[str], _claim: int, _limit: float
    ) -> tuple[int, bytes]:
        work = Path(argv[argv.index("-g") + 1])
        assert work.parent == config.gamelist_root / "nes"
        assert not (work / "gamelist.xml").exists()
        (work / "gamelist.xml").write_text(
            "<gameList><game><path>./a.nes</path><name>NEW</name></game></gameList>"
        )
        library.write_pending(config, ["nes", "psx"])
        return 0, b""

    assert library.generate(config, invoke) == 0
    assert (
        config.gamelist_root / "nes" / "gamelist.xml"
    ).read_text() == "<gameList><game><path>./a.nes</path><name>NEW</name></game></gameList>"
    assert library.read_pending(config) == ["psx"]


@pytest.mark.parametrize("status", [0, 1])
def test_stale_work_never_becomes_previous_gamelist_without_live_file(
    config: library.Config, status: int
) -> None:
    library.write_pending(config, ["nes"])
    parent = config.gamelist_root / "nes"
    stale = parent / ".emubox-library-work-old"
    stale.mkdir(parents=True)
    (stale / "gamelist.xml").write_text("TRUNCATED")
    seen: list[bool] = []

    def stub(
        _config: library.Config, argv: list[str], _claim: int, _limit: float
    ) -> tuple[int, bytes]:
        work = Path(argv[argv.index("-g") + 1])
        seen.append((work / "gamelist.xml").exists())
        (work / "gamelist.xml").write_text(
            "<gameList><game><path>./a.nes</path><name>NEW</name></game></gameList>"
            if status == 0
            else "BROKEN"
        )
        return status, b""

    assert library.generate(config, stub) == 0
    assert seen == [False]
    assert not stale.exists()
    assert not list(parent.glob(".emubox-library-work-*"))
    live = parent / "gamelist.xml"
    assert (live.read_text() if live.exists() else None) == (
        "<gameList><game><path>./a.nes</path><name>NEW</name></game></gameList>"
        if status == 0
        else None
    )
    assert json.loads(config.record_path.read_text())["folders"]["nes"] == (
        "generated" if status == 0 else "generation-failed"
    )
    assert library.read_pending(config) == []


def test_cleanup_logs_failure_only_when_pending_work_is_failed(
    config: library.Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    messages: list[str] = []
    monkeypatch.setattr(library, "journal", lambda _config, message: messages.append(message))
    library.atomic_json(config.revision_path, {"nes": "r1"})
    assert library.cleanup(config, {"nes": "r1"}) == 0
    assert messages == []
    library.write_pending(config, ["nes"])
    assert library.cleanup(config, {"nes": "r1"}) == 0
    assert messages == [
        "Generation failed for nes",
        "Generation could not finish with a progress window; frontend starting",
    ]


def test_revision_cleanup_preserves_new_fetch_and_missing_identity(config: library.Config) -> None:
    library.write_pending(config, ["nes", "psx"])
    library.atomic_json(config.revision_path, {"nes": "old", "psx": "old"})
    assert library.capture(config) == (0, {"nes": "old", "psx": "old"})
    library.atomic_json(config.revision_path, {"nes": "new", "psx": "old"})
    assert library.cleanup(config, {"nes": "old", "psx": "old"}) == 0
    assert library.read_pending(config) == ["nes"]
    assert json.loads(config.record_path.read_text())["folders"] == {"psx": "generation-failed"}
    assert library.cleanup(config, {"nes": "new"}) == 0
    assert library.read_pending(config) == []


def test_cleanup_leaves_pending_when_lock_or_record_write_fails(
    config: library.Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    messages: list[str] = []
    monkeypatch.setattr(library, "journal", lambda _config, message: messages.append(message))
    library.write_pending(config, ["nes"])
    library.atomic_json(config.revision_path, {"nes": "r1"})
    before = config.pending_path.read_bytes()
    claim = held_lock(config)
    try:
        assert library.cleanup(config, {"nes": "r1"}) == 1
        assert config.pending_path.read_bytes() == before
    finally:
        os.close(claim)
    assert messages == ["Generation failure cleanup deferred; the library claim was held"]

    original = library.atomic_json

    def fail_record(path: Path, value: object) -> None:
        if path == config.record_path:
            raise PermissionError("read-only records")
        original(path, value)

    monkeypatch.setattr(library, "atomic_json", fail_record)
    assert library.cleanup(config, {"nes": "r1"}) == 1
    assert config.pending_path.read_bytes() == before


def test_capture_reports_pending_without_revision_and_cleanup_retires_it(
    config: library.Config,
) -> None:
    library.write_pending(config, ["nes", "psx"])
    library.atomic_json(config.revision_path, {"psx": "r1"})
    status, batch = library.capture(config)
    assert (status, batch) == (0, {"nes": None, "psx": "r1"})
    assert library.cleanup(config, {"nes": "unknown"}) == 0
    assert library.read_pending(config) == ["nes", "psx"]
    assert library.cleanup(config, batch) == 0
    assert library.read_pending(config) == []
    assert json.loads(config.record_path.read_text())["folders"] == {
        "nes": "generation-failed",
        "psx": "generation-failed",
    }


def test_cleanup_keeps_a_folder_without_captured_revision_once_one_is_written(
    config: library.Config,
) -> None:
    library.write_pending(config, ["nes"])
    status, batch = library.capture(config)
    assert (status, batch) == (0, {"nes": None})
    library.atomic_json(config.revision_path, {"nes": "fetched-since"})
    assert library.cleanup(config, batch) == 0
    assert library.read_pending(config) == ["nes"]
    assert not config.record_path.exists()


def test_capture_cli_prints_null_for_missing_revision(
    config: library.Config, capsys: pytest.CaptureFixture[str]
) -> None:
    library.write_pending(config, ["nes"])
    settings = cli_config(config, config.cache_root.parent / "config.json")
    assert library.generate_main(["--config", str(settings), "capture"]) == 0
    assert json.loads(capsys.readouterr().out) == {"nes": None}


def test_cleanup_preserves_new_different_folder_after_batch_capture(config: library.Config) -> None:
    library.write_pending(config, ["nes"])
    library.atomic_json(config.revision_path, {"nes": "old"})
    assert library.capture(config) == (0, {"nes": "old"})
    library.atomic_json(config.revision_path, {"nes": "old", "psx": "new"})
    library.write_pending(config, ["nes", "psx"])
    assert library.cleanup(config, {"nes": "old"}) == 0
    assert library.read_pending(config) == ["psx"]
    assert json.loads(config.record_path.read_text())["folders"] == {"nes": "generation-failed"}


def test_killed_cleanup_keeps_uncommitted_pending_entry(config: library.Config) -> None:
    library.write_pending(config, ["nes"])
    library.atomic_json(config.revision_path, {"nes": "r1"})
    settings = cli_config(config, config.cache_root.parent / "config.json")
    marker = config.cache_root / "recorded-before-rewrite"
    code = (
        "import library, pathlib, sys, time\n"
        "config=library.Config.read(pathlib.Path(sys.argv[1]))\n"
        "def pause(config, folders):\n"
        " record=library.read_json(config.record_path, {})\n"
        " assert record['folders']['nes'] == 'generation-failed'\n"
        " (config.cache_root/'recorded-before-rewrite').touch()\n"
        " time.sleep(30)\n"
        "library.write_pending=pause\n"
        "library.cleanup(config, {'nes':'r1'})\n"
    )
    environment = dict(os.environ, PYTHONPATH=str(Path(__file__).parent))
    process = subprocess.Popen(
        [sys.executable, "-c", code, str(settings)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=environment,
    )
    try:
        wait_for(marker)
        process.kill()
        process.wait(timeout=3)
        assert library.read_pending(config) == ["nes"]
        assert json.loads(config.record_path.read_text())["folders"]["nes"] == ("generation-failed")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


def test_overall_generation_limit_records_all_unreached_without_invoking_scraper(
    config: library.Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    library.write_pending(config, ["nes", "psx"])
    monkeypatch.setattr(library, "ALL_FOLDERS_SECONDS", 0)
    assert library.generate(config, lambda *args: pytest.fail("unexpected scraper")) == 0
    assert library.read_pending(config) == []
    assert json.loads(config.record_path.read_text())["folders"] == {
        "nes": "generation-failed",
        "psx": "generation-failed",
    }


def test_per_folder_deadline_kills_hung_scraper_without_publishing_work(
    config: library.Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    library.write_pending(config, ["nes"])
    parent = config.gamelist_root / "nes"
    parent.mkdir(parents=True)
    live = parent / "gamelist.xml"
    live.write_text("<gameList><game><path>./a.nes</path><name>OLD</name></game></gameList>")
    scraper = config.cache_root.parent / "hung-scraper"
    scraper.write_text(
        f"#!{sys.executable}\n"
        "import pathlib, sys, time\n"
        "work=pathlib.Path(sys.argv[sys.argv.index('-g')+1])\n"
        "(work/'gamelist.xml').write_text('PARTIAL')\n"
        "time.sleep(30)\n"
    )
    scraper.chmod(0o755)
    monkeypatch.setattr(library, "PER_FOLDER_SECONDS", 0.2)
    start = time.monotonic()
    assert library.generate(replace(config, skyscraper=str(scraper))) == 0
    assert time.monotonic() - start < 10
    assert (
        live.read_text() == "<gameList><game><path>./a.nes</path><name>OLD</name></game></gameList>"
    )
    assert not list(parent.glob(".emubox-library-work-*"))
    assert json.loads(config.record_path.read_text())["folders"] == {"nes": "generation-failed"}
    assert library.read_pending(config) == []


def test_unreadable_pending_does_not_generate_or_claim_skip(
    config: library.Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    original = Path.read_text

    def unreadable(path: Path, encoding: str | None = None, errors: str | None = None) -> str:
        if path == config.pending_path:
            raise PermissionError("pending unavailable")
        return original(path, encoding=encoding, errors=errors)

    monkeypatch.setattr(Path, "read_text", unreadable)
    messages: list[str] = []
    monkeypatch.setattr(library, "journal", lambda _config, message: messages.append(message))
    assert library.generate(config, lambda *args: pytest.fail("unexpected scraper")) == 0
    assert messages == ["Generation could not read or write state: pending unavailable"]
    assert not config.record_path.exists()


def test_pending_folder_without_platform_fails_without_scraper(config: library.Config) -> None:
    library.write_pending(config, ["genesis"])
    assert library.generate(config, lambda *args: pytest.fail("unexpected scraper")) == 0
    assert library.read_pending(config) == []
    assert json.loads(config.record_path.read_text())["folders"] == {"genesis": "generation-failed"}


def test_pending_folder_the_frontend_lists_no_system_for_fails_without_scraper(
    config: library.Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    messages: list[str] = []
    monkeypatch.setattr(library, "journal", lambda _config, message: messages.append(message))
    config.platform_map.write_text(json.dumps({"nes": "nes", "arcade": "mame"}))
    game(config, "arcade", "a.zip")
    library.write_pending(config, ["arcade"])
    assert library.generate(config, lambda *args: pytest.fail("unexpected scraper")) == 0
    assert library.read_pending(config) == []
    assert json.loads(config.record_path.read_text())["folders"] == {"arcade": "generation-failed"}
    assert messages == ["Generation failed for arcade: the frontend lists no system named arcade"]
    assert not (config.gamelist_root / "arcade").exists()


def test_report_counts_extensions_descriptions_and_unknown(config: library.Config) -> None:
    for folder, name in (
        ("psx", "a.cue"),
        ("psx", "a.bin"),
        ("psx", "notes.txt"),
        ("unknown", "x.dat"),
    ):
        game(config, folder, name)
    parent = config.gamelist_root / "psx"
    parent.mkdir(parents=True)
    root = ET.Element("gameList")
    entry = ET.SubElement(root, "game")
    ET.SubElement(entry, "path").text = "./a.cue"
    ET.SubElement(entry, "desc").text = "Description"
    ET.ElementTree(root).write(parent / "gamelist.xml")
    library.write_record(config, "partial", {"psx": "fetch-failed"})
    library.write_pending(config, ["psx"])
    status, output = library.report(config, 2)
    assert status == 0
    assert "psx: 1 ROMs, 1 gamelist entries, 0 unscraped" in output
    assert "unknown: 1 ROMs, 0 gamelist entries, 1 unscraped (unknown system)" in output
    assert "Last run: partial" in output
    assert "Failed folders: psx" in output
    assert "Generation pending: psx" in output


def test_report_keeps_counting_past_a_malformed_gamelist(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    game(config, "psx", "a.cue")
    (config.gamelist_root / "nes").mkdir(parents=True)
    (config.gamelist_root / "nes" / "gamelist.xml").write_text("<gameList><game>")
    status, output = library.report(config, 2)
    assert status == 0
    assert output == (
        "nes: 1 ROMs, gamelist unreadable\n"
        "psx: 1 ROMs, 0 gamelist entries, 1 unscraped\n"
        "No scrape has run\n"
        "Generation pending: none\n"
    )


@pytest.mark.parametrize(
    "damage", ["wrong root", "directory", pytest.param("unreadable", marks=needs_permissions)]
)
def test_report_marks_only_the_damaged_gamelist_unreadable(
    config: library.Config, damage: str
) -> None:
    game(config, "nes", "a.nes")
    game(config, "psx", "a.cue")
    live = config.gamelist_root / "nes" / "gamelist.xml"
    live.parent.mkdir(parents=True)
    if damage == "directory":
        live.mkdir()
    else:
        live.write_text(
            "<wrong><game><path>./a.nes</path><desc>Art</desc></game></wrong>"
            if damage == "wrong root"
            else "<gameList />"
        )
    if damage == "unreadable":
        live.chmod(0)
    status, output = library.report(config, 5)
    assert status == 0
    assert output == (
        "nes: 1 ROMs, gamelist unreadable\n"
        "psx: 1 ROMs, 0 gamelist entries, 1 unscraped\n"
        "No scrape has run\n"
        "Generation pending: none\n"
    )


@pytest.mark.parametrize("record", [[], {"time": "fixed"}, {"result": "complete", "folders": []}])
def test_report_tolerates_malformed_run_record(config: library.Config, record: object) -> None:
    game(config, "nes", "a.nes")
    library.atomic_json(config.record_path, record)
    status, output = library.report(config, 2)
    assert status == 0
    assert "nes: 1 ROMs, 0 gamelist entries, 1 unscraped" in output
    assert "Generation pending: none" in output
    if record == {"time": "fixed"}:
        assert "No completed fetch recorded\n" in output
        assert "No scrape has run" not in output


def test_report_counts_bin_when_bundled_system_lists_it(config: library.Config) -> None:
    game(config, "psx", "a.cue")
    game(config, "psx", "a.bin")
    without_override = replace(config, custom_systems=None)
    status, output = library.report(without_override, 2)
    assert status == 0
    assert "psx: 2 ROMs, 0 gamelist entries, 2 unscraped" in output


def test_report_without_records(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    status, output = library.report(config, 2)
    assert status == 0
    assert "No scrape has run" in output
    assert "nes: 1 ROMs, 0 gamelist entries, 1 unscraped" in output


@pytest.mark.parametrize(
    ("result", "outcome", "description", "expected"),
    [
        (
            "failed",
            "fetch-failed",
            False,
            "nes: 1 ROMs, 0 gamelist entries, 1 unscraped\n"
            "Last run: failed at fixed\nFailed folders: nes\nGeneration pending: none\n",
        ),
        (
            "complete",
            "generated",
            True,
            "nes: 1 ROMs, 1 gamelist entries, 0 unscraped\n"
            "Last run: complete at fixed\nGeneration pending: none\n",
        ),
        (
            "complete",
            "generation-failed",
            False,
            "nes: 1 ROMs, 0 gamelist entries, 1 unscraped\n"
            "Last run: complete at fixed\nFailed folders: nes\nGeneration pending: none\n",
        ),
        (
            "refused",
            "fetch-failed",
            False,
            "nes: 1 ROMs, 0 gamelist entries, 1 unscraped\n"
            "Last run: refused at fixed\nFailed folders: nes\nGeneration pending: none\n",
        ),
        (
            "interrupted",
            "fetched",
            False,
            "nes: 1 ROMs, 0 gamelist entries, 1 unscraped\n"
            "Last run: interrupted at fixed\nGeneration pending: none\n",
        ),
    ],
)
def test_report_exact_record_outcomes(
    config: library.Config, result: str, outcome: str, description: bool, expected: str
) -> None:
    game(config, "nes", "a.nes")
    if description:
        parent = config.gamelist_root / "nes"
        parent.mkdir(parents=True)
        (parent / "gamelist.xml").write_text(
            "<gameList><game><path>./a.nes</path><desc>Art</desc></game></gameList>"
        )
    library.atomic_json(
        config.record_path, {"result": result, "time": "fixed", "folders": {"nes": outcome}}
    )
    assert library.report(config, 2) == (0, expected)


@pytest.mark.parametrize("status", [0, 1])
def test_generation_without_a_run_record_invents_no_run_result(
    config: library.Config, status: int
) -> None:
    game(config, "nes", "a.nes")
    library.write_pending(config, ["nes"])

    def invoke(_config: library.Config, argv: list[str], *_args: object) -> tuple[int, bytes]:
        (Path(argv[argv.index("-g") + 1]) / "gamelist.xml").write_text(
            "<gameList><game><path>./a.nes</path><desc>Art</desc></game></gameList>"
        )
        return status, b""

    assert library.generate(config, invoke) == 0
    outcome = "generated" if status == 0 else "generation-failed"
    assert json.loads(config.record_path.read_text()) == {"folders": {"nes": outcome}}
    code, output = library.report(config, 5)
    assert code == 0
    assert "Last run:" not in output
    assert output.endswith(
        "No completed fetch recorded\n"
        + ("" if status == 0 else "Failed folders: nes\n")
        + "Generation pending: none\n"
    )


def test_report_unmapped_folder_without_failures(config: library.Config) -> None:
    game(config, "genesis", "a.md")
    library.atomic_json(
        config.record_path,
        {"result": "complete", "time": "fixed", "folders": {"genesis": "unmapped"}},
    )
    assert library.report(config, 2) == (
        0,
        "genesis: 1 ROMs, 0 gamelist entries, 1 unscraped (unmapped)\n"
        "Last run: complete at fixed\nGeneration pending: none\n",
    )


def test_report_deadline_covers_discovery_and_keeps_records(config: library.Config) -> None:
    library.write_record(config, "complete", {"nes": "fetched"})
    library.write_pending(config, ["nes"])
    config.bundled_systems.unlink()
    os.mkfifo(config.bundled_systems)
    start = time.monotonic()
    status, output = library.report(config, 0.2)
    assert time.monotonic() - start < 10
    assert status == 1
    assert "Last run: complete" in output
    assert "Generation pending: nes" in output
    assert "Folder counts unavailable" in output
    assert "scan incomplete" in output


def test_report_deadline_keeps_completed_counts_on_blocked_gamelist(
    config: library.Config,
) -> None:
    game(config, "nes", "a.nes")
    game(config, "psx", "a.cue")
    psx_parent = config.gamelist_root / "psx"
    psx_parent.mkdir(parents=True)
    os.mkfifo(psx_parent / "gamelist.xml")
    start = time.monotonic()
    status, output = library.report(config, 0.2)
    assert time.monotonic() - start < 10
    assert status == 1
    assert "nes: 1 ROMs, 0 gamelist entries, 1 unscraped" in output
    assert "psx: counts unavailable" in output
    assert "scan incomplete" in output


def test_report_cli_exits_when_pending_read_blocks_and_keeps_run_record(
    config: library.Config,
) -> None:
    library.write_record(config, "partial", {"nes": "fetch-failed"})
    os.mkfifo(config.pending_path)
    settings = cli_config(config, config.cache_root.parent / "config.json")
    code = (
        "import library, sys\n"
        "original=library.report\n"
        "library.report=lambda source: original(source, 0.2)\n"
        "sys.exit(library.report_main(['--config', sys.argv[1]]))\n"
    )
    environment = dict(os.environ, PYTHONPATH=str(Path(__file__).parent))
    start = time.monotonic()
    result = subprocess.run(
        [sys.executable, "-c", code, str(settings)],
        capture_output=True,
        text=True,
        env=environment,
        timeout=10,
    )
    assert time.monotonic() - start < 10
    assert result.returncode == 1
    assert "Last run: partial" in result.stdout
    assert "Pending state unavailable" in result.stdout
    assert "scan incomplete" in result.stdout


def test_scraper_child_keeps_claim_after_wrapper_is_killed(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    game(config, "psx", "a.cue")
    ready = config.cache_root / "child-ready"
    pid_file = config.cache_root / "child-pid"
    release = config.cache_root / "release"
    scraper = config.cache_root.parent / "scraper"
    scraper.write_text(
        f"#!{sys.executable}\n"
        "import os, pathlib, sys, time\n"
        "cache=pathlib.Path(sys.argv[sys.argv.index('-d')+1])\n"
        "root=cache.parent\n"
        "(root/'child-pid').write_text(str(os.getpid()))\n"
        "if cache.name == 'psx' and not (root/'release').exists():\n"
        " (root/'child-ready').touch()\n"
        " while True: time.sleep(1)\n"
    )
    scraper.chmod(0o755)
    settings = cli_config(
        replace(config, skyscraper=str(scraper)), config.cache_root.parent / "config.json"
    )
    command = [
        sys.executable,
        str(Path(__file__).with_name("emubox_scrape.py")),
        "--config",
        str(settings),
    ]
    first = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_for(ready)
        assert library.read_pending(config) == ["nes"]
        assert "nes" in json.loads(config.revision_path.read_text())
        os.kill(first.pid, signal.SIGKILL)
        first.wait(timeout=3)
        second = subprocess.run(command, capture_output=True, text=True, timeout=3)
        assert second.returncode == 1
        assert "in progress" in second.stderr
    finally:
        if pid_file.exists():
            os.kill(int(pid_file.read_text()), signal.SIGKILL)
        if first.poll() is None:
            first.kill()
        first.wait(timeout=3)
    release.touch()
    third = subprocess.run(command, capture_output=True, text=True, timeout=5)
    assert third.returncode == 0, third.stderr
    assert library.read_pending(config) == ["nes", "psx"]


def test_killed_generation_keeps_live_gamelist_and_pending(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    library.write_pending(config, ["nes"])
    parent = config.gamelist_root / "nes"
    parent.mkdir(parents=True)
    live = parent / "gamelist.xml"
    live.write_text("<gameList><game><path>./a.nes</path><name>OLD</name></game></gameList>")
    ready = config.cache_root / "writing"
    pid_file = config.cache_root / "writer-pid"
    release = config.cache_root / "release"
    scraper = config.cache_root.parent / "writer"
    scraper.write_text(
        f"#!{sys.executable}\n"
        "import os, pathlib, sys, time\n"
        "argv=sys.argv\n"
        "root=pathlib.Path(argv[argv.index('-d')+1]).parent\n"
        "work=pathlib.Path(argv[argv.index('-g')+1])\n"
        "(root/'writer-pid').write_text(str(os.getpid()))\n"
        "if not (root/'release').exists():\n"
        " (work/'gamelist.xml').write_text('PARTIAL')\n"
        " (root/'writing').touch()\n"
        " while True: time.sleep(1)\n"
        "(work/'gamelist.xml').write_text('<gameList><game><path>./a.nes</path><name>NEW</name></game></gameList>')\n"
    )
    scraper.chmod(0o755)
    settings = cli_config(
        replace(config, skyscraper=str(scraper)), config.cache_root.parent / "config.json"
    )
    command = [
        sys.executable,
        str(Path(__file__).with_name("emubox_library_generate.py")),
        "--config",
        str(settings),
    ]
    first = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_for(ready)
        os.kill(first.pid, signal.SIGKILL)
        first.wait(timeout=3)
        assert (
            live.read_text()
            == "<gameList><game><path>./a.nes</path><name>OLD</name></game></gameList>"
        )
        assert library.read_pending(config) == ["nes"]
    finally:
        if pid_file.exists():
            os.kill(int(pid_file.read_text()), signal.SIGKILL)
        if first.poll() is None:
            first.kill()
        first.wait(timeout=3)
    release.touch()
    second = subprocess.run(command, capture_output=True, text=True, timeout=5)
    assert second.returncode == 0, second.stderr
    assert (
        live.read_text() == "<gameList><game><path>./a.nes</path><name>NEW</name></game></gameList>"
    )
    assert library.read_pending(config) == []
    assert not list(parent.glob(".emubox-library-work-*"))


@pytest.mark.parametrize("ending_signal", [signal.SIGTERM, signal.SIGHUP])
def test_signal_ends_scraper_process_group_and_releases_claim(
    config: library.Config, ending_signal: int
) -> None:
    game(config, "nes", "a.nes")
    ready = config.cache_root / "running"
    pid_file = config.cache_root / "pid"
    scraper = config.cache_root.parent / "sleeper"
    scraper.write_text(
        f"#!{sys.executable}\n"
        "import os, pathlib, sys, time\n"
        "root=pathlib.Path(sys.argv[sys.argv.index('-d')+1]).parent\n"
        "(root/'pid').write_text(str(os.getpid()))\n"
        "(root/'running').touch()\n"
        "while True: time.sleep(1)\n"
    )
    scraper.chmod(0o755)
    settings = cli_config(
        replace(config, skyscraper=str(scraper)), config.cache_root.parent / "config.json"
    )
    command = [
        sys.executable,
        str(Path(__file__).with_name("emubox_scrape.py")),
        "--config",
        str(settings),
    ]
    wrapper = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    child_pid = None
    try:
        wait_for(ready)
        child_pid = int(pid_file.read_text())
        os.kill(wrapper.pid, ending_signal)
        assert wrapper.wait(timeout=5) != 0
        with pytest.raises(ProcessLookupError):
            os.kill(child_pid, 0)
        claim = library.lock(config)
        assert claim is not None
        os.close(claim)
    finally:
        if wrapper.poll() is None:
            wrapper.kill()
            wrapper.wait()
        if child_pid is not None:
            with contextlib.suppress(ProcessLookupError):
                os.kill(child_pid, signal.SIGKILL)


@pytest.mark.parametrize("ending_signal", [signal.SIGTERM, signal.SIGHUP])
def test_signal_stops_generation_and_leaves_work_pending(
    config: library.Config, ending_signal: int
) -> None:
    game(config, "nes", "a.nes")
    game(config, "psx", "a.cue")
    library.write_pending(config, ["nes", "psx"])
    parent = config.gamelist_root / "nes"
    parent.mkdir(parents=True)
    live = parent / "gamelist.xml"
    live.write_text("<gameList><game><path>./a.nes</path><name>OLD</name></game></gameList>")
    ready = config.cache_root / "writing"
    pid_file = config.cache_root / "writer-pid"
    invoked = config.cache_root / "invoked"
    scraper = config.cache_root.parent / "writer"
    scraper.write_text(
        f"#!{sys.executable}\n"
        "import os, pathlib, sys, time\n"
        "argv=sys.argv\n"
        "root=pathlib.Path(argv[argv.index('-d')+1]).parent\n"
        "work=pathlib.Path(argv[argv.index('-g')+1])\n"
        "with (root/'invoked').open('a') as log: log.write(argv[argv.index('-p')+1]+'\\n')\n"
        "(root/'writer-pid').write_text(str(os.getpid()))\n"
        "(work/'gamelist.xml').write_text('PARTIAL')\n"
        "(root/'writing').touch()\n"
        "while True: time.sleep(1)\n"
    )
    scraper.chmod(0o755)
    settings = cli_config(
        replace(config, skyscraper=str(scraper)), config.cache_root.parent / "config.json"
    )
    command = [
        sys.executable,
        str(Path(__file__).with_name("emubox_library_generate.py")),
        "--config",
        str(settings),
    ]
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    child_pid = None
    try:
        wait_for(ready)
        child_pid = int(pid_file.read_text())
        os.kill(process.pid, ending_signal)
        assert process.wait(timeout=5) == 128 + ending_signal
        assert process.stderr is not None
        assert b"Traceback" not in process.stderr.read()
        with pytest.raises(ProcessLookupError):
            os.kill(child_pid, 0)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        if child_pid is not None:
            with contextlib.suppress(ProcessLookupError):
                os.kill(child_pid, signal.SIGKILL)
    assert invoked.read_text() == "nes\n"
    assert (
        live.read_text() == "<gameList><game><path>./a.nes</path><name>OLD</name></game></gameList>"
    )
    assert not list(parent.glob(".emubox-library-work-*"))
    assert library.read_pending(config) == ["nes", "psx"]
    assert not config.record_path.exists()


def test_published_gamelist_survives_kill_before_pending_rewrite(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    library.write_pending(config, ["nes"])
    parent = config.gamelist_root / "nes"
    parent.mkdir(parents=True)
    live = parent / "gamelist.xml"
    live.write_text("<gameList><game><path>./a.nes</path><name>OLD</name></game></gameList>")
    marker = config.cache_root / "renamed"
    scraper = config.cache_root.parent / "writer"
    scraper.write_text(
        f"#!{sys.executable}\n"
        "import pathlib, sys\n"
        "work=pathlib.Path(sys.argv[sys.argv.index('-g')+1])\n"
        "(work/'gamelist.xml').write_text('<gameList><game><path>./a.nes</path><name>NEW</name></game></gameList>')\n"
    )
    scraper.chmod(0o755)
    settings = cli_config(
        replace(config, skyscraper=str(scraper)), config.cache_root.parent / "config.json"
    )
    code = (
        "import library, pathlib, sys, time\n"
        "config=library.Config.read(pathlib.Path(sys.argv[1]))\n"
        "original=library.write_pending\n"
        "def pause(config, folders):\n"
        " live = config.gamelist_root/'nes'/'gamelist.xml'\n"
        " assert library.ET.parse(live).findtext('game/name') == 'NEW'\n"
        " (config.cache_root/'renamed').touch()\n"
        " time.sleep(30)\n"
        " original(config, folders)\n"
        "library.write_pending=pause\n"
        "library.generate(config)\n"
    )
    environment = dict(os.environ, PYTHONPATH=str(Path(__file__).parent))
    wrapper = subprocess.Popen(
        [sys.executable, "-c", code, str(settings)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=environment,
    )
    try:
        wait_for(marker)
        wrapper.kill()
        wrapper.wait(timeout=3)
        assert (
            live.read_text()
            == "<gameList><game><path>./a.nes</path><name>NEW</name></game></gameList>"
        )
        assert library.read_pending(config) == ["nes"]
    finally:
        if wrapper.poll() is None:
            wrapper.kill()
            wrapper.wait()


def test_deadline_still_applies_after_scraper_closes_output(config: library.Config) -> None:
    scraper = config.cache_root.parent / "silent-hang"
    scraper.write_text(
        f"#!{sys.executable}\nimport os, time\nos.close(1)\nos.close(2)\ntime.sleep(30)\n"
    )
    scraper.chmod(0o755)
    config = replace(config, skyscraper=str(scraper))
    claim = held_lock(config)
    try:
        start = time.monotonic()
        status, output = library.run_skyscraper(config, [], claim, start + 0.2)
        assert time.monotonic() - start < 10
        assert status == 124
        assert output == b""
    finally:
        os.close(claim)


def test_termination_handler_raises_once_per_run() -> None:
    library._arm_interrupt()
    with pytest.raises(library.Interrupted):
        library._interrupt(signal.SIGTERM, None)
    assert library._interrupt(signal.SIGHUP, None) is None
    assert library._interrupt(signal.SIGINT, None) is None


def test_each_scraper_run_rearms_the_termination_handler(config: library.Config) -> None:
    scraper = config.cache_root.parent / "self-terminating"
    scraper.write_text(
        f"#!{sys.executable}\n"
        "import os, signal, time\n"
        "os.kill(os.getppid(), signal.SIGTERM)\n"
        "time.sleep(30)\n"
    )
    scraper.chmod(0o755)
    config = replace(config, skyscraper=str(scraper))
    claim = held_lock(config)
    try:
        for _ in range(2):
            start = time.monotonic()
            with pytest.raises(library.Interrupted):
                library.run_skyscraper(config, [], claim, start + 20)
            assert time.monotonic() - start < 10
    finally:
        os.close(claim)


def test_descendant_is_ended_after_scraper_leader_exits(config: library.Config) -> None:
    marker = config.cache_root.parent / "descendant"
    scraper = config.cache_root.parent / "forking-scraper"
    scraper.write_text(
        f"#!{sys.executable}\n"
        "import os, pathlib, time\n"
        "child=os.fork()\n"
        "if child:\n"
        f" pathlib.Path({str(marker)!r}).write_text(str(child))\n"
        " os._exit(0)\n"
        "os.close(1)\n"
        "os.close(2)\n"
        "time.sleep(30)\n"
    )
    scraper.chmod(0o755)
    config = replace(config, skyscraper=str(scraper))
    claim = held_lock(config)
    try:
        status, _ = library.run_skyscraper(config, [], claim, time.monotonic() + 2)
        assert status == 0
        wait_for(marker)
    finally:
        os.close(claim)
    # Signal delivery to a surviving descendant and descriptor closure are
    # asynchronous; the wrapper must still end that process promptly.
    deadline = time.monotonic() + 2
    new_claim = library.lock(config)
    while new_claim is None and time.monotonic() < deadline:
        time.sleep(0.02)
        new_claim = library.lock(config)
    assert new_claim is not None
    os.close(new_claim)


BAD_STATE = ["{", "[]"]


@pytest.mark.parametrize("content", BAD_STATE)
def test_generation_drains_pending_past_a_malformed_run_record(
    config: library.Config, content: str
) -> None:
    library.write_pending(config, ["nes"])
    config.record_path.write_text(content)

    def success(
        _config: library.Config, argv: list[str], _claim: int, _limit: float
    ) -> tuple[int, bytes]:
        (Path(argv[argv.index("-g") + 1]) / "gamelist.xml").write_text(
            "<gameList><game><path>./a.nes</path><name>NEW</name></game></gameList>"
        )
        return 0, b""

    assert library.generate(config, success) == 0
    assert library.read_pending(config) == []
    assert json.loads(config.record_path.read_text())["folders"] == {"nes": "generated"}


@pytest.mark.parametrize("content", BAD_STATE)
def test_cleanup_drains_pending_past_a_malformed_run_record(
    config: library.Config, content: str
) -> None:
    library.write_pending(config, ["nes"])
    library.atomic_json(config.revision_path, {"nes": "r1"})
    config.record_path.write_text(content)
    assert library.cleanup(config, {"nes": "r1"}) == 0
    assert library.read_pending(config) == []
    assert json.loads(config.record_path.read_text())["folders"] == {"nes": "generation-failed"}


@pytest.mark.parametrize("content", BAD_STATE)
def test_malformed_revisions_read_as_missing_identities(
    config: library.Config, content: str
) -> None:
    library.write_pending(config, ["nes"])
    config.revision_path.write_text(content)
    assert library.capture(config) == (0, {"nes": None})
    assert library.cleanup(config, {"nes": "r1"}) == 0
    assert library.read_pending(config) == ["nes"]


@pytest.mark.parametrize("content", BAD_STATE)
def test_fetch_replaces_malformed_revisions_and_records_the_run(
    config: library.Config, content: str
) -> None:
    game(config, "nes", "a.nes")
    config.revision_path.parent.mkdir(parents=True)
    config.revision_path.write_text(content)
    assert library.scrape(config, lambda *args: (0, b"")) == 0
    assert set(json.loads(config.revision_path.read_text())) == {"nes"}
    assert library.read_pending(config) == ["nes"]
    assert json.loads(config.record_path.read_text())["result"] == "complete"


@pytest.mark.parametrize("content", BAD_STATE)
def test_refusal_replaces_a_malformed_run_record(config: library.Config, content: str) -> None:
    config.record_path.parent.mkdir(parents=True)
    config.record_path.write_text(content)
    config.scraper_config.unlink()
    assert library.scrape(config, lambda *args: pytest.fail("unexpected scraper")) == 1
    record = json.loads(config.record_path.read_text())
    assert (record["result"], record["folders"]) == ("refused", {})


@pytest.mark.parametrize("ending_signal", [signal.SIGTERM, signal.SIGHUP])
def test_signalled_fetch_records_interrupted_and_keeps_finished_folders_pending(
    config: library.Config, ending_signal: int
) -> None:
    game(config, "nes", "a.nes")
    game(config, "psx", "a.cue")
    library.write_record(
        config, "complete", {"nes": "fetch-failed", "psx": "generated", "gone": "fetched"}
    )
    ready = config.cache_root / "running"
    scraper = config.cache_root.parent / "sleeper"
    scraper.write_text(
        f"#!{sys.executable}\n"
        "import pathlib, sys, time\n"
        "cache=pathlib.Path(sys.argv[sys.argv.index('-d')+1])\n"
        "if cache.name == 'psx':\n"
        " (cache.parent/'running').touch()\n"
        " while True: time.sleep(1)\n"
    )
    scraper.chmod(0o755)
    settings = cli_config(
        replace(config, skyscraper=str(scraper)), config.cache_root.parent / "config.json"
    )
    command = [
        sys.executable,
        str(Path(__file__).with_name("emubox_scrape.py")),
        "--config",
        str(settings),
    ]
    wrapper = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_for(ready)
        os.kill(wrapper.pid, ending_signal)
        assert wrapper.wait(timeout=5) == 128 + ending_signal
    finally:
        if wrapper.poll() is None:
            wrapper.kill()
            wrapper.wait()
    assert library.read_pending(config) == ["nes"]
    assert set(json.loads(config.revision_path.read_text())) == {"nes"}
    record = json.loads(config.record_path.read_text())
    assert record["result"] == "interrupted"
    assert record["folders"] == {"nes": "fetched", "psx": "generated"}
    log = config.log_path.read_bytes()
    assert b"Fetching nes" in log and b"Fetching psx" in log
    status, output = library.report(config, 5)
    assert f"Last run: interrupted at {record['time']}" in output


@needs_permissions
def test_unlistable_folder_fails_alone_and_the_run_records(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    game(config, "psx", "a.cue")
    seen: list[str] = []

    def invoke(_config: library.Config, argv: list[str], _claim: int) -> tuple[int, bytes]:
        seen.append(argv[argv.index("-p") + 1])
        return 0, b""

    (config.rom_root / "psx").chmod(0)
    try:
        assert library.scrape(config, invoke) == 1
    finally:
        (config.rom_root / "psx").chmod(0o755)
    assert seen == ["nes"]
    record = json.loads(config.record_path.read_text())
    assert record["result"] == "partial"
    assert record["folders"] == {"nes": "fetched", "psx": "fetch-failed"}
    assert library.read_pending(config) == ["nes"]


@needs_permissions
def test_unlistable_folder_keeps_its_unmapped_or_unknown_classification(
    config: library.Config,
) -> None:
    for folder, name in (("nes", "a.nes"), ("genesis", "a.md"), ("mystery", "a.bin")):
        game(config, folder, name)
    for folder in ("genesis", "mystery"):
        (config.rom_root / folder).chmod(0)
    try:
        assert library.scrape(config, lambda *_args: (0, b"")) == 0
    finally:
        for folder in ("genesis", "mystery"):
            (config.rom_root / folder).chmod(0o755)
    record = json.loads(config.record_path.read_text())
    assert record["result"] == "complete"
    assert record["folders"] == {"genesis": "unmapped", "nes": "fetched"}


def test_scraper_that_cannot_start_fails_one_folder(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    game(config, "psx", "a.cue")

    def invoke(_config: library.Config, argv: list[str], _claim: int) -> tuple[int, bytes]:
        if "psx" in argv:
            raise PermissionError("not executable")
        return 0, b""

    assert library.scrape(config, invoke) == 1
    record = json.loads(config.record_path.read_text())
    assert record["folders"] == {"nes": "fetched", "psx": "fetch-failed"}
    assert b"not executable" in config.log_path.read_bytes()


def test_fetch_vector_is_exactly_the_cache_only_command(config: library.Config) -> None:
    assert library.fetch_vector(config, "nes", "nes", {".nes"}) == [
        "-p", "nes", "-s", "screenscraper", "-c", str(config.scraper_config),
        "-i", str(config.rom_root / "nes"), "-d", str(config.cache_root / "nes"),
        "--addext", ".nes",
        "--flags", "unattend,onlymissing,videos,manuals",
    ]  # fmt: skip


def test_fetch_uses_the_mapped_platform_with_folder_named_paths(config: library.Config) -> None:
    mapping = config.platform_map
    mapping.write_text(json.dumps({"genesis": "megadrive"}))
    game(config, "genesis", "a.md")
    seen: list[list[str]] = []

    def invoke(_config: library.Config, argv: list[str], _claim: int) -> tuple[int, bytes]:
        seen.append(argv)
        return 0, b""

    assert library.scrape(config, invoke) == 0
    (argv,) = seen
    assert argv[argv.index("-p") + 1] == "megadrive"
    assert argv[argv.index("-i") + 1] == str(config.rom_root / "genesis")
    assert argv[argv.index("-d") + 1] == str(config.cache_root / "genesis")
    assert json.loads(config.record_path.read_text())["folders"] == {"genesis": "fetched"}
    assert library.read_pending(config) == ["genesis"]


def test_empty_and_sidecar_only_folders_are_never_visited(config: library.Config) -> None:
    config.bundled_systems.write_text(
        "<systemList><system><name>nes</name><extension>.nes</extension></system>"
        "<system><name>snes</name><extension>.sfc</extension></system>"
        "<system><name>gba</name><extension>.gba</extension></system></systemList>"
    )
    config.platform_map.write_text(json.dumps({"nes": "nes", "snes": "snes", "gba": "gba"}))
    game(config, "nes", "a.nes")
    (config.rom_root / "snes").mkdir()
    game(config, "gba", "notes.txt")
    seen: list[str] = []

    def invoke(_config: library.Config, argv: list[str], _claim: int) -> tuple[int, bytes]:
        seen.append(argv[argv.index("-p") + 1])
        return 0, b""

    assert library.scrape(config, invoke) == 0
    assert seen == ["nes"]
    assert json.loads(config.record_path.read_text())["folders"] == {"nes": "fetched"}


def test_refused_second_run_leaves_the_first_to_record_its_result(
    config: library.Config,
) -> None:
    game(config, "nes", "a.nes")
    game(config, "psx", "a.cue")
    ready = config.cache_root.parent / "child-ready"
    release = config.cache_root.parent / "release"
    scraper = config.cache_root.parent / "scraper"
    scraper.write_text(
        f"#!{sys.executable}\n"
        "import pathlib, sys, time\n"
        "cache=pathlib.Path(sys.argv[sys.argv.index('-d')+1])\n"
        "root=cache.parent.parent\n"
        "if cache.name == 'psx':\n"
        " (root/'child-ready').touch()\n"
        " while not (root/'release').exists(): time.sleep(0.05)\n"
    )
    scraper.chmod(0o755)
    settings = cli_config(
        replace(config, skyscraper=str(scraper)), config.cache_root.parent / "config.json"
    )
    command = [
        sys.executable,
        str(Path(__file__).with_name("emubox_scrape.py")),
        "--config",
        str(settings),
    ]
    first = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_for(ready)
        second = subprocess.run(command, capture_output=True, text=True, timeout=5)
        assert second.returncode == 1
        assert "in progress" in second.stderr
        release.touch()
        assert first.wait(timeout=10) == 0
    finally:
        release.touch()
        if first.poll() is None:
            first.kill()
            first.wait(timeout=3)
    record = json.loads(config.record_path.read_text())
    assert record["result"] == "complete"
    assert record["folders"] == {"nes": "fetched", "psx": "fetched"}


def test_nothing_pending_generates_nothing(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    live = config.gamelist_root / "nes" / "gamelist.xml"
    live.parent.mkdir(parents=True)
    live.write_text("<gameList />")
    before = {path: path.read_bytes() for path in config.gamelist_root.rglob("*") if path.is_file()}
    assert library.capture(config) == (0, {})
    assert library.generate(config, lambda *args: pytest.fail("unexpected scraper")) == 0
    after = {path: path.read_bytes() for path in config.gamelist_root.rglob("*") if path.is_file()}
    assert after == before


def test_generation_prints_a_heading_per_folder(
    config: library.Config, capsys: pytest.CaptureFixture[str]
) -> None:
    game(config, "nes", "a.nes")
    library.write_pending(config, ["nes"])
    assert library.generate(config, lambda *args: (1, b"")) == 0
    assert "Generating nes" in capsys.readouterr().out


def test_journal_never_raises_when_systemd_cat_is_missing_or_hangs(
    config: library.Config,
) -> None:
    library.journal(replace(config, systemd_cat="/nonexistent/systemd-cat"), "message")
    hang = config.cache_root.parent / "hang"
    hang.write_text("#!/bin/sh\nexec sleep 30\n")
    hang.chmod(0o755)
    started = time.monotonic()
    library.journal(replace(config, systemd_cat=str(hang)), "message")
    assert time.monotonic() - started < 10


def test_report_matches_gamelist_entries_by_relative_path(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    game(config, "nes/sub", "a.nes")
    live = config.gamelist_root / "nes" / "gamelist.xml"
    live.parent.mkdir(parents=True)
    live.write_text("<gameList><game><path>./sub/a.nes</path><desc>Nested</desc></game></gameList>")
    status, output = library.report(config, 5)
    assert status == 0
    assert "nes: 1 ROMs, 1 gamelist entries, 1 unscraped" in output
    live.write_text(
        f"<gameList><game><path>{config.rom_root / 'nes' / 'a.nes'}</path>"
        "<desc>Top</desc></game></gameList>"
    )
    assert "nes: 1 ROMs, 1 gamelist entries, 0 unscraped" in library.report(config, 5)[1]


@pytest.mark.parametrize(
    "damage", ["unparseable", pytest.param("unreadable", marks=needs_permissions)]
)
def test_report_keeps_counting_past_a_damaged_run_record(
    config: library.Config, damage: str
) -> None:
    game(config, "nes", "a.nes")
    library.write_pending(config, ["nes"])
    config.record_path.write_text("{bad")
    if damage == "unreadable":
        config.record_path.chmod(0)
    status, output = library.report(config, 5)
    assert "Run record unavailable" in output
    assert "Generation pending: nes" in output
    assert "nes: 1 ROMs, 0 gamelist entries, 1 unscraped" in output
    assert status == 0


@needs_permissions
def test_report_keeps_counting_past_an_unreadable_pending_file(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    library.write_pending(config, ["nes"])
    config.pending_path.chmod(0)
    status, output = library.report(config, 5)
    assert "Pending state unavailable" in output
    assert "nes: 1 ROMs, 0 gamelist entries, 1 unscraped" in output
    assert status == 0


@needs_permissions
def test_report_marks_an_unlistable_folder_and_counts_the_rest(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    game(config, "psx", "a.cue")
    (config.rom_root / "psx").chmod(0)
    try:
        status, output = library.report(config, 5)
    finally:
        (config.rom_root / "psx").chmod(0o755)
    assert "psx: counts unavailable" in output
    assert "nes: 1 ROMs, 0 gamelist entries, 1 unscraped" in output
    assert status == 1


@pytest.mark.parametrize("command", ["scrape", "generate", "capture", "cleanup"])
def test_taking_the_claim_removes_stale_state_temporaries_only(
    config: library.Config, command: str
) -> None:
    config.cache_root.mkdir(parents=True)
    stale = [".pending.a1b2c3d4", ".revisions.json.x_9y8z7w", ".last-run.json.abcdefgh"]
    kept = [".pending.short", "pending.a1b2c3d4", ".other.a1b2c3d4", ".last-run.log.a1b2c3d4e"]
    for name in stale + kept:
        (config.cache_root / name).write_text("partial")
    run: dict[str, Callable[[], object]] = {
        "scrape": lambda: library.scrape(config, lambda *_args: (0, b"")),
        "generate": lambda: library.generate(config),
        "capture": lambda: library.capture(config),
        "cleanup": lambda: library.cleanup(config, {}),
    }
    run[command]()
    for name in stale:
        assert not (config.cache_root / name).exists(), name
    for name in kept:
        assert (config.cache_root / name).exists(), name


@pytest.mark.parametrize("content", [None, "{not json", "[]", "{}"])
@pytest.mark.parametrize(
    "arguments",
    [("scrape", []), ("generate", []), ("generate", ["capture"]), ("generate", ["cleanup"])],
)
def test_entry_points_name_an_unusable_config_in_one_line(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    content: str | None,
    arguments: tuple[str, list[str]],
) -> None:
    path = tmp_path / "library.json"
    if content is not None:
        path.write_text(content)
    command, rest = arguments
    main = library.scrape_main if command == "scrape" else library.generate_main
    assert main(["--config", str(path), *rest]) == 1
    error = capsys.readouterr().err
    assert error.count("\n") == 1 and str(path) in error, error


def test_report_names_an_unusable_config_without_a_traceback(tmp_path: Path) -> None:
    path = tmp_path / "missing.json"
    result = subprocess.run(
        [
            sys.executable,
            str(Path(__file__).with_name("emubox_library_report.py")),
            "--config",
            str(path),
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 1
    assert "Traceback" not in result.stderr + result.stdout
    assert str(path) in result.stdout


def test_scrape_names_an_unparseable_systems_document_in_one_line(
    config: library.Config, capsys: pytest.CaptureFixture[str]
) -> None:
    game(config, "nes", "a.nes")
    config.bundled_systems.write_text("<systemList><system>")
    settings = cli_config(config, config.cache_root.parent / "config.json")
    assert library.scrape_main(["--config", str(settings)]) == 1
    error = capsys.readouterr().err
    assert error.count("\n") == 1 and str(config.bundled_systems) in error, error


def test_generation_survives_an_unparseable_systems_document(
    config: library.Config, capsys: pytest.CaptureFixture[str]
) -> None:
    game(config, "nes", "a.nes")
    library.write_pending(config, ["nes"])
    config.bundled_systems.write_text("<systemList><system>")
    settings = cli_config(config, config.cache_root.parent / "config.json")
    assert library.generate_main(["--config", str(settings)]) == 0
    assert "Traceback" not in capsys.readouterr().err
    assert json.loads(config.record_path.read_text())["folders"] == {"nes": "generation-failed"}
    assert library.read_pending(config) == []


def test_scrape_names_a_failed_priority_change_in_one_line(
    config: library.Config, capsys: pytest.CaptureFixture[str], monkeypatch: pytest.MonkeyPatch
) -> None:
    game(config, "nes", "a.nes")
    monkeypatch.setattr(library, "IONICE", shutil.which("false"))
    settings = cli_config(config, config.cache_root.parent / "config.json")
    assert library.scrape_main(["--config", str(settings)]) == 1
    error = capsys.readouterr().err
    assert error.count("\n") == 1 and "priority" in error, error
    assert library.read_pending(config) == []


def scrape_signalled_at(
    config: library.Config,
    line: str,
    prelude: str = "",
    *extra: str,
    number: int = signal.SIGTERM,
) -> int:
    """Run emubox-scrape's entry point, sending itself `number` as it shows `line`."""
    scraper = config.cache_root.parent / "quick-scraper"
    scraper.write_text("#!/bin/sh\nexit 0\n")
    scraper.chmod(0o755)
    settings = cli_config(
        replace(config, skyscraper=str(scraper)), config.cache_root.parent / "config.json"
    )
    code = (
        "import library, os, signal, sys\n"
        "show=library.show\n"
        "def signalled(line):\n"
        f" if line == {line!r}:\n"
        f"  os.kill(os.getpid(), {int(number)})\n"
        " return show(line)\n"
        "library.show=signalled\n"
        + prelude
        + "sys.exit(library.scrape_main(['--config', sys.argv[1]]))\n"
    )
    environment = dict(os.environ, PYTHONPATH=str(Path(__file__).parent))
    result = subprocess.run(
        [sys.executable, "-c", code, str(settings), *extra],
        capture_output=True,
        env=environment,
        timeout=30,
    )
    return result.returncode


@pytest.mark.parametrize("number", [signal.SIGTERM, signal.SIGINT, signal.SIGHUP])
def test_signal_outside_the_scraper_records_interrupted(
    config: library.Config, number: int
) -> None:
    game(config, "nes", "a.nes")
    game(config, "psx", "a.cue")
    library.write_record(config, "complete", {"psx": "generated"})
    assert scrape_signalled_at(config, "Fetching psx", number=number) == 128 + number
    record = json.loads(config.record_path.read_text())
    assert record["result"] == "interrupted"
    assert record["folders"] == {"nes": "fetched", "psx": "generated"}
    assert library.read_pending(config) == ["nes"]


def test_interruption_keeps_its_status_when_the_record_cannot_be_written(
    config: library.Config,
) -> None:
    game(config, "nes", "a.nes")
    library.write_record(config, "complete", {"nes": "generated"})
    before = config.record_path.read_bytes()
    prelude = "def fail(path, content):\n raise PermissionError(path)\nlibrary.atomic_write=fail\n"
    assert scrape_signalled_at(config, "Fetching nes", prelude) == 128 + signal.SIGTERM
    assert config.record_path.read_bytes() == before


def test_interrupted_record_is_written_when_the_log_cannot_be(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    game(config, "psx", "a.cue")
    prelude = (
        "real=library.atomic_write\n"
        "def fail_log(path, content):\n"
        " if path.name == 'last-run.log':\n"
        "  raise PermissionError(path)\n"
        " real(path, content)\n"
        "library.atomic_write=fail_log\n"
    )
    assert scrape_signalled_at(config, "Fetching psx", prelude) == 128 + signal.SIGTERM
    record = json.loads(config.record_path.read_text())
    assert record["result"] == "interrupted"
    assert record["folders"] == {"nes": "fetched"}
    assert not config.log_path.exists()


def test_linked_rom_counts_and_broken_or_directory_links_do_not(config: library.Config) -> None:
    elsewhere = config.rom_root.parent / "elsewhere"
    elsewhere.mkdir()
    (elsewhere / "linked.nes").write_text("ROM")
    (elsewhere / "folder.nes").mkdir()
    nes = config.rom_root / "nes"
    nes.mkdir(parents=True)
    (nes / "linked.nes").symlink_to(elsewhere / "linked.nes")
    (nes / "broken.nes").symlink_to(elsewhere / "missing.nes")
    (nes / "directory.nes").symlink_to(elsewhere / "folder.nes")
    (nes / "loop.nes").symlink_to("loop.nes")
    psx = config.rom_root / "psx"
    psx.mkdir()
    (psx / "broken.cue").symlink_to(elsewhere / "missing.cue")
    # A directory named for no known system takes any regular file, linked or not.
    mystery = config.rom_root / "mystery"
    mystery.mkdir()
    (mystery / "linked.bin").symlink_to(elsewhere / "linked.nes")
    (mystery / "loop.bin").symlink_to("loop.bin")
    folders = library.discover(config, library.system_extensions(config))
    assert folders == {"mystery": [mystery / "linked.bin"], "nes": [nes / "linked.nes"]}
    status, output = library.report(config, 5)
    assert "nes: 1 ROMs, 0 gamelist entries, 1 unscraped" in output
    assert "mystery: 1 ROMs, 0 gamelist entries, 1 unscraped (unknown system)" in output
    assert "psx" not in output


def test_linked_rom_the_scraper_omits_gets_a_minimal_entry(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    (config.rom_root / "nes" / "alias.nes").symlink_to("a.nes")
    library.write_pending(config, ["nes"])

    def invoke(_config: library.Config, argv: list[str], *_args: object) -> tuple[int, bytes]:
        (Path(argv[argv.index("-g") + 1]) / "gamelist.xml").write_text(
            "<gameList><game><path>./a.nes</path><desc>A</desc></game></gameList>"
        )
        return 0, b""

    assert library.generate(config, invoke) == 0
    live = ET.parse(config.gamelist_root / "nes" / "gamelist.xml").getroot()
    assert [game.findtext("path") for game in live.findall("game")] == ["./a.nes", "./alias.nes"]


def test_generation_parses_the_systems_documents_once_per_run(
    config: library.Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    game(config, "nes", "a.nes")
    game(config, "psx", "a.cue")
    library.write_pending(config, ["nes", "psx"])
    parse = library.system_extensions
    calls: list[object] = []

    def counted(settings: library.Config) -> dict[str, set[str]]:
        calls.append(settings)
        return parse(settings)

    def invoke(_config: library.Config, argv: list[str], *_args: object) -> tuple[int, bytes]:
        (Path(argv[argv.index("-g") + 1]) / "gamelist.xml").write_text("<gameList />")
        return 0, b""

    monkeypatch.setattr(library, "system_extensions", counted)
    assert library.generate(config, invoke) == 0
    assert json.loads(config.record_path.read_text())["folders"] == {
        "nes": "generated",
        "psx": "generated",
    }
    assert len(calls) == 1


@needs_permissions
def test_untraversable_rom_root_still_records_interrupted_and_refused(
    config: library.Config,
) -> None:
    game(config, "nes", "a.nes")
    library.write_record(config, "complete", {"nes": "generated"})
    prelude = (
        "def signalled_check(config):\n"
        " os.kill(os.getpid(), signal.SIGTERM)\n"
        "library.credentials_error=signalled_check\n"
        "os.chmod(sys.argv[2], 0)\n"
    )
    try:
        status = scrape_signalled_at(config, "", prelude, str(config.rom_root))
    finally:
        config.rom_root.chmod(0o755)
    assert status == 128 + signal.SIGTERM
    record = json.loads(config.record_path.read_text())
    assert (record["result"], record["folders"]) == ("interrupted", {})

    config.scraper_config.unlink()
    library.write_record(config, "complete", {"nes": "generated"})
    config.rom_root.chmod(0)
    try:
        assert library.scrape(config) == 1
    finally:
        config.rom_root.chmod(0o755)
    record = json.loads(config.record_path.read_text())
    assert (record["result"], record["folders"]) == ("refused", {})


def test_signal_right_after_the_claim_records_interrupted(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    library.write_record(config, "complete", {"nes": "generated"})
    prelude = (
        "take=library.lock\n"
        "def signalled_lock(config):\n"
        " claim=take(config)\n"
        " os.kill(os.getpid(), signal.SIGTERM)\n"
        " return claim\n"
        "library.lock=signalled_lock\n"
    )
    assert scrape_signalled_at(config, "", prelude) == 128 + signal.SIGTERM
    record = json.loads(config.record_path.read_text())
    assert (record["result"], record["folders"]) == ("interrupted", {"nes": "generated"})
    assert library.read_pending(config) == []


@pytest.mark.parametrize("refused", [False, True])
def test_signal_after_the_final_record_keeps_the_run_result(
    config: library.Config, refused: bool
) -> None:
    game(config, "nes", "a.nes")
    if refused:
        config.scraper_config.unlink()
    prelude = (
        "write=library.write_record\n"
        "def signalled_write(config, result, *args):\n"
        " write(config, result, *args)\n"
        " os.kill(os.getpid(), signal.SIGTERM)\n"
        "library.write_record=signalled_write\n"
    )
    assert scrape_signalled_at(config, "", prelude) == (1 if refused else 0)
    record = json.loads(config.record_path.read_text())
    assert record["result"] == ("refused" if refused else "complete")


def test_scrape_parses_the_systems_documents_once_per_run(
    config: library.Config, monkeypatch: pytest.MonkeyPatch
) -> None:
    game(config, "nes", "a.nes")
    game(config, "psx", "a.cue")
    parse = library.system_extensions
    calls: list[object] = []

    def counted(settings: library.Config) -> dict[str, set[str]]:
        calls.append(settings)
        return parse(settings)

    monkeypatch.setattr(library, "system_extensions", counted)
    assert library.scrape(config, lambda *_args: (0, b"")) == 0
    assert json.loads(config.record_path.read_text())["folders"] == {
        "nes": "fetched",
        "psx": "fetched",
    }
    assert len(calls) == 1
