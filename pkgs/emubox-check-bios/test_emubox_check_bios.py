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
import zlib
from pathlib import Path

import pytest

import emubox_check_bios as ecb

CORRECT_BYTES = b"a correct bios image, for testing purposes only\n"
CORRECT_SHA256 = hashlib.sha256(CORRECT_BYTES).hexdigest()
CORRECT_MD5 = hashlib.md5(CORRECT_BYTES, usedforsecurity=False).hexdigest()
WRONG_BYTES = b"a corrupted or unrelated file\n"

# Chosen so its crc32 is under 0x10000000 and therefore prints with a
# leading zero in the zero-padded 8-hex-digit form every published CRC32
# reference uses - a `%x` formatter that dropped the pad would produce
# "ddd613f" (7 characters) here instead of "0ddd613f", so this is the one
# input that actually exercises the zero-pad rather than merely matching
# whatever the formatter happens to produce.
CRC32_LEADING_ZERO_BYTES = b"crc32 test payload 33"
CRC32_LEADING_ZERO_DIGEST = "0ddd613f"
assert f"{zlib.crc32(CRC32_LEADING_ZERO_BYTES):08x}" == CRC32_LEADING_ZERO_DIGEST


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


# --- the three per-entry states, across every supported algorithm ----------


def test_sha256_entry_present_and_matching_exits_zero(
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
                "algorithm": "sha256",
                "digest": CORRECT_SHA256,
                "name": "Test Console BIOS (sha256)",
            }
        },
    )

    assert ecb.main([str(values), str(bios_dir)]) == 0

    out = capsys.readouterr().out
    assert "OK" in out
    assert "Test Console BIOS (sha256)" in out
    assert "console.bin" in out


def test_md5_entry_present_and_matching_exits_zero(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # The realistic case: every real entry this module ships is md5, sourced
    # from DuckStation's own bios.cpp or docs.libretro.com's published
    # per-core BIOS tables, since nobody publishes sha256 for these files
    # (design D6).
    bios_dir = tmp_path / "bios"
    bios_dir.mkdir()
    (bios_dir / "console.bin").write_bytes(CORRECT_BYTES)
    values = inventory_file(
        tmp_path,
        {
            "console": {
                "path": "console.bin",
                "algorithm": "md5",
                "digest": CORRECT_MD5,
                "name": "Test Console BIOS (md5)",
            }
        },
    )

    assert ecb.main([str(values), str(bios_dir)]) == 0

    out = capsys.readouterr().out
    assert "OK" in out
    assert "Test Console BIOS (md5)" in out


def test_uppercase_declared_digest_still_matches_exits_zero(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # Every real entry this module ships is sourced from DuckStation's own
    # bios.cpp table or docs.libretro.com's per-core BIOS pages, and every
    # one of those publishes MD5 in mixed (often upper) case, while
    # `digest_of` always returns lowercase hex. An admin who pastes a
    # reference digest verbatim must not see a MISMATCH for a file that is
    # actually byte-identical.
    bios_dir = tmp_path / "bios"
    bios_dir.mkdir()
    (bios_dir / "console.bin").write_bytes(CORRECT_BYTES)
    values = inventory_file(
        tmp_path,
        {
            "console": {
                "path": "console.bin",
                "algorithm": "md5",
                "digest": CORRECT_MD5.upper(),
                "name": "Test Console BIOS (uppercase md5)",
            }
        },
    )

    assert ecb.main([str(values), str(bios_dir)]) == 0

    out = capsys.readouterr().out
    assert "OK" in out
    assert "MISMATCH" not in out


def test_crc32_entry_present_and_matching_exits_zero(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    bios_dir = tmp_path / "bios"
    bios_dir.mkdir()
    (bios_dir / "firmware.bin").write_bytes(CRC32_LEADING_ZERO_BYTES)
    values = inventory_file(
        tmp_path,
        {
            "console": {
                "path": "firmware.bin",
                "algorithm": "crc32",
                "digest": CRC32_LEADING_ZERO_DIGEST,
                "name": "Test Console Firmware (crc32)",
            }
        },
    )

    assert ecb.main([str(values), str(bios_dir)]) == 0

    out = capsys.readouterr().out
    assert "OK" in out
    assert "Test Console Firmware (crc32)" in out


def test_crc32_digest_is_zero_padded_to_eight_hex_digits(tmp_path: Path) -> None:
    # A direct unit test of the formatter itself, not only an end-to-end
    # pass/fail: this is what would have caught a `%x` that should have been
    # `%08x` even if some other part of the report happened to mask it.
    path = tmp_path / "firmware.bin"
    path.write_bytes(CRC32_LEADING_ZERO_BYTES)

    digest = ecb.digest_of(path, "crc32")

    assert digest == CRC32_LEADING_ZERO_DIGEST
    assert len(digest) == 8


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
                "algorithm": "sha256",
                "digest": CORRECT_SHA256,
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
                "algorithm": "sha256",
                "digest": CORRECT_SHA256,
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
    # sees the actual mismatch without a separate checksum run - and the
    # expected side is qualified by its algorithm, since a bare hex string
    # alone does not say what to compute to reproduce it.
    assert f"sha256:{CORRECT_SHA256}" in out
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
                "algorithm": "sha256",
                "digest": CORRECT_SHA256,
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
                "algorithm": "sha256",
                "digest": CORRECT_SHA256,
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
                "algorithm": "sha256",
                "digest": CORRECT_SHA256,
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
                "algorithm": "sha256",
                "digest": CORRECT_SHA256,
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
            "zsystem": {
                "path": "z.bin",
                "algorithm": "sha256",
                "digest": CORRECT_SHA256,
                "name": "Z System",
            },
            "asystem": {
                "path": "a.bin",
                "algorithm": "sha256",
                "digest": CORRECT_SHA256,
                "name": "A System",
            },
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
                "algorithm": "sha256",
                "digest": CORRECT_SHA256,
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
    values.write_text(
        json.dumps(
            {"console": {"path": "console.bin", "algorithm": "sha256", "digest": "abc"}}
        )
    )
    assert ecb.main([str(values), str(tmp_path)]) == 1


def test_main_rejects_malformed_json(tmp_path: Path) -> None:
    values = tmp_path / "inventory.json"
    values.write_text("{not json")
    assert ecb.main([str(values), str(tmp_path)]) == 1


def test_main_rejects_a_deeply_nested_inventory_without_a_traceback(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # `json.loads` raises RecursionError rather than a ValueError on a
    # deeply nested document, and RecursionError is not a ValueError, so a
    # guard naming only OSError and ValueError misses it and the tool dies
    # with a stack trace instead of the one journal line it promises. The
    # same store-path read in emubox-prepare already names it; these two
    # sites are the same read and answer the same way.
    values = tmp_path / "inventory.json"
    values.write_text("[" * 100000)

    assert ecb.main([str(values), str(tmp_path)]) == 1

    err = capsys.readouterr().err
    assert "inventory JSON" in err
    assert "Traceback" not in err


def test_main_rejects_an_unknown_algorithm_loudly(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # A whole-inventory hard failure, not a per-entry "unknown" result: a
    # checker that silently skipped an entry it cannot verify would exit 0
    # and look, from the outside, exactly like one that verified everything.
    bios_dir = tmp_path / "bios"
    bios_dir.mkdir()
    (bios_dir / "console.bin").write_bytes(CORRECT_BYTES)
    values = inventory_file(
        tmp_path,
        {
            "console": {
                "path": "console.bin",
                "algorithm": "crc64",
                "digest": "deadbeefdeadbeef",
                "name": "Test Console BIOS",
            }
        },
    )

    assert ecb.main([str(values), str(bios_dir)]) == 1

    err = capsys.readouterr().err
    assert "crc64" in err
    assert "console" in err


# --- unreadable declared files are reported as missing, not crashes --------


def test_unreadable_declared_file_is_reported_missing(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    bios_dir = tmp_path / "bios"
    bios_dir.mkdir()
    # A directory sitting where a file is declared: not a byte stream, so
    # digest_of must treat it the same as an absent file rather than raise.
    (bios_dir / "console.bin").mkdir()
    values = inventory_file(
        tmp_path,
        {
            "console": {
                "path": "console.bin",
                "algorithm": "sha256",
                "digest": CORRECT_SHA256,
                "name": "Test Console BIOS",
            }
        },
    )

    assert ecb.main([str(values), str(bios_dir)]) != 0
    assert "MISSING" in capsys.readouterr().out


def test_unreadable_declared_file_is_reported_missing_for_crc32_too(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # digest_of's crc32 branch has its own try/except around the read, so it
    # needs its own coverage of the same case the hashlib branch already
    # proves.
    bios_dir = tmp_path / "bios"
    bios_dir.mkdir()
    (bios_dir / "firmware.bin").mkdir()
    values = inventory_file(
        tmp_path,
        {
            "console": {
                "path": "firmware.bin",
                "algorithm": "crc32",
                "digest": CRC32_LEADING_ZERO_DIGEST,
                "name": "Test Console Firmware",
            }
        },
    )

    assert ecb.main([str(values), str(bios_dir)]) != 0
    assert "MISSING" in capsys.readouterr().out
