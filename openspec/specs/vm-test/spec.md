## Purpose

CI proves what the host configuration guarantees on every push, without hardware. In a VM twice over: through the same boot path the real box uses, for the base layer's ephemeral root, persisted state, secrets and networking declaration and the presence of the programs the box installs; and on a plain node with a graphical stack, for the kiosk session. Outside a VM once: the config editor's unit tests, lint and type check, which run on every system the flake is checked on, the admin's Mac included.

## Requirements

### Requirement: The VM boots through the real boot path
The VM test SHALL boot its node through the UEFI boot loader and the initrd, on a disk that carries the same btrfs subvolume layout as the box, so that the root rollback and the early mounts are exercised rather than bypassed.

#### Scenario: Layout matches the box
- **WHEN** the test node has booted
- **THEN** `/`, `/nix`, `/persist`, `/data` and `/data/cache` are each a btrfs subvolume mount, and the boot went through the boot loader rather than a direct kernel load

### Requirement: Persistence is proven across a reboot
The test SHALL boot the node, record `/etc/machine-id`, write a marker under `/root` and a marker under `/data`, reboot, and assert the `/root` marker is gone, the `/data` marker remains, the machine-id is unchanged and the reboot adds a boot the journal still lists, whose predecessor is readable. It SHALL then cut the node's power without a clean shutdown and assert the node boots again with the root wiped.

The boot count is asserted across the reboot rather than against a literal total. How many times the test restarts the node is a property of the test, not of the system: the reconciliation coverage this change adds restarts it too, so a fixed total of two would have to be revised every time the test gains or loses a restart. The persistence capability asks only that the machine has booted at least twice and that the previous boot's entries can be read.

#### Scenario: Two-boot assertion
- **WHEN** the test reboots the node after writing the markers
- **THEN** all four assertions hold

#### Scenario: Power cut
- **WHEN** a marker is written under `/root` and the node is stopped without a clean shutdown, then started
- **THEN** the node reaches multi-user with no filesystem repair prompt and the marker is gone

### Requirement: Secrets decrypt in the VM
The test node SHALL decrypt a test-only secrets file holding non-secret test values, encrypted to a test SSH host key committed for that purpose and converted to age the way the box's own key is, and the test SHALL assert the declared secrets exist with the expected values and modes and that `admin` can log in with the test password.

#### Scenario: Test secrets present
- **WHEN** the test node has booted
- **THEN** the WiFi PSK and admin password secrets exist on the runtime path with the declared owner and mode

#### Scenario: Closure carries no test secret
- **WHEN** the closure of the host configuration extended with the test module is built
- **THEN** a builder-side check over that closure finds neither the test PSK nor the test password hash in any store path

#### Scenario: Admin console login
- **WHEN** the test logs in as `admin` on a virtual console with the test password
- **THEN** a shell prompt is reached

### Requirement: Networking declaration is proven
The test SHALL assert the family WiFi profile is listed by the network manager with the PSK substituted from the test secret, and that no non-loopback listener other than the DHCP client's exists.

#### Scenario: Profile and listeners
- **WHEN** the test node has booted
- **THEN** the declared profile is listed, its generated connection file carries the test PSK, and every listening TCP socket, and every UDP socket other than the DHCP client's, is bound to loopback

### Requirement: Vendored programs are installed in the booted system
The test SHALL assert, on the booted node, that the frontend and the vendored emulator are installed on the system's program path and that the frontend reports the pinned version, so that a package that fails to build or is dropped from the host closure fails CI rather than being discovered on the box.

#### Scenario: Programs present
- **WHEN** the test node has booted
- **THEN** `es-de` and `duckstation` are executable files on the system's program path

#### Scenario: Frontend version
- **WHEN** the test runs `es-de --version` on the booted node, which has no display
- **THEN** the command succeeds and its output contains `ES-DE 3.4.1`

### Requirement: The kiosk session is proven in a second VM
A second VM test SHALL boot the host's software modules as a plain test node with a graphical stack (no disk layout, no boot loader, enough memory for the frontend, a virtual GPU) and SHALL assert, on that node: the display manager active, `player` holding the seat's active session, the frontend running inside the compositor within the test's startup budget, the settings file carrying the flake-owned values including the unlock sequence the configuration declares (enforced values by value, seeded values by presence), a seeded frontend setting changed while the frontend is stopped still holding the changed value after the reboot, RetroArch's launch-delivered settings winning at runtime over a stale copy in `retroarch.cfg`, the custom systems file present for a non-empty definition and absent for an empty one, a relaunch after the frontend is killed, a reboot returning to the frontend, and, after three consecutive short runs, no frontend running with the display manager still serving a login. A headless launch of RetroArch that the test performs with launch-time configuration of its own SHALL join that configuration onto the flake's launch-time configuration in the one place RetroArch reads it from, rather than replacing the flake's, and the flake's configuration it joins onto SHALL be the one the node's RetroArch wrapper actually passes, not a copy the test derives for itself; a launch that discarded the flake's configuration would prove nothing about it. The `kiosk` capability owns the constants these assertions check against; the wait budgets and test-only thresholds it uses to do so are implementation choices of the test, not requirements. The install test is unchanged by this requirement and keeps its display manager off. Which VM tests `nix flake check` runs, and that each is runnable on its own, is stated once by the "The test runs in CI and locally" requirement and is not restated here.

#### Scenario: Session assertions
- **WHEN** the kiosk test node has booted
- **THEN** each behaviour this requirement lists is asserted on that node, and the test fails if any assertion does not hold

#### Scenario: Seeded survival assertion
- **WHEN** the kiosk test, with the frontend stopped and the session at the greeter, changes a seeded frontend setting's entry in the settings file to a value the frontend accepts, then reboots the node
- **THEN** the test asserts the changed value is still in the settings file once the frontend is up again, and fails if it was reverted

#### Scenario: Launch-delivered settings win at runtime
- **WHEN** the kiosk test writes a stale value for one of RetroArch's launch-delivered settings into `retroarch.cfg` and then launches RetroArch headless with the flake's launch-time configuration in effect
- **THEN** the test asserts the value in effect after that launch is the flake's, and fails if the stale value was in effect

### Requirement: The config editor is tested without a VM
The program that seeds and asserts configuration files SHALL be unit-tested, linted and type-checked as part of its build, and those checks SHALL run under `nix flake check` on every system the flake is checked on, including the admin's macOS machine.

#### Scenario: Editor checks on macOS
- **WHEN** `nix flake check` runs on the admin's macOS machine
- **THEN** the config editor's tests, lint and type check run and their failure fails the check

### Requirement: The test runs in CI and locally
Each VM test SHALL be part of `nix flake check` so CI runs it on every push, and SHALL be runnable with a documented recipe on any `x86_64-linux` builder that exposes KVM; CI's runner is the one the tests are built on, and no local KVM builder is assumed.

#### Scenario: CI runs the test
- **WHEN** a push to `main` or a pull request runs CI
- **THEN** every VM test the flake defines is built and any one's failure fails the job

### Requirement: Emulator launches and achievements are proven in the VM
The kiosk VM test (or a sibling node built from the same modules) SHALL
assert emulator behavior without hardware: for each BIOS-free core
family in the system table for which a freely redistributable homebrew
ROM exists, RetroArch SHALL run that ROM headless and the test SHALL
assert a successful exit and a
log line proving the core ran; each standalone emulator SHALL get a
smoke launch asserting the process starts against the asserted
configuration. A core family SHALL be exempt from the headless launch
when no ROM for it carries an explicit licence or redistribution grant
from its author, since the fixtures are fetched by a public CI run and
pushed through a public binary cache; or when the core cannot run
headless at all - a core that demands a hardware render context has no
VM to demand it of; or when the launch failed in a way nobody has yet
attributed to either the core or the fixture, which is an admission of
ignorance rather than a finding and SHALL be recorded as one. The
configuration SHALL name each exempt family, which reason applies, and
what would return it to the tested set, so an exemption is a deliberate
line someone added rather than a family the test quietly skipped, and so
no exemption is permanent merely because nothing prompts anyone to
revisit it. An exempt family is a hardware checklist item, like the
BIOS-dependent cores.
Chasing a headless launch for a core that resists one is explicitly not
required: the VM proves the configuration the flake writes, and an
emulator's own runtime behaviour is a checklist item by design.
Against a RetroAchievements endpoint mocked inside the
test network, the test SHALL assert that each supporting emulator's
configuration carries the account name and token - DuckStation's by
decrypting the stored value the way the pinned DuckStation version does
- that no configuration contains the password, and that the hardcore
option is reflected in every supporting configuration in both its
positions. The test
SHALL also boot with no cached token and no route to the endpoint and
assert the frontend still comes up with achievements absent and the
journal recording the failed login. Systems
whose core needs BIOS images, and real performance, remain hardware
checklist items, not VM assertions.

#### Scenario: Core families launch headless
- **WHEN** the VM test runs RetroArch headless with the homebrew ROM of
  a BIOS-free core family that has one
- **THEN** the run exits successfully and the log carries the expected
  line, and any family's failure fails the test

#### Scenario: A family with no redistributable ROM
- **WHEN** a BIOS-free core family has no ROM carrying an explicit
  licence or redistribution grant
- **THEN** the configuration names that family as exempt, the test
  launches nothing for it and stays green, and the family is covered by
  the hardware checklist instead

#### Scenario: A family whose failure nobody has explained
- **WHEN** a BIOS-free core family's headless launch fails and it is not
  known whether the core or the fixture is at fault
- **THEN** the configuration records the exemption as unattributed
  rather than as a property of the core, states what was actually
  observed, and names what would settle it

#### Scenario: Tokens asserted against a mock
- **WHEN** the VM test boots with RetroAchievements enabled, test
  credentials and the mocked endpoint
- **THEN** every supporting emulator's configuration carries the mock's
  token in that emulator's at-rest form and no configuration carries the
  password

#### Scenario: Standalones smoke launch
- **WHEN** the VM test smoke-launches a standalone emulator against the
  asserted configuration
- **THEN** the process starts successfully, and any standalone's
  failure fails the test

#### Scenario: A standalone that cannot be launched headless
- **WHEN** a standalone emulator cannot be started far enough under the
  VM's headless drivers to read its configuration
- **THEN** the test proves what it can - that the binary runs - and the
  configuration records that this one proves less than the others, and
  why, so the weaker check is a stated exception rather than an
  assertion that quietly means less than its neighbours

#### Scenario: Offline boot without a cache
- **WHEN** the VM test boots with RetroAchievements enabled, no cached
  token and no route to the mocked endpoint
- **THEN** the frontend still comes up, no supporting configuration
  carries the account name or token while each one's
  achievements-enabled and hardcore settings are written as declared,
  and the journal records the failed login

### Requirement: Save placement and recovery are proven in the VM
The kiosk VM test, or a sibling built from the same modules, SHALL use a local
restic repository and test credentials to prove save routing and recovery
without Backblaze. It SHALL assert that the implemented route declaration
matches every field of the authoritative finite table, including every declared
setting and mandatory mount,
including ScummVM; exercise each deterministic route or record a specific
exemption; verify migration ordering and conflicts; and prove persistence. It
SHALL also prove that retained local snapshots are read-only and do not
recursively capture the sibling `@cache` and `@snapshots` subvolumes,
snapshot-consistent backup, the finite exclusion list and default inclusion,
failure visibility, transient cleanup, future scheduling, priority settings,
and runtime secret permissions. It SHALL reject lexically malformed typed roots
and home exclusions at evaluation, reject symlink escape and aliasing against
the source snapshot before restic runs, prove the repository initialization
gate is fail-closed, pair health markers to exact invocations, and keep local
operation available during cloud failure.

The VM proves the seams this project builds: the route table, the migration,
the snapshot transaction, and the wiring between them. It SHALL NOT re-prove
restic, btrbk or systemd themselves. Where the logic is pure it is proven by
the helper's own unit tests, which run natively on the administrator's Mac and
report a located failure in seconds rather than one assertion per CI build.

#### Scenario: Save route survives reboot
- **WHEN** the VM writes known bytes through a declared emulator save path and reboots
- **THEN** the bytes remain beneath that emulator's `/data/saves` directory

#### Scenario: Runtime save fixture is unavailable
- **WHEN** a route, including ScummVM, cannot be exercised deterministically
- **THEN** the test asserts its setting or mount and records the reason and condition for removing the exemption

#### Scenario: Upgrade migrates every changed route
- **WHEN** the VM upgrades with files at setting-directed and bind-mounted legacy paths
- **THEN** migration precedes activation and a forced conflict blocks activation without overwriting data

#### Scenario: Backup set honors explicit exclusions
- **WHEN** the VM backs up fixtures in every exclusion and an arbitrary unlisted player-home path
- **THEN** each exclusion is absent and the unlisted file is present

#### Scenario: Path declarations are invalid
- **WHEN** roots or home exclusions contain duplicates, traversal, the home root, or lexical save-route overlap
- **THEN** evaluation fails and no restic inputs are generated

#### Scenario: Filesystem path aliases protected data
- **WHEN** a home exclusion resolves through a symlink ancestor outside player home or onto a save route or another exclusion in the source snapshot
- **THEN** backup fails before invoking restic and reports the invalid declaration

#### Scenario: Backup captures the source snapshot, not the live file
- **WHEN** the VM backs up known fixture bytes and changes the live file while the source snapshot is open
- **THEN** the backed-up bytes are the source snapshot's rather than the later live file's

Restoring those bytes back through the local double would exercise the double's
own copy, not this project. Verified restore is proven where it is real: the
documented manual procedure and the one `restic restore --verify` against B2 in
the E12 rollout checklist.

#### Scenario: Failed backup supersedes prior success
- **WHEN** a successful backup is followed by a forced failure
- **THEN** current status shows failure, the transient source is removed, and the future timer remains enabled

#### Scenario: Interrupted backup artifact is reconciled
- **WHEN** the VM presents a transient source artifact at boot or between two backups without reboot
- **THEN** reconciliation removes it before the next backup creates its source snapshot

#### Scenario: Repository initialization gate is fail-closed
- **WHEN** initialization cannot open its repository
- **THEN** the backup's own activation fails without invoking restic's backup, and status reports that layer unhealthy rather than its previous success

#### Scenario: Health marker is not from the latest invocation
- **WHEN** a successful backup is followed by an invocation of the same unit that runs and fails
- **THEN** status reports that layer unhealthy and does not reuse the earlier success marker

Malformed, mismatched and never-run markers, the lock timeout inequalities
`M < R` and `B >= P + R + E`, and the precise-absence initialization result are
proven by the helper's unit tests and by evaluation-time assertions. The VM
proves only that a marker reaches the journal under the unit's current
invocation and that status reads it there.

#### Scenario: Cloud is unavailable
- **WHEN** initialization or backup cannot reach its repository
- **THEN** gameplay, display, save routes, and local snapshot creation still operate

#### Scenario: Cloud backup is rolled back
- **WHEN** the cloud backup and maintenance units and timers are stopped after migration
- **THEN** all save mappings remain active and a table-routed write survives reboot

Rollback itself is declarative: `/etc/systemd/system` is read-only on the box,
so `systemctl disable` cannot persist a change and turning off-site backup off
means `emubox.backups.enable = false` and a rebuild, which is evaluated rather
than run in a VM. What the VM proves is the runtime half, that taking the cloud
jobs away touches neither the save mounts nor the data beneath them.

### Requirement: Controller ownership is proven in the VM

The kiosk VM test, or a sibling built from the same modules, SHALL prove the
controller seams this project builds: that a recorded port becomes its player's
stable name, that the session declares the resulting enumeration order, that
the owned input keys reach each emulator's configuration in the tier they are
declared in, and that the operator status command aggregates the reports
contributed to it.

The port fixture SHALL supply the device path the rule matches and the
controller identification the rule requires, so the assertion covers the
mapping from a recorded port to its player name. It SHALL NOT depend on the
virtual machine's own bus topology, and the test SHALL NOT re-prove the
operating system's derivation of device paths, which is not this project's
code and whose values on the real box are a bring-up fact no virtual machine
can supply.

#### Scenario: Recorded ports become player names

- **WHEN** the fixture presents a controller on each recorded port
- **THEN** each port's player name resolves to that controller, in recorded
  order

#### Scenario: The session declares the enumeration order

- **WHEN** ports are recorded
- **THEN** the session environment carries the enumeration order listing those
  ports by position

#### Scenario: No ports are recorded

- **WHEN** the node records no controller ports, as the real box does before
  bring-up
- **THEN** the session environment declares no enumeration order at all

#### Scenario: Owned input keys reach each emulator

- **WHEN** the configuration editor has run over emulator configuration files
  that did not yet assign any owned key, as on a freshly built node
- **THEN** each standalone emulator's configuration carries its enforced
  route back to the frontend where the pinned emulator offers one - every
  standalone but Azahar - and any pad-identity fact it needs is recorded,
  carries the owned setting that suppresses its exit confirmation where one is
  declared, carries its gameplay bindings where they are declared, seeded, or
  enforced where they depend on a pad-identity fact, carries the settings that
  connect each bound player's controller slot where those are declared, and
  carries every other setting a binding depends on to reach a pad, where any
  pad-identity fact it needs is recorded; the slot settings and those other
  settings each sit in the tier of the binding they serve, which puts them in
  the enforced tier with the route back and with a binding that depends on a
  pad-identity fact, except that a flag deciding whether the stored binding
  beside it is read at all is enforced whatever that tier

#### Scenario: An enforced route back is restored

- **WHEN** the configuration of a standalone emulator other than Azahar,
  carrying its enforced route back, is altered to unbind that route back and
  the configuration editor runs again, as it does before the frontend starts
- **THEN** the enforced binding is restored

#### Scenario: A seeded gameplay binding is kept

- **WHEN** an emulator's configuration carries a player's altered seeded
  gameplay binding, one that depends on no pad-identity fact, and the editor
  runs again
- **THEN** the player's binding is unchanged

#### Scenario: Status aggregates its reports

- **WHEN** the operator status command runs on a node with more than one
  registered report
- **THEN** its output carries a section from each capability that registered a
  report on that node, the controllers section among them, and no section for
  a capability that registered none

#### Scenario: The backups report on a box with off-site backup disabled

- **WHEN** the operator status command runs on a node whose off-site backup is
  disabled
- **THEN** its backups section reports the local snapshot layer and reports
  neither off-site layer

#### Scenario: A failing report does not hide the others

- **WHEN** one contributed report fails to run
- **THEN** every other section is still produced and the command's exit status
  is unsuccessful

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
mode - is refused and leaves the selection unchanged. The unprivileged refusal
SHALL cover the privilege the session account does hold: as that account, the
privileged removal given an argument and the mode command run through the same
privilege route SHALL both be refused, with the flag asserted by exact value.

The test SHALL make its first switch the way an administrator at the box makes
it, so that the route the operator documentation names is proven and not only
the command. From the running frontend it SHALL press the keyboard's
virtual-console switch, assert that the console it names became the active one
and shows a login prompt, press the switch naming the frontend's console and
assert that the frontend's session, the same one, is the seat's active session
again, return to the prompt, log in there as `admin` with the test password, run
the mode command with administrative privilege by typing it, and read the
command's report off that console. Because the new-session assertions are made
on the seat's active session, they are then also the proof that the display
manager put the new session on the TV rather than leaving the console there.
The test SHALL also assert that the account the automatic session runs as has
no password to pass that prompt with, read from the account database rather
than by attempting a login. What this proves is the compositor's handling of
the key; that the box's own keyboard produces it is a bring-up item.

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

The test SHALL prove that the privileged removal of the flag resolves no
program from its caller's environment: it SHALL run that removal as the account
the automatic session runs as, with a program search path whose first entry
holds a substitute for a program the removal uses, and assert that nothing from
that path ran and that the flag was removed. It SHALL also assert that the
built removal carries no reference to an inherited search path, since the
tools it lists are found ahead of the caller's path either way and only that
assertion notices the caller's path being let back in.

The test SHALL prove the switch back with the desktop still running, not only
from a login prompt: after it, and once the desktop's shutdown has been given
a bounded time to finish, a new session SHALL be running the frontend, no
desktop startup or compositor process owned by the account the automatic
session runs as SHALL exist anywhere on the node, and no unit of the desktop's
workspace SHALL be active in that account's user service manager. The display
manager ends a session by signalling one process, so a desktop that runs as
part of the session survives the switch unless the session passes that signal
on. The same SHALL be asserted in the other direction: once the desktop is up
after a switch from the frontend, no frontend process owned by that account
exists anywhere on the node. Wherever the test asserts that the frontend is
running, it SHALL match the frontend's own process and not a command line that
merely names it, since the compositor's arguments name the frontend before the
frontend has started.

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

The test SHALL prove that repeated switches are not refused by the display
manager's start rate limit: it SHALL run the command several times, more often
than that limit permits in its window, each from a running session, and assert
that each invocation succeeds, that the display manager is running rather than
failed on its start limit, and that a session of the requested mode comes up.
The test MAY widen the unit's start-limit window on its node, so that the proof
does not depend on how fast the runner starts sessions. A switch made while the
display manager is still logging in the previous switch's session is outside
what this requirement proves.

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

#### Scenario: The operator's route is proven on the node

- **WHEN** the test presses the virtual-console switch on the node while the
  frontend is on the seat, logs in on that console as `admin` with the test
  password and types the mode command with administrative privilege
- **THEN** that console was the active one and showed a login prompt, the
  switch back made the frontend's own session the active one again, the
  command's report is read off the console, a new session running the desktop becomes
  the seat's active session, and the account database shows the session
  account with no password

#### Scenario: Switching back from a live desktop leaves no desktop behind

- **WHEN** the test switches the node to the frontend mode while the desktop
  session is still running
- **THEN** a new session is running the frontend, no desktop startup or
  compositor process owned by the session's account exists anywhere on the
  node, and no unit of the desktop's workspace is active in that account's user
  service manager

#### Scenario: Repeated switches are not refused by the start rate limit on the node

- **WHEN** the test runs the mode command as root more times than the display
  manager's start rate limit allows in its window, each from a running session
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

#### Scenario: The privileged removal ignores a poisoned search path on the node

- **WHEN** the flag is present and the test runs the privileged removal as the
  account the automatic session runs as, with a program search path whose first
  entry holds a substitute for a program the removal uses
- **THEN** the removal exits zero, nothing from that search path ran, and the
  flag is gone

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
