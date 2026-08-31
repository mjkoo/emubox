## Purpose

Provides bounded local history and encrypted off-site recovery for family data,
with routine integrity checks, restore evidence, and actionable operator status.

## ADDED Requirements

### Requirement: Data has bounded read-only local history
The system SHALL create read-only snapshots of the protected `/data` subvolume
while the box is running and retain 48 hourly and 14 daily recovery points;
the nested reconstructible cache subvolume SHALL not be part of those snapshots.
Snapshot scheduling SHALL be relative to boot and SHALL resume after downtime
without requiring the box to be powered on at a wall-clock time. Local history
SHALL remain on the data disk and SHALL be identified as protection from file
damage, not from disk loss.

#### Scenario: Hourly recovery point is created
- **WHEN** the box remains on through an hourly snapshot interval
- **THEN** a new read-only snapshot containing the current `/data` state exists

#### Scenario: Snapshot retention runs
- **WHEN** local history exceeds either declared retention count
- **THEN** the oldest recovery points beyond that count are removed while 48 hourly and 14 daily points remain available

#### Scenario: Box was powered off at the nominal time
- **WHEN** the box boots after being off through one or more snapshot intervals
- **THEN** snapshot scheduling resumes from boot without launching one job for every missed interval

### Requirement: Off-site backups use a fresh consistent snapshot
Each off-site backup SHALL create a fresh read-only snapshot and read all input
from that one recovery point. Its encrypted restic repository SHALL be in a
private Backblaze B2 bucket reached through the S3-compatible endpoint with an
application key restricted to that bucket. Backup creation SHALL include
`/data/saves`, the complete `player` home except declared reconstructible
caches, ES-DE settings, gamelists and collections, and `/data/bios`; it SHALL
exclude ROMs, scraped media, `/data/cache`, and local snapshot storage.

#### Scenario: Live files change during backup
- **WHEN** a live included file changes after the backup's source snapshot is created
- **THEN** the backup contains the file version from that source snapshot and no mixture of its earlier and later bytes

#### Scenario: Included data is backed up
- **WHEN** the source snapshot contains a file in any included path and backup creation succeeds
- **THEN** that file is present in the resulting restic snapshot

#### Scenario: Reconstructible data is excluded
- **WHEN** the source snapshot contains ROMs, scraped media, cache data, or local snapshots
- **THEN** none of those files is present in the resulting restic snapshot

### Requirement: Backup creation is frequent and independent of maintenance
Backup creation SHALL run 10 minutes after boot and every 4 hours thereafter,
including after an interval missed while powered off, at idle CPU and I/O
priority. Repository retention, prune, and integrity checking SHALL run in a
separate weekly job, so maintenance failure or duration cannot suppress the
creation of a new backup.

#### Scenario: Backup schedule follows use of the box
- **WHEN** the box boots and remains on for 10 minutes
- **THEN** a backup is attempted without waiting for a particular wall-clock time

#### Scenario: Maintenance fails
- **WHEN** weekly retention, prune, or integrity checking fails
- **THEN** the failure is recorded and the next scheduled backup creation remains independently runnable

### Requirement: Off-site history is retained and checked
Weekly maintenance SHALL retain 14 daily, 8 weekly, and 12 monthly restic
snapshots, remove unreferenced repository data, and authenticate repository
metadata plus a rotating 10 percent subset of stored data. The B2 setup
procedure SHALL require a dedicated private bucket, a bucket-scoped read/write
application key capable of normal restic maintenance, and provider-side prior
file-version retention. It SHALL state that credentials on the box do not make
the repository immutable and SHALL include a tested procedure for recovering a
prior B2 file version.

#### Scenario: Weekly maintenance succeeds
- **WHEN** the weekly maintenance job completes
- **THEN** restic reports the declared snapshot retention applied, unreferenced data pruned, and a 10 percent data-subset check successful

#### Scenario: Admin follows the B2 setup procedure
- **WHEN** the admin provisions the off-site repository
- **THEN** it uses a private dedicated bucket, retained prior file versions, and a read/write key restricted to that bucket

#### Scenario: Repository object must be recovered
- **WHEN** the admin performs the documented B2 version-recovery drill
- **THEN** an earlier version of a repository object is recovered and restic can read the repaired repository

### Requirement: A restore drill proves recoverability
At least monthly, and on manual request, the system SHALL restore the newest
restic snapshot into temporary storage and byte-compare its save tree with the
manifest captured from the source snapshot used by that backup. It SHALL record
the compared snapshot, completion time, and success or failure under persistent
operator state, and SHALL remove the temporary restore after recording the
result.

#### Scenario: Restored bytes match
- **WHEN** the monthly drill restores the newest backup and every restored save matches its captured source manifest
- **THEN** a successful drill result identifying that backup is persisted and the temporary restore is removed

#### Scenario: Restored bytes differ
- **WHEN** a restored save is missing, additional, or has different bytes from its captured source manifest
- **THEN** a failed drill result names the difference, remains available after reboot, and the service exits unsuccessfully

### Requirement: Operators have one backup status and recovery interface
The system SHALL provide a status command that reports the newest local
snapshot, last backup result, last maintenance and integrity-check result, last
restore-drill result, and latest unexpected-write result. A never-run, failed,
or stale result SHALL be visibly distinguished from success and name the
relevant service or journal query. A root-only wrapper SHALL expose repository
inspection and restore operations using the same declared repository and secret
inputs as automation.

#### Scenario: All layers are current
- **WHEN** each snapshot, backup, maintenance, drill, and leak check has a recent successful result
- **THEN** the status command reports each layer successful with its time and recovery point

#### Scenario: A layer has no successful result
- **WHEN** a layer has never run, last failed, or is older than its declared stale threshold
- **THEN** status identifies that condition and tells the operator which service or journal to inspect

#### Scenario: Admin inspects the repository
- **WHEN** root invokes the repository wrapper to list snapshots or restore data
- **THEN** it uses the same repository, credentials, password, and exclusions as the automated services without exposing secret values
