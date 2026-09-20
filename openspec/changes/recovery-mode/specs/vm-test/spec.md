## ADDED Requirements

### Requirement: Mode switching is proven in the VM

A VM test SHALL boot the host's software modules as a node with a graphical
stack and prove the mode switch end to end: that the node starts in the
frontend, that switching to the desktop mode replaces it with the desktop,
that switching back while that desktop is still up returns the frontend and
leaves nothing of the desktop running, that ending a desktop leaves a login
prompt on the seat, that a restart of the display manager from that prompt
returns the frontend, and that an invocation the command must refuse - one
without administrative privilege, one whose arguments are not a single
accepted word, and one made where nothing on the running system would read the
mode - is refused and leaves the selection unchanged.

The assertion that a switch took effect SHALL be made on session identity
rather than on the presence of a desktop alone: the test SHALL record the
session before the switch and assert that the session after it is a different
one, since a display manager that reactivated the existing session would leave
the flag unread. Session identity SHALL be read from the seat and session
records the operating system keeps, not from process names, since the wrappers
this project's programs are built with do not preserve a recognisable process
name.

The test SHALL prove the properties of the flag that decide, silently, which
program a new session starts: that a flag the command has written can be read
by the account the automatic session runs as, asserted as that account and not
as root; that the flag is gone once a session has handed over to the desktop;
and that a flag holding a word which names neither mode starts the frontend,
proven with such a word actually written into the flag, since nothing else
distinguishes a session that starts the desktop on the word for the desktop
from one that starts it on anything but the word for the frontend.

The test SHALL prove the switch back with the desktop still running, not only
from a login prompt: after it, and once the desktop's shutdown has been given
a bounded time to finish, a new session SHALL be running the frontend, no
desktop startup or compositor process owned by the account the automatic
session runs as SHALL exist anywhere on the node, and no unit of the desktop's
workspace SHALL be active in that account's user service manager. The display
manager ends a session by signalling one process, so a desktop that runs as
part of the session survives the switch unless the session passes that signal
on.

The test SHALL prove that ending the desktop leaves a login prompt rather than
a dead display: it SHALL end the desktop session with a failing status and
assert that the display manager is still running with a greeter on the seat,
that the frontend was not started by that ending, and that the status the
desktop really exited with is recorded in the journal, asserted by its exact
value. The display manager is left with no display by a session that exits
with status 1 specifically. A desktop killed by a signal it does not handle
reaches it as 128 plus the signal number and is followed by a greeter either
way, so the recorded status is the assertion that distinguishes a session that
outlived its desktop from one the desktop replaced. The desktop handles the
termination signal and ends in an orderly exit, so the test SHALL end it with
a signal it cannot handle.

The test SHALL prove that the command refuses where nothing on the running
system would read the mode, and SHALL reach that state as the system shape the
boot-menu recovery entry has - automatic login disabled while an
automatic-login user name remains configured - since every other part of the
test runs with automatic login enabled. It SHALL assert that the flag was not
written and that the display manager was not restarted.

While the desktop is up, the test SHALL prove that no file indexer process
owned by the account the automatic session runs as exists anywhere on the node,
held over a short window rather than read at one instant, and that the
indexer's user unit is masked, so that none can start rather than merely none
having started yet. The process is sought across the whole node because the
indexer is started by the account's user service manager and is therefore not
among the processes the session record attributes to the desktop session.

Wherever the command must refuse, the mode flag SHALL be asserted by the exact
word it is expected to hold - or by its absence, where that is the expected
state - and SHALL NOT be asserted merely as holding what it held before, since
a command that wrote the flag before making its checks would rewrite the same
word and satisfy a relative assertion.

The test SHALL prove that switches made faster than the display manager's
start rate limit allows are all applied: it SHALL run the command several
times in quick succession, more often than that limit permits, and assert that
each invocation succeeds, that the display manager is running rather than
failed on its start limit, and that a session of the requested mode comes up.

The test's outcome SHALL NOT depend on how quickly its steps follow one
another: before any restart of the display manager that the test makes itself,
it SHALL clear that unit's start rate limit accounting, as the command does for
the restarts it requests.

Where the desktop cannot be brought fully up under the test's software
renderer within the resources a VM test can be given, the test SHALL assert in
place of a fully drawn desktop that the new session's own process tree - the
processes the operating system's session record attributes to that session -
contains the desktop's startup process, and SHALL NOT be weakened further,
since nothing on the box reports which mode a session read. That weakened
assertion SHALL be made again after a bounded wait, or held over a window, so
that a desktop which started and exited immediately fails it.

This requirement does not change the kiosk-session requirement or the node it
describes: the assertions here restart the session out from under the node,
which the kiosk node's assertions about relaunch counting and the crash-loop
greeter cannot share. Which VM tests `nix flake check` runs is stated by the
"The test runs in CI and locally" requirement and is not restated here.

#### Scenario: The round trip is asserted

- **WHEN** the mode test node has booted into the frontend
- **THEN** switching to the desktop mode yields a session whose identity
  differs from the one recorded before the switch, with the desktop started in
  it, and switching back yields a further new session with the frontend
  running again

#### Scenario: Switching back from a live desktop leaves no desktop behind

- **WHEN** the test switches the node to the frontend mode while the desktop
  session is still running
- **THEN** a new session is running the frontend, no desktop startup or
  compositor process owned by the session's account exists anywhere on the
  node, and no unit of the desktop's workspace is active in that account's user
  service manager

#### Scenario: Switches in quick succession are all applied on the node

- **WHEN** the test runs the mode command as root more times in quick
  succession than the display manager's start rate limit allows
- **THEN** each invocation exits zero, the display manager is active and has
  not failed on its start limit, and a new session is running the requested
  mode's program

#### Scenario: The flag is readable by the session's account

- **WHEN** the test has switched the node into the frontend mode, on which the
  flag is not discarded, and the session that flag selected is running
- **THEN** reading the mode flag as the account the automatic session runs as
  succeeds and yields the whole word the command wrote

#### Scenario: The flag is gone after the desktop starts

- **WHEN** the node has switched into the desktop mode and the new session is
  running the desktop
- **THEN** the mode flag is no longer present on the node

#### Scenario: A flag naming neither mode starts the frontend on the node

- **WHEN** the test writes into the node's mode flag a word that is neither of
  the two the command accepts, and a new automatic session starts
- **THEN** that session is running the frontend and no desktop is running in it

#### Scenario: No indexer runs on the node while the desktop is up

- **WHEN** the node has switched into the desktop mode and the new session is
  running the desktop
- **THEN** over a short window no file indexer process owned by the session's
  account exists anywhere on the node, and the indexer's user unit is masked

#### Scenario: Ending the desktop leaves a greeter on the seat

- **WHEN** the test ends the desktop session on the node with a failing status
- **THEN** the display manager is still running with a greeter on the seat
  rather than a stopped display, the frontend has not been started by that
  ending, and the journal names the exact status the desktop exited with

#### Scenario: A restart from the greeter returns the frontend

- **WHEN** the display manager is restarted while the greeter left by an ended
  desktop is on the seat
- **THEN** a new automatic session starts and runs the frontend

#### Scenario: An unprivileged switch is refused on the node

- **WHEN** the test invokes the mode command on the node without
  administrative privilege
- **THEN** the invocation exits non-zero, the session on the seat is the one
  that was there before, the program running in it is unchanged, and the mode
  flag holds exactly the word it held when the invocation was made, asserted by
  that word

#### Scenario: A malformed invocation is refused on the node

- **WHEN** the test invokes the mode command on the node with no argument, with
  an unrecognised word, and with a further argument after an accepted word
- **THEN** each invocation exits non-zero, the flag holds exactly the word it
  held when the invocation was made, asserted by that word rather than as being
  unchanged, and the session on the seat is the one that was there before

#### Scenario: A switch nothing would read is refused on the node

- **WHEN** the test puts the node into the shape the boot-menu recovery entry
  has - automatic login disabled while an automatic-login user name is still
  configured - and invokes the mode command as root
- **THEN** the invocation exits non-zero saying that nothing there would read
  the mode, the flag holds exactly the word it held when the invocation was
  made, asserted by that word rather than as being unchanged, and the display
  manager was not restarted
