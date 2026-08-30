## ADDED Requirements

### Requirement: Vendored programs are installed in the booted system
The test SHALL assert, on the booted node, that the frontend and the vendored emulator are installed on the system's program path and that the frontend reports the pinned version, so that a package that fails to build or is dropped from the host closure fails CI rather than being discovered on the box.

#### Scenario: Programs present
- **WHEN** the test node has booted
- **THEN** `es-de` and `duckstation` are executable files on the system's program path

#### Scenario: Frontend version
- **WHEN** the test runs `es-de --version` on the booted node, which has no display
- **THEN** the command succeeds and its output contains `ES-DE 3.4.1`
