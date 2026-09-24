## Why

ROMs copied onto the box show in the frontend as bare file names: no art, no
description, no manual. The `library` module is a stub that installs
Skyscraper and nothing that runs it, so today the only way to get metadata is
the frontend's own scraper, which needs the full menu, a keyboard and the
ScreenScraper password typed on the TV. If this is not done, a family library
of a few hundred games stays a wall of file names, and every game added later
needs an admin at the box.

## What Changes

- A scrape command, `emubox-scrape`, fetches metadata, art, videos and manuals
  from ScreenScraper into a cache for every ROM folder that has games. It runs
  as the session account and refuses to run as anyone else, root included. It
  is started by hand: there is no timer and no file watch.
- Gamelists and media are generated from that cache at the next frontend
  start, never while the frontend is running, and with progress shown on the
  TV. A failed progress window records failure and launches the frontend
  without a windowless retry. Favourites, play counts and per-game emulator choices the family has
  made survive regeneration.
- A "Tools" system appears in the frontend, visible to the whole household,
  with one entry, "Update game art", that runs the scrape with its progress on
  screen and then restarts the frontend so the result shows at once. A restart
  asked for this way does not count towards the crash limit and resets the
  crash count.
- The frontend's custom systems stop being one verbatim document from one
  module and become a set of system definitions any module may contribute to.
- ScreenScraper credentials join the secrets file; the install placeholder
  guard covers them.
- `emubox-status` gains a `library` section: per-folder game and gamelist
  counts, games nothing was found for, folders Skyscraper has no platform for,
  the last scrape's result, and whether generation is pending. Slow counting
  returns available results and an explicit warning within 50 seconds.
- The ROM root carries a default access rule, set on the root alone and
  inherited by every folder created beneath it afterwards, so that a system
  folder created with the default mode, by the session account or by the
  admin, is one the admin can copy ROMs into without a step taken by hand.
  The rule is not applied to folders that already exist.
- The README gains an ingest runbook with both routes ROMs take onto the box:
  copying over SSH so ownership comes out right, and, on the shipped box
  today, switching to desktop mode with `sudo emubox-mode desktop` and
  copying from removable media as the session account, creating each system
  folder first and copying the game files into it, since a folder copied
  whole keeps its source mode and is not writable by `admin`; then how to start a
  scrape over SSH and from the frontend, and the one manual scrape with real
  credentials that proves the account.
- Not included: timers and path units; a fake ScreenScraper for tests;
  per-game overrides or cache editing; a "Switch to desktop" entry (wanted, but
  it would let the session account select the desktop, which the `recovery`
  capability forbids today, so it is a change of its own); a controller
  pairing entry; any remote access work. The SSH route in the runbook becomes
  usable on the box when remote administration lands; the Tools entry does not
  depend on it.

## Capabilities

### New Capabilities

- `library`: getting ROMs onto the box and turning them into a browsable
  library: the scrape command and who may run it, generation at frontend
  start, the Tools entry, the status section and the ingest runbook.

### Modified Capabilities

- `kiosk`: custom systems become a merged set of contributed definitions
  rather than one verbatim document; a restart requested from a Tools entry
  is not a crash; the frontend's start-time promises, at boot and at
  relaunch, are measured from the end of any pending generation; the
  restricted-frontend requirement now says that it is the frontend's own
  built-in scraper that stays closed, so a household-reachable scrape through
  the Tools entry does not contradict it. The generation step the session
  gains is specified under `library`, which owns its behaviour.
- `secrets`: the ScreenScraper username and password are declared, always
  required, and covered by the install placeholder guard.
- `packages`: retain FreeImage with explicit acceptance that downloaded
  ScreenScraper artwork reaches its vulnerable decoder; correct the existing
  rationale that calls these inputs trusted.
- `vm-test`: a new requirement proving scraping, generation, the Tools system
  and the refusals through nonvisual VM assertions; display and physical
  frontend interaction are deferred to manual hardware acceptance.

## Impact

- `modules/library` (the scrape configuration, the ROM root's default access
  rule, the Tools system, the status reporter registration, the secrets
  template, the session's generation step contributed through a kiosk
  option), `modules/kiosk` (custom systems option shape, the session loop and
  the option that carries a contributed step), `modules/emulators` (its
  fourteen system overrides contributed as list items), `modules/secrets`.
- New package `pkgs/emubox-library` (the scrape command, the generation step
  and the status reporter, with unit tests), wired into the overlay and the
  flake checks.
- `secrets/secrets.yaml` and the test secrets file gain two keys; the install
  placeholder guard keeps its single argument, the `install` recipe in the
  `justfile` is corrected to evaluate `emubox.backups.enable` in a form that
  renders a Boolean, since `nix eval --raw` on a Boolean aborts the recipe
  before the guard runs, and `secrets/README.md` follows.
- New nonvisual `tests/library.nix`, run in CI with the other VM tests,
  and a manual hardware checklist for display and frontend interaction; `tests/kiosk.nix`
  and the other readers and writers of custom systems, including
  `tests/controllers-config.nix` and `tests/mode.nix`, follow the option
  change; the README example follows it too.
- New runtime dependency in the session: a terminal emulator (`foot`) to show
  progress under the compositor.
- `flake.nix` records the accepted FreeImage risk for downloaded artwork.
- Account side: a ScreenScraper account.
