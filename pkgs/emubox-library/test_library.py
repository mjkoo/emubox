"""Behavioral checks for library state, process claims, and reports."""

from __future__ import annotations

import contextlib
import json
import os
import pwd
import signal
import stat
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
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
    assert [file.name for file in found["psx"]] == ["disc.cue"]


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
    assert terminal == b"Fetching nes\nscraper stdout\nscraper stderr\n"
    assert config.log_path.read_bytes() == terminal


@pytest.mark.parametrize("cause", ["missing", "unreadable", "placeholder"])
def test_credentials_replace_success_record_without_touching_pending(
    config: library.Config, cause: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    library.atomic_json(config.record_path, {"result": "complete", "time": "old", "folders": {}})
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
    assert cause in record["cause"]
    assert config.pending_path.read_bytes() == before


@pytest.mark.parametrize("value", ['":secret"', '"person:"'])
def test_empty_credential_component_refuses_before_scraper(
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
    assert config.pending_path.read_bytes() == before


def test_percent_in_valid_credentials_allows_fetch(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    config.scraper_config.write_text('[screenscraper]\nuserCreds="person:pa%ss"\n')
    seen: list[list[str]] = []

    def stub(_config: library.Config, argv: list[str], _claim: int) -> tuple[int, bytes]:
        seen.append(argv)
        return 0, b"ok\n"

    assert library.scrape(config, stub) == 0
    assert seen == [library.fetch_vector(config, "nes", "nes")]
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
        library.fetch_vector(config, "nes", "nes"),
        library.fetch_vector(config, "psx", "psx"),
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
        library.fetch_vector(config, "nes", "nes"),
        library.fetch_vector(config, "psx", "psx"),
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
        (work / "gamelist.xml").write_text("NEW")
        return 0, b""

    assert library.generate(config, success) == 0
    assert live.read_text() == "NEW"
    assert library.read_pending(config) == []
    assert not list(parent.glob(".emubox-library-work-*"))


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
        (work / "gamelist.xml").write_text("NEW")
        library.write_pending(config, ["nes", "psx"])
        return 0, b""

    assert library.generate(config, invoke) == 0
    assert (config.gamelist_root / "nes" / "gamelist.xml").read_text() == "NEW"
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
        (work / "gamelist.xml").write_text("NEW" if status == 0 else "BROKEN")
        return status, b""

    assert library.generate(config, stub) == 0
    assert seen == [False]
    assert not stale.exists()
    assert not list(parent.glob(".emubox-library-work-*"))
    live = parent / "gamelist.xml"
    assert (live.read_text() if live.exists() else None) == ("NEW" if status == 0 else None)
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
    assert messages == ["Generation could not finish with a progress window; frontend starting"]


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
    library.write_pending(config, ["nes"])
    library.atomic_json(config.revision_path, {"nes": "r1"})
    before = config.pending_path.read_bytes()
    claim = held_lock(config)
    try:
        assert library.cleanup(config, {"nes": "r1"}) == 1
        assert config.pending_path.read_bytes() == before
    finally:
        os.close(claim)

    original = library.atomic_json

    def fail_record(path: Path, value: object) -> None:
        if path == config.record_path:
            raise PermissionError("read-only records")
        original(path, value)

    monkeypatch.setattr(library, "atomic_json", fail_record)
    assert library.cleanup(config, {"nes": "r1"}) == 1
    assert config.pending_path.read_bytes() == before


def test_capture_preserves_pending_with_missing_revision(config: library.Config) -> None:
    library.write_pending(config, ["nes"])
    assert library.capture(config) == (0, {})
    assert library.cleanup(config, {"nes": "unknown"}) == 0
    assert library.read_pending(config) == ["nes"]


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
    live.write_text("OLD")
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
    assert time.monotonic() - start < 3
    assert live.read_text() == "OLD"
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
    assert library.generate(config, lambda *args: pytest.fail("unexpected scraper")) == 0


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
    assert time.monotonic() - start < 2
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
    assert time.monotonic() - start < 2
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
        timeout=3,
    )
    assert time.monotonic() - start < 2
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
        os.kill(int(pid_file.read_text()), signal.SIGKILL)
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
    live.write_text("OLD")
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
        "(work/'gamelist.xml').write_text('NEW')\n"
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
        assert live.read_text() == "OLD"
        assert library.read_pending(config) == ["nes"]
    finally:
        os.kill(int(pid_file.read_text()), signal.SIGKILL)
        first.wait(timeout=3)
    release.touch()
    second = subprocess.run(command, capture_output=True, text=True, timeout=5)
    assert second.returncode == 0, second.stderr
    assert live.read_text() == "NEW"
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


def test_published_gamelist_survives_kill_before_pending_rewrite(config: library.Config) -> None:
    game(config, "nes", "a.nes")
    library.write_pending(config, ["nes"])
    parent = config.gamelist_root / "nes"
    parent.mkdir(parents=True)
    live = parent / "gamelist.xml"
    live.write_text("OLD")
    marker = config.cache_root / "renamed"
    scraper = config.cache_root.parent / "writer"
    scraper.write_text(
        f"#!{sys.executable}\n"
        "import pathlib, sys\n"
        "work=pathlib.Path(sys.argv[sys.argv.index('-g')+1])\n"
        "(work/'gamelist.xml').write_text('NEW')\n"
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
        " assert (config.gamelist_root/'nes'/'gamelist.xml').read_text() == 'NEW'\n"
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
        assert live.read_text() == "NEW"
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
        assert time.monotonic() - start < 3
        assert status == 124
        assert output == b""
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
