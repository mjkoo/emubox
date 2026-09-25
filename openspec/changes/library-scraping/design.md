## Context

See proposal.md for motivation. The facts below were checked against the
pinned nixpkgs and the tree, and they shape the approach.

- Skyscraper is 3.18.5 (the Gemba fork), Linux only, built without XDG
  support, so its per-user files live in `~/.skyscraper`. One run handles one
  platform (`-p`); `-c` names the config file, `-i` the ROM folder, `-d` the
  cache folder, `-g` the gamelist folder, `-o` the media folder. A completed
  run exits 0 and a config or runtime error exits 1; its command-line parser
  rejects an option or `--flags` value its source does not declare with a
  non-zero exit before any work is done, so every option and flag this change
  passes must be one `src/cli.cpp` in the pinned source declares. It has no
  `--stderr` option.
- Its platform table (`peas.json`, 126 names) differs from ES-DE's folder
  names in places: `3ds` for `n3ds`, `megadrive` for `genesis`, `pcengine` for
  `tg16`, `pcenginecd` for `tg-cd`. The aliases in that table are search hints
  for scraping sites, not values `-p` accepts.
- Generating a gamelist for its `esde` frontend preserves `favorite`,
  `hidden`, `kidgame`, `lastplayed`, `playcount`, `sortname`, `altemulator`,
  `completed`, `broken`, `controller`, `collectionsortname`, `hidemetadata`,
  `nogamecount` and `nomultiscrape`, and emits covers, screenshots, marquees
  (the cached wheel image is written as the marquee,
  `src/abstractfrontend.cpp`), videos and manuals whenever the cache holds
  them: the fetch caches covers, screenshots, wheels, marquees and textures
  by default (`src/settings.h`) and videos and manuals through the `videos`
  and `manuals` flags of D5; textures are cached by default but never
  emitted, since `src/esde.cpp` leaves them out of the media it supports.
  Back covers and fan art are never cached because the fetch leaves them
  off, so generation emits none. Without the `skipped` flag a game it
  has no cached data for is dropped from the regenerated gamelist together
  with every tag ES-DE stored for it; with `skipped` the game keeps an entry
  with no metadata and its tags are preserved like any other entry's. It
  writes a folder's `gamelist.xml` in place, with no temporary file and no
  rename, and handles only SIGINT, so a kill or a power loss during that write
  leaves a truncated gamelist behind; that is why the wrapper, not Skyscraper,
  owns the live gamelist (D6). It reads the previous gamelist it preserves
  tags from out of the `-g` folder (`src/skyscraper.cpp`), and the gamelist it
  writes for ES-DE embeds no media paths (`src/esde.cpp`), so `-g` can name a
  work directory while `-o` still names the live media folder.
- ScreenScraper credentials are `userCreds="user:pass"` under
  `[screenscraper]` in the config file.
- Its `import` scraping module fills the cache from local files named after
  the ROM, with no network.
- ES-DE reads gamelists at startup and later writes its in-memory copy back,
  so a gamelist written while it runs is lost. It already has
  `ROMDirectory=/data/roms`, `MediaDirectory=/data/media` and application data
  under `/data/es-de`.
- The session loop runs `cage -s -- es-de` afresh on each pass and counts a
  run shorter than 60 seconds as a crash; three in a row end the session at
  the greeter. Session stderr goes to the display manager's session log, not
  the journal, so anything that must be read back goes through `systemd-cat`.
- `emubox.kiosk.customSystems` is one `types.str` holding a whole
  `es_systems.xml`, set only by `modules/emulators` (fourteen overrides).
- `/data/roms` is `2775 player:player` and `admin` is in group `player`.
  Setgid passes the group on to what is created inside, not group write, so
  a default ACL on the ROM root (D4) is what makes a folder created beneath
  it writable by `admin`: every folder created with the default mode, by
  `admin`, by `player` or by any tool that does not force a mode, inherits
  an ACL mask of `rwx`. ES-DE creates a system directory with an explicit
  mode of `0755` when it offers to create the ROM tree
  (`es-app/src/SystemData.cpp`, through
  `es-core/src/utils/FileSystemUtil.cpp`), which sets the inherited mask to
  `r-x` and caps the `group:player:rwx` entry at effective `r-x`, so the
  default ACL does not make such a folder writable by `admin`. The frontend
  does not create that folder in kiosk mode, but copying a whole folder from
  removable media does, since `cp` reproduces the source folder's mode; D4
  says why the runbook has the reader create the folder first and accepts
  what remains as a limitation. `/data/media` and `/data/cache` are `0755
  player`. Backups
  cover the save roots only, so media and cache are not backed up, which is
  right: both can be scraped again.
- `emubox.status.reporters` is the registry `emubox-status` aggregates.
- sshd is loopback-only with no authorised key until remote administration
  lands, so the SSH route is provable in a VM now and usable on the box later.

## Goals / Non-Goals

**Goals:**

- Fetching, generation and reporting require no root privilege, and no
  sudoers or polkit rule is added. Existing systemd-tmpfiles applies the
  declarative directory and root-only ACL rules as root at boot and switch.
- The frontend always launches. Nothing in scraping or generation can leave
  the family at a black screen or a greeter.
- Family-made metadata (favourites, play counts, emulator choices) survives.
- Everything except ScreenScraper's own API is proven without credentials.

**Non-Goals:**

- Unattended scraping. No scrape fires on a timer or on a file landing, and
  nothing in this change watches the ROM tree.
- Correcting wrong matches, per-game overrides, cache editing.
- A declared list of systems. Folders are discovered at run time.

## Decisions

### D1. Shared vocabulary

This table is the design vocabulary. The library spec also states the run
results so it remains readable independently; the records and tests use the
same meanings.

| Term | Meaning |
|---|---|
| ROM file | A regular file directly in a folder whose extension is in the frontend's extension list for that system: the list from the frontend's bundled `es_systems.xml`, as overridden by the custom systems the box declares. A sidecar file whose extension is not in the list is not a ROM file. |
| folder | A directory directly under `/data/roms` that holds at least one ROM file directly in it. A directory with no ROM file directly in it is empty: it is neither visited nor reported. The test is for a ROM file rather than for any regular file, chosen once here, because a folder holding only sidecar files has no games. |
| fetch | Filling the cache for one ROM folder from ScreenScraper. Safe while the frontend or a game runs. |
| generation | Writing one folder's gamelist and media from the cache. Only while the frontend is not running. |
| pending | A folder whose fetch finished and whose generation has not yet run. |
| folder outcome `fetched` | Fetch exited 0 for the folder. The folder becomes pending. |
| folder outcome `fetch-failed` | Fetch exited non-zero. The folder does not become pending. |
| folder outcome `unmapped` | The folder holds ROM files but has no Skyscraper platform. Skipped, never an error. |
| folder outcome `generated` | Generation exited 0 within its time limit and the folder's new gamelist was put live. |
| folder outcome `generation-failed` | Generation failed, exceeded its limit, was not reached before the overall limit, or could not run because its progress window failed. No failed output replaces a live gamelist; a replacement completed before an interruption remains live. |
| run result `complete` | Every mapped folder was `fetched`, including the case where there are none. |
| run result `partial` | At least one `fetched` and at least one `fetch-failed`. |
| run result `failed` | Folders were attempted and none was `fetched`. |
| run result `refused` | Nothing was attempted: wrong account, credentials unusable, or another run holds the lock. A credential refusal replaces the last-run record but carries the previous record's folder outcomes forward, since nothing was attempted that could change them; status therefore keeps naming earlier failures. |
| unscraped | A ROM file, as defined above, whose entry in its folder's gamelist carries no description, or that has no entry at all: a game the household can see in the frontend that lacks a description. |

An empty folder, one with no ROM file directly in it, has no outcome: it is
not visited and not reported. A directory directly under `/data/roms` named
for no system in the frontend's bundled systems document or the custom
systems the box declares has no extension list: it is a folder whenever it
holds at least one regular file directly in it, it is not fetched and gets
no outcome, the status
section notes it as a folder the frontend does not know (unlike `unmapped`,
a folder the frontend knows but Skyscraper has no platform for), and the run
result is unaffected.

### D2. Manual trigger, no timer and no file watch

A systemd path unit watches only the directory it names, not its
subdirectories, so one on `/data/roms` never sees a ROM land in
`/data/roms/snes/`. One watch per folder needs a declared system list the
tree does not have, still misses multi-disc subfolders, and would retrigger
through a large copy against ScreenScraper's daily quota. A boot-relative
timer was the fallback; it was rejected because the admin is already
connected when ROMs arrive and the Tools entry covers the case where they
are not, so unattended runs buy nothing and spend quota on folders nothing
changed in.

### D3. A plain program as `player`, no unit and no privilege

`emubox-scrape` runs as `player` and refuses any other account, root
included, naming `sudo -u player emubox-scrape` as the command to use;
`admin`'s existing sudo covers that, so no rule is added. It lowers itself to
nice 19 and idle I/O priority, sets the scraper child's `HOME` from the
configured session account's home rather than the caller's inherited `HOME`,
holds an exclusive lock on
`/data/cache/skyscraper/lock` for the run, and writes its output to the
caller's terminal and to `last-run.log`, with the run result, time and
folder outcomes in `last-run.json`, both beside the lock, and keeps the
per-folder fetch revision identities (D6) in `revisions.json` there too. The lock is shared
with `emubox-library-generate`, which takes it without waiting at frontend
start (D6), so a fetch and a generation never run together and neither
program waits on the other.

The lock is a `flock` on an open descriptor that the Skyscraper child
inherits, so the lock is held for as long as either the wrapper or the
scraper lives: a killed wrapper whose child survives keeps the lock held,
and a second run gets `refused` until that child ends. The wrapper runs
Skyscraper in its own process group and ends that group when it exits or is
signalled, so ending the wrapper ends the scraper; Skyscraper itself handles
only SIGINT and has no inter-process cache lock (`src/main.cpp` of the
pinned source), so nothing else keeps two scrapers off the same cache. A
lock whose every holder has ended is released by the kernel, which is why a
lock left by a killed run never blocks a later one.

`/data/cache/skyscraper` is `0755 player player`, and `last-run.json`,
`last-run.log`, `revisions.json` and the pending file are written `0644` by an explicit mode
on the atomic replace, independent of the caller's umask, so the status
reporter can read them as `admin` without sudo; a `mkstemp` replace alone
would leave them `0600`.

Rejected: a system oneshot (`User=player`) started on demand. It gave an
account guarantee, mutual exclusion, a journal record and survival of a
dropped SSH connection, but starting it and following its journal from the
frontend needs root, which meant a root wrapper behind a sudoers rule for
`player`. The refusal, the lock and the two last-run files cover the first
three with no privilege. The fourth is covered by resumability: fetch uses
`onlymissing`, and a folder becomes pending as soon as its own fetch
finishes, so an interrupted run loses nothing and running the command again
continues it. Also rejected: a user unit in `player`'s manager, which `admin`
can only reach through root and which does not exist in the recovery boot
entry, where nobody is logged in.

### D4. Folder discovery and the platform map

A folder is a directory directly under `/data/roms` that holds at least one
ROM file directly in it, as D1 defines both words; a directory with no ROM
file directly in it is empty and is neither visited nor reported. A
directory named for no system the frontend knows has no extension list, so
any regular file directly in it makes it a folder; it is not fetched, gets
no outcome, and is only noted by status (D1). Discovery only decides which
folders exist: Skyscraper's own scan of `-i` handles the files inside, and
every Skyscraper run passes the folder's frontend extension list with
`--addext` so that scan admits every extension the frontend lists, not only
Skyscraper's default formats for the platform. A folder the session account
cannot list is not skipped: it is a mapped folder whose fetch failed, so it
costs that folder alone. The
extension list that decides what is a ROM file comes from the
frontend's bundled systems document
(`${pkgs.es-de}/share/es-de/resources/systems/linux/es_systems.xml`), overridden per system by the rendered custom systems
document the kiosk module builds (D8), which is where the fourteen overrides
of `modules/emulators` carry their own `<extension>` lists; both are store
paths, so the program reads them without privilege and the module passes
their paths to it. A Nix
attrset maps ES-DE folder names to Skyscraper platforms and is rendered to
JSON for the program; a folder absent from the map is `unmapped`. Every
Skyscraper run passes `-i`, `-d`, `-g` and `-o` explicitly with the ES-DE
folder name, so the two naming schemes never meet on disk. A flake check
asserts every mapped platform exists in the pinned Skyscraper's `peas.json`,
so a bump that renames one fails a check rather than a scrape.

Rejected: passing the ES-DE name as `-p` and relying on aliases (they are not
accepted there); deriving the map from `peas.json` aliases at build time
(the aliases are for scraping sites and do not cover ES-DE's names).

Write access to the ROM tree is a property of the tree, not of who created a
folder, and one mechanism makes it so. `modules/library` sets a default ACL
on the ROM root through tmpfiles
(`a+ /data/roms - - - - d:g:player:rwx`); every folder created
beneath it with the default mode, by `admin`, by `player` or by any tool
that does not force a mode, inherits an ACL mask of `rwx` and is writable by
`admin`. The rule is set on the root alone and inherited by what is created
beneath it afterwards, never applied to existing entries, so a boot or a
configuration switch does not walk the ROM tree; the lower-case `a+` is
tmpfiles' non-recursive form, and the root's own access entry is already
given by its `2775` mode, so only the default entry is needed. A folder that
existed before the rule was set is not made writable by it. That is the
whole mechanism: systemd-tmpfiles applies this root-only rule as root;
no privileged repair program or ROM-tree watcher is added. It does not cover a folder created with an explicit
mode that denies group write: verified on a Linux builder, a folder created
by `mkdir -m 0755`, which is how ES-DE creates a system directory
(`es-app/src/SystemData.cpp` through
`es-core/src/utils/FileSystemUtil.cpp`), gets `mask::r-x`, so the inherited
`group:player:rwx` is effective `r-x` and `admin` cannot create inside it,
while a plain `mkdir` under the default umask inherits `mask::rwx` and is
writable. The documented removable-media route can produce such a folder
when a whole folder is copied, because `cp -r` and `cp -a` reproduce the
source folder's mode, which is why the runbook has the reader create each
system folder first and copy the game files into it. ES-DE offers to
create the ROM directories only when no system at all loads
(`es-app/src/main.cpp`), and the Tools system this change adds (D7) keeps
the system list non-empty; the other route,
Utilities > Create/update system directories (`es-app/src/guis/GuiMenu.cpp`),
exists only in full UI mode, which kiosk mode hides and the kiosk module
re-asserts at every launch. The frontend can therefore make a `0755` folder
only in an unlocked full UI session; that case and a folder copied whole
against the runbook keep today's behaviour,
where such a folder is not writable by `admin` until its mode is changed,
and this change accepts that residual as a limitation rather than promising
anything for it. Rejected: having the session account
create every folder up front (it needs the declared system list this
decision does without).

### D5. Fetch

Per folder:

    Skyscraper -p <platform> -s screenscraper -c <config> \
      -i /data/roms/<folder> -d /data/cache/skyscraper/<folder> \
      --addext "<frontend extensions>" \
      --flags unattend,onlymissing,videos,manuals

Credentials are checked before anything is contacted: a config file that is
missing, unreadable, or still holds the committed placeholder makes the run
`refused`. One folder failing does not stop the rest, whether the scraper
exits non-zero, cannot be started, or the folder cannot be listed. Region priority is US,
EU, JP and the language is English, from the config file. The thread count is
an option defaulting to 1, the free account tier.

### D6. Generation as a session-loop step, shown on the TV

Before `cage -s -- es-de`, when any folder is pending, the loop runs
`cage -s -- foot -e emubox-library-generate`. The `-s` is the flag the
frontend's own compositor gets, for the reason the kiosk module gives: without
it cage swallows Ctrl-Alt-Fn, the only route from the running session to a
login prompt, and a large pending set at power-on would otherwise leave the
admin with no console for the length of the overall time limit. The loop
wraps that windowed command in coreutils `timeout`, explicitly referenced
by store path in the contributed step, as `timeout --kill-after=30 2100 cage -s -- foot -e
emubox-library-generate`: the deadline is generation's overall limit (30
minutes, 1800 s) plus a fixed start allowance of five minutes, and on expiry
`timeout` sends SIGTERM and then SIGKILL 30 s later, so a compositor or
terminal that hangs before it ever runs the program cannot hold the frontend
back. Both of the program's own limits start only once it runs; the wrap is
the bound that holds when it never does. The kiosk
module does not write the step itself: `modules/library` contributes the
step's text through a kiosk option, so the kiosk module carries no knowledge
of the library.

Per pending folder the program first creates
`/data/es-de/gamelists/<folder>` as the session account, including missing
parents, removes any work directory an earlier killed or power-cut
generation left there, and then creates a fresh, empty work directory inside
it so the rename below is one atomic operation, copies the folder's existing `gamelist.xml` into it when there is
one, and runs

    Skyscraper -p <platform> -f esde -c <config> \
      -i /data/roms/<folder> -d /data/cache/skyscraper/<folder> \
      -g <workdir> -o /data/media/<folder> --addext "<frontend extensions>" \
      --flags unattend,skipped,videos,manuals,<every skipexisting flag>

Skyscraper reads the previous gamelist it preserves tags from out of the `-g`
folder, so the copy is what it preserves from, and the gamelist it writes for
ES-DE embeds no media paths, so `-o` still names the live media folder while
`-g` names the work directory. On exit 0 within the limit the program renames
the work directory's `gamelist.xml` over
`/data/es-de/gamelists/<folder>/gamelist.xml` in one atomic step
(`os.replace`); on any other outcome (non-zero exit, the time limit, or the
program itself dying) the work directory is discarded and the live file is
untouched. A SIGKILL or a power cut leaves no chance to discard it, so the
sweep before the folder's next generation removes it; because each attempt
starts from an empty work directory, a leftover truncated `gamelist.xml` is
never what Skyscraper reads from `-g` as the previous gamelist, and it is
never renamed live. The live gamelist is therefore at every instant either the
previous file or the completed new one, never a partial write. Skyscraper's
own in-place write and SIGINT-only handling (Context) are why the wrapper and
not Skyscraper owns the live file.

`skipped` keeps an entry for every ROM the cache holds nothing for, so the
tags ES-DE stored on such a game survive regeneration instead of being
dropped with the entry.

The wrapper does not rely on Skyscraper alone for that preservation. Before
the run it parses the copied previous gamelist; after a zero exit it
requires that Skyscraper wrote a new `gamelist.xml` (a changed file, with a
`gameList` root) and merges the previous file into it before the rename:
for each game present in both, matched by its path relative to the folder,
every family field the frontend stores (favorite, hidden, kid game, last
played, play count, sort name, alternative emulator, completed, broken,
controller, collection sort name, and the hide-metadata, no-game-count and
no-multiscrape flags) is taken from the previous entry; a game the previous file held and the output omits is carried over
whole; and a ROM file with no entry at all gets a minimal entry. A duplicate
path in the output, an output that does not parse, or the limit expiring
during the merge is `generation-failed`, and nothing is renamed.

A live gamelist that does not parse, or whose root is not `gameList`, is
never replaced: the folder records `generation-failed` without running the
scraper, the file is left byte-identical, and the journal line names the
folder, says its gamelist is unreadable, and says to repair it or move it
aside. The folder leaves the pending set as any failed folder does, and
status reports its gamelist as unreadable. This is deliberate: a damaged
file may still hold family metadata worth recovering by hand, and
generation cannot tell that apart from a file safe to discard. Moving the
file aside and marking the folder for another fetch is the recovery; the
next generation then starts from an empty previous gamelist.

Generation takes the lock D3 describes, without waiting. If a fetch holds it,
the program does nothing that start: the pending set is left exactly as it
was, one journal line says a fetch was running, it exits 75 - a status it
uses for no other outcome - and the loop launches the frontend at once; the
pending folders are generated at a later start after the fetch has ended.
Manual hardware acceptance must establish that exit 75 survives the real
`timeout`, cage and foot chain. Implementation may continue before that check,
but this remains an unverified dependency. A failed hardware check requires
revising the result channel before hardware acceptance. A lost 75 does no
damage in the meantime: the step then runs failure cleanup, which takes the
claim without waiting, finds it still held by the fetch, and leaves pending
state alone. Only a fetch that ends in the moment between the window closing
and cleanup starting would let cleanup fail folders the skip left pending.

The pending set is the file `/data/cache/skyscraper/pending`, one folder per
line. When generation holds the lock, a folder leaves the set only after its
rename has happened or its `generation-failed` outcome has been recorded, and
the file is rewritten without those folders, never truncated wholesale, so a
folder a fetch appends is never lost. A power cut between a folder's rename
and the pending rewrite therefore only regenerates that folder once more. A
`generation-failed` folder is recorded, reported by status and logged
through `systemd-cat`, and is not tried again until a later fetch makes it
pending, so a bad cache cannot add a delay to every power-on. Each folder has
a time limit and so does the step as a whole; both are enforced by killing
the child. The two limits are constants of the `emubox-library` package, 10
minutes per folder and 30 minutes overall, not options: tuning them is an
edit to the package, and no module option or VM knob exposes them. The
overall limit is terminal for the whole pending set: when it
fires, the program records `generation-failed` for every folder it did not
reach and removes those folders from the pending set too, so a pass that ran
at all leaves the set holding only folders a fetch appended meanwhile.

After the windowed step, the session never retries generation without a
window. The session journals the window's exit status whenever it is
non-zero, so a window that failed to start is told apart from one that hit
its deadline. Exit 75 leaves the pending set untouched even if the fetch has
since ended. Otherwise, if the window failed, hung or was interrupted and
left work pending, a record-only cleanup mode of `emubox-library-generate`
records `generation-failed` for the remaining work from that attempt and
removes it from pending. It does not start Skyscraper, touch gamelists or
media, or generate anything. It logs that generation could not finish with
a progress window and the frontend is starting.

Cleanup takes the shared lock without waiting. The attempted batch carries
per-folder fetch revision identities captured before window launch; cleanup
only fails still-pending entries with those identities, preserving any newer
fetch even for the same folder. Pending membership remains a file of folder
names; revision identities live in `/data/cache/skyscraper/revisions.json`,
a file of their own beside the lock, changed under the same lock. Each successful fetch stores a fresh revision before
publishing its pending entry. A missing or inconsistent revision is treated
conservatively as newer work and is not removed by failure cleanup;
capture still reports such a folder, with a null identity, so a pending
folder always opens the progress window and generation still works it; revision
state survives replacement of the last-run summary. If the claim cannot be taken, cleanup leaves state alone and
logs that cleanup was deferred. The session externally bounds record-only
cleanup to five seconds, ends its process group on expiry, and launches the
frontend even if cleanup or record writing fails. Such a failure leaves
uncommitted entries pending for a later start and is logged; the plan does
not promise successful persistence on an unwritable filesystem. The batch
capture also uses the non-blocking lock and an external five-second bound;
if it cannot finish or a fetch holds the claim, the whole step is skipped
without changing pending state and the reason is logged; for a held claim
the journal line says a fetch was running, the same line generation's own
skip writes, since capture is what normally observes the held claim and
exit 75 covers only a fetch that takes it after capture.

Time spent in this bounded step is outside the frontend crash window. There
is no second generation budget after the windowed pass. The unchanged outer
window deadline can still cost up to 35 minutes plus its 30-second kill grace
when the window command hangs before starting the program; this is an
accepted existing bound, not a claim of immediate startup on that failure.

Rejected: generating inside `emubox-prepare` (it is a settings editor with
ownership tiers, and generation is neither); generating right after fetch
(the frontend may be running); symlinking media into the cache to save space
(links dangle after a cache purge); generating with no display (a first run
over a few hundred games leaves a black screen for minutes); letting
Skyscraper write the live gamelist and restoring a copy afterwards (a kill of
the wrapper itself, or a power cut, between the truncating write and the
restore leaves the truncated file live).

### D7. The Tools system and the deliberate restart

`modules/library` contributes one custom system, `emubox-tools`, full name
"Tools", whose path is a read-only store directory of `.sh` entries and whose
`<command>` names an explicit interpreter or wrapper before `%ROM%`, because
ES-DE resolves the executable before it substitutes `%ROM%`, so a bare
`%ROM%` command loads but fails at launch; manual hardware
acceptance confirms the shape the frontend accepts. "Update game art" runs
`foot -e emubox-scrape`, writes a restart mark under the session's runtime
directory, and ends the frontend. The implementation starts with SIGTERM to
ES-DE, while persistence and relaunch through that route remain pending
manual hardware acceptance. Deferring the probe does not establish that
SIGTERM saves state. The loop, on seeing the mark after a
frontend exit, removes it, does not count that run as a crash whatever its
length, and resets the consecutive-crash count to zero whatever the run's
length, exactly as a run longer than 60 seconds does today; it then runs
generation and relaunches. A requested restart therefore always resets the
count: two unrequested short exits, a requested restart, and one more
unrequested short exit leave the count at one, not three. The mark is
honoured once per exit. If the termination request returns failure, the
entry removes its own mark before returning; the next genuine crash counts.
A successful signal delivery does not prove the frontend will exit: if it
ignores the signal, the mark can still excuse one later crash. That bounded
race remains an accepted limitation; there is no restart acknowledgement
protocol in this change.

Rejected: hiding the entry from the household (ES-DE shows a system whenever
its folder holds a matching file in the kiosk and full UI modes, and the
entry is harmless; Kid mode applies a mandatory kid-game filter to gamelist
entries and so hides its entry, which is acceptable because Kid mode is
reachable only by unlocking the full menu and the kiosk module re-asserts
kiosk mode at every launch);
restarting the whole session (it drops to the display manager and back for
no gain).

### D8. Custom systems become contributions

`emubox.kiosk.customSystems` becomes a list of `<system>` fragments; the
kiosk module wraps them in one `<systemList>` document, in a stable order,
and an empty list still means no file. `modules/emulators` contributes its
fourteen overrides as items, unchanged in text. Rejected: `types.lines` on
the whole document (two modules would each bring a wrapper); a second custom
systems file (ES-DE reads one). The migration sweeps every reader and writer
of `customSystems`, including the controller checks, and updates the README
example to a list of unwrapped `<system>` fragments.

### D9. Credentials

`screenscraper_username` and `screenscraper_password` are declared secrets. A
`sops.templates` entry renders the Skyscraper config (credentials, regions,
language, threads), owner `player`, mode 0400. Scraping is always installed,
so both keys are always required: `just install` refuses to proceed while
either ScreenScraper key still holds its committed placeholder, exactly as it
does for every other required secret. The placeholder guard keeps its single
argument, `<true|false>` (the backups-enabled value), and that argument has to reach it as the
literal `true` or `false`, which the recipe's present `nix eval --raw` cannot
produce: `--raw` on a Boolean exits non-zero with a coercion error, and under
the recipe's `set -euo pipefail` the assignment aborts the install one line
before the guard would run, so the guard has never run at all. The `install`
recipe evaluates the option in a form that renders a Boolean instead, either
`nix eval --json` or `nix eval --raw --apply 'b: if b then "true" else
"false"'`, and that correction applies to the existing
`emubox.backups.enable` evaluation, the guard's only production caller.
Rejected: `-u user:pass` on the command line, which shows in the process
list. The plaintext values in `tests/values.nix` for both new keys are
the literal committed placeholders; `secrets/test.yaml` is encrypted from
those values so the refusal leg exercises the actual placeholder check.

### D10. Status section

A `library` reporter registered through `emubox.status.reporters`: per
folder the ROM file count, gamelist entry count, unscraped count (ROM files
whose gamelist entry carries no description or that have no entry, as D1
defines it, so a `skipped` entry counts; an entry is matched to a ROM file by
its path relative to the folder, so a nested entry with the same file name
does not describe a top-level ROM) and an `unmapped` note or a note
that the frontend knows no system by that name (D1); then the last run's
result and time, folders whose last outcome was `fetch-failed` or
`generation-failed`, and whether anything is pending. A ROM file is what D1
says: a regular file directly in the folder whose extension is in the
frontend's extension list for that system, and the reporter takes those lists from the same two store
paths D4 names, the frontend's bundled systems document and the rendered
custom systems document, so the count mirrors what the household sees in the
frontend. A `.bin` beside a `.cue` therefore counts as a ROM file whenever
the system's list includes `.bin`, exactly as the frontend would list it;
that is by design, since the count mirrors the frontend rather than
second-guessing it. It reads the last-run and pending files and the
gamelists, needs no privilege, and bounds its output like the other
reporters. All filesystem reads run in a worker with a 45-second whole-scan deadline,
including run records, pending state, discovery, directory reads and
gamelist parsing. Records are read first so they can be returned even if
counting stalls; an unavailable record is identified as unavailable. The run
record and the pending file are read independently, and a record that is
unreadable or not JSON marks only itself unavailable: pending state and
folder counts are still reported. A folder the reporter cannot list is shown
with counts unavailable while the other folders are counted. The parent
retains completed folder results, stops the worker on expiry without an
unbounded wait, and returns within 50 seconds including reporting and
cleanup. Incomplete counts are labelled "counts unavailable" rather than
zero; the section explicitly says the scan was incomplete, including when
discovery itself did not finish, and still shows available run records and
pending information. An incomplete scan exits 1 (warning), not an unknown
code or an aggregator timeout. This is independent of the deliberately
unspecified health classification for credential refusal. Rejected: only
checking elapsed time between file reads, since one blocked read can exceed
the aggregator's 60-second limit; caching counts, which adds invalidation
state for files copied outside the scraper. Needing no privilege rests on the modes D3 fixes:
`/data/cache/skyscraper` is `0755 player player` and the two record files,
`revisions.json` and the pending file are written `0644` by an explicit mode on their atomic
replace, so `admin` running `emubox-status` without sudo reads the section
rather than an error or a false "no scrape has run". Rejected: a standalone
`emubox-library` command, which would duplicate the registry.

### D11. One package

`pkgs/emubox-library` (Python, like `emubox-prepare` and the status tools)
provides `emubox-scrape`, `emubox-library-generate` and the reporter, sharing
the folder discovery, the map and the record files. Skyscraper is invoked
through one function so unit tests substitute a stub. `modules/library`
adds `pkgs.emubox-library` to `environment.systemPackages`, so the admin
command and session resolve the same installed entry points. The contributed
session step and Tools entry use explicit store paths for `foot`, and the step
uses an explicit store path for coreutils `timeout`;
cage and systemd remain the session's existing runtime inputs. The library
program resolves from the installed system path, matching the existing
frontend and prepare commands. Evaluation and VM checks prove these paths.

### D12. Testing without ScreenScraper

Unit tests cover discovery, the map, outcomes and run results, the lock, the
account refusal, the credential check, the pending file and the generation
policy, against a stub Skyscraper. The VM test fills a fixture ROM's cache
with the real Skyscraper's `import` module, marks the folder pending, and
lets the real generation and frontend take it from there. Automated session
checks use a deterministic terminal adapter that runs the child and preserves
its exit status. They prove ordering, files, outcomes and restart logic; they
do not prove display or physical frontend interaction. CI uses no OCR or
screenshot assertions for the library. `docs/library-hardware-tests.md`
covers visible progress, physical entry selection, real child termination
and exit-status propagation through the real terminal chain. The
network fetch is upstream's code and is covered by one documented manual
scrape with real credentials. Rejected: a fake ScreenScraper (its API is
HTTPS at a fixed host, so it needs DNS and a trusted certificate in the VM to
prove only that upstream's client works).

## Risks / Trade-offs

### Early probe evidence

The first CI gate runs the nonvisual `checks.x86_64-linux.library` import
probe and pinned-source contracts. Local evaluation and a built test driver
do not establish scraper runtime behavior. CI run `36010935647` at
`d4368db` passed: the real first-run import as `player` with external `-c`
deployed its resources and produced a fixture quickid matching an imported
cache resource. The full flake checks and host build also passed. This clears
the nonvisual implementation gate.

CI run `36005946761` stopped at a standalone visible-text assertion. Cage
obtained the seat and foot started, but OCR returned empty or garbled text.
No screenshot was retained, so this was not proof of a display failure.
The subsequent font/readiness adjustment did not establish hardware behavior.
At the user's request, graphical probes are removed from CI and deferred to
manual testing on the target hardware. The checklist is
`docs/library-hardware-tests.md`. Its checks remain pending, not passed:

- Visible foot output under Cage, alone and from a frontend child.
- Physical selection of a store-backed shell entry with an explicit interpreter.
- Normal frontend shutdown from its child, persisted play count and relaunch.
- Exit 75 propagation through timeout, Cage and foot, with controls.

No hardware installation has been performed yet. These checks and the
real-account smoke tests are deferred until a future installation and
hardware-testing phase. They do not block completion of this implementation
after its automated gates pass; this does not establish readiness to install.
Record hardware revision, software commit and observed results before claiming
hardware acceptance. A failed manual check requires revising the affected
design. This accepts the risk of discovering display or process-chain problems
later; product requirements for visible progress and reliable skips are unchanged.

### Accepted risks and runtime dependencies

- [`foot` may not display under `cage`, alone or over ES-DE] -> manual hardware
  acceptance proves both cases. Implementation may proceed with this risk
  open; a failed check requires revising the display mechanism while retaining
  visible progress and the prohibition on windowless retries.
- [Downloaded artwork reaches a vulnerable decoder] -> accepted explicitly:
  ES-DE's raster texture path calls `ImageIO::loadFromMemoryRGBA32`, which
  calls `FreeImage_LoadFromMemory`. ScreenScraper artwork is external input,
  including when a household member starts the fetch. Keep the existing
  FreeImage permission, patches and vulnerability list, and update its
  acceptance rationale in the flake and packages spec. CI detects build
  regressions; it does not make image decoding safe.
- [Exit 75 may not survive the real `timeout`, cage and foot chain] ->
  manual hardware acceptance checks it with exit 0 and missing-executable
  controls. Until then it is an unverified runtime dependency; a lost 75
  falls back to failure cleanup, which finds the claim still held by the
  fetch and leaves pending state alone (D6).
- [After the outer deadline kills the window, the generation program may
  outlive `timeout` briefly] -> under the real foot it runs in foot's own
  terminal session, outside `timeout`'s process group, and ends on the
  hangup that follows, while its Skyscraper child still holds the inherited
  claim. Failure cleanup therefore retries the claim for up to three seconds
  before deferring; a longer straggler only defers cleanup, which keeps the
  folders pending for the next start. Hardware acceptance records whether
  the retry suffices.
- [Ending ES-DE from a child may skip its own gamelist write] -> probe whether
  SIGTERM to `es-de` is treated as a normal quit; if not, signal its `cage`
  after ES-DE's launch wrapper has returned. The Tools system's own play
  count is the only data at stake.
- [ES-DE may refuse a custom system whose path is a read-only store
  directory outside the ROM directory] -> fallback: a tmpfiles-managed
  directory of symlinks under `/data/roms`.
- [Skyscraper's first run deploys resource files into `~/.skyscraper` from
  its store prefix; with `-c` elsewhere this may behave differently] -> the VM
  test's first run is a first run; the unit under test is the real binary.
- [A long first scrape over SSH dies with the connection] -> accepted: the
  same command resumes it, and the Tools entry runs on the box.
- [ROMs ScreenScraper does not know are asked about again on every run] →
  accepted for a manual trigger; the status section names them so the admin
  can rename or remove them.
- [A household member can start a scrape] -> accepted: it spends quota and
  idle-priority CPU, and ends with a frontend restart they asked for. It also
  holds the display: the scrape's progress is what the TV shows until the
  scrape ends, and there is no way back to the frontend before then. A first
  scrape over a few hundred games is long; later runs are short because only
  games the cache holds nothing for are asked about. The README says so.

## Migration Plan

No data migration. `emubox.kiosk.customSystems` changes type; the only
definer is in this tree and moves in the same commit. Existing gamelists
written by the frontend's own scraper are regenerated with family tags
preserved. Rollback is a generation rollback; the cache, media and gamelists
it leaves behind are inert to an older configuration.

## Open Questions

- The generation time limits (per folder and overall). Start at 10 minutes
  and 30 minutes and set them from the first real scrape at bring-up; they
  change no requirement. They stay package constants (D6): setting them is
  an edit to `pkgs/emubox-library`, not an option, and the `timeout` wrap in
  the session loop follows the overall constant.
