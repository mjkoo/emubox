# The status capability's own module, one directory per concern as every
# other capability in modules/ has. It owns emubox.status.reporters -
# nobody else declares it - renders the registered list to a stable path,
# and puts the aggregator on the system path. A module directory this
# tree's imports list does not name is never evaluated, which would leave
# the option undeclared and every capability that registers a reporter
# against it failing host evaluation on an undefined option; see
# modules/default.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.emubox.status;
  names = map (reporter: reporter.name) cfg.reporters;
  duplicateNames = lib.unique (lib.filter (name: lib.count (other: other == name) names > 1) names);
in
{
  options.emubox.status.reporters = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = ''
              The capability this reporter's section is labelled with. Unique
              among the registered reporters, since each labels one section.
            '';
          };
          command = lib.mkOption {
            type = lib.types.nonEmptyListOf lib.types.str;
            description = ''
              The complete argv the aggregator runs for this reporter, exactly
              as registered: it neither extends nor rewrites the program
              search path it inherited, so the registering module is
              responsible for its own reporter's runtime closure, through
              that reporter's own packaging.
            '';
          };
        };
      }
    );
    default = [ ];
    description = ''
      Reports registered with the operator status command, run in this
      order and each labelled by its own name. A capability that registers
      none contributes no section.
    '';
  };

  config = {
    assertions = [
      {
        assertion = duplicateNames == [ ];
        message = ''
          emubox.status.reporters: each reporter labels its own section of
          emubox-status, so no two may share a name; registered more than
          once: ${lib.concatStringsSep ", " duplicateNames}.
        '';
      }
    ];

    # A stable path, not a store hash an administrator would have to look
    # up first - the same shape already used for emubox/bios-inventory.json:
    # a pkgs.writeText derivation, since a registered reporter's command
    # names its own program by store path, and environment.etc's plain
    # `text` option refuses a string that refers to one.
    environment.etc."emubox/status-reporters".source = pkgs.writeText "emubox-status-reporters.json" (
      builtins.toJSON cfg.reporters
    );

    # emubox-status's own package binary takes the reporter-list path as
    # an argument, which is what lets its unit tests point it at a fixture
    # instead of the real stable path. Exactly one emubox-status may exist
    # on the system path, so this wrapper - not the package's own binary -
    # is what environment.systemPackages carries: it is the only
    # derivation offering bin/emubox-status here, invoking the real binary
    # with the stable path ahead of any argument the caller gives.
    environment.systemPackages = [
      (pkgs.runCommand "emubox-status"
        {
          nativeBuildInputs = [ pkgs.makeWrapper ];
          meta.mainProgram = "emubox-status";
        }
        ''
          makeWrapper ${lib.getExe pkgs.emubox-status} $out/bin/emubox-status \
            --add-flags /etc/emubox/status-reporters
        ''
      )
    ];
  };
}
