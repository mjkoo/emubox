## Purpose

One command an administrator runs to read the health the box's capabilities
report, aggregated from the reports capabilities register with it rather than
from one capability's knowledge of the others.

## ADDED Requirements

### Requirement: One command aggregates the health reports capabilities register

The system SHALL provide a single operator status command that requires no
arguments and reports every report registered with it. Each capability SHALL
contribute its own report by registering it; the command SHALL NOT contain
knowledge of what any capability considers healthy. A capability's own
diagnostic command that is not registered with it, the `emulators`
capability's BIOS check among them, is not part of the aggregate, and its
absence from the output SHALL NOT be treated as a finding.

Each contributed report SHALL be identified in the output by the capability it
came from, so an administrator reading a warning knows which part of the box
produced it. Reports SHALL appear in a stable order, so successive runs are
comparable.

The command's exit status SHALL be the worst status any report returned, so a
single unhealthy capability is visible to an administrator who reads only the
exit code, and SHALL be successful only when every report was successful.

Each report SHALL be registered as a complete command, and the status command
SHALL execute it exactly as registered without extending or otherwise altering
the program search path it passes on. Making the programs a report depends on
reachable SHALL therefore be the responsibility of the capability that
registered it, through that report's own packaging, rather than of the status
command or of whatever environment an administrator happened to run it from.

A report that fails to run SHALL be treated as unhealthy and identified, and
SHALL NOT prevent the remaining reports from running or their findings from
being shown. One broken reporter therefore costs its own section, never the
whole command.

#### Scenario: Every registered report is healthy

- **WHEN** the administrator runs the status command and every contributed
  report succeeds
- **THEN** the output carries a section per contributing capability and the
  command exits successfully

#### Scenario: One capability is unhealthy

- **WHEN** any contributed report returns unhealthy
- **THEN** that section identifies the capability and its finding, and the
  command's exit status is unsuccessful

#### Scenario: A report cannot run

- **WHEN** a contributed report fails to execute
- **THEN** that capability is reported unhealthy and named, every other report
  still runs, and the command's exit status is unsuccessful

#### Scenario: A report shells out to another program

- **WHEN** a contributed report runs a program of its own while the status
  command is executing it
- **THEN** the status command has passed on the program search path unchanged,
  and the report reaches that program through its own packaging rather than
  through anything the status command added

#### Scenario: A capability contributes no report

- **WHEN** a capability registers no report
- **THEN** the command runs normally and its output has no section for that
  capability
