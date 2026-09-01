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
              endpoint = "https://s3.us-west-004.backblazeb2.com";
              bucket = "emubox-test-backups";
              prefix = "emubox";
            };
          };
        }
      ];
    }).config;
  backup = enabled.systemd.services."restic-backups-emubox";
  backupSettings = enabled.services.restic.backups.emubox;
  reconcile = enabled.systemd.services.emubox-restic-reconcile;
  backupTimer = enabled.systemd.timers."restic-backups-emubox".timerConfig;
  maintenance = enabled.systemd.services."restic-backups-emubox-maintenance";
  maintenanceSettings = enabled.services.restic.backups.emubox-maintenance;
  maintenanceTimer = enabled.systemd.timers."restic-backups-emubox-maintenance".timerConfig;
  invalidOption =
    value:
    let
      candidate = host.extendModules {
        modules = [
          {
            emubox.backups = {
              enable = true;
              b2 = {
                endpoint = "https://s3.us-west-004.backblazeb2.com";
                bucket = value;
              };
            };
          }
        ];
      };
    in
    !(builtins.tryEval candidate.config.system.build.toplevel.drvPath).success;
  invalidEndpoint =
    value:
    let
      candidate = host.extendModules {
        modules = [
          {
            emubox.backups = {
              enable = true;
              b2 = {
                endpoint = value;
                bucket = "emubox-test-backups";
              };
            };
          }
        ];
      };
    in
    !(builtins.tryEval candidate.config.system.build.toplevel.drvPath).success;
in
assert lib.assertMsg (
  !(disabled.services.restic.backups ? emubox)
  && !(disabled.services.restic.backups ? emubox-maintenance)
  && !(disabled.systemd.services ? emubox-restic-reconcile)
  && !(disabled.sops.secrets ? b2_key_id)
) "tests/backups.nix: disabled off-site backups must consume no B2 or restic secrets";
assert lib.assertMsg (lib.all invalidOption [
  ""
  "UPPERCASE"
  "has/slash"
  "-leading"
]) "tests/backups.nix: B2 settings must reject malformed bucket names before deployment";
assert lib.assertMsg (lib.all invalidEndpoint [
  ""
  "http://not-tls.example"
  "https://has/path"
]) "tests/backups.nix: B2 S3 endpoint must be a bare HTTPS endpoint";
assert lib.assertMsg (
  enabled.emubox.backups.repository
  == "s3:https://s3.us-west-004.backblazeb2.com/emubox-test-backups/emubox"
) "tests/backups.nix: B2 must use the configured S3-compatible endpoint and repository path";
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
  # `services.restic` runs backupCleanupCommand from postStop, so cleanup is
  # reached on success, failure and timeout alike and is not charged to B.
  && lib.hasInfix "--cleanup" backupSettings.backupCleanupCommand
  && lib.hasInfix "backupCleanupCommand" backup.postStop
  && backup.serviceConfig.Nice == 19
  && backup.serviceConfig.IOSchedulingClass == "idle"
) "tests/backups.nix: backup needs a bounded activation and cleanup outside that bound";
assert lib.assertMsg
  (
    # The restic command line is the module's, not a string this project
    # assembles. These are the arguments the capability actually requires.
    lib.any (lib.hasInfix "--retry-lock=3h15m") backup.serviceConfig.ExecStart
    && lib.any (lib.hasInfix "--tag=emubox-save") backup.serviceConfig.ExecStart
    && lib.any (lib.hasInfix "--exclude-file=/run/emubox/restic-excludes") backup.serviceConfig.ExecStart
    &&
      backupSettings.paths == [
        "/run/emubox/restic-source/saves"
        "/run/emubox/restic-source/es-de"
        "/run/emubox/restic-source/bios"
        "/run/emubox/restic-source/home/player"
      ]
    && backupSettings.createWrapper
  )
  "tests/backups.nix: restic must read the typed roots through the transient read-only source, with native lock retry";
assert lib.assertMsg
  (
    backupTimer.OnBootSec == "10min"
    && backupTimer.OnUnitActiveSec == "4h"
    && backupTimer.Persistent == false
  )
  "tests/backups.nix: backup timer must not queue missed activations while its oneshot stays active";
assert lib.assertMsg
  (
    # The gate is the first step of each job that needs it, so its failure is
    # a failure of that job's own invocation and reaches status. A separate
    # unit would fail the job by `dependency`, leaving the job's invocation,
    # result and journal describing its previous success.
    !(enabled.systemd.services ? emubox-restic-init)
    # The module's own `initialize` runs `init` whenever `cat config` fails at
    # all. This project needs the precise-absence gate instead, so it declines
    # upstream's and supplies its own as each job's prepare step.
    && backupSettings.initialize == false
    && maintenanceSettings.initialize == false
    && lib.hasInfix "--prepare" backupSettings.backupPrepareCommand
    && lib.hasInfix "--init" maintenanceSettings.backupPrepareCommand
    && lib.all (unit: lib.elem "data.mount" unit.requires) [
      backup
      maintenance
    ]
    && lib.all (unit: lib.elem "network-online.target" unit.wants) [
      backup
      maintenance
    ]
    && lib.elem "data-.snapshots.mount" backup.requires
    && enabled.sops.useSystemdActivation == false
    && !(lib.elem "sops-nix.service" backup.requires)
    && backup.serviceConfig.Type == "oneshot"
    && reconcile.wantedBy == [ "multi-user.target" ]
    && lib.elem "data-.snapshots.mount" reconcile.requires
    && lib.elem "restic-backups-emubox.service" reconcile.before
  )
  "tests/backups.nix: each off-site job must run the fail-closed init gate as its own first step, after data and network, with secrets installed during activation";
assert lib.assertMsg (
  enabled.sops.secrets.b2_key_id.mode == "0400"
  && enabled.sops.secrets.b2_key_id.owner == null
  && enabled.sops.secrets.b2_application_key.mode == "0400"
  && enabled.sops.secrets.restic_password.mode == "0400"
  && enabled.sops.templates."restic.env".mode == "0400"
  && lib.hasInfix "AWS_ACCESS_KEY_ID=" enabled.sops.templates."restic.env".content
  && lib.hasInfix "AWS_SECRET_ACCESS_KEY=" enabled.sops.templates."restic.env".content
  && !(lib.hasInfix "B2_ACCOUNT_" enabled.sops.templates."restic.env".content)
  && maintenance.serviceConfig.EnvironmentFile == enabled.sops.templates."restic.env".path
  && backup.serviceConfig.EnvironmentFile == enabled.sops.templates."restic.env".path
) "tests/backups.nix: enabled restic services must consume only root-only rendered sops inputs";
assert lib.assertMsg (
  maintenance.serviceConfig.TimeoutStartSec == "3h"
  && maintenanceTimer.OnCalendar == "weekly"
  && maintenanceTimer.Persistent == false
  &&
    maintenanceSettings.pruneOpts == [
      "--keep-daily 14"
      "--keep-weekly 8"
      "--keep-monthly 12"
    ]
  && maintenanceSettings.checkOpts == [ "--read-data-subset=10%" ]
  # No paths, so the module emits only forget/prune and check here.
  && maintenanceSettings.paths == [ ]
  && lib.any (lib.hasInfix "forget --prune") maintenance.serviceConfig.ExecStart
  && lib.any (lib.hasInfix "check --read-data-subset=10%") maintenance.serviceConfig.ExecStart
) "tests/backups.nix: bounded native-lock maintenance must retain and check restic history";
assert lib.assertMsg
  (
    lib.hasInfix "--emit-maintenance-marker" maintenance.serviceConfig.ExecStartPost
    && lib.hasInfix "--emit-backup-marker" backup.serviceConfig.ExecStartPost
  )
  "tests/backups.nix: maintenance and backup must emit same-invocation recovery markers after conventional restic operations";
assert lib.assertMsg
  (lib.hasInfix "--emit-local-marker" enabled.systemd.services.btrbk-local.serviceConfig.ExecStartPost)
  "tests/backups.nix: local snapshots must emit journal evidence";
pkgs.runCommand "emubox-backups" { } ''
  touch "$out"
''
