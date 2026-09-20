# The mode-switch test: a graphical node built from the host's software
# modules. It deliberately has its own node because each switch restarts the
# display manager underneath the active session.
{ self }:
let
  pkgs = self.nixosConfigurations.emubox.pkgs;
  py = builtins.toJSON;
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

      # This starts at the kiosk node's budget and requires a fully ready
      # desktop. CI is the first environment with KVM where that budget can
      # be measured; do not narrow the assertions without failure evidence.
      virtualisation.memorySize = 3072;
      virtualisation.qemu.options = [ "-vga none -device virtio-gpu-pci" ];

      emubox.facts.controllerPorts = lib.mkForce [ ];
      emubox.facts.controllerIdentities.sdlGamepadName = lib.mkForce null;
      emubox.facts.controllerIdentities.sdlJoystickGuid = lib.mkForce null;

      systemd.tmpfiles.rules = [
        "d /data/roms/emuboxtest 0755 player player -"
        "f /data/roms/emuboxtest/dummy.test 0644 player player -"
      ];
      emubox.kiosk.customSystems = lib.mkForce ''
        <?xml version="1.0"?>
        <systemList>
          <system>
            <name>emuboxtest</name>
            <fullname>emubox test system</fullname>
            <path>/data/roms/emuboxtest</path>
            <extension>.test</extension>
            <command>/bin/true %ROM%</command>
            <platform>test</platform>
            <theme>emuboxtest</theme>
          </system>
        </systemList>
      '';
    };

  testScript =
    { nodes }:
    let
      modeCommand = "${nodes.machine.system.path}/bin/emubox-mode";
    in
    ''
      import shlex
      import time

      ${builtins.readFile ./lib/test_helpers.py}

      MODE = ${py modeCommand}

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
          return "es-de" in session_processes(sid)

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

      with subtest("Switching to desktop creates a fully ready new session"):
          desktop_sid = switch("desktop", kiosk_sid)
          assert desktop_sid != kiosk_sid
          retry(lambda _: desktop_ready_in_session(desktop_sid), timeout_seconds=120)
          time.sleep(5)
          assert desktop_ready_in_session(desktop_sid)
          machine.fail("test -e /run/emubox/mode")

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

      with subtest("Four rapid switches stay within the display manager start limit"):
          first_sid = kiosk_sid
          started = time.monotonic()
          for _ in range(4):
              old_invocation = invocation_id()
              output = machine.succeed(f"{MODE} kiosk")
              assert "restart was accepted" in output, output
              wait_invocation_change(old_invocation)
          assert time.monotonic() - started < 30
          machine.wait_for_unit("display-manager.service")
          result = machine.succeed(
              "systemctl show display-manager.service -p ActiveState -p Result --value"
          ).split()
          assert "active" in result and "start-limit-hit" not in result, result
          kiosk_sid = wait_new_player_session(first_sid)
          retry(lambda _: frontend_in_session(kiosk_sid), timeout_seconds=120)
          assert_exact_flag("kiosk")

      with subtest("The player cannot switch modes"):
          assert_refused(
              f"su player -s /bin/sh -c {shlex.quote(MODE + ' desktop')}",
              ["su - admin", "sudo"],
              kiosk_sid,
          )

      with subtest("Malformed invocations leave kiosk selected"):
          commands = [MODE, f"{MODE} arcade", f"{MODE} kiosk extra", f"{MODE} desktop extra"]
          for command in commands:
              assert_refused(
                  command,
                  ["kiosk|desktop", "exactly one argument", "the flag selects kiosk as read by this command", "the player session may read it differently"],
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
          machine.fail("pgrep -u player -f '(^|/|[.])es-de([[:space:]]|$)'")
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
    '';
}
