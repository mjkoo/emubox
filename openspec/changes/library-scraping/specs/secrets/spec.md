## MODIFIED Requirements

### Requirement: This change's secrets are declared
The secrets file SHALL hold, at minimum, the family WiFi pre-shared key, the `admin` password hash, RetroAchievements username and password, the Backblaze B2 application-key identifier and secret, the restic repository password, and the scraping service username and password; later changes add their own keys to the same file. Install SHALL refuse to proceed while any secret required by an enabled feature still contains its committed replacement placeholder. The scraping service username and password are always required, so install SHALL refuse to proceed while either of them still holds its committed placeholder, the same as every other required secret. The scraping service credentials SHALL reach only the session account, in a file no other unprivileged account can read, and SHALL NOT appear on any command line.

#### Scenario: Required keys are present
- **WHEN** the secrets file is decrypted by the admin
- **THEN** it contains the WiFi, admin, RetroAchievements, B2, restic and scraping service entries required by the enabled configuration

#### Scenario: Backup placeholder remains
- **WHEN** the admin starts installation while a required B2 or restic secret still contains its committed replacement placeholder
- **THEN** installation stops before changing the target and names the unresolved secret

#### Scenario: Backups are disabled
- **WHEN** off-site backups are disabled by declaration
- **THEN** unresolved B2 and restic placeholders do not block installation, no off-site unit consumes them, and local snapshots and gameplay remain independent

#### Scenario: Scraping placeholder remains
- **WHEN** the admin starts installation while a scraping service secret still contains its committed replacement placeholder
- **THEN** installation stops before changing the target and names the unresolved secret

#### Scenario: Who can read the scraping credentials
- **WHEN** the rendered scraping credentials are inspected on a running box
- **THEN** they are owned by the session account with no access for group or others, and no running process's arguments contain them during a fetch
