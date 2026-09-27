## MODIFIED Requirements

### Requirement: FreeImage is vendored with its vulnerability record intact
FreeImage SHALL be the last derivation nixpkgs carried before removal, with its unbundling of system libraries, its CVE patches and its `knownVulnerabilities` list preserved unchanged, and the flake SHALL permit it explicitly by name with the accepted risk recorded next to that permission.

#### Scenario: Insecure package is permitted deliberately
- **WHEN** the host configuration or the standalone package is evaluated
- **THEN** FreeImage builds only because the flake's nixpkgs configuration lists that exact package name as permitted, and the accepted risk is recorded where the permission is granted: FreeImage decodes externally downloaded ScreenScraper artwork as well as locally supplied images and theme assets, including art fetched through the household entry; its known vulnerabilities remain accepted, and CI build checks do not establish that downloaded images are safe

#### Scenario: Permission is what admits it
- **WHEN** the package name is removed from the flake's permitted list and `nix build .#freeimage` runs
- **THEN** evaluation refuses with the `knownVulnerabilities` message; restoring the entry lets it build again

#### Scenario: Provenance is recorded
- **WHEN** a reader opens the vendored FreeImage or ES-DE package
- **THEN** it names the nixpkgs revision it was taken from and the removal it works around
