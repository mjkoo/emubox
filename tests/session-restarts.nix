# Run the production session control flow with deterministic process boundaries.
{ self, pkgs }:
let
  host = self.nixosConfigurations.emubox.extendModules {
    modules = [
      ({ lib, ... }: {
        emubox.kiosk.preFrontendStep = lib.mkForce ''
          echo step >> "$TEST_ROOT/events"
        '';
      })
    ];
  };
  sessions = builtins.filter (
    p: (p.providedSessions or [ ]) == [ "emubox" ]
  ) host.config.services.displayManager.sessionPackages;
  session = builtins.head sessions;
in
pkgs.runCommand "emubox-session-restarts"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.bash
      pkgs.coreutils
      pkgs.gnused
    ];
  }
  ''
    script=$(sed -n 's/^Exec=//p' ${session}/share/wayland-sessions/emubox.desktop)
    python3 ${./test-session-restarts.py} "$script" ${host.config.emubox.kiosk.customSystemsFile} ${pkgs.foot}/bin/foot
    touch "$out"
  ''
