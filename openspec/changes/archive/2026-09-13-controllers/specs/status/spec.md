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

### Requirement: Each report's section is bounded, legible and self-explaining

A report's exit status SHALL be read as healthy for 0, as a warning for 1 and
as unhealthy for 2. Any other exit status says nothing the command can
translate, and SHALL be read as the report having failed to run rather than as
a further kind of finding.

A report that has not finished within one minute SHALL be treated as having
failed to run, so one hung report cannot hold the command open and the reports
after it still run.

Each report's section SHALL open with a line at the left margin naming the
capability and the report's state, with everything the report printed indented
beneath it, so nothing a report prints, a blank line or a line shaped like a
section header included, can be read as the start of another section. Wherever
a report's state is anything other than healthy, what it wrote to its error
stream SHALL be shown in its section as well, so an administrator sent to that
section sees why.

If the list of registered reports cannot be read, or is not the shape it must
be, the command SHALL print one line naming that failure and exit with the
status a report that failed to run counts as.

No two reports SHALL be registered under the same name, since each labels its
own section: a configuration that registers a name twice SHALL fail
evaluation, naming the duplicated name, rather than build.

#### Scenario: A report exits outside the status alphabet

- **WHEN** a contributed report exits with a status other than 0, 1 or 2
- **THEN** its section reports it as not having run, and the command's exit
  status is unsuccessful

#### Scenario: A report hangs

- **WHEN** a contributed report has not finished when its time limit expires
- **THEN** its section reports it as not having run, every later report still
  runs, and the command's exit status is unsuccessful

#### Scenario: An unhealthy report explains itself

- **WHEN** a report returns anything but healthy and wrote to its error stream
- **THEN** that error output appears, indented, in the report's own section

#### Scenario: A report prints a line shaped like a header

- **WHEN** a report's own output carries a blank line or a line of the form
  `name: state`
- **THEN** it appears indented within that report's section and no further
  section is shown for it

#### Scenario: The report list cannot be read

- **WHEN** the list of registered reports is missing or malformed
- **THEN** the command prints one line naming the failure and exits with the
  status a report that did not run counts as

#### Scenario: Two reports share a name

- **WHEN** a configuration registers two reports under the same name
- **THEN** evaluating that configuration fails, naming the duplicated name
