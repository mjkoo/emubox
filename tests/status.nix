# Evaluation-only guard for the status capability's own module: the option
# every other capability registers a reporter against, the stable path it
# renders to in declared order, the aggregator command it puts on the
# system path exactly once, the registrations it refuses - and that all of
# it comes from modules/status being named in modules/default.nix's
# imports, not merely assumed.
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
    reporters: (host.extendModules { modules = [ { emubox.status.reporters = reporters; } ]; }).config;

  declarations = host.options.emubox.status.reporters.declarations;

  # Exactly one: the wrapper that passes the stable reporter list. A second
  # package of the same name beside it - the aggregator's own package added
  # to the system path directly, say - would collide on bin/emubox-status.
  aggregatorsOnPath = lib.count (
    p: lib.getName p == "emubox-status"
  ) host.config.environment.systemPackages;

  # Registrations the module has to refuse at evaluation rather than render:
  # each would otherwise surface only as a confusing section, or two
  # sections under one label, when the command runs.
  refused =
    reporters:
    let
      config = withReporters reporters;
      failedAssertions = lib.filter (a: !a.assertion) config.assertions;
      result = builtins.tryEval (
        builtins.deepSeq config.emubox.status.reporters (failedAssertions != [ ])
      );
    in
    !result.success || result.value;
  malformedAccepted = lib.filter (candidate: !(refused candidate.reporters)) [
    {
      label = "an empty command";
      reporters = [
        {
          name = "alpha";
          command = [ ];
        }
      ];
    }
    {
      label = "an empty name";
      reporters = [
        {
          name = "";
          command = [ "/bin/true" ];
        }
      ];
    }
    {
      label = "a name registered twice";
      reporters = [
        {
          name = "alpha";
          command = [ "/bin/true" ];
        }
        {
          name = "alpha";
          command = [ "/bin/false" ];
        }
      ];
    }
  ];
in
assert lib.assertMsg
  (lib.length declarations == 1 && lib.hasSuffix "modules/status" (lib.head declarations))
  ''
    tests/status.nix: emubox.status.reporters must be declared by
    modules/status alone, not by any capability that registers a reporter
    against it - got ${builtins.toJSON declarations}.
  '';
assert lib.assertMsg
  (
    (withReporters fixtureReporters).emubox.status.reporters
    == host.config.emubox.status.reporters ++ fixtureReporters
  )
  ''
    tests/status.nix: registering two more reporters must carry every
    reporter's name and command into the merged list that
    environment.etc."emubox/status-reporters" renders verbatim, in
    declared order, alongside whatever the real host already registers.
  '';
assert lib.assertMsg
  (host.config.environment.etc ? "emubox/status-reporters" && aggregatorsOnPath == 1)
  ''
    tests/status.nix: evaluating the real host configuration must yield
    both the rendered reporter list at its stable path and exactly one
    aggregator on the system path (got ${toString aggregatorsOnPath}), so
    modules/status being named in modules/default.nix's imports is proved
    rather than assumed.
  '';
assert lib.assertMsg (malformedAccepted == [ ]) ''
  tests/status.nix: emubox.status.reporters accepted a registration it must
  refuse: ${lib.concatMapStringsSep ", " (candidate: candidate.label) malformedAccepted}.
'';
pkgs.runCommand "emubox-status-module" { } ''
  touch "$out"
''
