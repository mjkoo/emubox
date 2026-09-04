# prepare-flat-cst

## Why

The configupdater migration removed the flat-file editors' index
arithmetic, but the measured outcome was a wash in complexity: the layer
went from 173 statements and 83 branch points to 177 and 88, because the
library's comment-preserving document model arrived with a borrowed
parser whose semantics the program must defend against. Roughly 86 lines
exist only as that defence: a synthetic wrapper section every file is
read through and its two reserved-name refusals, an indiscriminate
`lstrip` of every line so nothing parses as a value continuation, a
reconciliation loop between this program's section grammar and
`Parser.SECTCRE`, an `optionxform` assigned post-construction under a
type-checker suppression, and a tuple naming four library exception
classes that share no base.

That defence also couples which files are editable to configupdater
internals that are not public API. Nothing is broken today; what breaks
if this stays is tomorrow's maintenance. A configupdater release that
changes `SECTCRE`, the exception surface, or continuation handling
silently moves the boundary between "edited in place" and "recreated,
unowned settings lost" - the failure mode is data loss, not a crash. And
every future flat-file behavior change (first in line: reading PPSSPP's
BOM-prefixed `ppsspp.ini`, which today loses every unowned setting on
every launch) must be threaded through the borrowed parser's semantics
instead of through a grammar this program states itself.

## What Changes

- Replace the flat-file layer in `emubox_prepare.py` with a typed,
  lossless line-oriented document model built on the standard library:
  dataclass nodes that each keep their source line verbatim, one
  per-line classifier per format, and rendering by concatenation. No
  parsing library; the grammar is exactly what each emulator's own
  parser reads, stated in one place.
- The two editors (`set_ini_settings`, `set_retroarch_settings`) operate
  on nodes instead of on a wrapped ConfigUpdater document. Sweep, write,
  survivor reduction, flash-wear comparison, the multi-line value guard
  and the recreate policy carry over unchanged.
- Delete the impedance layer: the wrapper section and header constants,
  `_flat_source`, `_flat_document`, `_FLAT_PARSE_ERRORS`, the reserved
  section-name guard, and the configupdater imports.
- Drop `configupdater` from `package.nix` and the flake's prepare
  devshell; the program becomes stdlib-plus-cryptography again.
- Strict parity: the observable contract is unchanged. The set of files
  refused and recreated is identical, with exactly two deliberate
  exceptions, both artifacts of the wrapper trick that no emulator can
  produce: a file carrying a section literally named
  `emubox-flat-file-wrapper` becomes an ordinary editable file, and an
  owned-values table naming that section stops being reserved. Both
  move the implementation toward the spec, which mandates recreation
  only for files that cannot be read as the emulator's format.
- Presentation is preserved strictly better within the spec's stated
  tolerance: unowned lines keep their indentation and a section header
  keeps its trailing comment, where the current implementation
  normalises both away on any write. Tests pinning the old presentation
  are amended, not deleted.
- Not in scope: the PPSSPP BOM fix. A BOM-prefixed file stays
  unreadable here, so parity holds; making it readable widens which
  files are editable and is a follow-up change of its own on top of
  this one.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None. This is a pure refactor: every requirement and scenario in the
`emulators`, `kiosk` and `retroachievements` specs holds identically
before and after, and the two refusal-set exceptions above are
implementation artifacts the specs never described. The change sets
`skip_specs: true`; inventing a delta would document internals, not
behavior.

## Impact

- `pkgs/emubox-prepare/emubox_prepare.py`: the flat-file layer
  (roughly `_writable` through `set_retroarch_settings`) is rewritten;
  the ES-DE XML editor, the RetroAchievements flow and everything else
  are untouched.
- `pkgs/emubox-prepare/test_emubox_prepare.py`: behavior tests are the
  parity instrument and run unchanged; tests that pin configupdater
  internals or the normalised presentation are replaced or amended.
- `pkgs/emubox-prepare/package.nix`, `flake.nix`: `configupdater`
  removed from both python closures.
- Depends on the `prepare-configupdater` change: its branch is the
  parity baseline and the implementation branch is cut from it (or from
  main once it has landed there).
