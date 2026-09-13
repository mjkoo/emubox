## Purpose

Which physical port is which player, and what the flake owns in each
standalone emulator's controller configuration so a pad alone can both play a
game and leave it - including the route back out of a standalone emulator,
which belongs here and not to the `emulators` capability, and the record of the
one emulator whose pinned version offers no route back a pad can take.

## ADDED Requirements

### Requirement: Physical port determines player order

The configuration SHALL record the box's controller ports as an ordered list of
stable device paths, and SHALL give each recorded port a stable name derived
from its position in that list. The naming SHALL be applied by the operating
system's device manager, so a pad connected after boot is named as soon as it
appears and a pad moved between ports takes the name of the port it is moved
to.

The session SHALL tell every emulator that reads controllers through the
system's game controller library to enumerate the named ports first, in
recorded order, so the pad in the first recorded port is player one in every
such emulator. A pad reached through both its port name and its underlying
device node SHALL be presented once, not twice.

When no ports are recorded, the session SHALL declare no enumeration order
rather than an empty one, and every emulator SHALL fall back to the operating
system's own order. This is the state of a box whose ports have not yet been
recorded, and it SHALL NOT be an error.

For an emulator the recorded order reaches, which is one that reads
controllers through the system's game controller library, the ordering SHALL
be applied whenever that emulator enumerates controllers, which is at each
game launch. Three consequences follow for such an emulator and are accepted
rather than corrected: a pad in the second port alone becomes player one,
because nothing else can be; a pad connected while a game is running takes the
lowest free player index regardless of its port; and a pad disconnected and
reconnected during a game takes the lowest free player index like any other
connection, which is its former index only when no lower index is free. In
such an emulator the recorded order is what a launch applies, and a
reconnection during a game is governed by the same free-index rule however the
pad came back. An emulator that enumerates controllers through an input
backend of its own is outside the order the session declares, and this
requirement promises it neither the recorded order at a launch nor any player
index on a connection or a reconnection.

#### Scenario: Recorded ports become player order

- **WHEN** ports are recorded and a pad is present on one of them
- **THEN** that port's stable name resolves to the pad's device, and the
  session's declared enumeration order lists the recorded ports by position

#### Scenario: A pad is connected after boot

- **WHEN** a pad appears on a recorded port while the system is running
- **THEN** that port's stable name resolves to it without a reboot

#### Scenario: Two pads drop mid-game and player two's returns first

- **WHEN** during a game in an emulator the recorded order reaches, the pads
  that are players one and two both disconnect, and the pad that was player
  two reconnects first
- **THEN** it takes player one, the lowest free player index, rather than its
  former index

#### Scenario: No ports are recorded

- **WHEN** the configuration records no controller ports
- **THEN** no port names exist, the session declares no enumeration order at
  all, and the system evaluates and boots normally

### Requirement: Every standalone emulator can be left with only a pad

For every standalone emulator the box launches, Azahar excepted as set out
below, the flake SHALL own a controller binding that returns the player to the
frontend, once any pad-identity fact that binding needs is recorded under the
rule set out below. The binding SHALL
hold for every system the frontend launches through that emulator, so an
emulator that keeps a separate controller profile per system carries it in
each. The binding SHALL end the emulator's process and so return the player
to the frontend, with no prompt in between that a pad cannot answer. That
binding SHALL be enforced at the anchor every other enforced setting is
asserted at - before the frontend starts, each relaunch included - so a
rebinding cannot outlive the frontend session it was made in. Where an
emulator raises a confirmation before closing by default, the flake SHALL own
the setting that suppresses it, enforced like the binding; and where an
emulator exits to the frontend only when launched with a particular option,
the frontend's launch command for that emulator SHALL carry that option. Any
setting the binding depends on to reach a pad, such as a setting naming the
device a group of bindings is resolved against, SHALL be owned and enforced
with the binding, since an enforced binding whose dependency is left unowned
can survive while no pad can fire it; a setting that must name the pad itself
is owned only once its pad-identity fact is recorded, under the rule below. Where
an emulator cannot express the same binding as the others, the binding SHALL
still exist and its difference SHALL be recorded with the reason. A
difference in how the route back is expressed - a chord, a single input, or a
pause menu's Exit entry - is allowed; a route back that does not end the
emulator's process is not.

The anchor is the frontend's start, not each game's, and the limit that
follows is accepted rather than corrected: a player who unbinds the route back
inside an emulator's own menus stays unbound for the rest of that frontend
session, including every game launched after it, and the binding returns when
the frontend next starts. Narrowing the anchor would mean writing emulator
configuration on the path between the frontend handing off and an emulator
starting, which nothing else writes on.

Azahar is the one exception, and its limit is recorded rather than papered
over. At the version the flake pins, Azahar persists each hotkey as a keyboard
sequence and nothing else, so it has no pad-bindable action that ends its
process, and the box has no keyboard. This requirement holds for every other
standalone emulator. Azahar's route back is deferred to a later change; until
it lands, a game launched through Azahar can be played with a pad, under the
gameplay requirement below, but not left with one, and the flake owns no
binding or confirmation setting presented as Azahar's route back.

Some settings must name the pad itself rather than an input on it - a setting
naming, by the backend's own name for the pad, the device a group of bindings
is resolved against, or a binding value carrying the pad's identity - and for
some of them the emulator offers no form that names no particular device, such
as a device index. Such a setting's value is a pad-identity fact: a bring-up
fact, recorded from the real pad under Linux beside the controller port paths,
since the same setting taken from any other machine names a device the box
does not have. The value SHALL be read from the real pad with a command the
box carries that prints it in the form the emulator stores, and SHALL NOT be
derived by hand from other properties of the pad, since a plausible value
assembled that way passes every check the configuration is given while naming
no device the emulator finds. Until that fact is recorded, the setting SHALL
be declared in neither tier; no route back and no gameplay binding that depends on it SHALL be
declared either; and nothing SHALL be declared in its place, neither a
placeholder nor a value taken from any other machine, since a value declared
in its place would be written as if it were right. A gameplay binding that
depends on a pad-identity fact, and every setting it depends on to reach a
pad, SHALL be enforced rather than seeded, so that it is written the first
time the configuration editor runs after the fact is recorded, whatever the
emulator wrote into those settings in the meantime; until then the emulator's
own values stand. An emulator may write its own values into those settings
whenever it saves its configuration, and a seeded setting is written only
while the file has no assignment for it, so a seeded binding declared once the
fact arrived might never be written. A player who rebinds such a binding in
the emulator's own menus keeps the change until the frontend next starts, as
with the route back. Until the fact is recorded, that emulator's route back and its pad play are not
promised, by this requirement or by the gameplay requirement below, and the
bring-up checklist item that records the fact is the gate: once it is
recorded, both requirements hold for that emulator as for any other.

This extends the guarantee that previously existed only for the core-based
frontend to every standalone emulator this requirement covers. It SHALL NOT change the two combos already
owned for that frontend. The core-based frontend's route back is owned by the
`emulators` capability and is delivered at each game's launch rather than at
the frontend's start, so it lies outside this requirement's anchor as well as
its scope.

#### Scenario: A standalone game is exited with a pad

- **WHEN** a standalone emulator other than Azahar is launched for any system
  it serves, any pad-identity fact its route back needs is recorded, and its
  owned configuration for that system is read
- **THEN** the configuration carries the enforced binding that returns to the
  frontend

#### Scenario: A 3DS game is played through Azahar but cannot be left with a pad

- **WHEN** a 3DS game is launched through Azahar at the version the flake pins
  and its owned configuration is read
- **THEN** it carries gameplay bindings a pad can play with, once any
  pad-identity fact they need is recorded, and no binding is owned or
  presented as a way back from Azahar, whose inability to be left with a pad
  stands recorded as this requirement's exception, deferred to a later change

#### Scenario: A binding waits on an unrecorded pad identity

- **WHEN** an emulator's route back or gameplay bindings depend on a setting
  that must name the pad itself, for which the emulator offers no form naming
  no particular device, on a box whose pad-identity facts are still empty
- **THEN** the flake declares neither that setting nor any binding that
  depends on it, in either tier, and declares nothing in their place, neither
  a placeholder nor a value taken from another machine, and neither pad play
  nor the route back is promised for that emulator until bring-up records the
  fact

#### Scenario: Leaving an emulator needs nothing a pad cannot give

- **WHEN** a standalone emulator other than Azahar, with any pad-identity fact
  its route back needs recorded, by default asks for confirmation before
  closing, or exits only to its own menu unless launched with a particular
  option, and its owned configuration is read after the configuration editor
  has run
- **THEN** that configuration carries the setting that suppresses the
  confirmation, and where an option is needed, the frontend's launch command
  for that emulator carries it, so the route back ends the emulator's process
  and returns the player to the frontend

#### Scenario: A player rebinds the route back

- **WHEN** a player changes that binding in the emulator's own menus and the
  frontend is started again
- **THEN** the enforced binding is restored before any emulator is launched

#### Scenario: A rebinding lasts out the frontend session

- **WHEN** a player changes that binding in the emulator's own menus and
  another game is launched without the frontend having restarted
- **THEN** the player's change is still in effect for that game, and the
  enforced binding returns at the frontend's next start

### Requirement: Every emulator is playable with only a pad

For every emulator that does not leave the box's controller bound for gameplay
by defaults the flake's own ownership of its configuration cannot erase, the
flake SHALL own gameplay bindings, once any pad-identity fact they need is
recorded, for each system the frontend launches
through that emulator: for player one, and for each further player that system
supports, up to a maximum of player four. The players a system supports are
its native controller ports, counted without a multiplayer accessory such as a
multitap, and the flake SHALL enable no such accessory. A system that supports
two players therefore gets bindings for players one and two and none for a
player three or a player four, and a system that supports more than four gets bindings through
player four and no further. Four players is the governing limit everywhere in
this requirement: the box records four controller ports, so a binding for a
fifth player names a pad that cannot reach the box, and no rule below SHALL be
read as asking for one even where a system supports more. The per-system
player count and the four-player limit bound the bindings the flake declares;
they SHALL NOT remove anything already in a readable file, and a binding
beyond them that a player or an emulator wrote is unowned and is kept under
the `emulators` capability's ownership rules. These bindings SHALL be seeded,
written when absent and left alone afterwards, so a player who rebinds in an
emulator's own menus keeps the change, except a binding that depends on a
pad-identity fact, which is enforced under the rule the route-back
requirement above sets.

The additional players' bindings SHALL be declared whether or not any
controller port has been recorded. They name a controller index the emulator
assigns from its own enumeration, not a port this configuration records, so
the recorded port list is the authority for player order alone and SHALL NOT
decide whether these bindings exist; a box with no ports recorded still gets
every player each such system supports up to the fourth, withholding only a
binding that waits on an unrecorded pad-identity fact.

For every player the flake declares gameplay bindings for, where the emulator
leaves that player's controller slot disconnected by default, the flake SHALL
own the setting that connects that slot, in whichever configuration file holds
that setting, including a file another capability owns. That setting SHALL be
owned in the tier of the bindings it makes usable: seeded like them, written
when absent and left alone afterwards, so a household that turns a slot off in
an emulator's own menus keeps that choice, except where those bindings depend
on a pad-identity fact, when it is enforced with them under the rule the
route-back requirement above sets. A binding for a disconnected slot is a pad
that plays nothing. Any other setting a gameplay binding the flake declares
depends on to reach a pad, such as a setting naming the device a group of
bindings is resolved against, or one selecting which stored bindings are
read, such as the count of a profile array or the index of the active
profile, SHALL likewise be owned with that binding and in its tier, in
whichever configuration file holds it. A flag that decides whether the one
stored binding it sits beside is read at all, rather than which input the
binding names, is the one exception to that tier: it SHALL be owned beside the
binding and enforced, whatever tier the binding sits in, since a stale flag
discards whatever binding is stored, a player's own as readily as the
flake's. Azahar's `<key>\default` flags are the case; a setting selecting
which of the stored bindings are read is not such a flag.

The rule the route-back requirement above sets for a setting that must name
the pad itself governs every gameplay binding and every setting this
requirement has the flake own, both in what it withholds until the
pad-identity fact is recorded, while that emulator's pad play is not
promised, and in the tier it gives a binding that depends on the fact.

Which emulators need bindings, and which of their systems support local
multiplayer, SHALL be determined from each emulator's own defaults and its
systems at the version the flake pins, rather than from a list fixed in
advance. The unit of that determination SHALL be the emulator together with
every system the frontend assigns it, not the emulator alone: an emulator
serving more than one system may keep a separate controller profile per
system, and a system whose profile is left unowned launches with nothing
bound. That determination SHALL establish, for each such system, which
configuration file holds that system's bindings, and for each of those files,
whether the emulator's pad defaults are built into the emulator as fallbacks
for bindings the file does not carry, or are written into that file when the
emulator first runs, and whether the flake owns that file. It SHALL also
establish, for each such system and each player it supports, whether that
player's controller slot is connected by default and, where it is not, which
configuration file and which setting connect it, and which other settings, if
any, those bindings depend on to reach a pad.

Where an emulator's pad defaults are written into the configuration file
holding a system's bindings and the flake owns that file, the flake SHALL
own the complete gameplay binding set for every player that system supports
up to player four, whatever a pristine install of it would have produced for
those players, each binding in the tier set out above. Where a pristine
install's binding names an input the pad never sends, so the control it serves
does nothing even in a pristine install, the flake SHALL instead bind that
control to the input the pad does report for it; PPSSPP's shoulder buttons are
the case. Owning a file is what decides the content
of a file that has to be recreated, and a recreated file carries the owned
keys and nothing else, so a default that lives in the file rather than in the
emulator is a default the box can lose. Only defaults built into the emulator,
which survive any file the flake writes, SHALL be left unrestated.

#### Scenario: An emulator that does not bind a pad by default

- **WHEN** such an emulator's owned configuration is read after a first
  launch, with any pad-identity fact its bindings need recorded
- **THEN** it carries the flake's gameplay bindings for player one, except
  that a seeded binding the file already assigned before the configuration
  editor ran keeps the value it held

#### Scenario: An emulator serving more than one system

- **WHEN** an emulator that needs gameplay bindings is launched by the frontend
  for more than one system and keeps a separate controller profile for each,
  with any pad-identity fact its bindings need recorded
- **THEN** each system's profile carries the flake's gameplay bindings for
  player one and each further player that system supports, up to player four,
  except that a seeded binding the profile already assigned before the
  configuration editor ran keeps the value it held

#### Scenario: An emulator whose defaults live in a file the flake owns

- **WHEN** an emulator writes its pad defaults into a configuration file the
  flake owns, any pad-identity fact its bindings need is recorded, and that
  file is read after the configuration editor has run
- **THEN** every binding in the flake's complete gameplay binding set for
  every player that file's system supports up to player four is assigned in
  it, rather than depending on defaults a recreated file would not carry: a
  binding that depends on a pad-identity fact carries the flake's value
  whatever the file held, a seeded binding the file held no assignment for
  carries the flake's value, and a seeded binding the file already assigned,
  with the emulator's own value or a player's, keeps that value; so a file the
  configuration editor created or recreated carries the flake's complete set,
  and where it recreated that file from nothing, it carries no binding for a
  player beyond the fourth

#### Scenario: A local-multiplayer emulator on a box with no ports recorded

- **WHEN** such an emulator's owned configuration is read on a box that
  records no controller ports, with any pad-identity fact its bindings need
  recorded
- **THEN** it carries gameplay bindings for every further player that file's
  system supports, up to player four, alongside player one's, as on a box
  with ports recorded - the flake's, except that a seeded binding the file
  already assigned keeps the value it held - and the bindings the flake
  declares for it include none for a player that system does not support

#### Scenario: A further player's slot is disconnected by default

- **WHEN** an emulator leaves a further player's controller slot disconnected
  by default, the flake declares that player's gameplay bindings, and its
  configuration is read after the configuration editor has run
- **THEN** that player's slot setting and gameplay bindings carry the flake's
  values, connecting the slot, except that a seeded one of them the file
  already assigned keeps the value it held

#### Scenario: A binding beyond the declared players is kept

- **WHEN** a readable owned configuration file already holds a gameplay
  binding for a player beyond those the flake declares for it, and one of the
  owned gameplay bindings is missing from it
- **THEN** after the configuration editor runs, the missing owned binding is
  written and the existing binding is still there

#### Scenario: A player rebinds gameplay controls

- **WHEN** a player changes a seeded gameplay binding, one that depends on no
  pad-identity fact, in the emulator's own menus and the emulator is launched
  again
- **THEN** the player's binding is preserved

#### Scenario: A player changes a controller slot setting

- **WHEN** a player changes a controller slot setting the flake seeds in the
  emulator's own menus, such as turning a player's slot off, and the emulator
  is launched again
- **THEN** the player's setting is preserved

#### Scenario: An emulator filled its identity-dependent bindings before bring-up

- **WHEN** an emulator whose gameplay bindings depend on a pad-identity fact
  has written its own values into those bindings, and into the settings they
  depend on to reach a pad, before the fact was recorded, and the fact is then
  recorded and the configuration editor runs
- **THEN** the file carries the flake's gameplay bindings and every setting
  they depend on to reach a pad, in place of the emulator's own values

### Requirement: Controller state is reported to the operator

The controllers capability SHALL contribute to the operator status command a
report of which recorded ports currently resolve to a connected pad, and SHALL
warn when a connected controller identifies as none of the controller modes
the box accepts, naming it so the administrator can act on it.

The accepted modes SHALL be a declared set rather than a single identity, so
that a further mode can be added without reworking the report. The set covers
the wired pads the box is used with, in the mode the in-kernel driver presents
for them. The warning SHALL cover every controller the system sees and not only
those on recorded ports, since a pad in an unaccepted mode is worth reporting
wherever it is attached. A controller, for this report, is an input event
device the operating system's device manager marks as a joystick, the marking
the port naming already requires, and its identity SHALL be the vendor and
product the input device itself reports, not a property derived from a USB
device it is attached through. Any other input device, such as a power
button, a keyboard or a receiver, is not a controller here whatever identity
it carries: it SHALL NOT be named, and it SHALL NOT make this report
unhealthy.

An empty slot is information, not a finding. A recorded port that resolves to
no connected pad SHALL be reported as unoccupied without warning, and a box
that records no controller ports at all SHALL be reported as recording none,
also without warning. A connected controller identifying as none of the
accepted modes SHALL be the only condition under which this report is
unhealthy. The box ships with no ports recorded, and a household that plays
two-player games leaves two of its four ports empty, so treating an empty slot
as a finding would make the status command unsuccessful on a healthy box for
the life of that box - a standing warning about a state that is not wrong,
which an administrator learns to ignore and which then costs the report its
whole value.

#### Scenario: Pads are connected to recorded ports

- **WHEN** the operator runs the status command
- **THEN** it reports which recorded ports resolve to a connected pad

#### Scenario: A recorded port has no pad, or no ports are recorded

- **WHEN** the operator runs the status command on a box where a recorded port
  resolves to no connected pad, or on a box that records no controller ports
  at all
- **THEN** the report lists the recorded ports and says which resolve to a pad
  and which do not, or says that no ports are recorded, and it warns in
  neither case

#### Scenario: A pad is in an unaccepted mode

- **WHEN** a connected controller identifies as none of the accepted modes,
  whether or not it is on a recorded port
- **THEN** status warns and names it

#### Scenario: An input device that is not a controller

- **WHEN** an input device the operating system's device manager does not mark
  as a joystick, such as a power button, a keyboard or a receiver, is present
  carrying an identity outside the accepted modes
- **THEN** status does not name it, and it does not make the controllers
  report unhealthy
