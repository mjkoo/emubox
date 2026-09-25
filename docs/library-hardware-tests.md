# Library hardware acceptance

Status: deferred until a future hardware installation. No hardware
installation has been performed yet. These checks are post-installation
follow-up work and do not block completion of the current implementation. Run
them when the project is ready for hardware testing; they require the target
appliance, its display and physical keyboard or controller. A green CI run
does not establish that they pass. CI covers source contracts, local scraper
import and nonvisual library and session logic. It does not use OCR for the
library.

Record the date, tester, machine/GPU/display, deployed software commit, each
observed result and relevant logs. Mark unavailable functionality as not run.
This checklist does not establish readiness to install on hardware. Keep
failures and unrun checks open until tested on an installed appliance.

Use disposable test ROMs and back up the test system's gamelist before
changing it. Restore the test configuration and fixtures afterwards. Run
terminal checks as the session account on the appliance's local login seat;
root or an SSH session alone does not reproduce its display permissions.

## Standalone terminal and exit statuses

With the frontend stopped and the seat available to the session account,
run the production command chain with these fixture commands:

```sh
timeout --kill-after=30 2100 cage -s -- foot -e sh -c 'printf "VISIBLE TERMINAL PROBE\n"; sleep 30'
printf 'status=%s\n' "$?"

timeout --kill-after=30 2100 cage -s -- foot -e sh -c 'exit 0'
printf 'status=%s\n' "$?"

timeout --kill-after=30 2100 cage -s -- foot -e sh -c 'exit 75'
printf 'status=%s\n' "$?"

timeout --kill-after=30 2100 cage -s -- foot -e /run/emubox-missing-executable
printf 'status=%s\n' "$?"
```

Verify the last path is absent before the failure control. Observe readable
text on the display for the first command and status 0 afterwards. The next
two statuses must be exactly 0 and 75; the missing-executable status must be
neither. Record actual statuses, including failures. Do not infer visibility
from a process list. Also check the console-switch key works during progress.

## Frontend launch and return

Use the deployed Tools system, backed by a read-only store directory outside
`/data/roms`, with its shell entry invoked through an explicit interpreter
before `%ROM%`. Inspect the deployed custom system definition and record the
exact command and store path. With the frontend running:

1. Navigate to Tools and select "Update game art" using physical input.
   Record the frontend's launch line from `/data/es-de/logs/es_log.txt`.
2. Observe readable progress on the display while the command runs as a
   frontend child, with no blank screen or invisible background operation.
3. Observe the frontend return after completion, with updated fixture art.
   Record the old and new frontend PIDs and the session journal.

Source inspection or invoking the entry directly does not prove frontend
selection. Do not edit store files.

## Child termination and saved state

Use a temporary test configuration with gamelist saving set to "on exit".
Launch a disposable entry once and verify its play count changed in memory
but has not yet been written to its gamelist. From a frontend child, send
SIGTERM to the session account's `es-de` process. Verify the changed play
count was written and the session launched a new frontend process.

If ES-DE termination does not save the change, repeat with fresh unsaved
state and terminate its Cage parent. Record which route preserves the state
and relaunches; a changed PID alone is insufficient. Feed the observed route
back into the implementation before accepting its restart behavior.

## Integrated generation and real account

After hardware installation, prepare a disposable cached game with generation
pending. Restart the frontend and observe progress before it starts, then
confirm the new artwork is shown. Run one small scrape with real ScreenScraper
credentials through the documented admin route and one through Tools. Record
outcomes, never credentials. This checks service acceptance as well as the
display.

All checks above, including the real-account smoke tests, are deferred until
post-installation testing and remain unverified until a tester records
evidence. Failure of display, state persistence or exit-status propagation
requires correcting the implementation before hardware acceptance, even if
automated checks pass.
