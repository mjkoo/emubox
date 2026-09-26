# The mode-switch test: a graphical node built from the host's software
# modules. It deliberately has its own node because each switch restarts the
# display manager underneath the active session.
{ self }:
let
  pkgs = self.nixosConfigurations.emubox.pkgs;
  py = builtins.toJSON;
  # The console leg logs in as `admin` with the test password, whose hash the
  # node decrypts from secrets/test.yaml (tests/boot-adaptations.nix).
  values = import ./values.nix;
in
{
  name = "emubox-mode";

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        self.nixosModules.emubox
        ../hosts/emubox/facts.nix
        ./boot-adaptations.nix
      ];

      system.stateVersion = "26.05";

      # The kiosk node's budget, which also carries a fully ready Plasma
      # desktop under llvmpipe: the desktop assertions below are the full
      # ones, not the narrowed process-tree fallback.
      virtualisation.memorySize = 3072;
      virtualisation.qemu.options = [ "-vga none -device virtio-gpu-pci" ];

      # The rapid-switch subtest proves the command clears the display
      # manager's start accounting. The unit's own 30-second window would
      # make that proof depend on how fast the runner starts four sessions;
      # a window longer than the whole test makes every start count, so a
      # command that stopped clearing it fails here on any runner.
      systemd.services.display-manager.startLimitIntervalSec = lib.mkForce 3600;

      # No snapshot timer on this node. It has no btrfs layer, so the hourly
      # timer fails the moment it elapses, and a test that happens to cross
      # the top of an hour then carries a failed unit into
      # `switch-to-configuration test`, which exits non-zero because of it.
      services.btrbk.instances.local.onCalendar = lib.mkForce null;

      emubox.facts.controllerPorts = lib.mkForce [ ];
      emubox.facts.controllerIdentities.sdlGamepadName = lib.mkForce null;
      emubox.facts.controllerIdentities.sdlJoystickGuid = lib.mkForce null;

      systemd.tmpfiles.rules = [
        "d /data/roms/emuboxtest 0755 player player -"
        "f /data/roms/emuboxtest/dummy.test 0644 player player -"
      ];
      emubox.kiosk.customSystems = lib.mkForce [
        ''
          <system>
            <name>emuboxtest</name>
            <fullname>emubox test system</fullname>
            <path>/data/roms/emuboxtest</path>
            <extension>.test</extension>
            <command>/bin/true %ROM%</command>
            <platform>test</platform>
            <theme>emuboxtest</theme>
          </system>
        ''
      ];
    };

  testScript =
    { nodes }:
    let
      modeCommand = "${nodes.machine.system.path}/bin/emubox-mode";
      clearCommand = nodes.machine.emubox.recovery.clearModeCommand;
    in
    ''
      import shlex
      import time

      ${builtins.readFile ./lib/test_helpers.py}

      MODE = ${py modeCommand}
      CLEAR = ${py clearCommand}
      ADMIN_PASSWORD = ${py values.password}

      def session_id():
          return active_session_on_seat(machine.execute)

      def session_property(sid, prop):
          return machine.succeed(
              f"loginctl show-session {shlex.quote(sid)} -p {shlex.quote(prop)} --value"
          ).strip()

      def session_processes(sid):
          leader = session_property(sid, "Leader")
          return machine.succeed(
              "leader=" + shlex.quote(leader) + "; "
              "descendants=\"$leader\"; frontier=\"$leader\"; "
              "while [ -n \"$frontier\" ]; do "
              "next=; for parent in $frontier; do "
              "children=$(pgrep -P \"$parent\" 2>/dev/null || true); "
              "[ -z \"$children\" ] || next=\"$next $children\"; done; "
              "[ -z \"$next\" ] || descendants=\"$descendants $next\"; frontier=$next; done; "
              "ps -ww -o pid=,ppid=,args= -p $(echo $descendants | tr ' ' ',')"
          )

      def wait_new_player_session(old_sid, timeout=120):
          def changed(_):
              sid = session_id()
              return sid is not None and sid != old_sid and session_on_seat(machine.execute, "player")
          retry(changed, timeout_seconds=timeout)
          return session_id()

      def frontend_in_session(sid):
          """Is ES-DE itself among the session's processes?

          Matched on the program each process runs, not on a substring of the
          listing: cage's own arguments name `es-de` before ES-DE has started.
          """
          for line in session_processes(sid).splitlines():
              fields = line.split(None, 2)
              if len(fields) < 3:
                  continue
              if fields[2].split()[0].rsplit("/", 1)[-1] == "es-de":
                  return True
          return False

      def no_player_frontend():
          """No ES-DE owned by `player` anywhere on the node, by name and by
          command line, so that neither spelling can pass vacuously."""
          by_name = machine.execute("pgrep -u player -x es-de")[0]
          by_args = machine.execute(
              "pgrep -u player -f '(^|/|[.])es-de([.]?-wrapped)?([[:space:]]|$)'"
          )[0]
          # 1 is pgrep's "nothing matched"; an error is not an absence.
          return by_name == 1 and by_args == 1

      def desktop_ready_in_session(sid):
          processes = session_processes(sid)
          if "startplasma-wayland" not in processes:
              return False
          if machine.execute("pgrep -u player -f '(^|/|[.])kwin_wayland([.]?-wrapped)?([[:space:]]|$)'")[0] != 0:
              return False
          rc, units = machine.execute(
              "systemctl --user --machine=player@ is-active "
              "plasma-workspace.target plasma-kwin_wayland.service "
              "plasma-plasmashell.service"
          )
          return rc == 0 and units.split() == ["active", "active", "active"]

      def switch(mode, old_sid, restrictive_umask=False):
          command = f"{MODE} {mode}"
          if restrictive_umask:
              command = "sh -c " + shlex.quote("umask 0077; exec " + command)
          output = machine.succeed(command)
          assert f"switching to {mode}" in output, output
          assert "current session is about to end" in output, output
          assert "restart was accepted" in output, output
          sid = wait_new_player_session(old_sid)
          return sid

      def assert_exact_flag(word):
          assert machine.succeed("cat /run/emubox/mode").strip() == word

      def assert_refused(command, fragments, sid, flag="kiosk"):
          rc, output = machine.execute(command + " 2>&1")
          assert rc != 0, output
          for fragment in fragments:
              assert fragment in output, output
          assert_exact_flag(flag)
          assert session_id() == sid
          assert frontend_in_session(sid)

      def invocation_id():
          return machine.succeed(
              "systemctl show display-manager.service -p InvocationID --value"
          ).strip()

      def wait_invocation_change(old):
          retry(lambda _: invocation_id() not in ("", old), timeout_seconds=30)
          return invocation_id()

      def restart_display_manager():
          machine.succeed("systemctl reset-failed display-manager.service")
          machine.succeed("systemctl restart display-manager.service")

      def no_active_plasma_units():
          rc, output = machine.execute(
              "systemctl --user --machine=player@ list-units --state=active "
              "--plain --no-legend 'plasma-*'"
          )
          return rc == 0 and not output.strip()

      def player_user_manager_stopped():
          output = machine.succeed(
              "systemctl show user@$(id -u player).service -p ActiveState -p MainPID --value"
          ).split()
          return "0" in output and any(state in output for state in ("inactive", "failed"))

      start_all()

      with subtest("The normal boot starts a player frontend session"):
          machine.wait_for_unit("display-manager.service")
          retry(lambda _: session_on_seat(machine.execute, "player"), timeout_seconds=120)
          kiosk_sid = session_id()
          retry(lambda _: frontend_in_session(kiosk_sid), timeout_seconds=120)

      with subtest("An administrator at a console switches to a fully ready desktop"):
          # The first switch is made the way an operator makes it: the
          # keyboard's console switch from the running frontend, a console
          # login, the typed command. tty6 is the console logind reserves, so
          # it always carries a login prompt and the display manager is never
          # handed it. The key is sent until it takes, since cage only acts on
          # it once its keyboard is up.
          def active_console():
              rc, active = machine.execute("cat /sys/class/tty/tty0/active")
              return active.strip() if rc == 0 else None

          def on_console(_):
              machine.send_key("ctrl-alt-f6")
              return active_console() == "tty6"

          frontend_pids = machine.succeed("pgrep -u player -x es-de").split()
          assert len(frontend_pids) == 1, frontend_pids
          retry(on_console, timeout_seconds=60)
          machine.wait_until_tty_matches("6", "login: ", timeout=120)

          # The way back for someone who cannot pass that prompt: the switch
          # naming the frontend's own console returns the same session, with
          # the same frontend process still running in it.
          frontend_vt = session_property(kiosk_sid, "VTNr")
          assert frontend_vt in ("1", "2", "3", "4", "5"), frontend_vt
          machine.send_key(f"ctrl-alt-f{frontend_vt}")
          retry(lambda _: active_console() == f"tty{frontend_vt}", timeout_seconds=30)
          retry(
              lambda _: session_id() == kiosk_sid
              and session_on_seat(machine.execute, "player"),
              timeout_seconds=30,
          )
          assert machine.succeed("pgrep -u player -x es-de").split() == frontend_pids
          retry(on_console, timeout_seconds=60)
          machine.send_chars("admin\n")
          machine.wait_until_tty_matches("6", "Password: ", timeout=60)
          machine.send_chars(ADMIN_PASSWORD + "\n")
          machine.wait_until_tty_matches("6", r"admin@.*\$", timeout=120)
          machine.send_chars("sudo emubox-mode desktop\n")
          # The console's login is not part of the session being ended, so the
          # whole report stays readable there.
          machine.wait_until_tty_matches("6", "restart was accepted", timeout=60)

          # The seat's active session being a new one of `player`'s is also
          # the proof that the display manager took the TV back from tty6.
          desktop_sid = wait_new_player_session(kiosk_sid)
          assert desktop_sid != kiosk_sid
          assert active_console() != "tty6"
          # Read only now, with the old session ended and the new one up.
          report = machine.get_tty_text("6")
          for statement in (
              "switching to desktop",
              "current session is about to end",
              "restart was accepted",
          ):
              assert statement in report, report

          # What the key offers the family is a prompt they cannot pass.
          shadow = machine.succeed("getent shadow player").split(":")[1]
          assert shadow[:1] in ("!", "*"), shadow

          # No later subtest runs beside an `admin` session.
          machine.succeed("loginctl terminate-user admin")
          retry(lambda _: desktop_ready_in_session(desktop_sid), timeout_seconds=120)
          time.sleep(5)
          assert desktop_ready_in_session(desktop_sid)
          machine.fail("test -e /run/emubox/mode")
          # The switch replaced the frontend rather than starting beside it.
          retry(lambda _: no_player_frontend(), timeout_seconds=30)

          for _ in range(5):
              machine.fail("pgrep -u player -f '(^|/|[.])baloo_file([.]?-wrapped)?([[:space:]]|$)'")
              time.sleep(1)
          rc, state = machine.execute(
              "systemctl --user --machine=player@ is-enabled kde-baloo.service"
          )
          assert rc != 0 and state.strip() == "masked", (rc, state)

      with subtest("Switching back from a live desktop removes Plasma"):
          kiosk_sid = switch("kiosk", desktop_sid, restrictive_umask=True)
          retry(lambda _: frontend_in_session(kiosk_sid), timeout_seconds=120)
          # Plasma's pinned shell service has a 40-second stop timeout;
          # the compositor stops after it. Allow the ordered teardown to finish.
          retry(
              lambda _: machine.execute(
                  "! pgrep -u player -f 'startplasma-wayland|kwin_wayland'"
              )[0] == 0,
              timeout_seconds=120,
          )
          retry(
              lambda _: no_active_plasma_units(),
              timeout_seconds=30,
          )
          assert machine.succeed(
              "su player -s /bin/sh -c 'cat /run/emubox/mode'"
          ).strip() == "kiosk"

      with subtest("Four further switches are not refused by the display manager start limit"):
          for _ in range(4):
              old_invocation = invocation_id()
              output = machine.succeed(f"{MODE} kiosk")
              assert "restart was accepted" in output, output
              wait_invocation_change(old_invocation)
              # Restarting SDDM during PAM setup can strand its VT owner.
              # Each switch is made from a running session; the node's
              # start-limit window spans the whole test.
              kiosk_sid = wait_new_player_session(kiosk_sid)
              retry(lambda _: frontend_in_session(kiosk_sid), timeout_seconds=120)
          machine.wait_for_unit("display-manager.service")
          result = machine.succeed(
              "systemctl show display-manager.service -p ActiveState -p Result --value"
          ).split()
          assert "active" in result and "start-limit-hit" not in result, result
          assert_exact_flag("kiosk")

      with subtest("The player cannot switch modes"):
          assert_refused(
              f"su player -s /bin/sh -c {shlex.quote(MODE + ' desktop')}",
              ["su - admin", "sudo"],
              kiosk_sid,
          )
          # Nor through the one privilege `player` does hold: the rule admits
          # the helper alone, as root, with no argument. The refusal asserted
          # is sudo's own, so a broken `su` or wrapper cannot stand in for it.
          for command in (f"{CLEAR} x", f"-u admin {CLEAR}", f"{MODE} desktop"):
              rc, output = machine.execute(
                  "su player -s /bin/sh -c "
                  + shlex.quote(f"/run/wrappers/bin/sudo -n {command}")
                  + " 2>&1"
              )
              assert rc != 0, output
              assert "a password is required" in output, output
              assert_exact_flag("kiosk")
              assert session_id() == kiosk_sid

      with subtest("Malformed invocations leave kiosk selected"):
          commands = [MODE, f"{MODE} arcade", f"{MODE} kiosk extra", f"{MODE} desktop extra"]
          for command in commands:
              assert_refused(
                  command,
                  ["kiosk|desktop", "exactly one argument", "next automatic session: kiosk"],
                  kiosk_sid,
              )

      with subtest("The recovery system shape refuses an unread mode"):
          machine.succeed(
              "/run/booted-system/specialisation/recovery/bin/switch-to-configuration test"
          )
          machine.fail("grep -q '^\\[Autologin\\]$' /etc/sddm.conf.d/00-nixos.conf")
          recovery_sid = session_id()
          old_invocation = invocation_id()
          rc, output = machine.execute(f"{MODE} desktop 2>&1")
          assert rc != 0, output
          assert "nothing here would read the mode" in output, output
          assert_exact_flag("kiosk")
          assert invocation_id() == old_invocation
          assert session_id() == recovery_sid
          # A test activation can leave the already running automatic session
          # alive; a real recovery boot has no such session. The refusal,
          # exact flag value and unchanged display manager hold either way.
          machine.succeed("/run/booted-system/bin/switch-to-configuration test")

      with subtest("A killed desktop leaves a greeter and records status 137"):
          old_sid = session_id()
          desktop_sid = switch("desktop", old_sid)
          retry(lambda _: desktop_ready_in_session(desktop_sid), timeout_seconds=120)
          processes = session_processes(desktop_sid)
          startup = [
              line.split(None, 1)[0]
              for line in processes.splitlines()
              if "startplasma-wayland" in line
          ]
          assert startup, processes
          machine.succeed(f"kill -KILL {startup[0]}")
          retry(lambda _: session_on_seat(machine.execute, "sddm"), timeout_seconds=120)
          machine.wait_for_unit("display-manager.service")
          assert no_player_frontend()
          retry(
              lambda _: "desktop exited with status 137" in machine.succeed(
                  "journalctl -t emubox-session --no-pager"
              ),
              timeout_seconds=30,
          )
          machine.succeed("loginctl terminate-user player")
          retry(
              lambda _: player_user_manager_stopped(),
              timeout_seconds=120,
          )

      with subtest("An unknown mode and a restart from the greeter start the frontend"):
          machine.succeed("printf '%s\\n' arcade > /run/emubox/mode && chmod 0644 /run/emubox/mode")
          old_sid = session_id()
          restart_display_manager()
          kiosk_sid = wait_new_player_session(old_sid)
          retry(lambda _: frontend_in_session(kiosk_sid), timeout_seconds=120)
          assert "startplasma-wayland" not in session_processes(kiosk_sid)

      # Last, because the helper legitimately removes the flag and no later
      # subtest may depend on its value.
      with subtest("The clear helper runs nothing from its caller's PATH"):
          machine.succeed(
              "install -d -o player /tmp/poison && "
              "printf '#!/bin/sh\\ntouch /tmp/poison/ran-as-$(id -u)\\n' > /tmp/poison/rm && "
              "chmod 0755 /tmp/poison/rm"
          )
          machine.succeed("test -e /run/emubox/mode")
          machine.succeed(
              "su player -s /bin/sh -c "
              + shlex.quote(f"PATH=/tmp/poison:$PATH /run/wrappers/bin/sudo -n {CLEAR}")
          )
          machine.fail("ls /tmp/poison | grep -q '^ran-as-'")
          machine.fail("test -e /run/emubox/mode")
          # The helper's listed tools come first on its PATH either way, so the
          # poisoned `rm` alone would not notice the caller's PATH being let
          # back in behind them. The built script shows it.
          # 1 is grep's "no match"; an unreadable script is not an absence.
          assert machine.execute(f"grep -F '$PATH' {CLEAR}")[0] == 1
    '';
}
