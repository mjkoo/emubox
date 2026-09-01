from pathlib import Path

import pytest

import emubox_save_migrate as esm


def test_migrates_tree_and_is_idempotent(tmp_path: Path) -> None:
    source = tmp_path / "legacy"
    destination = tmp_path / "destination"
    (source / "nested").mkdir(parents=True)
    (source / "nested" / "save.sav").write_bytes(b"save")

    esm.migrate_tree(source, destination)
    esm.migrate_tree(source, destination)

    assert (destination / "nested" / "save.sav").read_bytes() == b"save"
    assert source.is_dir()
    assert list(source.iterdir()) == []


def test_equal_data_is_accepted(tmp_path: Path) -> None:
    source = tmp_path / "legacy"
    destination = tmp_path / "destination"
    source.mkdir()
    destination.mkdir()
    (source / "save.sav").write_bytes(b"same")
    (destination / "save.sav").write_bytes(b"same")

    esm.migrate_tree(source, destination)

    assert (destination / "save.sav").read_bytes() == b"same"
    assert source.is_dir()
    assert list(source.iterdir()) == []


def test_conflict_preserves_both_paths(tmp_path: Path) -> None:
    source = tmp_path / "legacy"
    destination = tmp_path / "destination"
    source.mkdir()
    destination.mkdir()
    (source / "save.sav").write_bytes(b"old")
    (destination / "save.sav").write_bytes(b"new")

    with pytest.raises(esm.MigrationConflict, match="refusing to overwrite"):
        esm.migrate_tree(source, destination)

    assert (source / "save.sav").read_bytes() == b"old"
    assert (destination / "save.sav").read_bytes() == b"new"
