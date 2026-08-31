## MODIFIED Requirements

### Requirement: This change's secrets are declared
The secrets file SHALL hold, at minimum, the family WiFi pre-shared key, the
`admin` password hash, RetroAchievements username and password, the Backblaze B2
application-key identifier and secret, and the restic repository password;
later changes add their own keys to the same file. Install SHALL refuse to
proceed while any secret required by an enabled feature still contains its
committed replacement placeholder.

#### Scenario: Required keys are present
- **WHEN** the secrets file is decrypted by the admin
- **THEN** it contains the WiFi, admin, RetroAchievements, B2, and restic entries required by the enabled configuration

#### Scenario: Backup placeholder remains
- **WHEN** the admin starts installation while a required B2 or restic secret still contains its committed replacement placeholder
- **THEN** installation stops before changing the target and names the unresolved secret

#### Scenario: Backups are disabled
- **WHEN** off-site backups are disabled by declaration
- **THEN** unresolved B2 and restic placeholders do not block installation and no runtime backup service consumes them

