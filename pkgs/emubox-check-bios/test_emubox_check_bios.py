"""Tests for emubox-check-bios: the report, the exit status and the promise
that it never writes anything.

Every test runs against a temporary directory standing in for /data/bios and
a temporary inventory file standing in for the module's rendered JSON, since
the tool's whole contract is "compare this directory against this JSON and
say what you see" - a property of a directory and a document, not something
a VM boot is needed to show.
"""

import hashlib
import json
import os
from pathlib import Path

import pytest

import emubox_check_bios as ecb

CORRECT_BYTES = b"a correct bios image, for testing purposes only\n"
CORRECT_SHA256 = hashlib.sha256(CORRECT_BYTES).hexdigest()
WRONG_BYTES = b"a corrupted or unrelated file\n"


def inventory_file(tmp_path: Path, entries: dict[str, dict[str, str]]) -> Path:
    path = tmp_path / "inventory.json"
    path.write_text(json.dumps(entries))
    return path


def snapshot(directory: Path) -> dict[str, tuple[bytes, float]]:
    """Every file's bytes and mtime, keyed by relative path - what "the tool
    writes nothing" is checked against before and after a run."""
    return {
        str(p.relative_to(directory)): (p.read_bytes(), p.stat().st_mtime)
        for p in sorted(directory.rglob("*"))
        if p.is_file()
    }


# --- the three per-entry states --------------------------------------------


def test_all_present_and_matching_exits_zero(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    bios_dir = tmp_path / "bios"
    bios_dir.mkdir()
    (bios_dir / "console.bin").write_bytes(CORRECT_BYTES)
    values = inventory_file(
        tmp_path,
        {
            "console": {
                "path": "console.bin",
                "sha256": CORRECT_SHA256,
                "name": "Test Console BIOS",
            }
        },
    )

    assert ecb.main([str(values), str(bios_dir)]) == 0

    out = capsys.readouterr().out
    assert "OK" in out
    assert "Test Console BIOS" in out
    assert "console.bin" in out


def test_missing_file_exits_nonzero_and_names_it(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    bios_dir = tmp_path / "bios"
    bios_dir.mkdir()
    values = inventory_file(
        tmp_path,
        {
            "console": {
                "path": "console.bin",
                "sha256": CORRECT_SHA256,
                "name": "Test Console BIOS",
            }
        },
    )

    assert ecb.main([str(values), str(bios_dir)]) != 0

    out = capsys.readouterr().out
    assert "MISSING" in out
    assert "Test Console BIOS" in out
    assert "console.bin" in out


def test_wrong_checksum_exits_nonzero_and_names_it(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    bios_dir = tmp_path / "bios"
    bios_dir.mkdir()
    (bios_dir / "console.bin").write_bytes(WRONG_BYTES)
    values = inventory_file(
        tmp_path,
        {
            "console": {
                "path": "console.bin",
                "sha256": CORRECT_SHA256,
                "name": "Test Console BIOS",
            }
        },
    )

    assert ecb.main([str(values), str(bios_dir)]) != 0

    out = capsys.readouterr().out
    assert "MISMATCH" in out
    assert "Test Console BIOS" in out
    assert "console.bin" in out
    # The report names both digests, not only that they differ, so an admin
    # sees the actual mismatch without a separate sha256sum run.
    assert CORRECT_SHA256 in out
    assert hashlib.sha256(WRONG_BYTES).hexdigest() in out


# --- undeclared extras ------------------------------------------------------


def test_undeclared_extra_is_listed_and_does_not_affect_exit_status(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    bios_dir = tmp_path / "bios"
    bios_dir.mkdir()
    (bios_dir / "console.bin").write_bytes(CORRECT_BYTES)
    (bios_dir / "mystery.bin").write_bytes(b"nobody declared this one\n")
    values = inventory_file(
        tmp_path,
        {
            "console": {
                "path": "console.bin",
                "sha256": CORRECT_SHA256,
                "name": "Test Console BIOS",
            }
        },
    )

    assert ecb.main([str(values), str(bios_dir)]) == 0

    out = capsys.readouterr().out
    assert "EXTRA" in out
    assert "mystery.bin" in out


def test_extra_present_alongside_a_real_miss_does_not_mask_it(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # An extra file existing must never be mistaken for the declared file
    # that is actually missing - the report has to name both, and the exit
    # status has to reflect the miss, not the extra's harmless presence.
    bios_dir = tmp_path / "bios"
    bios_dir.mkdir()
    (bios_dir / "mystery.bin").write_bytes(b"nobody declared this one\n")
    values = inventory_file(
        tmp_path,
        {
            "console": {
                "path": "console.bin",
                "sha256": CORRECT_SHA256,
                "name": "Test Console BIOS",
            }
        },
    )

    assert ecb.main([str(values), str(bios_dir)]) != 0

    out = capsys.readouterr().out
    assert "MISSING" in out
    assert "EXTRA" in out
    assert "mystery.bin" in out


# --- writes nothing ----------------------------------------------------------


def test_writes_nothing(tmp_path: Path) -> None:
    bios_dir = tmp_path / "bios"
    bios_dir.mkdir()
    (bios_dir / "console.bin").write_bytes(CORRECT_BYTES)
    (bios_dir / "mystery.bin").write_bytes(b"nobody declared this one\n")
    values = inventory_file(
        tmp_path,
        {
            "console": {
                "path": "console.bin",
                "sha256": CORRECT_SHA256,
                "name": "Test Console BIOS",
            }
        },
    )
    # Frozen to a fixed value distinct from "now" so a rewrite that happens
    # to reproduce identical bytes is still caught by the mtime check.
    for path in bios_dir.iterdir():
        os.utime(path, (0, 0))
    before_dir = snapshot(bios_dir)
    before_names = sorted(p.name for p in bios_dir.iterdir())

    # A run that finds a miss (nothing declares mystery.bin's presence, and
    # nothing here is wrong) still must not touch the directory - the
    # contract holds on every exit status, not only the successful one.
    ecb.main([str(values), str(bios_dir)])

    assert sorted(p.name for p in bios_dir.iterdir()) == before_names
    assert snapshot(bios_dir) == before_dir


def test_writes_nothing_even_with_a_mismatch(tmp_path: Path) -> None:
    bios_dir = tmp_path / "bios"
    bios_dir.mkdir()
    (bios_dir / "console.bin").write_bytes(WRONG_BYTES)
    values = inventory_file(
        tmp_path,
        {
            "console": {
                "path": "console.bin",
                "sha256": CORRECT_SHA256,
                "name": "Test Console BIOS",
            }
        },
    )
    os.utime(bios_dir / "console.bin", (0, 0))
    before = snapshot(bios_dir)

    ecb.main([str(values), str(bios_dir)])

    assert snapshot(bios_dir) == before


# --- ordering and empty inputs ----------------------------------------------


def test_report_is_ordered_by_path_for_reproducibility(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    bios_dir = tmp_path / "bios"
    bios_dir.mkdir()
    (bios_dir / "z.bin").write_bytes(CORRECT_BYTES)
    (bios_dir / "a.bin").write_bytes(CORRECT_BYTES)
    values = inventory_file(
        tmp_path,
        {
            "zsystem": {"path": "z.bin", "sha256": CORRECT_SHA256, "name": "Z System"},
            "asystem": {"path": "a.bin", "sha256": CORRECT_SHA256, "name": "A System"},
        },
    )

    assert ecb.main([str(values), str(bios_dir)]) == 0

    out = capsys.readouterr().out
    assert out.index("a.bin") < out.index("z.bin")


def test_empty_inventory_and_empty_directory_exits_zero(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    bios_dir = tmp_path / "bios"
    bios_dir.mkdir()
    values = inventory_file(tmp_path, {})

    assert ecb.main([str(values), str(bios_dir)]) == 0
    assert capsys.readouterr().out == ""


def test_missing_bios_directory_reports_every_entry_missing(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # /data/bios is created by tmpfiles before this tool ever runs, but a
    # broken box could still be missing it - reporting every declared file
    # as missing, rather than crashing on the absent directory, is the
    # honest report policy for that case too.
    bios_dir = tmp_path / "does-not-exist"
    values = inventory_file(
        tmp_path,
        {
            "console": {
                "path": "console.bin",
                "sha256": CORRECT_SHA256,
                "name": "Test Console BIOS",
            }
        },
    )

    assert ecb.main([str(values), str(bios_dir)]) != 0
    assert "MISSING" in capsys.readouterr().out


# --- invocation contract and malformed inputs -------------------------------


def test_main_requires_exactly_two_positional_arguments(tmp_path: Path) -> None:
    values = inventory_file(tmp_path, {})
    assert ecb.main([str(values)]) != 0
    assert ecb.main([str(values), str(tmp_path), "extra"]) != 0


def test_main_reports_unreadable_inventory_without_a_traceback(tmp_path: Path) -> None:
    assert ecb.main([str(tmp_path / "does-not-exist.json"), str(tmp_path)]) == 1


def test_main_rejects_a_top_level_value_that_is_not_an_object(tmp_path: Path) -> None:
    values = tmp_path / "inventory.json"
    values.write_text("[]")
    assert ecb.main([str(values), str(tmp_path)]) == 1


def test_main_rejects_an_entry_missing_a_required_field(tmp_path: Path) -> None:
    values = tmp_path / "inventory.json"
    values.write_text(json.dumps({"console": {"path": "console.bin", "sha256": "abc"}}))
    assert ecb.main([str(values), str(tmp_path)]) == 1


def test_main_rejects_malformed_json(tmp_path: Path) -> None:
    values = tmp_path / "inventory.json"
    values.write_text("{not json")
    assert ecb.main([str(values), str(tmp_path)]) == 1


# --- unreadable declared files are reported as missing, not crashes --------


def test_unreadable_declared_file_is_reported_missing(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    bios_dir = tmp_path / "bios"
    bios_dir.mkdir()
    # A directory sitting where a file is declared: not a byte stream, so
    # sha256_of must treat it the same as an absent file rather than raise.
    (bios_dir / "console.bin").mkdir()
    values = inventory_file(
        tmp_path,
        {
            "console": {
                "path": "console.bin",
                "sha256": CORRECT_SHA256,
                "name": "Test Console BIOS",
            }
        },
    )

    assert ecb.main([str(values), str(bios_dir)]) != 0
    assert "MISSING" in capsys.readouterr().out
