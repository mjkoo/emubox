## Purpose

Getting games onto the box and turning them into a browsable library: how
ROMs the admin copies in become usable, how their art, descriptions, videos
and manuals are fetched and shown, who may start that and from where, and how
the admin sees what state the library is in. The words ROM file, folder,
fetch, generation, pending, unscraped, the folder outcomes and the run
results are defined where they are first used below and mean the same thing
throughout.

## ADDED Requirements

### Requirement: ROMs the admin copies in are usable by the session account
A file or directory created by `admin` under a system's folder in
`/data/roms` SHALL belong to the session account's group and SHALL be readable
by the session account, with no ownership change made by hand. Write access
SHALL be a property of the ROM tree rather than of who created a folder: the
ROM root SHALL carry a default access rule, set on the root alone, that every
folder created beneath it afterwards inherits, and a system folder created by
the session account with the default mode, as the copy command or a plain
`mkdir` does, SHALL be writable by `admin` with no step taken by hand. The
rule is inherited, not applied: a folder that already existed when the rule
was set keeps the access it had. In kiosk mode the frontend does not create
system folders, because the Tools system keeps its system list non-empty and
the frontend offers to create the ROM directories only when no system loads; a folder created with an explicit
mode that denies group write, by the frontend in an unlocked full UI session
or by copying a whole folder from removable media, is outside this promise.
The repository SHALL document, readable from a fresh clone, a copy
command that produces this from a machine whose own accounts and groups do
not exist on the box.

#### Scenario: A file created by admin
- **WHEN** `admin` creates a directory and a file in it under `/data/roms/<system>/`
- **THEN** both carry the session account's group, the directory passes that group on to what is created inside it, and the session account can read the file

#### Scenario: A system folder created with the default mode
- **WHEN** the session account creates `/data/roms/<system>/` with a plain `mkdir` under its default umask and `admin` then creates a file in it
- **THEN** the file is created without a permission error, carries the session account's group, and is readable by the session account

### Requirement: The scrape command runs only as the session account
`emubox-scrape` SHALL do its work only when run as the session account. Run as
any other account, root included, it SHALL attempt nothing, SHALL exit
non-zero, SHALL name the command that runs it as the session account, and
SHALL leave the last-run record, the cache and the pending set unchanged. No
part of scraping or generation SHALL run as root, and the box SHALL grant the
session account no new privilege for it.

#### Scenario: Run as root
- **WHEN** root runs `emubox-scrape`
- **THEN** it exits non-zero naming the command to use instead, starts no scraper process, and the last-run record is byte-identical to before

#### Scenario: Run as admin
- **WHEN** `admin` runs `emubox-scrape` without changing account
- **THEN** the same refusal happens, and the command it names, run by `admin`, does the work as the session account

#### Scenario: No new privilege
- **WHEN** the privileges granted to the session account are listed
- **THEN** they are the ones that existed before this capability, with none naming a scrape or generation command

### Requirement: A fetch covers every folder that has games
A ROM file is a regular file, or a symbolic link to one, whose extension is in the frontend's extension
list for its system, taken from the frontend's bundled systems document as
overridden by the custom systems the box declares. A folder is a directory
directly under `/data/roms` that holds at least one ROM file directly in it;
a directory with no ROM file directly in it is empty. A directory named for
no system the frontend knows has no extension list and is a folder whenever
any regular file lies directly in it; such a folder SHALL NOT be fetched,
SHALL get no outcome, and SHALL NOT affect the run result. A run SHALL visit
every folder, and SHALL fetch metadata, art, videos and manuals into the
cache for each one that has a scraper platform, asking the scraping service
only about games the cache holds nothing for. A folder with no scraper
platform SHALL get the outcome `unmapped` and SHALL NOT make the run fail. A
folder whose fetch fails SHALL get `fetch-failed` and SHALL NOT stop the
remaining folders. An empty folder SHALL NOT be visited and SHALL NOT be
reported. A fetch SHALL write
nothing outside the cache, the scraper's own per-user files and the run's
records, so it is safe while the frontend or a game is running.

A completed fetch run SHALL report `complete` when every mapped folder
was fetched, including when there are no mapped folders; `partial` when at
least one fetched and at least one failed; and `failed` when at least one
was attempted and none fetched. A run prevented from attempting work by the
account, credentials or concurrency checks is `refused`. A run ended by a
termination signal SHALL record `interrupted`, keeping the outcomes of the
folders it finished and the previous record's outcomes for the others. Only
`complete` SHALL exit zero. The account refusal and concurrent-run refusal SHALL leave
existing records unchanged as their requirements specify.

#### Scenario: Mixed folders
- **WHEN** a run finds one folder that fetches, one whose fetch exits non-zero, one with no scraper platform and one directory with no ROM file in it
- **THEN** the outcomes recorded are `fetched`, `fetch-failed` and `unmapped` for the first three, nothing is recorded for the empty one, the run result is `partial`, and the exit status is non-zero

#### Scenario: Folder names that differ from the scraper's
- **WHEN** a folder is named as the frontend names that system and the scraper names the platform differently
- **THEN** the fetch uses the scraper's platform, and the cache, gamelist and media for it are kept under the frontend's folder name

#### Scenario: Nothing outside the cache
- **WHEN** a fetch runs while the frontend is up
- **THEN** no gamelist and no file under `/data/media` is created or modified by it

### Requirement: Unusable credentials refuse the run before anything is contacted
When the scraping service credentials are missing, unreadable, or still the
committed placeholder, a run SHALL get the result `refused`, SHALL say which of
those is the case, SHALL make no network request and start no scraper process,
and SHALL leave the pending set unchanged.

#### Scenario: Placeholder credentials
- **WHEN** `emubox-scrape` runs as the session account with the committed placeholder credentials
- **THEN** it exits non-zero naming the placeholder as the cause, the last-run record shows `refused` and keeps the previous record's folder outcomes, and the pending set is unchanged

### Requirement: One run at a time
While a run is in progress, a second `emubox-scrape` SHALL get the result
`refused`, SHALL say a run is in progress, and SHALL NOT disturb the first or
overwrite its records. Generation at frontend start SHALL take the same
claim, without waiting, so a fetch and a generation never run together and a
fetch is never delayed by one. The claim SHALL be held for as long as any
process of the run lives, the scraper process it starts included, and SHALL
be released only when the run's processes have all ended; ending the command
SHALL end the scraper process it started, so two scraper processes never
work the same cache. A run that ended without releasing its claim, because
the box lost power or the process was killed, SHALL NOT block later runs
once its processes have all ended.

#### Scenario: Second run during a first
- **WHEN** `emubox-scrape` is started while another is fetching
- **THEN** the second exits non-zero saying a run is in progress and the first finishes with its own result recorded

#### Scenario: After a killed run
- **WHEN** a run is killed mid-fetch, every process of that run has ended, and `emubox-scrape` is started again
- **THEN** the new run proceeds

#### Scenario: A killed run whose scraper process survives
- **WHEN** `emubox-scrape` is killed in a way that leaves the scraper process it started alive, and `emubox-scrape` is started again
- **THEN** the new run is `refused` while that scraper process lives, and a run started after it has ended proceeds

### Requirement: An interrupted run loses nothing
A folder SHALL become pending as soon as its own fetch finishes with
`fetched`, not when the whole run ends, and a later run SHALL skip games
already in the cache. Running the command again after an interruption SHALL
therefore continue the work rather than repeat it.

#### Scenario: Interrupted after the first folder
- **WHEN** a run is killed after one folder is `fetched` and before the next finishes
- **THEN** the first folder is pending, and the next run asks the scraping service about none of that folder's cached games

#### Scenario: Stopped by a signal
- **WHEN** a run receives a termination signal after one folder is `fetched`
- **THEN** the last-run record shows `interrupted` with that folder `fetched`, the other folders keep their previous outcomes, and the first folder is pending

### Requirement: Generation happens at frontend start and never while the frontend runs
When any folder is pending and the frontend is about to launch, the session
SHALL attempt to generate that folder's gamelist and media from the cache
before launching, subject to the concurrency and failure rules below, and SHALL NOT generate at any other time. When a fetch holds the
claim at that moment, generation SHALL do nothing that start: the pending set
SHALL be left exactly as it was, one journal line SHALL say a fetch was
running, generation SHALL report that skip to the session through a distinct
exit status it uses for no other outcome, and the frontend SHALL launch at
once; the pending folders are generated at a later start after the fetch has
ended. Generation SHALL
preserve metadata the family has set on a game through the frontend:
favourite, hidden, kid-game, completed, play count, last played, sort name
and alternative emulator, and the alternative emulator the family has chosen
for the whole system. A game the cache holds nothing for SHALL keep an
entry in the regenerated gamelist, with no metadata, so those fields survive
for it too. The live gamelist SHALL never be written in place: generation
SHALL write a folder's new gamelist in a work area of its own, reading the
previous gamelist from a copy placed there, and SHALL replace the live file
with the new one in a single atomic rename only once the folder's generation
has completed successfully within its time limit; on any other outcome the
live file is untouched and the work area is discarded. When generation itself
is killed or the box loses power, the work area left behind SHALL be removed
before that folder's next generation begins, each generation SHALL start
from a fresh, empty work area, and a leftover work area SHALL never be read as
the previous gamelist or put live. The live gamelist is
therefore at every instant either the previous file or the completed new one.
A folder SHALL leave the pending set only after its live gamelist has been
replaced or its failure has been recorded, so an interruption between the
replacement and the pending set's rewrite leaves the completed file live.
A surviving session handles the remaining pending entry through failure
cleanup; if the session also ends, a later start may generate it once more. While generation runs, the display SHALL show its progress rather than
a blank screen. This step happens before the kiosk's own timing promises for
the frontend begin: those are measured from the end of this step, which is
bounded in time whatever the windowed command does. After the step, processed folders and folders the overall limit kept it
from reaching SHALL leave the pending set after success or recorded failure, subject
to the bounded failure-cleanup exceptions below; newer fetches remain pending.

#### Scenario: A pending folder at frontend start
- **WHEN** a folder is pending, generation can take the claim and finish successfully with its progress window, and the session is about to launch the frontend
- **THEN** before the frontend process starts, that folder's gamelist holds an entry with the cached description for each cached game even on the first generation with no pre-existing gamelist directory, and supported cached media exists under `/data/media/<folder>/` (covers, screenshots, marquees, videos and manuals, with cached wheels emitted as marquees; textures are not emitted and no `textures` or `wheels` directory is required), the outcome recorded is `generated`, and the pending set is empty

#### Scenario: A fetch is running at frontend start
- **WHEN** a folder is pending, a fetch holds the claim, and the session is about to launch the frontend
- **THEN** no generation runs, the pending set is byte-identical to before, the journal holds a line saying a fetch was running, the frontend starts at once, and the folder is generated at the next frontend start after the fetch has ended

#### Scenario: Family metadata survives
- **WHEN** a folder's existing gamelist gives a cached game a non-default value for each of favourite, hidden, kid-game, completed, play count, last played, sort name and alternative emulator, and the folder is generated
- **THEN** the regenerated entry carries every one of those eight values unchanged

#### Scenario: An uncached game keeps its tags
- **WHEN** a folder's existing gamelist gives a game the cache holds nothing for the same eight values, and the folder is generated
- **THEN** the regenerated gamelist still holds an entry for that game carrying every one of those eight values, and the entry has no description

#### Scenario: The box loses power mid-write
- **WHEN** the box loses power while a folder's gamelist is being written
- **THEN** at the next start the folder's live gamelist is byte-identical to the one before generation began, the folder is still pending, and its next generation removes the work area left behind before starting, neither reading the partial file as the previous gamelist nor putting it live

#### Scenario: Windowed generation is killed while the session survives
- **WHEN** the windowed generation is killed mid-write while the session goes on
- **THEN** the live gamelist is never a partial file, and remaining work from that attempt is recorded as `generation-failed` without another generation pass before the frontend launches, subject to the bounded cleanup exceptions below

#### Scenario: The replacement lands before the pending set is rewritten
- **WHEN** the session ends after a folder's live gamelist has been replaced and before the pending set has been rewritten
- **THEN** the live gamelist is the completed new one, the folder is still pending, and the next start generates it again with the same result

#### Scenario: An unreadable gamelist is left alone
- **WHEN** a folder is pending and its live gamelist does not parse or has no `gameList` root
- **THEN** that gamelist is byte-identical afterwards, no scraper runs for the folder, its outcome is `generation-failed`, the journal line names the folder and says its gamelist is unreadable, and the folder leaves the pending set

#### Scenario: Nothing pending
- **WHEN** no folder is pending and the session is about to launch the frontend
- **THEN** no generation runs and no gamelist is modified

#### Scenario: Progress is visible
- **WHEN** generation is running
- **THEN** a window showing its output is displayed by the session's compositor

### Requirement: Generation cannot keep the frontend from launching
Generation SHALL be bounded in time per folder and as a whole. The session
SHALL also bound the windowed step externally, including when its window
command never starts generation, and end that step on expiry. There SHALL
be no windowless generation retry. The console-switch key SHALL remain
available during generation, as it is while the frontend runs.

A failed or timed-out folder SHALL get `generation-failed`, be logged and
reported by status, and be removed from the pending set until a later fetch makes it pending
again. No failed output SHALL replace a live gamelist. An overall timeout
SHALL similarly fail every folder the pass did not reach. If the window
fails or the windowed step is interrupted, remaining work from that attempt
SHALL be recorded as `generation-failed` and removed from pending without
running the scraper again; a completed atomic replacement SHALL remain live.
Newer fetches SHALL remain pending, even for a folder in the attempted batch.

Capturing the attempted work SHALL also be bounded to five seconds; if it
cannot finish, the session SHALL leave pending work unchanged, log the
deferred attempt and launch the frontend. When a fetch holds the claim at
capture, the step SHALL be skipped the same way, and the journal line SHALL
say a fetch was running. Failure recording SHALL not wait for a fetch or indefinitely delay the
frontend. If the claim is held, records cannot be written, or cleanup
exceeds its five-second bound, it SHALL log the deferred cleanup, leave
uncommitted pending work for a later start, and launch the frontend. A step
that reports the held-claim skip SHALL leave all pending state untouched
for that start even if the fetch subsequently ends. Generation time SHALL
NOT count toward the frontend crash limit.

#### Scenario: Generation fails or hangs
- **WHEN** a folder's generation fails or exceeds its limit
- **THEN** its outcome is `generation-failed`, its previous live gamelist is unchanged, the failure is logged, the folder is no longer pending, and the frontend launches

#### Scenario: The overall limit leaves folders unreached
- **WHEN** the overall time limit ends a generation pass
- **THEN** unreached folders are recorded `generation-failed` and removed from pending, no second generation pass runs, and the frontend launches

#### Scenario: The console switch works during generation
- **WHEN** generation is running and the console-switch key is pressed
- **THEN** the login prompt on that console is shown

#### Scenario: The progress window fails or hangs
- **WHEN** the progress window fails to start, or its command hangs until the external deadline
- **THEN** the windowed step is ended, its remaining pending work is recorded `generation-failed` without generating anything windowlessly, the reason is logged, and the frontend launches

#### Scenario: A newer fetch survives failure cleanup
- **WHEN** a fetch makes a folder pending after the failed windowed attempt captured its work, including a newer fetch of the same folder
- **THEN** cleanup preserves that newer pending work for a later start

#### Scenario: Failure cleanup cannot finish
- **WHEN** failure recording cannot take the claim, cannot write its records, or reaches its five-second limit
- **THEN** cleanup is deferred and logged, uncommitted work stays pending, and the frontend launches without waiting further

#### Scenario: The claim is released after a skip
- **WHEN** the windowed step reports the held-claim skip and the fetch ends before the session handles that result
- **THEN** no generation or failure cleanup runs that start, pending state remains unchanged, and the frontend launches

### Requirement: The household can update game art from the frontend
The frontend SHALL show a Tools system in its kiosk and full UI modes,
holding an entry named "Update game art". The frontend's Kid mode filters
gamelist entries to games flagged kid-friendly and so hides its entry; that
is acceptable because Kid mode is reachable only by unlocking the full menu,
and kiosk mode is re-asserted at every launch. Selecting the entry SHALL run
a scrape as the session
account with its progress shown on the display, and when the scrape ends,
whatever its result, SHALL restart the frontend so that generation runs and
the result is visible without anyone doing anything further. The display
SHALL show the scrape's progress until the scrape ends, and there is no way
back to the frontend before then; a first scrape over a large library is
long, and later runs are short because only games the cache holds nothing for
are asked about.

#### Scenario: The entry is there
- **WHEN** the frontend has started in kiosk UI mode
- **THEN** its system list includes Tools and that system lists "Update game art"

#### Scenario: Selecting the entry
- **WHEN** the entry is selected with a folder whose cache can be filled
- **THEN** a window showing the scrape's output is displayed, the frontend then exits and a new frontend process starts, and the folder's games carry their descriptions in the new one

### Requirement: The status command reports the library
The operator status command SHALL include a `library` section giving, for each
folder, meaning each directory directly under `/data/roms` with at least one
ROM file directly in it, or with at least one regular file directly in it
when its name is one the frontend knows no system by, the number of ROM
files, the number of gamelist entries, the number unscraped, and a note when
the folder is `unmapped` or is named for no system the frontend knows; then
the last run's result and time, each folder whose latest outcome is
`fetch-failed` or `generation-failed`, and whether any folder is pending. A
ROM file is a regular file, or a symbolic link to one, directly in the folder whose extension is in the
frontend's extension list for that system, taken from the frontend's bundled
systems document as overridden by the custom systems the box declares, so the
count mirrors what the household sees in the frontend: a
`.bin` beside a `.cue` counts when the system's list includes `.bin`, exactly
as the frontend lists it. A ROM file counts as unscraped when its gamelist
entry carries no description or it has no entry at all: a game the household
can see that lacks a description. It SHALL need no privilege: the last-run record, the run's log and the pending set
SHALL be readable by `admin` without sudo whatever umask the run that wrote
them had, so that `admin` running the status command directly sees the same
section as root does rather than an error or a false "no scrape has run".
It SHALL say so plainly when no run has ever happened rather than report an
error. Counting SHALL return within 50 seconds, below the operator command's
60-second reporter limit. If counting cannot finish, the section SHALL show
completed counts and available run and pending information, explicitly mark
incomplete counts as "counts unavailable", state that the scan is incomplete,
and report a warning rather than zero counts or "did not run".

#### Scenario: Counting stalls
- **WHEN** a directory read or gamelist read stalls during counting
- **THEN** within 50 seconds the section returns available results, identifies unavailable counts and the incomplete scan, and the operator command receives a warning rather than a reporter timeout

#### Scenario: Read by admin without sudo
- **WHEN** `admin` runs the status command without sudo after a run has written its records
- **THEN** the `library` section shows the same counts and result that it shows to root

#### Scenario: Counts follow the frontend's extension list
- **WHEN** a folder holds a `.cue` file, its `.bin` file and a sidecar file whose extension is not in the system's list, and the system's list includes both `.cue` and `.bin`
- **THEN** the section counts two ROM files for that folder and does not count the sidecar

#### Scenario: After a partial run
- **WHEN** the status command runs after a `partial` run that left one folder pending
- **THEN** the section shows each folder's counts, names the `fetch-failed` folder, gives the result `partial` with its time, and says generation is pending

#### Scenario: After a generation failure
- **WHEN** the status command runs after a run whose result was `complete` and a folder's generation then recorded `generation-failed`
- **THEN** the section names that folder

#### Scenario: Never run
- **WHEN** the status command runs on a box where no scrape has ever run
- **THEN** the section shows the folder counts and says no scrape has run

### Requirement: The ingest route is documented
The repository SHALL document, readable from a fresh clone: the copy command
over SSH and why a plain archive-mode copy is wrong for it; the route that
works on the shipped box before remote administration lands, switching to
desktop mode with `sudo emubox-mode desktop` as the `recovery` capability
provides and copying from removable media as the session account, telling
the reader to create each system folder first (a new folder in the file
manager or a plain `mkdir`, which the ROM root's default access rule makes
writable by `admin`) and then copy the game files into it, because copying
a whole folder reproduces the source folder's mode and produces one `admin`
cannot write into; starting a scrape over SSH
and from the frontend, and that art appears at the next frontend start; that
a scrape started from the frontend holds the display until it ends; that the
SSH route needs remote administration, which this capability does not
provide, while the frontend route does not; the scraping service account the
admin must create and where its credentials go; and one manual scrape of a
few ROMs with real credentials as the proof the account works.

#### Scenario: Reading the runbook
- **WHEN** an admin reads the repository's documentation with no other source
- **THEN** each of those items is stated, with the exact commands
