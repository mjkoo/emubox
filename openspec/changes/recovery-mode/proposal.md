## Why

The box can already be told to show a desktop and cannot yet be told so by
anyone. `modules/kiosk/default.nix` reads `/run/emubox/mode` on every turn of
the session loop and execs `startplasma-wayland` when it holds `desktop`
(lines 105-109), but nothing in the tree writes that file, and
`modules/recovery/default.nix:26` still carries the TODO for the command that
would. Plasma 6, the `admin` account and the boot-menu recovery specialisation
are all built; the switch between the two modes is the one missing piece.

Routes to a desktop already exist - the greeter the session script gives up to
after three short runs (`README.md:112-116`), and the boot-menu recovery
entry. What the command adds is narrower:

- It saves a reboot and a keypress caught on a box configured to show no boot
  menu; the command switches a running box.
- It removes the trap that logging out of the desktop otherwise leaves. A flag
  that outlived the session it selected would send every later login back into
  the desktop. The flag is one-shot: the session that hands over to the
  desktop clears it first, so any restart of the display manager, or a reboot
  into the entry the box normally boots, returns the frontend.
- It gives the two modes a vocabulary. `kiosk` and `desktop` become words the
  configuration, the specs and an administrator all use, instead of a branch in
  the session script.
- It is the switch a remote shell will call once the remote-administration
  capability lands its link.

## What Changes

- A new `recovery` capability owns the box's two session modes, the flag that
  selects between them and the command that sets it. `emubox-mode kiosk` and
  `emubox-mode desktop` write the mode word to `/run/emubox/mode` and hand a
  display-manager restart to the service manager; autologin returns the
  `player` session, the session script reads the flag, and the right program
  starts. The session reads the flag once, at its start, rather than on every
  turn of its relaunch loop as it does today, so the desktop is no longer
  something the frontend's loop can enter. No boot carries a mode forward,
  because `/run` is memory-backed; on the entry the box normally boots a reboot
  is a return to the frontend with nothing having to be set first.
- The flag is one-shot on the way into the desktop. The session that hands over
  to the desktop first clears the flag, through a privileged helper whose only
  action is removing that file. A flag selecting the frontend is left alone,
  because it selects what its absence selects. The session's account gains the
  ability to clear the flag and never the ability to write one.
- Desktop mode runs Plasma inside the existing `player` session, not as
  `admin` behind a greeter, which is what the code already does. No
  display-manager configuration is mutated at runtime.
- The switch is root-only. `admin` reaches it through the passwordless sudo it
  already has; `player` is not in `wheel`, gets no polkit rule and no sudo rule
  beyond the clear-only helper, so nothing inside the frontend or a game can
  put a desktop on the family's TV.
- The command refuses before it disturbs anything in three cases: it is not
  run as root, its arguments are not exactly one of the two words, or the
  running system logs nobody in automatically - the boot-menu recovery entry
  deliberately does not - so that nothing there would read the mode. A refusal
  leaves the running session and the selection unchanged. Otherwise it prints
  the mode it is switching to and that the current session will end, clears the
  display manager's start rate limit accounting so that switches made in quick
  succession are not counted as crashes and refused, and hands the restart to
  the service manager so the job outlives the caller's session. It reports
  that the mode was recorded and the restart accepted, never that the box is
  in the requested mode.
- Failure diagnostics name the mode inferred from the command's own read of
  the flag and explicitly qualify that view. Unusual permissions can make it
  differ from what `player` reads; the command gains no privileged reporting
  helper to eliminate that limit. The session's only extra privilege remains
  clearing the flag.
- The capability also documents what is already built and owned by no spec:
  the `admin` account and its privileges, the Plasma desktop, and the boot-menu
  recovery specialisation. Their behaviour does not change; writing them down
  gives a later change something to check itself against.
- No ES-DE entry. Upstream ES-DE decides a system's visibility purely by
  whether its ROM directory holds a matching file, and every documented way to
  hide one applies to every UI mode alike, so an entry hidden in kiosk mode is
  not buildable, and one visible to the whole household is not wanted. The
  switch has no on-box invoker until the remote-administration capability
  lands a shell, and that is accepted.
- Quitting Plasma lands at a login prompt rather than the frontend, because
  the display manager's automatic login is not repeated within one daemon's
  life - and it lands there whatever status Plasma exited with: the desktop
  runs as part of the session script rather than replacing it, so the script's
  clean-exit reporting still covers the desktop's ending, with the real status
  written to the journal. The script is then the process the display manager signals to stop a
  session, so it passes that signal on, and a switch back from a running
  desktop leaves nothing of it behind.
- The desktop runs no file indexer. Plasma's indexer cannot be left out of the
  installed set, and it would index `player`'s home and rewrite its index
  there continuously, inside a declared backup root; its user unit is masked.
- A new CI-only VM test proves the round trip: the switch to desktop producing
  a genuinely new session running Plasma with the flag gone and no indexer
  running; the switch back from the live desktop returning the frontend with
  nothing of the desktop left and the flag readable by `player`; switches made
  faster than the display manager's start rate limit all being applied; ending a
  desktop leaving a greeter rather than a stopped display; a flag holding a
  word that is neither mode starting the frontend on a plain restart from that
  greeter; and the three refusals - non-root, malformed, and a node put into
  the recovery entry's own shape - each with the flag asserted by exact value.
- `/run/emubox` gains a tmpfiles rule, the repository's first under `/run`.
  The directory exists today only as a side effect of the restic helper's
  `mkdir(mode=0o700, parents=True)`
  (`pkgs/emubox-restic-backup/emubox_restic_backup.py:400-401`), root-owned and
  unreadable by anything else. The rule declares it at 0755, and the command
  writes the flag world-readable, which together are what the session script's
  read of the flag as `player` needs.
- The `kiosk` capability's guarantees about automatic login at boot are
  narrowed to the normal boot entry, in the power-on requirement and in the
  "a reboot restores automatic login" clause alike. As written they contradict
  the recovery boot entry, which turns automatic login off on purpose.
- No status reporter for mode state: the mode is visible on the TV.

## Capabilities

### New Capabilities

- `recovery`: the box's two session modes and the vocabulary that names them,
  the flag that selects one, how long it lasts and where it lives, the command
  that sets it and who may run it, what a reboot does to it, the administrator
  account and the desktop it reaches, and the boot-menu specialisation that
  reaches a greeter when the normal session cannot be trusted.

### Modified Capabilities

- `vm-test`: gains the requirement that the mode switch is proven in a VM -
  that switching produces a new session rather than reactivating the old one,
  that each mode starts its own program, that a switch back from a live
  desktop leaves nothing of it running, that switches made in quick succession
  are not refused by the start rate limit, that the flag is readable by the
  session's account and does not outlive the session that hands over to the
  desktop, that a word which is neither mode starts the frontend, that ending
  the desktop leaves a greeter on the seat, that no file indexer runs beside
  the desktop, and that each of the three refusals - no administrative
  privilege, malformed arguments, no automatic login on the running system -
  changes nothing. The kiosk-session requirement is not changed: the new
  assertions restart the session out from under the node, which the kiosk
  node's assertions cannot share.
- `kiosk`: the automatic-login guarantees are scoped to the normal boot entry,
  in the power-on requirement and in the frontend-is-kept-up requirement alike.

## Impact

- `modules/recovery/default.nix`: gains `emubox-mode` and the clear-only
  helper as `writeShellApplication`s on `environment.systemPackages`; an
  internal, read-only option under `config.emubox` carrying the helper's store
  path, from which both the sudo rule and the session script's invocation are
  built - the idiom of `emubox.emulators.configDirs`; the passwordless sudo
  rule letting `player` run that helper and nothing else; the tmpfiles rule;
  the mask on the file indexer's user unit; and loses the TODO on line 26. A
  module that declares an option cannot hold bare top-level attributes, so the
  specialisation, the `admin` account and the Plasma enablement move under a
  `config` block, unchanged in effect.
- `modules/kiosk/default.nix`: the `# TODO: desktop mode hands over to Plasma.`
  comment is deleted; the mode read and the desktop branch move above the
  relaunch loop; and the branch clears the flag before handing over, runs the
  desktop as a child rather than replacing the shell, forwards a termination
  signal to it, and ends through the script's exit trap. The frontend path -
  the loop's body, its crash counter and its give-up path - is untouched.
- `flake.nix`: the new VM test joins the `hostOnly` check set. The two new
  shell programs need no check of their own: the host toplevel check already
  builds them.
- `tests/`: a new node built from the same modules and shared boot adaptations
  as the kiosk and controllers nodes. The seat-session helper is lifted out of
  `tests/kiosk.nix` into `tests/lib/test_helpers.py`, the kiosk test switched
  to it, and a sibling added that returns the seat's active session id.
- `justfile`: a recipe for the new VM test, and its evaluation gate gains the
  new check, which is what evaluates it on a machine with no Linux builder.
- `README.md`: `emubox-mode` documented as an operator command, including the
  route to privilege from the desktop; the two passages describing the
  recovery desktop as reachable only after a crash or from the boot menu
  corrected; and the count of VM tests, with the two lists of tests and
  recipes beside it.
- No new external dependency: `systemctl` and Plasma are already in the
  closure.
- Not affected: sshd, the admin's SSH key and the tunnel are the
  remote-administration capability's. Wireless-pad pairing was cut with
  wireless pads.
