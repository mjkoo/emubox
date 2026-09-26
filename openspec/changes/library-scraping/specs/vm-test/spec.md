## ADDED Requirements

### Requirement: Library scraping is proven in the VM

A VM test SHALL boot the host's software modules and prove the nonvisual
library contracts without contacting the scraping service. Library CI checks
SHALL NOT depend on OCR, screenshot matching or frontend UI navigation.
Automated session tests SHALL use a deterministic terminal adapter that runs
the child command and preserves its exit status. Display, physical input and
the real terminal chain SHALL be covered by documented manual hardware
acceptance, which MAY be deferred until post-installation testing without
blocking implementation completion. Deferred checks SHALL remain explicitly
unverified. The real-account smoke tests MAY be deferred to the same phase.

The VM test SHALL place a fixture ROM in a system folder as `admin`, fill that
folder's cache for it with the real scraper reading local fixture files, make
the folder pending, and start the session. It SHALL then assert that before
the frontend process started the folder's gamelist gained the fixture's entry
with its description even when no live gamelist parent existed beforehand,
that supported fixture media exists under `/data/media`, cached wheels appear
as marquees and cached textures are not emitted,
that the pending set is empty, that generation ran through the test terminal
adapter, and that the frontend is up. It SHALL assert that the compositor showing
generation's progress was started with the same console-switch flag as the
frontend's compositor, by inspecting the production session script, so the
console-switch key stays available for the length of the step. Because the scraper run here is the node's first, the
test is also the proof that the scraper's first-run setup works for the
session account.

The test SHALL prove that family metadata survives, with the eight preserved
fields as the authority: favourite, hidden, kid-game, completed, play count,
last played, sort name and alternative emulator. A gamelist written before
generation SHALL give two fixture ROMs a distinct non-default value for every
one of the eight fields: the cached fixture, and a second ROM the cache holds
nothing for. After generation the cached fixture's entry SHALL carry every one
of the eight values, asserted each by value, and the uncached ROM SHALL still
have an entry carrying every one of the eight values and no description. A
negative control SHALL show that an entry missing any one of the eight fields
fails the assertion.

The test SHALL prove that the pending set is not blanked and the frontend is
not held when a fetch holds the claim: with the claim held by a process the
test starts and a folder pending, the session SHALL start, the frontend SHALL
come up, the pending set SHALL be byte-identical to before, and the journal
SHALL hold a line saying a fetch was running; once the claim is released, the
next frontend start SHALL generate the folder. It SHALL also prove a
held-claim skip is handled correctly through the test terminal adapter.
Propagation through the real terminal/compositor/timeout chain remains a
separate manual hardware check.
A deterministic handshake SHALL release the fetch claim after the command
has returned the skip but before the session handles it. No generation or
failure cleanup SHALL then run, pending SHALL remain unchanged, and the
frontend SHALL launch. A negative control that discards the skip and performs
failure cleanup SHALL fail the pending assertion; following a journal line
is not an ordering barrier.

The test SHALL prove the positive admin route as well as refusals: the exact
documented sudo command run from admin with an inherited admin home SHALL
record a successful run and folder outcome as the session account, using a
test-only scraper stub and non-placeholder fixture config to avoid the
service. The separate real import probe SHALL prove the session account's
first-run resources are usable.

The test SHALL prove the refusals by exact result: `emubox-scrape` as root and
as `admin` exits non-zero, names the command to use, and leaves the last-run
record byte-identical; as the session account with the test secrets file's
placeholder credentials it records `refused` and leaves the pending set
unchanged; and a second run started while a first holds the claim exits
non-zero while the first is undisturbed. It SHALL assert that the session
account's privileges are those the node had without this capability.

The test SHALL prove that generation cannot hold the frontend back: with a
pending folder whose cache is made unreadable to the scraper, the frontend
SHALL still come up, the outcome recorded SHALL be `generation-failed`, the
journal SHALL hold a line naming the folder, and the folder SHALL NOT be
pending afterwards. With the window command failing or hanging before it
starts generation, the external deadline SHALL end it, no windowless
scraper pass SHALL run, remaining attempted work SHALL become
`generation-failed` and leave the pending set, and the frontend SHALL launch. The
failure SHALL be logged and live gamelists SHALL remain unchanged. An
interrupted pass with one completed folder SHALL retain that folder's
completed replacement. Newer fetches, including for the same folder, SHALL
survive cleanup. A stalled batch capture SHALL leave pending unchanged and launch the
frontend within its bound. Cleanup contention, write failure or a stall SHALL be
logged and leave uncommitted work pending, with frontend launch bounded by
the cleanup deadline rather than blocked by it.

The automated test SHALL invoke the Tools command through its explicit
interpreter and test terminal adapter, assert the requested-restart mark
being honoured by the session and a new frontend process replacing the old
one; three such restarts inside the crash window
SHALL leave the session running, three unrequested short exits after a
requested restart SHALL end the session at the greeter, and two unrequested
short exits followed by a requested restart and one more unrequested short
exit SHALL leave the frontend relaunched and the session running, since the
requested restart reset the count. A failed termination request SHALL clear
its mark, and a subsequent genuine crash SHALL increment the count. Direct invocation proves session logic only. Manual hardware acceptance SHALL
select "Update game art" inside the frontend using physical input and record
its launch log, visible progress, persisted gamelist changes and relaunch.
This is necessary because the frontend resolves the executable before
substituting the entry's path, so a command it rejects can still load.
It SHALL prove that ownership comes out right for a file `admin` creates
under a system folder, asserted as the session account reading it, and that
a system folder the session account creates with a plain `mkdir` under its
default umask is one `admin` can create a file in at once.

The status command's `library` section SHALL be asserted after these steps:
the fixture folder's counts by value, with the uncached ROM counted as
unscraped although it has a gamelist entry, the last run's result, and the
`generation-failed` folder named. Every one of these assertions SHALL
be made twice, with the status command run as root and run as `admin`
without sudo, and the `admin` run SHALL show the same section as the root
run rather than an error or a report that no scrape has run. Process-level
reporter tests SHALL also stall discovery and gamelist reading, proving
available results and "counts unavailable" return as a warning before the
aggregator timeout rather than reporting zero or "did not run".

What this test does not prove, and the documented manual scrape does, is that
the scraping service accepts the real account.

#### Scenario: The library test passes
- **WHEN** the library VM test runs in CI
- **THEN** every assertion above holds on a node built from the host's own modules, with no network access to the scraping service

#### Scenario: A regression in preservation is caught
- **WHEN** generation is changed so that it no longer preserves any one of the eight fields, or drops the entry of a game the cache holds nothing for
- **THEN** the test fails on that field's assertion rather than passing on the entry's presence alone

#### Scenario: Graphical behavior is accepted on hardware
- **WHEN** the manual checklist is run on the target hardware
- **THEN** the recorded software revision and observations prove visible terminal output alone and from the frontend, physical entry selection, persisted frontend state after child termination and relaunch, and exit 75 through the real timeout/compositor/terminal chain with success and launch-failure controls
- **AND** deferred or unrun checks remain explicitly unverified; a green CI run does not establish hardware acceptance
