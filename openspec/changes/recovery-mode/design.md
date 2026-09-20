## Context

See proposal.md for motivation. This section records what was read out of the
tree and out of pinned nixpkgs, because most of this change is already built.

**The session script already reads the flag, inside the relaunch loop.**
`modules/kiosk/default.nix` lines 105-109 read `/run/emubox/mode`, default to
`kiosk` when the file cannot be read, and on `desktop` `exec
startplasma-wayland`. The read sits inside `while true; do` (line 104), so the
mode is re-decided on every relaunch of the frontend. Nothing has ever written
the flag, so the `desktop` branch has never been taken on any box. D4 moves
the read and the branch above the loop.

**Plasma, `admin` and the boot-menu entry already exist.**
`modules/recovery/default.nix:9` enables Plasma 6, lines 11-23 declare `admin`
in `wheel` with its password hash from the secrets file, line 24 makes sudo
passwordless for `wheel`, and lines 32-36 declare the recovery boot entry that
forces automatic login off and pre-selects the Plasma session. This change
leaves their effect as it is: the declarations move under a `config` block so
the module can declare an option (D6), and the module gains the mask on the
file indexer's user unit (D1). The recovery spec is where they acquire
requirements.

**Reaching privilege from the desktop is `su` and then `sudo`.** The desktop
runs as `player` (D1), a normal user (`modules/kiosk/default.nix:585`) in
`player`, `video`, `input` and `audio` and not in `wheel`, so `sudo` from a
terminal there is refused. `security.sudo.wheelNeedsPassword` is false, `admin`
has an interactive shell, and `security.pam.services.su.requireWheel` is left
at its NixOS default of false. The route is therefore `su - admin`, which
prompts for the admin password the `secrets` capability supplies, and then
`sudo`, which does not prompt.

**ES-DE cannot hide a system in kiosk mode.** Upstream ES-DE shows a system
whenever its ROM directory holds a file with a declared extension, and the
documented ways to hide one - renaming the directory, a `DISABLED` folder, a
`noload.txt` marker - apply to every UI mode alike.

**There is no shell on the box today.** `modules/remote/default.nix` binds
sshd to `127.0.0.1`, and `admin`'s `authorizedKeys.keys` is empty. Until the
remote-administration capability lands, the only route to a prompt is a
console at the box or the boot-menu recovery entry.

**The frontend's compositor swallows the console switch.** The session runs
`cage -- es-de`, and the pinned cage 0.3.0 acts on Ctrl-Alt-Fn only when
started with `-s` ("Allow VT switching" in its manual); under a Wayland
compositor the kernel does not switch consoles itself. As the tree stands, a
box showing the frontend therefore has no route to a console at all, and the
README's existing bring-up line saying Ctrl-Alt-F3 reaches one is wrong. The
greeter's compositor and Plasma's both honour the key. `player` is given no
password, so its account is locked at a console prompt (D12).

**`sddm.autoLogin.relogin = false` is deliberate.**
`modules/kiosk/default.nix:596-618` sets it so that the session script's
three-short-runs give-up lands at a greeter instead of looping.

**Restarting the display manager restores automatic login.** In the pinned
SDDM, 0.21.0, `first` is a plain in-process member
(`src/daemon/DaemonApp.h:44`, `bool first { true };`) persisted nowhere, and
`src/daemon/Display.cpp:275-276` evaluates
`(daemonApp->first || mainConfig.Autologin.Relogin.get()) && !mainConfig.Autologin.User.get().isEmpty()`
on the first display of each process. A new daemon process therefore
autologins exactly as a reboot does. The second conjunct bounds the approach:
on a system booted through the recovery entry a restart logs nobody in and the
flag selects nothing. That state is readable at runtime because NixOS emits
the `[Autologin]` section of `/etc/sddm.conf.d/00-nixos.conf` only where
`services.displayManager.autoLogin.enable` is true. The recovery entry forces
the enablement off and leaves `autoLogin.user = "player"` standing in the
configuration it was built from, so the enablement - the presence of that
section - is what the command checks, never the configured user name.

**A restart ends the running session cleanly.** In the same source, SIGTERM
reaches `DaemonApp::quit` (`src/daemon/DaemonApp.cpp:84-85`), the `Display`
destructor calls `stop()` (`src/daemon/Display.cpp:170-172`), which reaches
`Auth::stop()` (`src/auth/Auth.cpp:387-397`) terminating `sddm-helper`, whose
destructor calls `UserSession::stop()` and then the PAM backend's
`closeSession()` (`src/helper/HelperApp.cpp:286-288`). The session is closed
through PAM rather than left behind. `UserSession::stop()` is a
`QProcess::terminate()`: SIGTERM to the one session process and to nothing
else, followed by a kill after 60 seconds
(`src/helper/UserSession.cpp:146-158`), and logind's `KillUserProcesses` is
false in the pin, so whatever that process does not pass on stays running
(D4). The daemon itself waits only 5 seconds for `sddm-helper` before killing
it (`Auth::stop()`, `waitForFinished(5000)` then `kill()`), so a desktop's
orderly shutdown can still be finishing when the next session appears.

**A session's stderr does not reach the journal.** For every non-greeter
session SDDM's helper opens `$HOME/` + `Wayland.SessionLogFile` - by default
`.local/share/sddm/wayland-session.log` (`src/common/Configuration.h:85`), which
neither the pinned `sddm.nix` nor this repository overrides - with
`O_WRONLY|O_CREAT|O_TRUNC`, dup2s it over stderr and points stdout at
`/dev/null` (`src/helper/UserSession.cpp:351-381`). A line echoed to stderr
therefore lands in a file the next `player` session truncates (D4).

**The display manager unit is rate limited.** The pinned
`nixos/modules/services/display-managers/generic.nix` gives
`display-manager.service` `startLimitIntervalSec = 30`, `startLimitBurst = 3`
and `Restart = "always"`, and the limit counts manual starts (D3).

**Nothing in this repository creates anything under `/run`.** `/run/emubox`
exists today only because the restic helper calls `mkdir(mode=0o700,
parents=True)` while preparing a backup
(`pkgs/emubox-restic-backup/emubox_restic_backup.py:400-401`), which leaves a
root-owned directory `player` cannot read through. Likewise a file renamed
into place keeps its temporary file's mode, unreadable by `player` under a
root umask, and the session script's `cat ... || echo kiosk` turns an
unreadable flag into the frontend without a word.

## Goals / Non-Goals

**Goals:**

- One command that switches modes on a running box, with no reboot and no
  runtime mutation of display-manager configuration.
- A reboot into the entry the box normally boots that returns the frontend
  with nothing having to be set first: no boot of any entry carries a mode
  forward.
- A mode that does not outlive the session it selected, so that leaving the
  desktop is not a trap for the next login.
- Requirements for the recovery surface that is already built.

**Non-Goals:**

- Any frontend entry or on-screen surface for the switch, and therefore any
  invoker on the box other than a console or, later, a shell.
- Any change to what the session script does on the frontend path, to its
  crash counter, or to the display-manager configuration. The edits to
  `modules/kiosk` are the desktop branch, the stale comment above it, moving
  the mode read and that branch above the relaunch loop (D4), and the one
  compositor flag that lets a keyboard reach a console (D12).
- Any change to what the recovery boot entry, the `admin` account or the
  Plasma enablement do. Their declarations move under a `config` block with
  unchanged effect and the module gains the indexer mask (D1); beyond that they
  gain requirements, not edits.
- Any state surviving a boot, and therefore any persisted default mode.

## Mode vocabulary

The words below are the whole vocabulary. Requirements in the `recovery`
capability use them and nothing else names a mode.

| State | How it arises | What the session does |
| --- | --- | --- |
| `kiosk` | the flag holds `kiosk`, written by the command | starts the frontend |
| `desktop` | the flag holds `desktop`, written by the command | starts the Plasma desktop |
| absent | every boot, because `/run` is memory-backed | starts the frontend |
| unreadable or unrecognised | a truncated, empty or corrupt flag, or one the session's account cannot read | starts the frontend |

The last two rows collapse to the same behaviour deliberately: the session
script's existing `cat ... || echo kiosk` and its `if [ "$mode" = desktop ]`
test already produce it, and both are kept as they are. Failure diagnostics
apply that same value rule to the command's read of the flag and end with
`next automatic session: <kiosk|desktop>`: `desktop` only when it reads
exactly `desktop`, and `kiosk` otherwise. No privileged read surface is added
for diagnostics; the clear-only privilege boundary stays as specified. Neither
the reported value nor the session's selection describes the TV: once a
desktop consumes the flag (D6), the selection is `kiosk` while the desktop is
still up.

## Decisions

**D1. Desktop mode runs Plasma in the existing `player` session, with the file
indexer masked.** The alternative was to drop to a greeter and have `admin`
log into Plasma there. Rejected: it needs the display manager's configuration
mutated at runtime or a second session declared for the purpose, it puts a
password prompt between the administrator and the desktop, and it is not what
the existing code does. The cost is that the desktop runs as `player`, so the
route to privilege is `su - admin` and then `sudo` (Context), and the
command's own refusal message names that route.

A second cost: `player`'s home, `/data/home/player`, is one of the four roots
`modules/saves` declares for off-site backup (where an operator has enabled
it; the option defaults off), and the local hourly snapshots take the data
subvolume whole. Plasma writes its configuration under `.config` and its data
under `.local/share`, and the pinned Plasma module installs Baloo, whose index
lives under `.local/share/baloo`. Baloo's default indexed folder is the user's
home - `src/lib/baloosettings.kcfg` in the pinned baloo 6.26.0 defaults
`folders` to `QDir::homePath()` - so it would index the emulator configuration
and the save routes `modules/saves` binds into that home (not `/data/roms` or
`/data/media`, which lie outside it) and rewrite its index there continuously,
seeding a constantly changing file into every backup and snapshot.

So the indexer is masked. It cannot be left out instead: the Plasma module
lists `baloo` among its required packages and
`environment.plasma6.excludePackages` filters only the optional list. The
package ships a systemd user unit, `kde-baloo.service`; a unit definition with
`enable = false` renders as a symlink to `/dev/null` under `/etc/systemd/user`,
which takes precedence over the package's copy, so the indexer starts in no
session on the box, whatever configuration files a home directory contains
(a user-level unit of the same name under `~/.config/systemd/user` would
still be searched first, and nothing on the box writes one). The package also ships
`etc/xdg/autostart/baloo_file.desktop` for the same binary, carrying
`X-systemd-skip=true`, which leaves it inert while Plasma's startup is
systemd-managed. Both routes start `baloo_file` from `player`'s user service
manager (`kde-baloo.service` carries `Slice=background.slice`), outside the
logind session scope, so the VM test looks for the process across the whole
node rather than in the desktop session's process tree.

Moving the desktop's state root elsewhere was rejected: it would set the
session's environment around the handoff for an unrelated reason. The
desktop's own configuration stays in the backup set: those are settings a
person entered, they are small, and `emubox.saves.homeCacheExclusions` would
not reach the local snapshots anyway.

**D2. No ES-DE entry.** A kiosk-hidden entry is not buildable (Context), and an
entry the whole household can see is not wanted. This change therefore ships a
command with no on-box invoker except a console, which is worth doing because
the command has to exist before a remote shell has anything to call.

**D3. The switch is a flag write plus a display-manager restart handed to the
service manager, after one precondition is checked.** Rejected: ending the
session and relying on a relaunch, which `relogin = false` turns into a
greeter; and reworking the session loop to hand back and forth within one
session, which edits the box's most safety-critical script and buys nothing,
since a restart already returns automatic login and re-runs the script from
the top.

- *It refuses first where nothing would read the mode.* A restart stops before
  it starts, so on a system with no automatic login the command would end the
  administrator's session and leave a prompt with a mode recorded that nothing
  reads. The command checks the enablement (Context) before touching anything.
  It does not check whether the display manager unit can be started: a masked
  or absent `display-manager.service` is not a state a box built from these
  modules can enter, and the one refusal to start the unit really carries, the
  start rate limit, is handled below. The refusals are therefore three: not
  root (D5), malformed arguments, and no automatic login on the running
  system.
- *It says what it is about to do.* Before handing the restart over it prints
  the mode it is switching to and that the current session is about to end,
  because the caller is often sitting in that session.
- *It clears the start rate limit first.* The limit (Context) applies to manual
  starts. Observed on a Linux builder with a unit carrying exactly those
  settings: the fourth `systemctl restart --no-block` inside 30 seconds exited
  0, the unit ended `failed` with `Result=start-limit-hit`, `CanStart` still
  read `yes`, and `Restart=always` did not retry - nothing on the TV, and a
  command that reported success. With `systemctl reset-failed <unit>` before
  each restart, five in a row succeeded; on an active, non-failed unit
  reset-failed exits 0 and is harmless. An administrator-requested restart is
  not a crash and must not be counted against the crash limiter, so the command
  runs `systemctl reset-failed display-manager.service` immediately before the
  hand-off. It is best-effort: its failure is not allowed to end the command
  under `set -e`, and the hand-off proceeds. The guarantee covers switches each
  made once the previous switch's session is running, however many fall in the
  limit's window. Observed in CI: running the command again while SDDM is still
  setting up the previous login, during PAM session setup, leaves SDDM looping
  on `HELPER_TTY_ERROR` with no session and no greeter. That is not guarded
  against: the promise is narrowed to exclude it, and the README tells the
  operator to wait for the screen between switches.
- *It hands the restart to the service manager rather than performing it.* The
  restart is enqueued without waiting, so the job belongs to PID 1 and survives
  the caller's session ending. The hand-off is guarded rather than left to
  `set -e`: a `writeShellApplication` runs under `set -euo pipefail`, so an
  unguarded enqueue that fails would end the command silently with the flag
  already written, and the caller has to be told that the mode was recorded
  and the session was not restarted. Success is reported as the mode recorded
  and the restart accepted, never as the box being in the requested mode.

**D4. The session picks its mode once, above the relaunch loop, and runs the
desktop as a background child it forwards termination to.** The read and the
`desktop` branch move above `while true; do`, unchanged in what they test. The
loop that remains is the frontend's alone, and the desktop cannot be entered
from inside it; that is reason enough for the move. (The loop sleeps 2 seconds
before each re-read, so an outgoing session consuming a flag meant for its
successor was a window of milliseconds, not the motive.) The stale TODO
comment goes.

The branch stops being `exec startplasma-wayland`. The script's exit
discipline is one `EXIT` trap that reports a clean exit whatever the real
status was, because SDDM casts the session helper's exit code to its helper
status, 1 is `HELPER_AUTH_ERROR`, and a session exiting 1 leaves the daemon
alive with no display and no greeter - which `modules/kiosk/default.nix`
documents as proved in CI. `exec` replaces the shell, so the trap does not
cover the desktop and a Plasma exit of 1 would reach the helper unmodified.
Only status 1 does that. A desktop killed by a signal it does not handle
reaches SDDM as 128 plus the signal number (137 for SIGKILL), which a greeter
follows in either form. SIGTERM is not such a signal: the pinned
`startplasma-wayland` (plasma-workspace 6.6.6, `startkde/`) installs a SIGTERM
handler that quits its event loop, after which `main` runs
`stopSystemdSession()` - an orderly stop of Plasma's user units - and returns
0, or 4 if startup had failed.

Running the desktop as a child loses what `exec` used to give: the process
SDDM sends SIGTERM to when it stops a session (Context) is now the bash script,
and bash running a foreground child defers a trap until the child exits, or
with no TERM trap simply exits 143 and leaves the child running. So the
required shape, tested locally under `set -euo pipefail` with the existing
`EXIT` trap, is: install a trap on TERM and HUP before launching the desktop,
recording a pending termination request while no child pid is available; start
the desktop in the background and record its pid; immediately forward any
pending TERM to that pid; wait for the pid
in a loop that waits again when `wait` was interrupted by the trap rather than
by the child exiting; capture the child's real exit status without `set -e`
ending the script; log that status; and exit through the existing `EXIT` trap,
never entering the relaunch loop. In that test the child received TERM, cleaned
up and exited, and the script logged the child's real status and reported a
clean exit. The SIGTERM handler above is why forwarding TERM is the right lever
for the switch back: the desktop's own startup process stops Plasma's user
units when it receives it. The status line is written to the journal
explicitly, through `systemd-cat -t emubox-session` with `pkgs.systemd` added
to the script's `runtimeInputs`, because the session's stderr goes to a
truncated file (Context); it is the one line that must not rely on stderr, and
the frontend path's existing logging is left as it is. The branch writes one
more line the same way when the clear (D6) fails, before falling through to the
frontend, so that an administrator who asked for a desktop and got the frontend
can see why. Never entering the loop is what keeps "ending the desktop leaves a
login prompt" true. The loop's body, the crash counter and the give-up path
are untouched; the desktop is not a frontend run and is not counted as one.

**D5. Setting a mode is root-only, with no polkit rule for `player`.** Both
the flag write and the restart need root; the decision is not to buy `player`
a way around that, since a polkit rule letting the session restart the display
manager would let anything reachable from the frontend or a game put a desktop
on the TV. `admin` reaches the command through its passwordless sudo, and from
the desktop through D1's route. The boundary is: **the session may clear the
flag, never set it.** Clearing can only move the box towards the frontend.

**D6. The flag is one-shot: the session that hands over to the desktop clears
it first.** "Write the flag" and "remove the flag" are separate capabilities: a
helper that runs as root, takes no argument and does nothing but remove
`/run/emubox/mode`, invocable by `player` through a passwordless rule naming
exactly that command, is one-way by construction. A world-writable flag or a
setuid helper were rejected because both hand the session the ability to set a
mode. What it buys: `emubox-mode desktop` means "give me a desktop now", and
ending the desktop does not arm every later login to land back in Plasma.

The helper takes nothing from its caller's environment either. sudo preserves
the caller's `PATH` under `env_reset`, and the pinned NixOS sudo module sets no
`secure_path`, so a helper that resolved `rm` from the `PATH` it was handed
would run the caller's `rm` as root. Two things close that. `coreutils` is in
`runtimeInputs`, and the pinned `writeShellApplication` puts `runtimeInputs`
ahead of any inherited `PATH`, so the `rm` that runs is the pinned one either
way. And the helper is built with `inheritPath = false`, which drops the
caller's `PATH` altogether, so that a tool added to the script later and
forgotten in `runtimeInputs` fails to resolve instead of resolving from the
caller. `emubox-mode` is closed the same way. Because the listed tools win
either way, a poisoned `PATH` alone cannot show `inheritPath` being dropped;
the VM test therefore also asserts that the built helper carries no reference
to an inherited `PATH`. The sudo rule is as narrow as the helper: it runs the
command as root only (the NixOS rule default is any user and group) and admits
no argument.

The helper is defined in `modules/recovery` and invoked from the session script
in `modules/kiosk`, across a boundary a `let` binding does not cross, and a
sudo rule naming a store path does not match an invocation that `PATH` resolves
to `/run/current-system/sw/bin/...`. So `modules/recovery` declares an
internal, read-only option, `emubox.recovery.clearModeCommand` in the
repository's `emubox.<module>.*` namespace, holding the helper's
`${pkg}/bin/<name>` path, and both the rule and the invocation are built from
it - the idiom of `emubox.emulators.configDirs`. Declaring an option is what
forces the module's bare attributes under a `config` block. The script invokes
`/run/wrappers/bin/sudo -n <that path>`: SDDM gives the session the VT as stdin
and controlling terminal, so a `sudo` the rules do not admit would otherwise
prompt on the VT and block for the password timeout instead of failing, and
`pkgs.sudo` stays out of the script's `runtimeInputs` because a store sudo is
not setuid and would shadow the wrapper.

The clear happens before the handoff and the desktop starts only if it
succeeded; otherwise the session falls through to the frontend. The clear is in
the desktop branch only: a flag holding `kiosk` selects what its absence
selects.

**D7. The flag stays on tmpfs and nothing persists a default.** `/run` is
cleared on boot, so the flag's absence is the boot state whichever entry is
booted; an entry that logs nobody in reads no flag at all. A persisted
preference was rejected: it would make "reboot to get the TV back" conditional
on a file's contents.

**D8. The command and the helper are `writeShellApplication`s, with no check
of their own.** A packaged Python program in the shape of `emubox-status` was
rejected: those earn a package because they have algorithms, while this command
validates one of two words, writes a file and restarts a unit.
`emubox-session` is a `writeShellApplication` for the same reason. No flake
check is added for the two programs: `flake.nix` already has
`hostOnly.toplevel`, the host's system toplevel, as a check, and both programs
are on `environment.systemPackages`, so `nix flake check` already builds them
and runs their shellcheck.

**D9. The flag is written by rename, world-readable, and `/run/emubox` gets a
tmpfiles rule.** The command writes a temporary file in `/run/emubox` and
renames it over the flag, so a concurrent reader sees a whole value. Rename
preserves the temporary file's mode, so the command sets it to 0644 before the
rename (Context). The tmpfiles rule creates `/run/emubox` at 0755 root-owned on
every boot; the command still creates the directory if it is missing. Having
the command chmod what the restic helper left was rejected as fixing a symptom
in the wrong place.

**D10. The mode test is a node of its own.** Its assertions restart the
session out from under the node several times, while the kiosk node asserts
relaunch counting and the crash-loop greeter - exactly what a restart
disturbs. The cost is a fourth VM test and its CI minutes. The test runs
`systemctl reset-failed display-manager.service` before any display-manager
restart it makes itself, so it does not depend on its legs being more than the
rate-limit interval apart. The node also forces the unit's
`startLimitIntervalSec` to 3600, far above the test's run time, so that every
start in the test counts against the burst of 3 and the rate-limit leg's proof
does not depend on how fast the runner starts four sessions.

**D11. The mode test asserts session identity, not the presence of a
desktop.** SDDM's `Users.ReuseSession` defaults to true
(`src/common/Configuration.h:99`). If a daemon died uncleanly and left an
online session for `player`, the next automatic login would reactivate it, the
session script would not re-run, and the flag would not be re-read; a test that
looked only for a desktop process would pass while the TV showed the frontend.
Recording the session id before the switch and asserting a different one
afterwards catches that class. A graceful `systemctl restart` closes the
session through PAM first (Context), which is why the command restarts the
unit rather than killing anything.

**D12. The frontend's compositor allows the console switch.** The session
starts cage with `-s`. Without it this change ships a command that a healthy
box offers no place to run (Context), and the capability's own text - the
command is run from "a console on the box itself" - describes a console nobody
can reach. Correcting the documentation instead was considered and rejected:
the flag is one character, and the route it opens can be proven in the VM,
because the test driver's key injection reaches cage through the same input
path a keyboard does and the node already carries the test `admin` password.
What the key exposes is a login prompt, not a shell: `player` has no password
and `admin`'s is the `secrets` capability's, so a family member who presses it
meets a prompt they cannot pass and the same key takes them back. cage acts on
the key before its client sees it, so the route works from inside a game as
well. The mode test makes its first switch this way - key, console login,
typed command, report read off the console - and the seat's active session
being the new one is the proof that SDDM took the TV back from the console.
The VM proves cage's handling of the key, not that the box's keyboard produces
it, which joins the bring-up checklist.

## Risks / Trade-offs

- **Plasma 6 under the test's software renderer may not come up in the
  resources a VM test can be given.** The kiosk node runs cage and ES-DE under
  llvmpipe with 3 GB (`tests/kiosk.nix:517-518`). → Raise the node's memory
  first. Only if that fails, assert instead that the new session's own process
  tree, read from the session record, contains the desktop's startup process,
  made again after a bounded wait or held over a window so that a desktop which
  starts and dies immediately fails it. The vm-test requirement bounds this.
- **A command with no on-box invoker could be built wrong and nobody would
  notice.** → The VM test is the only thing that exercises it end to end until
  a shell exists, which is why it is a round trip, a refusal matrix and a
  readability assertion, and why it asserts session identity (D11).
- **The box is left at a login prompt if the administrator closes Plasma and
  walks away.** → The same thing three frontend crashes already produce, and
  not sticky: the flag was consumed on the way in (D6), so any restart of the
  display manager or reboot into the normal entry brings the frontend back.
- **A restart stops before it starts, so a display manager that does not come
  back leaves nothing on the TV.** → The command refuses where there is no
  automatic login, and clears the start rate limit so that repeated switches
  are not refused as a crash loop (D3), which the VM test proves with four
  switches, each made from a running frontend session, on a node whose
  start-limit window is widened past the test's run time so that every start
  counts against the burst on any runner (D10). Restarting the pinned SDDM
  during PAM session setup leaves it looping on `HELPER_TTY_ERROR` with no
  session and no greeter until a reboot; the guarantee and the test exclude
  that case, and the README says to wait for the screen between switches. For
  a start that fails anyway the
  guarantee is honesty: the report is that the mode was recorded and the
  restart accepted.
- **The session script, not Plasma, is now what the display manager signals.**
  → The script forwards termination to the desktop (D4), and the VM test
  switches back from a live desktop and asserts that no desktop process or
  workspace unit of `player`'s is left.
- **A keyboard now reaches a login prompt from the frontend.** → The prompt
  admits only an account with a password, `player` has none, and the same key
  returns to the frontend (D12). The VM proves the compositor's side; the
  box's own keyboard is a bring-up item.
- **The clear-only helper is a privileged program the session's account can
  run.** → Its whole body removes one path, it resolves its one tool from a
  closed `PATH` with that tool listed first, which the VM test proves under a
  poisoned `PATH` and by reading the built script, the sudo rule names that
  one command, as root only and with no argument, and its only effect is to
  move the box towards the frontend (D5, D6). It is built, and so shellchecked,
  with the host toplevel (D8).
- **The tmpfiles rule changes a directory another component creates.** → The
  restic helper's `mkdir(..., exist_ok=True)` neither fails on an existing
  directory nor chmods it, so the rule wins and the helper is unaffected. At
  0755 the helper's read-only bind of the backup snapshot under
  `/run/emubox/restic-source` becomes traversable by non-root while a backup
  runs; that exposes nothing new, because files there keep `/data`'s own
  modes.

## Migration Plan

Nothing to migrate: no persisted state, no interface anything else consumes,
and nothing on the box can invoke the command before this change lands. Rolling
back is the generation rollback the boot loader already offers.

## Open Questions

- Whether the mode test's node needs more memory than the kiosk node's 3 GB,
  and by how much. This is measurable only in CI, since no local builder
  exposes KVM, and its answer changes a number in the test rather than the
  specs, the approach or the task breakdown.
