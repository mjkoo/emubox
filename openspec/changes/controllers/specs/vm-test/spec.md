## ADDED Requirements

### Requirement: Controller ownership is proven in the VM

The kiosk VM test, or a sibling built from the same modules, SHALL prove the
controller seams this project builds: that a recorded port becomes its player's
stable name, that the session declares the resulting enumeration order, that
the owned input keys reach each emulator's configuration in the tier they are
declared in, and that the operator status command aggregates the reports
contributed to it.

The port fixture SHALL supply the device path the rule matches and the
controller identification the rule requires, so the assertion covers the
mapping from a recorded port to its player name. It SHALL NOT depend on the
virtual machine's own bus topology, and the test SHALL NOT re-prove the
operating system's derivation of device paths, which is not this project's
code and whose values on the real box are a bring-up fact no virtual machine
can supply.

#### Scenario: Recorded ports become player names

- **WHEN** the fixture presents a controller on each recorded port
- **THEN** each port's player name resolves to that controller, in recorded
  order

#### Scenario: The session declares the enumeration order

- **WHEN** ports are recorded
- **THEN** the session environment carries the enumeration order listing those
  ports by position

#### Scenario: No ports are recorded

- **WHEN** the node records no controller ports, as the real box does before
  bring-up
- **THEN** the session environment declares no enumeration order at all

#### Scenario: Owned input keys reach each emulator

- **WHEN** the configuration editor has run over emulator configuration files
  that did not yet assign any owned key, as on a freshly built node
- **THEN** each standalone emulator's configuration carries its enforced
  route back to the frontend where the pinned emulator offers one - every
  standalone but Azahar - and any pad-identity fact it needs is recorded,
  carries the owned setting that suppresses its exit confirmation where one is
  declared, carries its gameplay bindings where they are declared, seeded, or
  enforced where they depend on a pad-identity fact, carries the settings that
  connect each bound player's controller slot where those are declared, and
  carries every other setting a binding depends on to reach a pad, where any
  pad-identity fact it needs is recorded; the slot settings and those other
  settings each sit in the tier of the binding they serve, which puts them in
  the enforced tier with the route back and with a binding that depends on a
  pad-identity fact, except that a flag deciding whether the stored binding
  beside it is read at all is enforced whatever that tier

#### Scenario: An enforced route back is restored

- **WHEN** the configuration of a standalone emulator other than Azahar,
  carrying its enforced route back, is altered to unbind that route back and
  the configuration editor runs again, as it does before the frontend starts
- **THEN** the enforced binding is restored

#### Scenario: A seeded gameplay binding is kept

- **WHEN** an emulator's configuration carries a player's altered seeded
  gameplay binding, one that depends on no pad-identity fact, and the editor
  runs again
- **THEN** the player's binding is unchanged

#### Scenario: Status aggregates its reports

- **WHEN** the operator status command runs on a node with more than one
  registered report
- **THEN** its output carries a section from each capability that registered a
  report on that node, the controllers section among them, and no section for
  a capability that registered none

#### Scenario: The backups report on a box with off-site backup disabled

- **WHEN** the operator status command runs on a node whose off-site backup is
  disabled
- **THEN** its backups section reports the local snapshot layer and reports
  neither off-site layer

#### Scenario: A failing report does not hide the others

- **WHEN** one contributed report fails to run
- **THEN** every other section is still produced and the command's exit status
  is unsuccessful
