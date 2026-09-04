# prepare-flat-bom

## Why

PPSSPP's own config writer (`IniFile::Save`) prefixes `ppsspp.ini` with
a UTF-8 byte order mark unconditionally. The prepare program decodes
that mark to U+FEFF at the start of the first line rather than dropping
it, so the file never reads as its format and takes the recreate path -
on every single launch. The recreated file carries only the owned
values, PPSSPP re-adds the mark on its next save, and the loop repeats:
every preference the family sets inside PPSSPP is silently lost before
the next launch, forever. This is live data loss today, found and
recorded during the configupdater migration and deliberately deferred
because widening which files are editable is a behavior change that
rewrite was forbidden to make. If this change is not made, PPSSPP is
the one emulator on the box whose settings menu does not work.

## What Changes

- A flat configuration file whose only obstacle is a leading UTF-8
  byte order mark is read as its format: the mark is not part of the
  first line's content. This applies to both flat formats uniformly;
  only PPSSPP is known to write one, but the rule is about the file,
  not the emulator.
- The mark survives a write byte-for-byte, leading the file exactly
  where the emulator put it. Preservation, not stripping: the byte the
  emulator wrote is treated like every other byte the flake does not
  own.
- Only a leading mark at the start of the file is tolerated. A U+FEFF
  anywhere else gets no special treatment: it is ordinary content, and
  the line carrying it keeps whatever behavior the existing rules
  already give it.
- A file containing only the mark is an empty file: after the mark is
  set aside, the existing rules apply verbatim.
- Everything else about the flat-file contract is untouched.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `emulators`: the requirement that the flake owns each emulator's
  launch settings gains the byte-order-mark tolerance - a file
  differing from a readable one only by a leading mark keeps every
  unowned key through an edit, rather than being replaced by a file
  carrying only the owned values, and the mark survives the edit.

## Impact

- `pkgs/emubox-prepare/emubox_prepare.py`: the flat-file reading layer
  learns to set a leading mark aside and the writer to put it back;
  the editors' own emptiness checks - the deferred empty-file note
  and the judgment of whether a file holds anything a recreation
  would drop - learn the same set-aside, so a mark-only file counts
  as empty there too; nothing else changes.
- `pkgs/emubox-prepare/test_emubox_prepare.py`: new tests for the
  tolerated and still-refused mark positions; the existing
  recreate-loop reproduction becomes the regression test.
- `openspec/specs/emulators/spec.md`: one requirement modified.
- Ordering: archives after `prepare-configupdater`, whose open delta
  modifies the same requirement; this change's delta is written
  against that text. Implementation is sequenced after
  `prepare-flat-cst` if that change proceeds - the line classifier
  makes the fix a prefix rule - but does not strictly require it: on
  the current layer the same rule lands where flat text is read and
  written.
