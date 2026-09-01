# Conventional restic-to-B2 scheduling on `services.restic`, which owns the
# units, timers, secrets plumbing and the restic command line. What is left
# here is what upstream has no opinion about: the read-only btrfs snapshot each
# backup runs against, a stricter initialization gate, and the journal markers
# `emubox-status` reads.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.emubox.backups;
  saves = config.emubox.saves;
  helper = "${pkgs.emubox-restic-backup}/bin/emubox-restic-backup";

  # The transient read-only copy of `/data` that restic actually reads.
  mountpoint = "/run/emubox/restic-source";
  snapshotDir = "/data/.snapshots/restic";
  exclusionFile = "/run/emubox/restic-excludes";
  inSource = path: "${mountpoint}/${lib.removePrefix "/data/" path}";

  backupName = "emubox";
  maintenanceName = "emubox-maintenance";
  backupUnit = "restic-backups-${backupName}.service";

  sourceSpec = pkgs.writeText "emubox-restic-source.json" (
    builtins.toJSON {
      roots = saves.backupRoots;
      homeCacheExclusions = saves.homeCacheExclusions;
      retryLock = cfg.lock.retry;
      host = config.networking.hostName;
      tag = "emubox-save";
    }
  );
  helperPaths = "--snapshot-dir ${snapshotDir} --mountpoint ${mountpoint} --exclusion-file ${exclusionFile}";
  initCommand = "${helper} --init";
  reconcileCommand = "${helper} --reconcile ${helperPaths}";
  backupMarkerCommand = "${helper} --source-spec ${sourceSpec} --emit-backup-marker";
  maintenanceMarkerCommand = "${helper} --source-spec ${sourceSpec} --emit-maintenance-marker";

  # `services.restic` runs backupPrepareCommand at the head of its preStart,
  # before the includes file, so the source exists by the time restic runs. The
  # gate is first inside `--prepare`, so an unreachable repository costs no
  # snapshot. `emubox-status` reads both unit names; the helper carries the
  # same pair as its argparse defaults, and the VM test runs it against these
  # units, so a rename that misses one side fails there rather than silently
  # reporting a unit that does not exist.
  prepareCommand = "${helper} --prepare --source-spec ${sourceSpec} --data /data ${helperPaths}";
  cleanupCommand = "${helper} --cleanup ${helperPaths}";

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
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.restic;
      defaultText = lib.literalExpression "pkgs.restic";
      description = "Restic package used by backup services and the operator wrapper.";
    };
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
      # Only the bucket credentials need rendering. The repository URL is not a
      # secret and the restic password is already a secret file, so both go to
      # `services.restic` as options rather than through a template.
      sops.templates."restic.env" = {
        content = ''
          AWS_ACCESS_KEY_ID=${config.sops.placeholder.b2_key_id}
          AWS_SECRET_ACCESS_KEY=${config.sops.placeholder.b2_application_key}
        '';
        mode = "0400";
      };

      # Shared by both jobs: the same repository, credentials and restic
      # binary, and the hardening the units had before this moved onto
      # `services.restic`.
      services.restic.backups =
        let
          common = {
            inherit (cfg) package;
            repository = resticRepository;
            passwordFile = config.sops.secrets.restic_password.path;
            environmentFile = config.sops.templates."restic.env".path;
            user = "root";
            # `initialize` here would run `init` whenever `cat config` fails at
            # all, including on an authentication or network error. The gate in
            # `--prepare` and `--init` initializes only on restic's precise
            # nonexistent-repository result and fails closed otherwise, which
            # is what the backups capability requires.
            initialize = false;
          };
        in
        {
          ${backupName} = common // {
            paths = map inSource saves.backupRoots;
            # The exclusion list is resolved against the live snapshot rather
            # than declared statically, because a declared cache path that
            # resolves through a symlink onto a save route has to be rejected
            # before restic reads it. `--prepare` writes this file.
            extraBackupArgs = [
              "--retry-lock=${cfg.lock.retry}"
              "--host=${config.networking.hostName}"
              "--tag=emubox-save"
              "--exclude-file=${exclusionFile}"
            ];
            backupPrepareCommand = prepareCommand;
            backupCleanupCommand = cleanupCommand;
            timerConfig = {
              OnBootSec = "10min";
              OnUnitActiveSec = "4h";
              Persistent = false;
            };
            createWrapper = true;
          };

          # No paths, so the module emits only forget/prune and check. Weekly,
          # staggered from the four-hour backups, under restic's own exclusive
          # locks.
          ${maintenanceName} = common // {
            paths = [ ];
            pruneOpts = [
              "--keep-daily 14"
              "--keep-weekly 8"
              "--keep-monthly 12"
            ];
            checkOpts = [ "--read-data-subset=10%" ];
            backupPrepareCommand = initCommand;
            timerConfig = {
              OnCalendar = "weekly";
              RandomizedDelaySec = "30min";
              Persistent = false;
            };
            createWrapper = false;
          };
        };

      systemd.services = {
        "restic-backups-${backupName}" = {
          # `Type=oneshot` with no `Restart=`, so systemd's start rate limiter
          # cannot protect against a restart loop. All it can do is refuse a
          # legitimate activation with `start-limit-hit`, which an operator
          # running the job by hand a few times would hit.
          startLimitIntervalSec = 0;
          requires = [
            "data.mount"
            "data-.snapshots.mount"
          ];
          after = [
            "data.mount"
            "data-.snapshots.mount"
          ];
          environment.EMUBOX_RESTIC = lib.getExe cfg.package;
          serviceConfig = {
            ExecStartPost = backupMarkerCommand;
            TimeoutStartSec = cfg.timeout.activation;
            TimeoutStopSec = "10m";
            Nice = 19;
            IOSchedulingClass = "idle";
            NoNewPrivileges = true;
            # Load-bearing, and the module's default is the opposite. Any
            # namespacing option makes systemd build a fresh mount namespace
            # for *each* Exec* process, so the read-only bind that
            # `backupPrepareCommand` creates would not exist by the time restic
            # runs, and `backupCleanupCommand` could not unmount it. The source
            # therefore lives in the host namespace, root-only at mode 0700,
            # and the cleanup path is what removes it. `mkForce` because the
            # module sets the opposite, and this is a correctness requirement
            # of the prepare/backup/cleanup split rather than a preference.
            PrivateTmp = lib.mkForce false;
          };
        };

        "restic-backups-${maintenanceName}" = {
          startLimitIntervalSec = 0;
          requires = [ "data.mount" ];
          after = [ "data.mount" ];
          environment.EMUBOX_RESTIC = lib.getExe cfg.package;
          serviceConfig = {
            ExecStartPost = maintenanceMarkerCommand;
            TimeoutStartSec = cfg.lock.maintenance;
            Nice = 19;
            IOSchedulingClass = "idle";
            NoNewPrivileges = true;
          };
        };

        # Not something `services.restic` has an opinion about: a backup killed
        # by power loss leaves a read-only subvolume behind, and nothing else
        # would ever remove it.
        emubox-restic-reconcile = {
          description = "Reconcile interrupted EmuBox restic source snapshots";
          startLimitIntervalSec = 0;
          wantedBy = [ "multi-user.target" ];
          requires = [ "data-.snapshots.mount" ];
          after = [ "data-.snapshots.mount" ];
          before = [ backupUnit ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = reconcileCommand;
            User = "root";
            Group = "root";
          };
        };
      };

      # `createWrapper` on the backup above installs `restic-emubox`, which is
      # restic with this repository's environment already set. It is readable
      # only by root because the credentials file it sources is, which is the
      # real boundary; the command allowlist this replaced enforced nothing
      # against the one account that could reach it.
      environment.systemPackages = [
        cfg.package
        pkgs.emubox-restic-backup
      ];
      emubox.backups.repository = resticRepository;
    })
  ];
}
