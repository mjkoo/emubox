## Purpose

Provides bounded local history and conventional encrypted off-site recovery for
family data, with routine integrity checks and actionable operator status.

## ADDED Requirements

### Requirement: Data has bounded read-only local history
The system SHALL create read-only snapshots of protected `/data` while the box
is running. It SHALL keep every real snapshot from the most recent 48 hours and
one representative from each populated daily bucket in the preceding 14 days;
one snapshot MAY satisfy both buckets. An empty bucket caused by downtime SHALL
NOT be a retention violation. Retained points SHALL remain read-only. The
reconstructible cache subvolume SHALL not be captured. Scheduling SHALL resume
from boot without fabricating points for time powered off.

#### Scenario: Hourly recovery point is created
- **WHEN** the box remains on through an hourly snapshot interval
- **THEN** a new read-only snapshot containing the current `/data` state exists

#### Scenario: Time-bucket retention runs
- **WHEN** retention runs with snapshots inside and outside the declared windows
- **THEN** every point from 48 hours and one representative from each populated daily bucket in the preceding 14 days remain read-only, with overlap permitted

#### Scenario: Box was powered off
- **WHEN** the box boots after missing snapshot intervals
- **THEN** scheduling resumes without creating snapshots for missed intervals

### Requirement: Off-site backups use a fresh consistent snapshot
Each off-site backup SHALL create and read from one fresh read-only snapshot.
The transient snapshot SHALL be removed on success, failure, and timeout. Stale
transient snapshots left by interruption SHALL be reconciled both at boot and
at the start of every backup, before a new source snapshot is created. The
encrypted restic repository SHALL use a private B2
bucket through its S3-compatible endpoint with a bucket-restricted key.

#### Scenario: Live files change during backup
- **WHEN** a live included file changes after the source snapshot is created
- **THEN** the backup contains the version from the immutable source snapshot

#### Scenario: Backup exits unsuccessfully
- **WHEN** backup fails or exceeds its runtime limit
- **THEN** the transient source is removed and the failure is visible

#### Scenario: Power loss leaves a transient artifact
- **WHEN** boot finds a stale transient snapshot from an interrupted run
- **THEN** it removes that artifact before permitting the next backup

#### Scenario: Hard interruption occurs without reboot
- **WHEN** a prior backup is interrupted and a later backup starts on the same boot
- **THEN** start-of-run reconciliation removes the stale artifact before creating a new source snapshot

### Requirement: Backup inclusion is default-on
Backup creation SHALL take exactly four typed roots from the source snapshot:
`/data/saves`; the complete `/data/es-de` directory;
`/data/bios`; and the complete `/data/home/player` tree. ROMs, scraped media,
the data-cache subvolume, and local snapshot storage SHALL be outside those
roots, not exclusions. One finite declarative exclude list SHALL contain only
strict normalized descendants of `player` home that are known reconstructible
caches and SHALL generate restic's only exclusion input. Evaluation SHALL
reject duplicates, `..`, home itself, and lexical equality, ancestor, or
descendant overlap with any save route. Before invoking restic, the backup
service SHALL resolve every declared path against the fresh source snapshot and
fail before generating restic input if an existing symlink ancestor escapes
`player` home or aliases a save route or another exclusion. Any unlisted path
beneath `player` home SHALL be included.

#### Scenario: Unlisted player-home data is backed up
- **WHEN** the source contains a file at an arbitrary unlisted player-home path
- **THEN** the resulting restic snapshot contains that file

#### Scenario: Declared reconstructible data is excluded
- **WHEN** the source contains a file in each explicitly excluded path
- **THEN** the resulting restic snapshot contains none of those files

#### Scenario: Invalid home exclusion is declared
- **WHEN** an exclusion is not a strict normalized lexically non-overlapping descendant of player home
- **THEN** evaluation rejects the declaration before generating restic input

#### Scenario: Runtime path aliases protected data
- **WHEN** a declared exclusion resolves through an existing symlink ancestor outside player home or onto a save route or another exclusion in the fresh source snapshot
- **THEN** backup fails before invoking restic and identifies the invalid declaration

### Requirement: Backup creation and maintenance use native repository locking
Backup creation SHALL run 10 minutes after boot and every 4 hours thereafter at
idle CPU and I/O priority. Weekly retention, prune, and checking SHALL be
staggered from routine backups. Operations SHALL use restic's native locks
without an external repository lock or custom queue. The complete maintenance
sequence, including lock wait, SHALL be bounded to `M = 3h`. Backup SHALL allow
`P = 10m` before restic, use `R = 3h15m` as its retry-lock window, preserve
`E = 4h` after lock acquisition, and use activation bound `B = 7h25m`,
validating `M < R` and `B >= P + R + E`. Final cleanup SHALL remain available
after termination and outside `B`. A timeout caused by another locker SHALL
fail visibly without disabling future timers. Same-service activations SHALL
not overlap, and a timer activation missed while backup remains active SHALL
not be queued. Only local btrfs snapshot creation and removal SHALL use a short
filesystem lock.

#### Scenario: Maintenance holds the repository lock
- **WHEN** a backup starts while bounded weekly maintenance holds its native restic lock
- **THEN** the backup retry window outlasts maintenance and the backup proceeds after the lock is released

#### Scenario: Another lock cause exceeds the retry window
- **WHEN** a backup cannot acquire a compatible restic lock for a reason other than bounded weekly maintenance
- **THEN** that attempt fails visibly and the next scheduled activation remains enabled

#### Scenario: Maintenance fails
- **WHEN** weekly retention, prune, or checking fails
- **THEN** the failure is recorded and future backup scheduling remains enabled

#### Scenario: Backup outlasts its normal cadence
- **WHEN** one backup remains active across a later four-hour timer activation
- **THEN** no second backup overlaps or queues and subsequent timer activations remain enabled

### Requirement: Repository initialization is fail-closed and cloud-isolated
When off-site backup is enabled, an idempotent initialization gate SHALL first
open the configured repository. It SHALL initialize only for restic's precise
nonexistent-repository result and SHALL fail for authentication, network,
corruption, and every other result. Backup and maintenance SHALL each run this
gate as their own first step, so that a gate failure is a failure of that job's
own activation rather than of a dependency, and SHALL retry it on later
independent timer activations. Local snapshots,
gameplay, display, and save preparation SHALL remain independent of network,
backup secrets, initialization, backup, and maintenance. When off-site backup
is disabled, its services SHALL not consume backup secrets.

#### Scenario: Existing repository is reachable
- **WHEN** initialization opens the configured existing repository
- **THEN** it succeeds without modifying or recreating the repository

#### Scenario: Repository is precisely absent
- **WHEN** restic reports the configured repository does not exist
- **THEN** the gate initializes it once and later invocations open it idempotently

#### Scenario: Cloud setup fails
- **WHEN** credentials, network, or repository integrity prevents initialization
- **THEN** the job's own activation fails, status reports that layer unhealthy rather than its previous success, and gameplay and local snapshots remain available

### Requirement: Off-site history is retained and checked
Weekly maintenance SHALL retain 14 daily, 8 weekly, and 12 monthly restic
snapshots, prune unreferenced data, and run `check --read-data-subset=10%`.
The percentage form selects a random subset on each invocation; it does not
promise a rotation or eventual full coverage. Setup SHALL require a dedicated private bucket, a
bucket-scoped read/write key, and at least 30 days of prior file versions. It
SHALL identify prior versions as a last-resort aid and state that host
credentials do not provide immutability.

#### Scenario: Weekly maintenance succeeds
- **WHEN** the weekly maintenance job completes
- **THEN** retention and prune complete and `check --read-data-subset=10%` succeeds

#### Scenario: Admin follows the B2 setup procedure
- **WHEN** the admin provisions the off-site repository
- **THEN** it uses the declared private bucket, prior-version window, and bucket-scoped read/write key

### Requirement: Operators have one backup status and recovery interface
The system SHALL provide status for the newest local snapshot, last off-site
backup, and last weekly maintenance/check. The latest systemd invocation paired
with its parseable same-invocation journal marker SHALL be authoritative,
without a parallel job-state database. The local marker SHALL contain canonical
read-only snapshot path and creation time; the backup marker SHALL contain
snapshot ID, repository ID, host/tag selector, and timestamp; the maintenance
marker SHALL contain repository ID, completion time, and newest matching
protected snapshot ID after operations. Maintenance SHALL fail if no matching
snapshot exists. Missing, malformed, or mismatched markers SHALL be unhealthy.
A local snapshot older than 2 hours, backup older than 8 hours, or
maintenance/check older than 14 days SHALL warn. Never-run and last-failed units
SHALL warn and identify the relevant unit or journal query. Optional live
confirmation MAY add a warning but SHALL NOT erase the last known outcome. A wrapper
SHALL expose inspection and manual `restic restore --verify` using automation's
repository and secret inputs. It SHALL be restricted to root by the permissions
on the credentials it reads. It SHALL NOT claim to restrict which restic
commands root may run: root can read those credentials directly, so a command
allowlist would constrain nobody who can reach the wrapper.

#### Scenario: All layers are current
- **WHEN** all three layers last succeeded within their freshness thresholds
- **THEN** status reports them successful with their time and recovery point

#### Scenario: A layer is unhealthy
- **WHEN** a layer never ran, last failed, or exceeds its freshness threshold
- **THEN** status warns and identifies the relevant unit or journal query

#### Scenario: A later backup fails
- **WHEN** a successful backup is followed by a failed backup
- **THEN** current status reports the later failure and future scheduling remains enabled

#### Scenario: Latest marker cannot prove its invocation
- **WHEN** the latest invocation's marker is missing, malformed, or identifies another invocation
- **THEN** current status reports that layer unhealthy instead of using an older success

#### Scenario: Admin restores data
- **WHEN** root invokes the wrapper to restore with verification
- **THEN** it uses the declared repository and secrets without exposing secret values
