# Evaluation-only guard for the status capability's own module: the option
# every other capability registers a reporter against, the stable path it
# renders to in declared order, and the aggregator command it puts on the
# system path - and that all three come from modules/status being named in
# modules/default.nix's imports, not merely assumed.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  host = self.nixosConfigurations.emubox;

  fixtureReporters = [
    {
      name = "alpha";
      command = [
        "/bin/true"
        "--flag"
      ];
    }
    {
      name = "beta";
      command = [ "/bin/false" ];
    }
  ];

  withReporters =
    (host.extendModules { modules = [ { emubox.status.reporters = fixtureReporters; } ]; }).config;

  declarations = host.options.emubox.status.reporters.declarations;

  systemPackageNames = map lib.getName host.config.environment.systemPackages;
in
assert lib.assertMsg
  (lib.length declarations == 1 && lib.hasSuffix "modules/status" (lib.head declarations))
  ''
    tests/status.nix: emubox.status.reporters must be declared by
    modules/status alone, not by any capability that registers a reporter
    against it - got ${builtins.toJSON declarations}.
  '';
assert lib.assertMsg
  (builtins.fromJSON withReporters.environment.etc."emubox/status-reporters".text == fixtureReporters)
  ''
    tests/status.nix: the rendered reporter list must carry every
    registered reporter's name and command, in declared order.
  '';
assert lib.assertMsg
  (
    host.config.environment.etc ? "emubox/status-reporters"
    && lib.elem "emubox-status" systemPackageNames
  )
  ''
    tests/status.nix: evaluating the real host configuration must yield
    both the rendered reporter list at its stable path and the aggregator
    on the system path, so modules/status being named in
    modules/default.nix's imports is proved rather than assumed.
  '';
pkgs.runCommand "emubox-status-module" { } ''
  touch "$out"
''
