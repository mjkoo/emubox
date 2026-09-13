## MODIFIED Requirements

### Requirement: Operators have one backup status and recovery interface
The system SHALL provide status for the newest local snapshot on every box,
and, where off-site backup is enabled, for the last off-site backup and the
last weekly maintenance/check. Local snapshots are taken wherever protected
data lives, so the local layer SHALL be reported unconditionally; the two
off-site layers exist only where off-site backup is enabled, and on a box
where it is not, their absence SHALL NOT be reported at all rather than
reported as unhealthy. The latest systemd invocation paired
with its parseable same-invocation journal marker SHALL be authoritative,
without a parallel job-state database. The local marker SHALL contain canonical
read-only snapshot path and creation time; the backup marker SHALL contain
snapshot ID, repository ID, host/tag selector, and timestamp; the maintenance
marker SHALL contain repository ID, completion time, and newest matching
protected snapshot ID after operations. Maintenance SHALL fail if no matching
snapshot exists. Missing, malformed, or mismatched markers SHALL be unhealthy.
A local snapshot older than 2 hours, backup older than 8 hours, or
maintenance/check older than 14 days SHALL warn. Never-run and last-failed units
SHALL warn and identify the relevant unit or journal query, for the layers
being reported. Optional live confirmation MAY add a warning but SHALL NOT erase the last known outcome. A wrapper
SHALL expose inspection and manual `restic restore --verify` using automation's
repository and secret inputs. It SHALL be restricted to root by the permissions
on the credentials it reads. It SHALL NOT claim to restrict which restic
commands root may run: root can read those credentials directly, so a command
allowlist would constrain nobody who can reach the wrapper.

#### Scenario: All layers are current
- **WHEN** every reported layer last succeeded within its freshness threshold
- **THEN** status reports them successful with their time and recovery point

#### Scenario: A layer is unhealthy
- **WHEN** a reported layer never ran, last failed, or exceeds its freshness threshold
- **THEN** status warns and identifies the relevant unit or journal query

#### Scenario: A later backup fails
- **WHEN** a successful backup is followed by a failed backup
- **THEN** current status reports the later failure and future scheduling remains enabled

#### Scenario: Latest marker cannot prove its invocation
- **WHEN** the latest invocation's marker is missing, malformed, or identifies another invocation
- **THEN** current status reports that layer unhealthy instead of using an older success

#### Scenario: Off-site backup is not enabled
- **WHEN** status runs on a box whose off-site backup is disabled and whose local snapshots are current
- **THEN** it reports the local snapshot layer as successful, reports neither off-site layer at all, and does not warn about them

#### Scenario: Admin restores data
- **WHEN** root invokes the wrapper to restore with verification
- **THEN** it uses the declared repository and secrets without exposing secret values
