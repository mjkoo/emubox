## Purpose

One encrypted file in the repository holds every secret the box needs; the box decrypts it with its own SSH host key and the admin edits it with an age key, so a reinstall is "flake plus one secrets file" and no secret is ever in the Nix store or in git as plaintext.

## ADDED Requirements

### Requirement: One secrets file with two recipients
All of the box's secrets SHALL live in a single encrypted file under `secrets/` in the repository, encrypted to exactly two recipients: the admin's age key and the box's SSH host key converted to age. The repository SHALL declare both recipients so the file can be re-keyed when either changes. A second, test-only file under `secrets/` holds non-secret test values for the VM test; it SHALL be encrypted to the committed test host key only (an SSH key converted to age, as the box's is), and neither that key nor that file SHALL be a recipient of, or consumed by, the box's configuration.

#### Scenario: The committed file is ciphertext only
- **WHEN** the box's secrets file is inspected in git
- **THEN** every value is encrypted and no plaintext value of the box's secrets appears anywhere in the repository history; the committed test key and the test values are not secrets and do not count

#### Scenario: The admin can edit the file
- **WHEN** the admin opens the secrets file with the sops tooling and their age key available
- **THEN** the file decrypts, edits are re-encrypted to both recipients, and the result is a normal git diff of ciphertext

### Requirement: The box decrypts with its persisted host key
At boot the box SHALL decrypt the secrets file using the SSH host key stored under `/persist`, before any service that consumes a secret starts. Decrypted secrets SHALL be placed on a memory-backed filesystem with an owner and mode that limit them to their consumer.

#### Scenario: Secrets are available after boot
- **WHEN** the system reaches multi-user
- **THEN** every declared secret exists as a file with the declared owner and mode and decrypts to the expected value

#### Scenario: Secrets never enter the Nix store
- **WHEN** the system closure is built
- **THEN** no decrypted secret value is present in any store path

#### Scenario: Decryption failure is visible
- **WHEN** the host key under `/persist` does not match a recipient of the secrets file
- **THEN** the boot still reaches a console, and the journal reports which secrets failed to decrypt

### Requirement: The admin password comes from secrets
The `admin` account's password SHALL be the hash held in the secrets file, made available before user accounts are created at boot, so the password is set on a fresh root without being present in the flake.

#### Scenario: Admin can log in with the secret password
- **WHEN** `admin` enters the password whose hash is in the secrets file at a console login
- **THEN** the login succeeds

#### Scenario: No password material in the flake
- **WHEN** the repository and the built closure are searched
- **THEN** neither the box's password nor its hash appears outside the encrypted secrets file and the decrypted runtime path; the committed test values do not count, per the carve-out in "One secrets file with two recipients"

### Requirement: This change's secrets are declared
The secrets file SHALL hold, at minimum, the family WiFi pre-shared key and the `admin` password hash; later changes add their own keys to the same file.

#### Scenario: Required keys are present
- **WHEN** the secrets file is decrypted by the admin
- **THEN** it contains a WiFi PSK entry and an admin password hash entry
