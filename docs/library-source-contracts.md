# Library source contracts

The contract check reads the source fetched by the configured Nix packages. It
does not infer behavior from a newer upstream release. The current pins are
Skyscraper 3.18.5 from the flake's root nixpkgs revision
`d57af924f160a5084293c71c2043f058bd1cdb60` (source hash
`sha256-lX+ew/PkZdOFjYDVLCsF3JH8oqQBAjxfZQegHZ1vcDo=`) and ES-DE 3.4.1
from [the local package recipe](../pkgs/es-de/package.nix) (source hash
`sha256-MVmJIdxwEG3wgvwbhuIEYCxKaYss/3hq9xszGLjZ1Xw=`). The ES-DE source
checks inspect the fetched, unpatched archive. The package adds a kiosk quit
menu patch; these source contracts do not assert the behavior of that patch.

Run `tests/library-source-contracts.py` with `--skyscraper-source`,
`--esde-source`, and `--nixpkgs-source` pointing at the fetched source trees.
The check derives accepted options and flags from `src/cli.cpp`, reads platform
keys from `peas.json`, and verifies these source contracts:

| Contract | Pinned source evidence |
| --- | --- |
| Platform vocabulary | Skyscraper `peas.json` has 126 platform keys; `3ds`, `megadrive`, `pcengine`, and `pcenginecd` are keys, while the corresponding ES-DE folder names `n3ds`, `genesis`, `tg16`, and `tg-cd` are not. Aliases are not platform keys. |
| CLI | Skyscraper `src/cli.cpp`, `Cli::createParser` and `Cli::getSubCommandOpts`, declare the required path, frontend, scraper, and flags options and the run flags. They do not declare `--stderr`. The script rejects a bogus platform, `--stderr`, and a bogus flag as negative controls. |
| Home and resource deployment | Skyscraper `src/config.cpp`, `Config::initSkyFolders` and `Config::setupUserConfig`, select `~/.skyscraper` in the non-XDG branch, create import/cache/resource directories, and copy defaults from the installed `SYSCONFDIR/skyscraper`. The pinned nixpkgs recipe defaults `enableXdg` to false and only enables it by an optional patch. A first-run deployment with `-c` outside the home is a separate VM check. |
| Lock and termination | Skyscraper `src/main.cpp` installs a SIGINT handler. The check also scans its C++ sources for known file-lock APIs. This supports the wrapper's own lock and process cleanup; source inspection does not prove how a killed process behaves, which requires process tests. |
| Output and metadata | Skyscraper `src/skyscraper.cpp` loads an existing gamelist, includes cache misses only with `skipped`, and writes the generated file with `QIODevice::WriteOnly`. `src/gameentry.cpp` lists the family tags copied from the old entry. `src/esde.cpp` emits no media paths and supports covers, screenshots, marquees, videos, manuals, and wheels, but not textures. `src/abstractfrontend.cpp` copies cached media, including wheel data to the ES-DE marquee destination. |
| Frontend launch and input | ES-DE `es-app/src/SystemData.cpp` parses system commands and extension lists and logs loaded systems and game count. `es-app/src/FileData.cpp` resolves the command executable before substituting `%ROM%` and logs a launch. `es-app/src/main.cpp` passes SDL events to `InputManager`. A store-hosted `.sh` entry therefore needs an explicit interpreter or executable wrapper before `%ROM%`. Actual window, physical input, frontend launch and signal behavior remain manual hardware acceptance checks. |

The script accepts an exported folder-to-platform JSON object through
`--platform-map` and an exported JSON object of Skyscraper argument vectors
through `--vectors`. Each vector is a list of arguments after `Skyscraper`,
with option and value as separate elements. The flake check binds these inputs to the configured platform map and the
package's installed argument-vector export, with rejection controls applied
to each export.

Source inspection establishes the declarations and code paths above. It does
not establish that the first-run deployment, frontend interaction, windowing,
or signal behavior works on the configured Linux machine. CI checks the real
first-run import and nonvisual library behavior. Record display and physical
frontend observations using [the hardware checklist](library-hardware-tests.md);
a green CI result does not establish those hardware results.
