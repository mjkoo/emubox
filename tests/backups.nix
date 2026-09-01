# Evaluation-only contract for the conventional restic-to-B2 service graph.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  host = self.nixosConfigurations.emubox;
  disabled = host.config;
  enabled =
    (host.extendModules {
      modules = [
        {
          emubox.backups = {
            enable = true;
            b2 = {
              bucket = "emubox-test-backups";
              prefix = "emubox";
            };
          };
        }
      ];
    }).config;
  backup = enabled.systemd.services.emubox-restic-backup;
  reconcile = enabled.systemd.services.emubox-restic-reconcile;
  backupTimer = enabled.systemd.timers.emubox-restic-backup.timerConfig;
  maintenance = enabled.systemd.services.emubox-restic-maintenance;
  maintenanceTimer = enabled.systemd.timers.emubox-restic-maintenance.timerConfig;
  init = enabled.systemd.services.emubox-restic-init;
in
assert lib.assertMsg (
  !(disabled.systemd.services ? emubox-restic-init)
  && !(disabled.systemd.services ? emubox-restic-backup)
  && !(disabled.systemd.services ? emubox-restic-maintenance)
  && !(disabled.systemd.services ? emubox-restic-reconcile)
  && !(disabled.sops.secrets ? b2_key_id)
) "tests/backups.nix: disabled off-site backups must consume no B2 or restic secrets";
assert lib.assertMsg (
  enabled.emubox.backups.lock.maintenance == "3h"
  && enabled.emubox.backups.lock.retry == "3h15m"
  && enabled.emubox.backups.timeout.preRestic == "10m"
  && enabled.emubox.backups.timeout.postLock == "4h"
  && enabled.emubox.backups.timeout.activation == "7h25m"
) "tests/backups.nix: timeout algebra must retain M=3h, R=3h15m, P=10m, E=4h, B=7h25m";
assert lib.assertMsg (
  backup.serviceConfig.TimeoutStartSec == "7h25m"
  && backup.serviceConfig.TimeoutStopSec == "10m"
  && lib.hasInfix "--reconcile" backup.serviceConfig.ExecStopPost
  && backup.serviceConfig.Nice == 19
  && backup.serviceConfig.IOSchedulingClass == "idle"
) "tests/backups.nix: backup needs a bounded activation and cleanup outside that bound";
assert lib.assertMsg
  (
    backupTimer.OnBootSec == "10min"
    && backupTimer.OnUnitActiveSec == "4h"
    && backupTimer.Persistent == false
    && backupTimer.Unit == "emubox-restic-backup.service"
  )
  "tests/backups.nix: backup timer must not queue missed activations while its oneshot stays active";
assert lib.assertMsg (
  lib.elem "emubox-restic-init.service" backup.requires
  && lib.elem "data-.snapshots.mount" backup.requires
  && lib.elem "data.mount" init.requires
  && lib.elem "network-online.target" init.requires
  && lib.elem "sops-nix.service" init.requires
  && init.serviceConfig.Type == "oneshot"
  && reconcile.wantedBy == [ "multi-user.target" ]
  && lib.elem "data-.snapshots.mount" reconcile.requires
  && lib.elem "emubox-restic-backup.service" reconcile.before
) "tests/backups.nix: backup must retry the fail-closed init gate after data, secrets, and network";
assert lib.assertMsg (
  maintenance.serviceConfig.TimeoutStartSec == "3h"
  && maintenanceTimer.OnCalendar == "weekly"
  && maintenanceTimer.Persistent == false
) "tests/backups.nix: bounded native-lock maintenance must retain and check restic history";
pkgs.runCommand "emubox-backups" { } ''
  touch "$out"
''
