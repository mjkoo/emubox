# Conventional restic-to-B2 scheduling. The backup helper owns only the
# snapshot transaction; systemd remains the source of truth for activations.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.emubox.backups;
  saves = config.emubox.saves;
  sourceSpec = pkgs.writeText "emubox-restic-source.json" (
    builtins.toJSON {
      roots = saves.backupRoots;
      homeCacheExclusions = saves.homeCacheExclusions;
      retryLock = cfg.lock.retry;
      host = config.networking.hostName;
      tag = "emubox-save";
    }
  );
  maintenanceProgram = pkgs.writeShellApplication {
    name = "emubox-restic-maintenance";
    runtimeInputs = [
      pkgs.restic
      pkgs.emubox-restic-backup
    ];
    text = ''
      set -euo pipefail
      restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
      restic check --read-data-subset=10%
      emubox-restic-backup --source-spec ${sourceSpec} --emit-maintenance-marker
    '';
  };
  resticWrapper = pkgs.writeShellApplication {
    name = "emubox-restic";
    runtimeInputs = [ pkgs.restic ];
    text = ''
      export EMUBOX_RESTIC_ENV=${lib.escapeShellArg config.sops.templates."restic.env".path}
      exec ${pkgs.emubox-restic-backup}/bin/emubox-restic "$@"
    '';
  };
  backupMarkerCommand = "${pkgs.emubox-restic-backup}/bin/emubox-restic-backup --source-spec ${sourceSpec} --emit-backup-marker";
  maintenance = pkgs.writeShellScript "emubox-restic-maintenance" ''
    set -euo pipefail
    exec ${maintenanceProgram}/bin/emubox-restic-maintenance
  '';
  backupCommand = "${pkgs.emubox-restic-backup}/bin/emubox-restic-backup --source-spec ${sourceSpec}";
  validBucket = builtins.match "[a-z0-9][a-z0-9.-]*[a-z0-9]" cfg.b2.bucket != null;
  validEndpoint = builtins.match "https://[a-zA-Z0-9.-]+(:[0-9]+)?" cfg.b2.endpoint != null;
  validPrefix =
    cfg.b2.prefix == ""
    || (
      !(lib.hasPrefix "/" cfg.b2.prefix)
      && !(lib.hasSuffix "/" cfg.b2.prefix)
      && !(lib.hasInfix ".." cfg.b2.prefix)
      && !(lib.hasInfix "//" cfg.b2.prefix)
    );
  backupTimeoutSeconds = 7 * 60 * 60 + 25 * 60;
  preResticSeconds = 10 * 60;
  retryLockSeconds = 3 * 60 * 60 + 15 * 60;
  postLockSeconds = 4 * 60 * 60;
  maintenanceSeconds = 3 * 60 * 60;
  resticRepository =
    if cfg.b2.prefix == "" then
      "s3:${cfg.b2.endpoint}/${cfg.b2.bucket}"
    else
      "s3:${cfg.b2.endpoint}/${cfg.b2.bucket}/${cfg.b2.prefix}";
in
{
  options.emubox.backups = {
    enable = lib.mkEnableOption "off-site restic backups";
    b2 = {
      endpoint = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "https://s3.us-west-004.backblazeb2.com";
        description = "The bucket region's Backblaze B2 S3-compatible HTTPS endpoint.";
      };
      bucket = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Dedicated private Backblaze B2 bucket.";
      };
      prefix = lib.mkOption {
        type = lib.types.str;
        default = "emubox";
        description = "Optional normalized repository prefix within the bucket.";
      };
    };
    repository = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Derived restic S3 repository URL, without credentials.";
    };
    lock = {
      maintenance = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "3h";
      };
      retry = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "3h15m";
      };
    };
    timeout = {
      preRestic = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "10m";
      };
      postLock = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "4h";
      };
      activation = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "7h25m";
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = maintenanceSeconds < retryLockSeconds;
          message = "emubox backups require M < R so bounded maintenance cannot exhaust backup lock retry";
        }
        {
          assertion = backupTimeoutSeconds >= preResticSeconds + retryLockSeconds + postLockSeconds;
          message = "emubox backups require B >= P + R + E to preserve restic's post-lock budget";
        }
      ];
    }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = validBucket;
          message = "emubox.backups.b2.bucket must be a normalized B2 bucket name";
        }
        {
          assertion = validEndpoint;
          message = "emubox.backups.b2.endpoint must be an HTTPS S3-compatible endpoint without a path";
        }
        {
          assertion = validPrefix;
          message = "emubox.backups.b2.prefix must be empty or normalized without slash or traversal";
        }
      ];

      sops.secrets = {
        b2_key_id = { };
        b2_application_key = { };
        restic_password = { };
      };
      sops.templates."restic.env" = {
        content = ''
          RESTIC_REPOSITORY=${resticRepository}
          AWS_ACCESS_KEY_ID=${config.sops.placeholder.b2_key_id}
          AWS_SECRET_ACCESS_KEY=${config.sops.placeholder.b2_application_key}
          RESTIC_PASSWORD_FILE=${config.sops.secrets.restic_password.path}
        '';
        mode = "0400";
      };

      systemd.services.emubox-restic-init = {
        description = "Initialize or open the EmuBox restic repository";
        requires = [
          "data.mount"
          "network-online.target"
        ];
        after = [
          "data.mount"
          "network-online.target"
        ];
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = config.sops.templates."restic.env".path;
          ExecStart = "${pkgs.emubox-restic-backup}/bin/emubox-restic-backup --init";
          User = "root";
          Group = "root";
          NoNewPrivileges = true;
          PrivateTmp = true;
        };
      };

      systemd.services.emubox-restic-backup = {
        description = "Create a snapshot-consistent EmuBox restic backup";
        requires = [
          "emubox-restic-init.service"
          "data-.snapshots.mount"
        ];
        after = [
          "emubox-restic-init.service"
          "data-.snapshots.mount"
        ];
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = config.sops.templates."restic.env".path;
          ExecStart = backupCommand;
          ExecStartPost = backupMarkerCommand;
          ExecStopPost = "${backupCommand} --reconcile";
          TimeoutStartSec = cfg.timeout.activation;
          TimeoutStopSec = "10m";
          User = "root";
          Group = "root";
          Nice = 19;
          IOSchedulingClass = "idle";
          NoNewPrivileges = true;
          PrivateTmp = true;
        };
      };
      systemd.services.emubox-restic-reconcile = {
        description = "Reconcile interrupted EmuBox restic source snapshots";
        wantedBy = [ "multi-user.target" ];
        requires = [ "data-.snapshots.mount" ];
        after = [ "data-.snapshots.mount" ];
        before = [ "emubox-restic-backup.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${backupCommand} --reconcile";
          User = "root";
          Group = "root";
        };
      };
      systemd.timers.emubox-restic-backup = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "10min";
          OnUnitActiveSec = "4h";
          Persistent = false;
          Unit = "emubox-restic-backup.service";
        };
      };

      # Kept here because the timing algebra and native locking are shared
      # with backup. Group 4 adds markers, status and the operator wrapper.
      systemd.services.emubox-restic-maintenance = {
        description = "Maintain EmuBox restic history";
        requires = [ "emubox-restic-init.service" ];
        after = [ "emubox-restic-init.service" ];
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = config.sops.templates."restic.env".path;
          ExecStart = maintenance;
          TimeoutStartSec = cfg.lock.maintenance;
          User = "root";
          Group = "root";
          Nice = 19;
          IOSchedulingClass = "idle";
          NoNewPrivileges = true;
          PrivateTmp = true;
        };
      };
      systemd.timers.emubox-restic-maintenance = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "weekly";
          RandomizedDelaySec = "30min";
          Persistent = false;
          Unit = "emubox-restic-maintenance.service";
        };
      };

      environment.systemPackages = [
        pkgs.restic
        pkgs.emubox-restic-backup
        resticWrapper
      ];
      emubox.backups.repository = resticRepository;
    })
  ];
}
