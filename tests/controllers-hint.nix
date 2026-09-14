# Evaluation-only guard for the controllers capability's session hint: the
# recorded ports, joined to their emubox-pN paths in order, and nothing
# declared at all when no port is recorded.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  host = self.nixosConfigurations.emubox;
  # Forced on both sides rather than inherited from the host's own facts: a
  # list option concatenates definitions of equal priority, so a plain
  # assignment would add to any ports the host records rather than replace
  # them, and the side with nothing recorded has to keep meaning that once
  # bring-up records real ports in hosts/emubox/facts.nix.
  withControllerPorts =
    ports:
    (host.extendModules {
      modules = [ { emubox.facts.controllerPorts = lib.mkForce ports; } ];
    }).config;
  withoutPorts = withControllerPorts [ ];
  withPorts = withControllerPorts [
    "fixture-controller-port-1"
    "fixture-controller-port-2"
    "fixture-controller-port-3"
  ];
in
assert lib.assertMsg (!(withoutPorts.environment.sessionVariables ? SDL_JOYSTICK_DEVICE))
  "tests/controllers-hint.nix: with no controller port recorded, SDL_JOYSTICK_DEVICE must not be declared";
assert lib.assertMsg
  (
    withPorts.environment.sessionVariables.SDL_JOYSTICK_DEVICE
    == "/dev/input/emubox-p1:/dev/input/emubox-p2:/dev/input/emubox-p3"
  )
  ''
    tests/controllers-hint.nix: SDL_JOYSTICK_DEVICE must join the emubox-pN
    paths in recorded port order, got ${
      withPorts.environment.sessionVariables.SDL_JOYSTICK_DEVICE or "<unset>"
    }.
  '';
pkgs.runCommand "emubox-controllers-hint" { } ''
  touch "$out"
''
