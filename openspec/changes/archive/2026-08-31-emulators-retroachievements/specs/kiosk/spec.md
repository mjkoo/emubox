## MODIFIED Requirements

### Requirement: Custom systems come from the configuration
The configuration SHALL accept a custom systems definition (`emubox.kiosk.customSystems`) that the frontend reads as its custom systems file, complementing the bundled systems. When it is empty, no custom systems file SHALL exist.

#### Scenario: Definition present
- **WHEN** `emubox.kiosk.customSystems` is non-empty and the frontend is about to launch
- **THEN** the frontend's custom systems file under `/data/es-de` holds exactly that definition

#### Scenario: Definition empty
- **WHEN** `emubox.kiosk.customSystems` is empty and a custom systems file exists from an earlier configuration
- **THEN** the file is removed before the frontend launches

#### Scenario: Definition empty and no file present
- **WHEN** `emubox.kiosk.customSystems` is empty and no custom systems file exists
- **THEN** none is created, and the session goes on to launch the frontend rather than treating the absent file as a failure
