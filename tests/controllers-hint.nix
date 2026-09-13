# Evaluation-only guard for the controllers capability's session hint: the
# recorded ports, joined to their emubox-pN paths in order, and nothing
# declared at all when no port is recorded.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  host = self.nixosConfigurations.emubox;
  withoutPorts = host.config;
  fixturePorts = [
    "fixture-controller-port-1"
    "fixture-controller-port-2"
    "fixture-controller-port-3"
  ];
  withPorts =
    (host.extendModules {
      modules = [ { emubox.facts.controllerPorts = fixturePorts; } ];
    }).config;
in
assert lib.assertMsg (
  withoutPorts.emubox.facts.controllerPorts == [ ]
  && !(withoutPorts.environment.sessionVariables ? SDL_JOYSTICK_DEVICE)
) "tests/controllers-hint.nix: the host records no controller ports, so SDL_JOYSTICK_DEVICE must not be declared";
assert lib.assertMsg (
  withPorts.environment.sessionVariables.SDL_JOYSTICK_DEVICE
  == "/dev/input/emubox-p1:/dev/input/emubox-p2:/dev/input/emubox-p3"
) ''
  tests/controllers-hint.nix: SDL_JOYSTICK_DEVICE must join the emubox-pN
  paths in recorded port order, got ${withPorts.environment.sessionVariables.SDL_JOYSTICK_DEVICE or "<unset>"}.
'';
pkgs.runCommand "emubox-controllers-hint" { } ''
  touch "$out"
''
