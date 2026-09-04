## MODIFIED Requirements

### Requirement: Reinstall and disk swap path
The documented procedure SHALL cover a reinstall on a new or wiped disk: run
the install, then either restore `/data/saves`, `/data/es-de`, `/data/bios`, and
`/data/home/player` from a verified off-site recovery or start with those
protected roots empty. ROMs, scraped media, caches, and local snapshot history
SHALL be reconstructed separately and SHALL NOT be described as recoverable
from the off-site repository. Nothing on the old disk SHALL be required.

#### Scenario: Disk swap
- **WHEN** the disk is replaced and the install is run
- **THEN** the box boots with an empty, correctly laid out `/data` ready for the four protected roots to be restored and reconstructible content to be repopulated separately

#### Scenario: Disk swap uses off-site recovery
- **WHEN** the operator restores the off-site repository after a disk swap
- **THEN** only the four protected roots are expected from restic and ROMs, scraped media, caches, and local snapshot history are reconstructed separately
