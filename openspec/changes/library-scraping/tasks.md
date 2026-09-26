## 1. Early probes and upstream contracts

CI covers nonvisual contracts. Graphical checks are deferred to manual
post-installation hardware acceptance in `docs/library-hardware-tests.md`.
No hardware installation has been performed yet. These checks, including
the real-account smoke tests, are deferred follow-up work and do not block
completion of this implementation. They remain unchecked and unverified
until hardware testing is scheduled and evidence is recorded.
A failed hardware check requires fixing the design before hardware acceptance.

- [x] 1.1 Scaffold `tests/library.nix` as a nonvisual node built from the host's modules, wire it into the flake's checks and a `just library-test` recipe, and add it to CI; proven by evaluation under `just check-all` and a green CI run
- [ ] 1.2 Deferred until hardware installation: foot under Cage visibly prints progress, alone and as a frontend child; record hardware, revision and observations using `docs/library-hardware-tests.md`
- [ ] 1.3 Deferred until hardware installation: the frontend loads a read-only store system outside `/data/roms` with one `.sh` entry; select it using physical input and record the launch log and accepted explicit-interpreter command shape in design.md D7
- [ ] 1.4 Deferred until hardware installation: termination from a frontend child persists an in-memory gamelist change and the session relaunches; test ES-DE SIGTERM first, then its Cage parent if needed, and record the working route in design.md D7
- [x] 1.5 Nonvisual VM: the real Skyscraper's first run as `player`, with external `-c`, deploys resources and imports a fixture ROM into cache; assert exit 0 and matching quickid/resource entries, and record the CI result in design.md
- [ ] 1.6 Deferred until hardware installation: the exact `timeout --kill-after=30 2100 cage -s -- foot -e <fixture>` chain preserves exit 75, with exit 0 and missing-executable controls; record observed statuses; this remains an unverified runtime dependency until hardware acceptance
- [x] 1.7 Pinned-source contract evidence: add executable checks under `tests/` and a source evidence report under `docs/` for the exact Skyscraper and ES-DE revisions, covering platform names, accepted options/flags, absence of `--stderr`, non-XDG home/resource deployment, cache locking and signal handling, media output and family-tag preservation, and frontend launch/input assumptions; distinguish source inspection from VM evidence; invalid platform and option negative controls fail, and 3.11/3.12 later bind these checks to the actual exported map and vectors

### First CI gate status

Pinned-source contracts passed against 126 platforms, 35 options and 40
flags, including invalid-platform, `--stderr` and invalid-flag controls.
CI run `36005946761` timed out in OCR before reaching the import probe.
The graphical probes have been removed from CI at the user's request;
`tests/library.nix` now runs the real first-import check without a display.
CI run `36010935647` at `d4368db` passed the reduced library check, full
flake checks and host build. The first-run import deployed resources and
matched the fixture quickid to an imported cache entry. Source inspection
and driver builds do not prove hardware behavior. Manual tasks above remain
unchecked; deferral is not a passing result.

## 2. Custom systems as contributions

- [x] 2.1 Failing evaluation check first: two modules contributing `<system>` fragments yield one well-formed `<systemList>` document holding both, identical across two evaluations, and an empty list yields no file path; added beside the existing flake checks
- [x] 2.2 Change `emubox.kiosk.customSystems` to a list of fragments wrapped by the kiosk module in a stable order, with an assertion rejecting a fragment that carries its own `<systemList>` or XML declaration; 2.1's check passes
- [x] 2.3 `modules/emulators` contributes its fourteen overrides as list items with their text unchanged; proven by a check that the rendered document's `<system>` blocks equal the ones the previous single string held, compared by value
- [x] 2.4 Sweep every reader and writer with `rg customSystems`, including `tests/controllers-config.nix`, `tests/kiosk.nix` and `tests/mode.nix`; migrate string inputs to fragments and string consumers to the rendered document or an explicit concatenation appropriate to the assertion; update the README option example to a list of unwrapped `<system>` fragments; proven by `just check-all`, the affected test drivers building, and review of the README example against the option type
- [x] 2.5 Declare the kiosk's optional pre-frontend step option, a `lines` option defaulting to the empty string, which carries a contributed step's text, so `modules/library` can set it in group 4 before the session loop runs it in group 5; with the option unset the session script contributes no step text; proven by an evaluation check that the default is empty and that the session script rendered without `modules/library` contains no library step text

## 3. The `emubox-library` package

Red then green per task; the tests live in `pkgs/emubox-library/` and run as
the package's check phase and as a flake check. Skyscraper is reached through
one function the tests replace with a stub.

- [x] 3.1 Package skeleton (`package.nix`, `ruff.toml`, the three entry points `emubox-scrape`, `emubox-library-generate` and the status reporter), wired into `pkgs/default.nix`, the overlay and the flake checks the way `emubox-status` is; proven by the package building on the builder with an empty passing test suite
- [x] 3.2 Folder discovery and the platform map: a folder is a directory directly under the ROM root that holds at least one ROM file directly in it, where a ROM file is a regular file whose extension is in the frontend's extension list for that system (design D1; the lists come from the two store paths D4 names, the frontend's bundled systems document and the rendered custom systems document, whose paths the module passes to the package); a directory with no ROM file directly in it is empty and is neither visited nor reported; `unmapped` for a name absent from the map, a directory named for no system in either document treated as a folder whenever any regular file lies directly in it, not fetched and given no outcome (design D1), and the frontend's folder name used for cache, gamelist and media paths whatever the platform is called; unit tests by value, including a directory holding only subdirectories with no files (not discovered), a directory holding only sidecar files whose extensions are not in the system's list (not discovered), and a directory named for no system holding files (discovered, not fetched, no outcome, run result unchanged)
- [x] 3.3 Account refusal: any effective user other than the configured session account, root included, exits non-zero naming `sudo -u player emubox-scrape`, invokes nothing and writes nothing; unit tests including that the record files are untouched
- [x] 3.4 Credential check: missing, unreadable and placeholder config each give `refused` with its own message before the Skyscraper function is called, and each replaces the last-run record with one whose result is `refused`, whose cause names that case and which keeps the previous record's folder outcomes; unit tests start from a previous record holding a failed folder and assert by value that it is replaced by the `refused` record carrying that folder's outcome, that the stub was never invoked and that the pending file is unchanged
- [x] 3.5 The lock: a second run while the lock is held gives `refused` and leaves the first run's records alone; the lock is a `flock` on an open descriptor the Skyscraper child inherits, the child runs in its own process group and the wrapper ends that group when it exits or is signalled (design D3), so a lock whose every holder has ended does not block; unit tests using a real held lock in a temporary directory, plus a process-level test that runs the real wrapper with a stub scraper that signals readiness and stays alive, kills the wrapper, asserts a second run is `refused` while the stub lives, and asserts the second run proceeds once the stub is gone
- [x] 3.6 Fetch: the exact argument vector of design D5 per folder, carrying no option the pinned scraper does not declare (there is no `--stderr`), nice and idle I/O priority set on the run, scraper child HOME set from the configured session account rather than the inherited environment (unit assertion with an admin HOME), folder outcomes and run results exactly as design D1 defines them, exit status non-zero unless `complete`; unit tests for mixed folders, all-success, all-failed and no mapped folders by value
- [x] 3.7 Resumability: a folder is appended to the pending file the moment its fetch is `fetched`, without duplicates, written atomically, with a fresh per-folder fetch revision identity persisted in `/data/cache/skyscraper/revisions.json` before pending publication, under the same lock, for every successful fetch (including refetch of an already pending folder); unit test proves revisions change on refetch; a process-level test runs the real wrapper with a stub scraper that completes the first folder and signals readiness while working the second, SIGKILLs the wrapper there, and asserts the first folder is in the pending file with its revision persisted in `revisions.json`, so a build that publishes pending only when the run ends fails
- [x] 3.8 Records: `last-run.log` receives the output the terminal receives, `last-run.json` holds result, time and folder outcomes, both replaced atomically with an explicit mode of `0644` independent of the caller's umask, as are `revisions.json` and the pending file (design D3); unit tests parse the JSON by value and assert the mode of both record files, `revisions.json` and the pending file is `0644` after a replace performed under a `077` umask
- [x] 3.9 Generation: the exact argument vector of design D6 per pending folder, `skipped` among the flags and no option the pinned scraper does not declare; the lock of design D3 taken without waiting, and when it is held: nothing invoked, the pending file unchanged, one journal line saying a fetch was running, exit 75, a status used for no other outcome so the session can tell that skip from a failure (design D6); a per-folder and an overall time limit, package constants of 10 and 30 minutes rather than options (design D6), enforced by killing the child; `generated` or `generation-failed` recorded per folder, a journal line per failure through `systemd-cat`; the live gamelist never written in place: per folder the live gamelist parent and any missing ancestors are created as the session account, any work directory an earlier killed or power-cut generation left in that parent is removed, then a fresh, empty work directory is created inside that parent, the folder's existing gamelist copied into it, Skyscraper run with `-g <workdir>` while `-o` still names `/data/media/<folder>`, and on exit 0 within the limit the work directory's `gamelist.xml` renamed over `/data/es-de/gamelists/<folder>/gamelist.xml` with `os.replace`, the work directory discarded and the live file untouched on any other outcome; the overall limit terminal for the whole pending set, every unreached folder recorded `generation-failed`; a folder removed from the pending file only after its rename or its failure record, by rewriting the file, never truncating it, so a line appended meanwhile survives; exit status always 0 apart from that skip; unit tests for success with no existing gamelist directory, non-zero exit (live gamelist byte-identical), a hang (live gamelist byte-identical), an unreadable pending file, the held lock (stub lock held, generation invokes nothing, pending byte-identical, exit status 75 asserted by value, with the success, non-zero-exit and overall-limit cases asserted to exit 0 so the status distinguishes the skip from every other ending), the overall limit firing with folders unreached (every unreached folder recorded `generation-failed` and none of them left in the pending file), the interrupted write (the generate process itself, not only the stub, is killed while the stub is writing the work directory's gamelist: the live gamelist is byte-identical to before and the folder is still pending; the folder's next generation then leaves no work directory in the parent afterwards), a stale work area (a leftover work directory holding a truncated `gamelist.xml` is planted in the parent before generation, with and without a live gamelist: the stub records what it finds in `-g` and asserts the truncated file is absent from it, the stale directory is gone afterwards, and the live gamelist is never the truncated file, for both a successful and a failing run), the ordering (the rename is observed to happen before the pending rewrite, by killing the process between the two and asserting the new gamelist live with the folder still pending) and the rewrite (a line appended to the pending file while the stub runs is still there afterwards)
- [x] 3.10 Reporter: the section design D10 describes, with a separate worker for all filesystem reads (records and pending first, then counting), a 45-second whole-scan deadline and a parent that returns within 50 seconds including shutdown, completed results retained and unfinished counts labelled "counts unavailable", an explicit incomplete-scan notice and exit 1 on incomplete counts, available run records and pending information still shown; process tests with a worker blocked during discovery and during a gamelist read prove a warning within a shortened test deadline, no fabricated zero, and no unbounded wait for worker exit; a plain "no scrape has run" with no record files; a ROM file counted as design D1 defines it, a regular file directly in the folder whose extension is in the frontend's extension list for that system, the lists read from the frontend's bundled systems document and the rendered custom systems document (the store paths of design D4, the custom document overriding the bundled one per system); unscraped counted as ROM files whose gamelist entry has no description or that have no entry, matched by path; a fixture folder holding a `.cue`, its `.bin` and a sidecar file outside the list, under a system whose list includes both `.cue` and `.bin`, asserting by value a ROM file count of two, the sidecar not counted, and the unscraped count following those two files' gamelist entries; a second fixture under a system whose list lacks `.bin` asserting the count of one; a third fixture directory named for no system, holding files, noted in the section as a folder the frontend does not know; unit tests against fixture gamelists and records asserting by value the section's text for each of: no records, `complete` with every folder `generated`, `partial`, `failed`, `complete` with one `generation-failed` folder, and an `unmapped` folder with no failures
- [x] 3.11 Flake check that every platform in the map exists in the pinned Skyscraper source's `peas.json`; proven by the check passing and by failing when a bogus platform is added to the map in the check's own negative case
- [x] 3.12 Flake check that every option and every `--flags` value the package passes to Skyscraper (the fetch and generation vectors of design D5 and D6, exported by the package for the check) is declared in the pinned source's `src/cli.cpp`, so a stub-based unit test can never hide an option the real binary rejects; proven by the check passing and by failing in its own negative case when `--stderr` is added to a vector

- [x] 3.13 Record-only failure cleanup and batch capture: capture pending folders with their fetch revision identities from `revisions.json` under the non-blocking shared lock before window launch, a held lock skipping the step with the journal line saying a fetch was running; cleanup takes the same lock without waiting and records `generation-failed` only for still-pending captured revisions, then removes those entries without invoking Skyscraper or touching gamelists/media; no cleanup on exit 75; revision state survives last-run replacement, is persisted before pending publication, and missing or inconsistent identities are preserved conservatively: capture reports a pending folder with no identity as null, so it still opens the progress window, and cleanup never removes it; a malformed `revisions.json` or `last-run.json` reads as empty rather than ending capture, fetch, generation or cleanup; unit tests cover a pending folder with no identity, malformed and non-object state files, a failed window, a partially completed batch, newer fetches for both a new folder and the same folder, a held lock, unwritable records, and interrupted cleanup leaving uncommitted entries pending

## 4. Module wiring

- [x] 4.1 Options: thread count (default 1); the platform map as a Nix attrset rendered to JSON for the package; tmpfiles for `/data/cache/skyscraper` as `0755 player player`; a default ACL on the ROM root through tmpfiles, the non-recursive root-only line `a+ /data/roms - - - - d:g:player:rwx`, so a system folder created beneath it afterwards with the default mode is writable by `admin`, the sole write-access mechanism (design D4), set on the root alone and never applied to existing entries so a boot does not walk the ROM tree, with no unit watching `/data/roms`; existing systemd-tmpfiles applies the root-only rule as root, while fetching, generation and reporting require no root privilege; `${pkgs.es-de}/share/es-de/resources/systems/linux/es_systems.xml` and the rendered custom systems document passed to the package for its extension lists (design D4); `modules/library` sets the kiosk option of 2.5 to the generation step's text; `modules/library`'s header comment states what the module holds and cites no document, and its TODO is gone; proven by an evaluation check on the rendered map, the tmpfiles rules asserting by value that the ACL line is exactly `a+ /data/roms - - - - d:g:player:rwx` and that no rule for `/data/roms` uses tmpfiles' recursive upper-case ACL type, the cache directory's mode, both systems-document paths (including existence of the bundled document in a package check), and the kiosk option's rendered text
- [x] 4.2 Secrets: `screenscraper_username` and `screenscraper_password` declared, placeholders added to `secrets/secrets.yaml`, the same literal placeholder values defined in `tests/values.nix` and encrypted into `secrets/test.yaml`, a `sops.templates` Skyscraper config owned by `player` mode 0400 carrying credentials, regions US, EU, JP, language en and the thread count; proven by extending the secrets assertions in `tests/default.nix` for path, owner and mode
- [x] 4.3 Placeholder guard and the Boolean the install recipe must render: `scripts/emubox-install-placeholder-guard` keeps its single argument, `<true|false>` (the backups-enabled value), and exits with its usage error for any other count or value; the two ScreenScraper keys are always required, so no argument exempts them and an unresolved placeholder in either blocks install; the `install` recipe in the justfile, the guard's only production caller, stops evaluating `emubox.backups.enable` with `nix eval --raw`, which exits non-zero on a Boolean with a coercion error and, under the recipe's `set -euo pipefail`, aborts the install one line before the guard runs, and evaluates it in a form that renders a Boolean instead (`nix eval --json`, or `nix eval --raw --apply 'b: if b then "true" else "false"'`); this corrects the existing evaluation, since the guard has never run; `tests/test-install-placeholder-guard.sh` gains a case for each ScreenScraper key holding its placeholder and the usage error on no argument and on a non-Boolean one, plus a check that runs the evaluation expression the recipe uses against the host configuration and asserts its output is the literal `true` or `false` the guard accepts, so a value the guard would reject fails a check rather than an install; `just install-guard-test` passes; `secrets/README.md` names the keys and its placeholder count is corrected
- [x] 4.4 The Tools system: a store directory with the "Update game art" entry and the custom system fragment contributed through 2.2's option, the entry following design D7 using ES-DE SIGTERM provisionally, with the actual persistence/relaunch route still awaiting manual hardware task 1.4; `pkgs.emubox-library` added to `environment.systemPackages`; the contributed step references coreutils `timeout` and `foot` by explicit store paths and the Tools entry also uses an explicit `foot` path, while the generation command resolves from the installed system path; an evaluation assertion covers the installed package and rendered dependency paths, and the VM resolves all three installed entry points; proven by an evaluation check that the rendered custom systems hold `emubox-tools` and that the entry script builds (shellcheck) on the builder
- [x] 4.5 Status reporter registered as `library` through `emubox.status.reporters`; proven by adding a host-level registered-reporters assertion beside `tests/status.nix`'s module checks and by the VM library section
- [x] 4.6 No new privilege: an evaluation check that `security.sudo.configFile` and the polkit configuration are byte-identical to the ones the host renders with `modules/library` absent

## 5. The session loop

- [x] 5.1 Generation step contributed, not built in: the session loop runs the pre-frontend step option of 2.5, filled by `modules/library`; the step captures the attempted pending batch without waiting for a fetch, externally bounded to five seconds with unchanged pending and frontend launch on capture failure, a claim held at capture skipping the step with the journal line saying a fetch was running, runs `timeout --kill-after=30 2100 cage -s -- foot -e emubox-library-generate` with the dependency paths of 4.4, captures the exit status, and excludes the step from crash timing. Exit 75 skips all further work; any non-zero exit status is journalled; otherwise remaining work receives the record-only cleanup of 3.13, externally bounded to five seconds including process-group termination, with no windowless generation. Failed or deferred cleanup is logged and cannot prevent frontend launch. Proven by the built `just session-check`, unit assertions that no retry command is emitted, and 6.8/6.9

- [x] 5.2 Requested restart: the mark under the session's runtime directory is removed when seen after a frontend exit, that one run is not counted as a crash whatever its length, and the consecutive-crash count is reset to zero whatever the run's length (design D7), so two unrequested short exits, a requested restart and one more unrequested short exit leave the count at one; the Tools entry removes its own restart mark if the termination request returns failure; proven by `just session-check`, 6.6, and a failed-signal fixture followed by a real crash asserting the count increments instead of resetting; successful signal delivery without a subsequent exit remains the documented one-crash limitation
- [x] 5.3 The kiosk module's stale `TODO: emubox-leakcheck` line, which names a tool the saves capability decided against, is removed in the same edit; proven by the diff

## 6. The library VM test

Every automated leg asserts by value; the vm-test delta is the checklist.
Use a deterministic terminal adapter for session logic, preserving its child
command and exit status. CI does not use OCR, screenshots or UI navigation
as assertions. Real display, input and terminal-chain behavior are manual
hardware acceptance checks.

- [x] 6.1 Ingest ownership: `admin` creates a directory and a fixture ROM under a system folder, asserted group and mode, and read as `player`; a second leg where `player` creates a system folder with a plain `mkdir` under the default umask and `admin` then creates a file in it without a permission error, asserted as `player` reading it, the default ACL of 4.1 being what makes the creation succeed
- [x] 6.2 Generation at start: cache filled by 1.5's import run, folder made pending, session started; gamelist entry with the fixture's description, supported media under `/data/media` with a cached wheel asserted at the marquee destination and cached textures not emitted (no `textures` or `wheels` directory required); start with no live gamelist parent and assert its creation, pending empty, generation invoked through the test terminal adapter, all ordered before the frontend's start time; the generation compositor asserted to be started with the same console-switch flag as the frontend's, by inspecting the production session script's text; then the frontend is up
- [x] 6.3 Preservation: a gamelist written beforehand gives two fixture ROMs, the cached one and a second the cache holds nothing for, a distinct non-default value for each of the eight fields (favourite, hidden, kid-game, completed, play count, last played, sort name, alternative emulator); after generation both entries exist, the cached one with its description and the uncached one without, and each of the eight values is asserted by value on both; a negative control shows the assertion fails when any one field is dropped from either entry and when the uncached entry is absent
- [x] 6.4 Refusals: root, `admin` and a second run under a held lock, each by exit status, message and unchanged records; placeholder credentials as the session account, starting from a previous successful last-run record, asserted by exit status, message, the last-run record replaced by one showing `refused` with the placeholder as the cause, and the pending file byte-identical; `sudo -l` for `player` equals the list captured from a node without the capability
- [x] 6.5 Generation failure: a pending folder whose cache is unreadable gives `generation-failed`, a journal line naming the folder, the frontend up, and nothing pending afterwards
- [x] 6.6 Session restart logic: invoke the Tools command through its explicit interpreter with a deterministic terminal adapter, assert the requested-restart mark is honoured and a new frontend process replaces the old one; three requested restarts leave the session running, three unrequested short exits after a requested one end at the greeter, and two unrequested short exits, a requested restart and one more unrequested short exit leave the frontend relaunched; record physical frontend selection, visible progress and real child termination separately in the hardware checklist
- [x] 6.7 Status: `emubox-status`'s `library` section after the legs above, the fixture folder's counts (the uncached ROM counted as unscraped although it has an entry), the last result and the failed folder asserted by value; every one of these assertions run twice, from the test driver as root and as `admin` without sudo (`runuser -u admin -- emubox-status`), with the `admin` run asserted to show the same section rather than an error or "no scrape has run", and the modes of `last-run.json`, `last-run.log` and the pending file asserted `0644`
- [x] 6.8 Window failure: replace the window command with a failing stub and then with a stub that hangs before launching generation under a short test-only external deadline; in both cases assert the process is ended, no scraper or windowless generation starts, attempted pending entries become `generation-failed`, the live gamelist remains unchanged, the reason is logged, and the frontend launches; cover interrupted windowed generation with one folder already completed, preserving its replacement; prove a stalled batch capture leaves pending unchanged and launches the frontend within its bound; prove cleanup lock contention, write failure and a stalled cleanup cannot delay frontend beyond the cleanup bound and leave uncommitted pending entries intact
- [x] 6.9 Claim held at start: while a fetch holds the shared lock, assert the frontend launches, pending is byte-identical and the journal holds the line saying a fetch was running; release and restart to generate. For the windowed skip itself, a test-only handshake pauses the session after batch capture, acquires the fetch lock, then lets the generation command through the test terminal adapter observe it and return 75. Pause again after the command returns but before result handling, release and acknowledge the fetch lock, then resume. Assert no generation or failure cleanup runs, pending is unchanged, and the frontend launches; a negative control discarding exit 75 and taking the failure-cleanup path must fail the pending assertion. No journal timing is used as a barrier. The real-chain status check from 1.6 is separate manual hardware acceptance, not CI proof

- [x] 6.10 Positive admin route: from an actual `admin` session invoke the exact documented `sudo -u player emubox-scrape`, with the inherited `HOME` deliberately pointing at admin's home; a test-only scraper stub and non-placeholder fixture config avoid contacting ScreenScraper while exercising the real wrapper, credential and account checks, PATH and sudo; assert a successful last-run record and fetched folder outcome, then use 1.5's real import probe to prove resource deployment under the session account home; no new sudo rule

## 7. Documentation

- [x] 7.1 README "Library" section: the copy command over SSH and why archive mode is wrong; the on-box ingest route that works today, switching to desktop mode with `sudo emubox-mode desktop` as the "Desktop and recovery" section already describes and copying from removable media as the session account, telling the reader to create each system folder first (a new folder in the file manager or a plain `mkdir`, which the ROM root's default access rule makes writable by `admin`) and then copy the game files into it, because copying a whole folder reproduces the source folder's mode and produces one `admin` cannot write into; both scrape routes, that art appears at the next frontend start, one sentence telling the household that "Update game art" holds the TV until the scrape ends and that later runs are short, that the SSH route waits on remote administration while the Tools entry does not, the ScreenScraper account chore, the manual real-credential scrape, and what `emubox-status` shows; the layout listing names `modules/library` and `pkgs/emubox-library`; proven by the library spec's documentation scenario read against the rendered section in review
- [x] 7.2 The post-install checklist names the two new secrets; proven by the same review
- [x] 7.3 Correct the FreeImage permission rationale in `flake.nix`: explicitly accept externally downloaded ScreenScraper artwork passing through the vulnerable decoder, including household-triggered fetches, without claiming CI or admin initiation makes it trusted; preserve the permission and vulnerability metadata; proven by review against the packages delta and the existing package checks

## 8. Gate and reviews

- [ ] 8.1 `just check-all` passes at the final implementation commit, and the host toplevel, the session script, `pkgs/emubox-library` and the library and kiosk test drivers build on the x86_64-linux builder; the commands' final lines are recorded under this task
- [ ] 8.2 A green CI run of every check at the final implementation commit, its run number recorded under this task, since the session script's text changes and with it every VM check
- [x] 8.3 Per-group evidencing reviews and the closing review wave the implementation workflow requires, with findings and their resolutions recorded under this task


8.1 and 8.2 are reopened for the commit that closes group 9. The evidence
below names `4b3af66` and run 36044891955; a later run, 36169570415, was
green at `82eaaf2` before group 9 began.

## 9. Verification fix round

- [x] 9.1 A folder the session account cannot list, or a scraper that cannot be started, records `fetch-failed` for that folder alone and the run continues and writes its record (design D4, D5); unit tests with an unreadable folder beside a good one and with an `invoke` that raises `OSError`
- [x] 9.2 Status reads the run record and the pending file independently: an unreadable or non-JSON record marks only itself unavailable, and an unlistable folder shows counts unavailable while others are counted (design D10); unit tests for `{bad`, mode 000 and an unlistable folder
- [x] 9.3 An unparseable live gamelist is left byte-identical, records `generation-failed`, and the journal line names the folder, says its gamelist is unreadable and says to repair it or move it aside (design D6); the existing invalid-gamelist unit test asserts the journal text
- [x] 9.4 Journal writes never raise, whether `systemd-cat` is missing or hangs; unit tests for both
- [x] 9.5 Failure cleanup keeps taking the claim without waiting; a generation program that outlives the window's deadline only defers cleanup (design, accepted risks), and the hardware runbook records how long it lives; the existing held-lock cleanup test still proves the deferral
- [x] 9.6 Status matches gamelist entries to ROM files by relative path (design D10); unit test with a nested entry sharing a top-level ROM's file name
- [x] 9.7 Generation prints a heading per folder, as fetch does
- [x] 9.8 Unit tests: the literal fetch vector (with `onlymissing`, and no `-g`, `-o` or `-f`) written out by hand rather than read from the vectors file; a folder whose platform name differs from its folder name; the mixed-folders run with an empty and a sidecar-only directory; a refused second run while a live first run finishes and records its own result; nothing pending leaves the gamelist tree untouched
- [x] 9.9 VM test: the failed-termination and held-claim assertions read only their own subtest's evidence and prove generation ran; a real-Skyscraper run of the production fetch vector (with only the scraping module and config swapped for the local import) leaves gamelists and `/data/media` unchanged; nothing pending opens no window and leaves the gamelist byte-identical; screenshots, videos and manuals from the import fixture land under `/data/media/nes` (the pinned import scraper reads no textures folder, so texture non-emission keeps its source-contract evidence); the Tools-triggered restart carries the fixture description; credentials never appear in fetch arguments; the lock holder is still active when a concurrent run is refused; requested restarts log no crash count; a nested admin directory and an admin file in a session-account folder carry the `player` group
- [x] 9.10 README gives the unreadable-gamelist recovery and the smoke test's exact restart route; the hardware runbook records whether cleanup's retry covers the generation program outliving the outer deadline
- [x] 9.11 A scoped fresh review of `2ef007a`, `ef1a210`, `82eaaf2` and this group's commits, recorded below with the test count
- [x] 9.12 Wave fixes: generation serializes and re-parses the merged gamelist before publishing, detects Skyscraper's write by a sentinel modification time, carries the previous file's system-level elements (the system alternative emulator) when the output lacks them, and records outcomes without inventing a run result when no record exists; status treats a gamelist with no `gameList` root or an unreadable one as unreadable for that folder alone; a second termination signal cannot skip ending the scraper's process group; unit tests for each, and duplicate-entry counts in the merge assertions
- [x] 9.13 Wave test fixes: the Tools restart proves regeneration from a gamelist with no description, the VM shows a frontend-only format with no previous entry gaining the scraper's description, the unreadable-gamelist journal check covers both unparseable and wrong-root files, and redundant negative controls and duplicated test halves are removed
- [x] 9.14 Every remaining review finding: a signalled fetch records `interrupted` with the outcomes it finished and the previous ones carried (unit test, design D1); failure cleanup retires a null-identity folder while its revision is still absent (unit tests for retired and for a revision written since capture); a restart mark that is too old at the frontend's exit lapses and the exit counts (session-restart test; first built with a 60-second lapse, shortened to 15 seconds by 9.15); cleanup's held-claim journal line says the library claim was held; stale atomic-write temporaries are swept under the claim; the command entry points print a one-line cause instead of a traceback for a missing or malformed config, an unreadable systems document or a failed priority change; merge identities do not resolve symlinks, so a symlinked alias is its own game; a pending folder the frontend lists no system for fails generation with a journal line; carried system-level elements skip `<folder>` entries whose directory is gone; status says "No completed fetch recorded" for a record without a result; `just eval` covers the new host-only checks; the host-side player groups match a plain node at evaluation; the test window's event label names the command it ran; the redundant generation-count assertion is dropped; an unlistable folder that is unmapped or unknown keeps that classification (unit test); stale kiosk test comments are corrected
- [x] 9.15 Review fixes for 9.14: a restart request lapses unless the frontend exits within 15 seconds of it, with a session-restart sequence for a request ignored and a crash inside the launch window, and the hardware runbook records the time from request to exit; a termination signal anywhere in a scrape's claimed section records `interrupted`, with the exit status pinned through the entry point; the log and record writes of an interrupted run are attempted independently; carried outcomes omit folders that no longer exist; ROM files include symbolic links to regular files, matching the frontend and the merge; the merge's lexical containment is commented; generation parses the systems documents once per run
- [x] 9.16 Re-review minors for 9.15: an unreadable folder while carrying outcomes counts as absent and never skips the record writes; the termination handlers are installed before the claim is used and disarmed before they are restored, and a signal after the final record write cannot relabel it; the fetch vector takes the already parsed extensions; tests for SIGINT and SIGHUP between folders, a symlink loop, an unknown system's linked file, the 15-second lapse boundary, and a scraper that emits both a link and its target; the session harness comments why an aged mark on an immediate exit is a fair model

### Implementation review evidence

Per-group reviews covered the custom-system migration (`8db220c`), package
and credential fixes (`45f388c`, `8c74a20`), module/session/documentation
integration (`92cf563`), and nonvisual VM scenarios (`9b269a6`, `15f30db`,
`51d647b`). The closing review covered the whole change from `eb9a72e`,
with separate concurrency, public-interface, idiom and proportionality
lenses. Its fixes added cover-output, direct-generation and child-HOME
assertions, corrected the hardware checklist and removed duplicate static
source checks. Scoped rereview found no remaining blocking issues.

The completion audit identified three missing package-test proofs:
existing records surviving account refusal, process HOME and scheduling,
and terminal/log equivalence. `77eb9bb` adds those tests. Five deliberate
regressions fail their corresponding assertions; native and Linux package
builds each pass Ruff, formatting, ty and 46 tests. Scoped review and the
subset audit confirm all three corrections. An initial audit reused a reviewer while the concurrent agent slots were
full. After a slot became available, a fresh reviewer independently
confirmed all 29 checked boxes at `8cec8ad`, with no unevidenced findings.
Expanded VM execution subsequently passed in CI; the manual hardware checks remain pending.


### Final automated gate evidence

The final implementation commit is `4b3af66`. Subsequent task-evidence
updates contain documentation only. CI run
[36044891955](https://github.com/mjkoo/emubox/actions/runs/36044891955)
completed successfully at that commit: format check, library nonvisual
integration, full flake checks and host closure build all passed. This
includes the installed-system secrets assertions and all library VM
scenarios. The preceding run also passed the full library test, finishing
its script in 182.44 seconds, before exposing an outdated reporter-set
expectation in the controllers test; that expectation is now corrected.

`direnv exec . just check-all` exited 0 at `4b3af66`. Its final checks were
`actionlint`, `zizmor .github/workflows` ("No findings to report") and
`bash tests/test-install-placeholder-guard.sh`. An ignored Nix SQLite
cache-busy warning did not fail the command.

The following build command exited 0 at the same commit, resolving all
required Linux outputs on the configured builder:

```sh
nix build .#nixosConfigurations.emubox.config.system.build.toplevel \
  .#checks.x86_64-linux.session .#packages.x86_64-linux.emubox-library \
  .#checks.x86_64-linux.library.driver .#checks.x86_64-linux.kiosk.driver \
  --no-link -L
```

The package passed Ruff, formatting, ty and 47 tests on native and Linux
builds. Both VM drivers reported "All checks passed!" for their type and
lint checks. The final combined build used already-built outputs and
completed without a new build error. The updated controllers driver also
built successfully.

Post-audit corrections received scoped reviews: desktop session executable
resolution, ACL-mode and status assertions, test-service command paths,
the dedicated dummy frontend, stderr capture, transient lock-holder paths,
and the registered library status section. Successful cleanup now emits
no false failure summary; a red-then-green regression covers both no-op
and actual-failure logging, and a subset audit confirmed the affected
cleanup and review tasks. No blocking review findings remain.

### Post-implementation review

A later review found that the interrupt raised on SIGTERM or SIGHUP was an
`OSError`, so generation's per-folder file-error handler absorbed it and
went on to the next folder. A dedicated exception now ends generation,
leaving unfinished folders pending for the session's cleanup; a
red-then-green process test covers both signals. The same review made the
status reporter keep counting past a malformed gamelist or run record,
narrowed the credential check to credentials containing the committed
placeholder marker (a substring match, as the install guard's), added
a closing scrape result line to the terminal and `last-run.log`, and
removed duplicate installed data files. The package passes Ruff,
formatting, ty and 58 tests on native and Linux builds; `just check-all`,
the source contracts, the library and session drivers and the host
toplevel pass locally. The library VM test awaits its next CI run.

### Second post-implementation review

A further review found that a malformed or non-object `last-run.json` or
`revisions.json` stopped generation and cleanup from draining pending, so
every start reopened the progress window; both now read as empty. Capture
omitted pending folders with no revision, so they never opened a window; it
now reports them as null, and cleanup still never retires them. A refused
run replaced the record's folder outcomes, hiding earlier failures from
status; it now carries them forward. The session journals the window's
non-zero exit status. The pre-frontend step option is empty text by default,
checked against the session script of a host without the library. The
source-contract check moved to the host-only checks, since it reads the
host's pinned sources. VM journal assertions now read only the lines their
own subtest produced, and the failed-termination leg no longer relies on a
sleep. The package passes Ruff, formatting, ty and 73 tests on native and
Linux builds; `just check-all`, the source contracts, the custom-systems,
session and session-restart checks, the library and kiosk drivers and the
host toplevel pass. The library VM test awaits its next CI run.

Graphical acceptance remains explicitly deferred to manual tasks 1.2,
1.3, 1.4 and 1.6. Green CI establishes no result for those checks. The
separate verification and archive workflows have not been invoked.

### Verification fix round review

A verification pass found no missing requirement; its findings became
group 9. A fresh scoped review of `2ef007a`, `ef1a210` and `82eaaf2` found
no critical issue and five to fix: a merged gamelist that the next run
would refuse as unparseable, the system-level alternative emulator dropped
on regeneration, timestamp-granularity change detection, a VM test that did
not exercise `--addext`, and design text that overstated carry-over. The
group's evidencing review confirmed all ten boxes. A wave of three
reviewers (failure modes, test proportionality, idiom and public surface)
found no critical issue. It led to reverting a cleanup claim retry that
contradicted the no-wait rule, a once-only termination handler, a shared
readability rule for status and generation, no invented run result, the
merge hardening, and removal of redundant tests; the texture import it
suggested was refuted, since the pinned import scraper reads no textures
folder. One fix round landed in `3427a73`..`32b12e9`, and its scoped
re-review confirmed every fix. Its remaining finding, a password containing
`:` that Skyscraper silently ignores, was fixed in `6bd5f5f` together with
two minor hardening items. The package passes Ruff, formatting, ty and 114
tests (one skipped on macOS); the library driver, package, source-contract
and session-restart checks build on the Linux builder. The library VM test
awaits its next CI run.

### Remaining findings review

Every finding the earlier rounds had left as minor was then implemented
(`b9c0cd7`..`ac1a491`). A fresh review confirmed each clause and raised two
issues: the 60-second restart lapse could not change any outcome, since a
mark older than the launch window implies a run long enough to reset the
count anyway, and `interrupted` was recorded only for a signal arriving
while the scraper ran. The lapse became 15 seconds, closing the case of a
frontend that ignores the request and crashes inside its launch window, and
the termination handlers now cover the whole claimed section
(`0168c9d`..`858e70e`). A re-review approved that range; its minors were
fixed in `641d59f`..`ac07510`, with the handler disarmed just before the
final record write rather than after it, because a signal between the write
and a later disarm would still relabel the record. A last re-review
approved that range. Its assertion note was fixed in `41569a3`; two notes
were refuted: a signal in the microseconds between an unexpected error
leaving the claimed section and the section's cleanup cannot be excluded by
any ordering of that cleanup, and the pending-signal drain on exit cannot be
driven deterministically without hooks the code would carry only for the
test. The package passes Ruff, formatting, ty and 157 tests (one skipped on
macOS; 158 on Linux); the package, library and kiosk drivers, session and
session-restart checks build on the Linux builder, and `just check-all` and
`just eval` pass. The library VM test awaits its next CI run.
