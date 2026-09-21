## Purpose

How an administrator gets a working desktop on the box and gives the TV back
to the family: the two session modes and the flag that selects one, how long
that selection lasts, the command that switches between them and who may run
it, the administrator account the desktop belongs to, and the boot-menu entry
that reaches a login prompt when the normal session cannot be trusted at all.

## Requirements

### Requirement: The box has two session modes and the frontend is the default

The box's automatic session SHALL start one of two things: the frontend, which
is the `kiosk` capability's business from that point on, or a graphical
desktop for an administrator. Which one it starts SHALL be selected by a mode
flag at `/run/emubox/mode` holding exactly one of the words `kiosk` or
`desktop`. A flag that is absent, unreadable, or holds anything else SHALL
select the frontend, so that no state of that file can leave the family
without their games.

The flag SHALL live on a memory-backed filesystem, which the `persistence`
capability already guarantees `/run` to be, so that its absence is the boot
state. No boot SHALL carry a mode selection forward, whichever boot entry it
uses, and no mode selection SHALL be recorded anywhere that survives a boot; a
reboot into the entry the box normally boots is therefore a return to the
frontend that needs nothing to have been set first. A boot entry that logs
nobody in automatically starts no automatic session, so the flag selects
nothing there.

#### Scenario: A fresh boot lands in the frontend

- **WHEN** the box boots into the entry it normally boots with no mode flag
  present, which is every boot
- **THEN** the automatic session starts the frontend

#### Scenario: An unrecognized flag lands in the frontend

- **WHEN** the automatic session starts with the mode flag holding a word that
  is neither `kiosk` nor `desktop`, or holding nothing, or unreadable
- **THEN** the session starts the frontend rather than failing or starting a
  desktop

#### Scenario: A reboot leaves desktop mode

- **WHEN** the box is in desktop mode and is rebooted into the entry it
  normally boots
- **THEN** it comes up in the frontend, with no mode flag present

#### Scenario: No boot carries a mode forward

- **WHEN** the box is in desktop mode and is rebooted, into either of the boot
  entries it offers
- **THEN** no mode flag is present on the system that comes up

### Requirement: A flag selecting the desktop is discarded by the session that acts on it

A flag selecting the desktop SHALL select the next automatic session and not a
standing configuration: an automatic session that finds the flag selecting the
desktop SHALL remove the flag before it starts the desktop, so that the session
after that one starts the frontend unless the desktop is asked for again.
Ending the desktop therefore SHALL NOT leave the box arranged to return to it.
A flag selecting the frontend SHALL be left in place, because it selects
exactly what its absence selects.

Removing the flag SHALL be available to the account the automatic session runs
as, through a privileged action whose only effect is that removal and which
takes no direction from its caller: it runs as root and as nothing else,
admits no argument, and resolves no program from its caller's environment.
Writing the flag SHALL NOT be available to
that account by that action or any other, so that the session can give the TV
back to the family but can never take it away from them.

Where the flag cannot be removed, the session SHALL start the frontend rather
than the desktop, since a desktop started with the selection still in place is
the state this requirement exists to prevent.

#### Scenario: The flag does not outlive the session it selected

- **WHEN** an automatic session finds the flag selecting the desktop and hands
  over to it
- **THEN** the flag is no longer present, and a later automatic session on the
  same boot starts the frontend

#### Scenario: The session account can give the TV back but cannot take it

- **WHEN** the account the automatic session runs as uses the privileged action
  available to it
- **THEN** the flag is removed, and no use of that action or of any other
  privilege granted to that account writes a mode into the flag

#### Scenario: The privileged removal runs nothing its caller supplies

- **WHEN** that account invokes the privileged action with a program search
  path of its own choosing
- **THEN** the flag is removed and no program found on that search path is run

#### Scenario: A flag selecting the frontend is left alone

- **WHEN** an automatic session finds the flag selecting the frontend and
  starts it
- **THEN** the flag is still present afterwards, and a later automatic session
  on the same boot starts the frontend as well

#### Scenario: A flag that cannot be removed keeps the frontend

- **WHEN** an automatic session finds the flag selecting the desktop and cannot
  remove it
- **THEN** it starts the frontend rather than the desktop

### Requirement: One command switches the box between the modes

The box SHALL carry a command, `emubox-mode`, that puts the box into a named
mode without a reboot: `emubox-mode desktop` SHALL replace whatever is on the
TV with a desktop, and `emubox-mode kiosk` SHALL replace it with the frontend.
The mode selected after the command returns successfully SHALL be the mode it
was asked for, even where the mode before the command was the same one, so
that the command is a way to reassert a mode. A switch away from a running
desktop SHALL end that desktop: nothing of it SHALL be left running beside the
session that replaces it.

The command SHALL record the requested mode in the flag before it changes
anything on the TV, SHALL write the flag in a way that a concurrent reader
sees either the whole previous value or the whole new one and never a partial
word, and SHALL leave the flag readable by the account the automatic session
runs as, since a flag that account cannot read selects the frontend as surely
as no flag at all.

The command SHALL take exactly one argument. An invocation with no argument,
with a word other than those two, or with anything after an accepted word
SHALL be refused with a message naming the accepted words and the single
argument they occupy, with a non-zero exit, and SHALL leave the selection
unchanged.

The command SHALL refuse, before it disturbs anything, where the running
system logs nobody in automatically, since no automatic session there will
read the flag. That check SHALL be on automatic login being enabled and not on
an automatic-login user name being configured, since the boot-menu recovery
entry turns the first off and leaves the second standing. A refusal SHALL
leave the running session on the TV untouched and the selection unchanged.

Past that check the command SHALL name the mode it is switching to and say
that the current session is about to end, before it acts, since the caller is
commonly sitting in the session that is about to end. It SHALL then hand the
restart of the display manager to the service manager in a way that outlives
the caller's own session, rather than waiting on an outcome it will not be
alive to observe. Repeated switches, each made once the previous switch's
session is running, SHALL NOT be refused by the display manager's start rate
limit and leave nothing on the TV, however many are made in that limit's
window: a restart an administrator asked for is not a crash and SHALL NOT be
counted as one. A switch made while the display manager is still logging in
the previous switch's session is outside this guarantee and can leave the TV
with no session until a reboot; the operator documentation says to wait for
the screen before switching again.

#### Scenario: Into the desktop

- **WHEN** an administrator runs `emubox-mode desktop` on a box showing the
  frontend
- **THEN** the command names the mode it is switching to and that the current
  session will end, and a graphical desktop replaces the frontend on the TV,
  without a reboot

#### Scenario: Back to the frontend

- **WHEN** an administrator runs `emubox-mode kiosk` on a box showing the
  desktop
- **THEN** the frontend replaces the desktop on the TV, prepared as it is at
  every launch, without a reboot, and nothing of the desktop is left running

#### Scenario: Repeated switches are not refused by the start rate limit

- **WHEN** the command is run several times, each once the previous switch's
  session is running, more often than the display manager's start rate limit
  allows in its window
- **THEN** each restart is accepted, and the display manager is running with
  the requested mode's session afterwards

#### Scenario: The session's account can read the flag

- **WHEN** the command has recorded a mode in the flag
- **THEN** the account the automatic session runs as can read the whole word
  the command wrote

#### Scenario: A malformed invocation changes nothing

- **WHEN** `emubox-mode` is run with no argument, with a word other than
  `kiosk` or `desktop`, or with a further argument after `kiosk` or `desktop`
- **THEN** it exits non-zero with a message naming the accepted words and that
  exactly one of them is taken, and the selection is unchanged

#### Scenario: A system that logs nobody in automatically is refused

- **WHEN** the command is run on a running system that has no automatic login,
  such as one booted through the boot-menu recovery entry, whose automatic
  login is off although an automatic-login user name is still configured
- **THEN** it exits non-zero saying that nothing there would read the mode, and
  the running session and the selection are both unchanged

### Requirement: Only the administrator may switch modes

Switching modes SHALL require administrative privilege. The command SHALL
refuse to run without it, with a message naming the route to that privilege
from the desktop the box itself provides - becoming the administrator account,
which prompts for its password, and raising privilege from there, which does
not - and a non-zero exit, before it writes the flag or touches the TV, since
the desktop runs as the session's own account, which holds no such privilege
directly. The `player` account the automatic session runs as SHALL NOT be able
to switch modes, either by running the command or through any privilege
granted to it for another purpose, so that nothing the frontend or a running
game can do with that account's privilege puts a desktop on the family's TV.

#### Scenario: An unprivileged invocation is refused

- **WHEN** `emubox-mode desktop` is run by an account without administrative
  privilege
- **THEN** it exits non-zero with a message naming the route to privilege from
  the box's own desktop, the flag is not written, and the selection is
  unchanged

#### Scenario: The player account cannot switch modes

- **WHEN** the account the automatic session runs as attempts to switch modes
- **THEN** the attempt is refused, and no privilege granted to that account for
  any other purpose lets it succeed, the removal of the flag it is allowed
  included

### Requirement: Every failure reports its outcome and the next automatic session

The command SHALL exit zero only when the requested mode has been recorded and
the restart that applies it has been accepted by the service manager. It SHALL
NOT claim that the box is in the requested mode, which it cannot know: the
session that reads the flag outlives the command, and commonly the command's
own session is the one being ended.

On any failure it SHALL exit non-zero with a message that names what failed
and the mode the next automatic session will start: `desktop` only when the
command's read of the flag yields exactly `desktop`, and `kiosk` in every
other case - absent, empty, unreadable or unrecognised. No additional
privileged reporting action SHALL be granted to satisfy diagnostics; the
clear-only privilege boundary remains unchanged. This diagnostic is not a
claim about what is on the TV. Where the flag was written but no restart was
accepted, the message
SHALL say so, since the requested mode is what the next start of an automatic
session would otherwise unexpectedly produce - except that a boot clears the
flag, which the message SHALL NOT contradict.

#### Scenario: A failure names the next automatic session

- **WHEN** an invocation fails
- **THEN** its message names what failed and the mode the next automatic
  session will start - `desktop` where the flag holds exactly `desktop`, and
  `kiosk` in every other case - without gaining another privileged reporting
  action

#### Scenario: The flag cannot be written

- **WHEN** the mode flag cannot be written
- **THEN** the command exits non-zero saying so, and the selection is unchanged

#### Scenario: The flag is written but no restart is accepted

- **WHEN** the flag has been written and the restart cannot be handed to the
  service manager
- **THEN** the command exits non-zero with a message saying the mode was
  recorded and the session was not restarted

#### Scenario: A successful exit claims only what it knows

- **WHEN** the command exits zero
- **THEN** its report is that the mode was recorded and the restart was
  accepted, and it makes no claim about what is on the TV

### Requirement: Leaving the desktop is an explicit act

Ending the desktop SHALL NOT by itself start the frontend: it SHALL leave a
login prompt on the TV, because the automatic login is not repeated within one
display manager's life. That SHALL hold whatever status the desktop exited
with. The automatic session SHALL report its own ending to the display manager
as a clean one however the desktop it handed over to ended, and SHALL record
the real status where it can be read back, because a display manager that reads
a failing session as an authentication failure keeps running with no session
and no login prompt at all - a black screen with no way in. The desktop
therefore SHALL run as part of the automatic session rather than replacing it,
and the session SHALL end rather than return to the frontend at that point.

Bringing the frontend back SHALL be `emubox-mode kiosk`, a restart of the
display manager, or a reboot into the entry the box normally boots - any of
which suffices, because the selection was already discarded when the desktop
started.

#### Scenario: Quitting the desktop

- **WHEN** an administrator ends the desktop session from within it
- **THEN** the TV shows a login prompt, and the frontend does not start by
  itself

#### Scenario: A desktop that ends badly still leaves a login prompt

- **WHEN** the desktop ends with a failing status
- **THEN** the TV shows a login prompt, the display manager is still running
  with a session to log into, and the desktop's real status is recorded where it
  can be read back

#### Scenario: The way back needs no mode to be set

- **WHEN** the box is rebooted into the entry it normally boots, or its display
  manager restarted on a system booted through that entry, after a desktop
  session has been started and ended
- **THEN** the frontend starts, with no mode having to be written first

### Requirement: The frontend offers no route to the desktop

No surface the family can reach SHALL offer to switch modes. The frontend
SHALL NOT carry an entry, a system or a menu item that puts the box into
desktop mode, in its restricted mode or its full one. Until the
remote-administration capability provides a shell, the only place the command
can be run is a console on the box itself, and that is a deliberate limit
rather than an omission. The requirement below is what makes that console
reachable.

#### Scenario: Nothing in the frontend switches modes

- **WHEN** the frontend is browsed, in its restricted mode or after the full
  menu is unlocked
- **THEN** no entry, system or menu item switches the box to desktop mode

### Requirement: A console on the box is reachable from the frontend

A box showing the frontend SHALL offer an administrator with a keyboard a
login prompt without a reboot and without waiting for the frontend to fail:
the compositor the frontend runs under SHALL honour the keyboard's
virtual-console switch, from the frontend and from a running game alike. A
compositor that swallows that key leaves a healthy box with no place to run
the mode command at all, since nothing else on it offers a shell.

That prompt is not a surface that offers the switch. It SHALL admit only an
account that has a password, and the configuration SHALL give the account the
automatic session runs as none, so what the family can reach with that key is
a prompt they cannot pass, and the same switch naming the frontend's own
console SHALL return them to the frontend as they left it.

A mode switch made from that console SHALL put the new session on the TV
rather than leave the TV on the console, and the command's report SHALL remain
readable on the console afterwards, since that console's login is not part of
the session being ended.

#### Scenario: A console is reachable from the running frontend

- **WHEN** the keyboard's virtual-console switch is pressed on a box showing
  the frontend
- **THEN** that console becomes the one on the TV and shows a login prompt, at
  which `admin` logs in with its password

#### Scenario: The frontend is a key away again

- **WHEN** the virtual-console switch naming the frontend's console is pressed
  at that login prompt
- **THEN** the frontend's session is the active one on the seat again, the
  same session as before

#### Scenario: The session account cannot pass the prompt

- **WHEN** the box's configuration is evaluated
- **THEN** the account the automatic session runs as is given no password, so
  no login as that account succeeds at the prompt

#### Scenario: A switch made from the console reaches the TV

- **WHEN** `admin`, logged in on that console, runs `emubox-mode desktop` with
  administrative privilege
- **THEN** the desktop's session becomes the active session on the seat, and
  the command's report is still readable on the console

### Requirement: The box carries an administrator account with a desktop

The box SHALL carry an account, `admin`, that is not the account the automatic
session runs as, that holds full administrative privilege without being
prompted for a password once logged in, and that can write the shared data
layout the family's games and saves live in. The box SHALL carry a graphical
desktop environment that account can run, which is what desktop mode starts
and what the boot-menu entry below reaches. The account SHALL be reachable
from a terminal in the desktop the box provides by an ordinary account switch
prompting for its password, since that desktop runs as the session's own
account and holds no administrative privilege of its own. The account's
password is the `secrets` capability's to supply; this capability requires
only that the account exists with those privileges and that a desktop exists
for it to use.

#### Scenario: The administrator account exists with its privileges

- **WHEN** the box's configuration is evaluated
- **THEN** it declares an `admin` account, distinct from the session account,
  holding administrative privilege that needs no password prompt and write
  access to the shared data layout

#### Scenario: A desktop is available to log into

- **WHEN** a login prompt is reached on the box
- **THEN** a graphical desktop session is among the sessions that can be
  chosen there

#### Scenario: The administrator is reachable from the desktop

- **WHEN** a terminal is opened in the desktop the box starts in desktop mode
- **THEN** switching to the administrator account succeeds on that account's
  password, and administrative privilege from there needs no further password

### Requirement: The desktop runs no file indexer

The desktop the box provides SHALL run no file indexer. The desktop
environment the box carries ships one, which would index the home of the
account the desktop runs as - where emulator configuration and the save routes
live - and rewrite its index there continuously, so an indexed box pays for a
desktop it reaches occasionally with an index that never settles. No session on
the box SHALL start one, whatever desktop configuration files a particular
home directory happens to contain, so that the property holds for a home
restored from backup or created fresh as much as for the one in front of the
administrator.

#### Scenario: No indexer runs in a desktop session

- **WHEN** the box is in desktop mode and the desktop session is running
- **THEN** no file indexer is running on the box

### Requirement: A boot-menu entry reaches a login prompt with no kiosk session

The box SHALL offer, from its boot menu, an entry that starts the same system
with the automatic login turned off and the desktop pre-selected, so that a
box whose automatic session cannot be trusted - or whose mode flag cannot be
reached because nothing on the box is reachable - still presents a login
prompt an administrator can use. That entry SHALL start from the same
configuration as the normal entry, so that reaching it needs no separate
system to have been built or kept working.

Because nothing is logged in automatically on a system started that way, the
mode flag selects nothing there, and the command that writes it refuses rather
than appearing to work. Reaching a desktop from this entry is logging in at
the prompt, not switching modes.

#### Scenario: The recovery entry is offered and logs nobody in

- **WHEN** the box's configuration is evaluated
- **THEN** it declares a boot entry, built from the same configuration as the
  normal one, in which nothing is logged in automatically and the desktop is
  the pre-selected session
