# Evaluation-only guard for the enforce/seed split in emubox.kiosk.ownedFiles:
# a key belongs to exactly one tier, and a RetroAchievements target's own key
# may never double as a seed entry in the file it targets. The module
# assertion this exercises only runs once `system.build.toplevel` is actually
# evaluated, so each candidate below is built through that attribute rather
# than through a shallower one that would pass whether or not the assertion
# exists.
#
# The three candidates are independent - each trips exactly one of the three
# assertions in modules/kiosk/default.nix, not any of the others - because
# `emubox.retroachievements.enable` defaults to true on the host these tests
# extend. `modules/emulators/default.nix`'s `raDisabledFiles` - which is what
# forces a target's `enabled`/`hardcore` keys into that file's own `enforce`
# map - is only folded in while the feature is off, so on this host
# `retroarchTarget.keys.enabled`'s key is absent from `enforce` entirely.
# `targetKeyInSeed` seeds that same key, which therefore only ever collides
# with `raTargetSeedOverlaps`'s own check; on a host with the feature
# disabled by default the identical candidate would also trip the plain
# enforce/seed overlap the other two candidates exercise, since the key would
# already sit in `enforce` too.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  host = self.nixosConfigurations.emubox;
  owned = host.config.emubox.kiosk.ownedFiles;

  retroarchFile = lib.head (lib.filter (f: owned.${f}.format == "retroarch") (lib.attrNames owned));
  retroarchEnforceKey = lib.head (lib.attrNames owned.${retroarchFile}.enforce);

  iniFile = lib.head (
    lib.filter (f: owned.${f}.format == "ini" && owned.${f}.enforce != { }) (lib.attrNames owned)
  );
  iniSection = lib.head (lib.attrNames owned.${iniFile}.enforce);
  iniKey = lib.head (lib.attrNames owned.${iniFile}.enforce.${iniSection});

  retroarchTarget =
    lib.findFirst (t: t.name == "retroarch")
      (throw "tests/owned-key-tiers.nix: no retroarch target in emubox.kiosk.retroachievementsNamespace.targets")
      host.config.emubox.kiosk.retroachievementsNamespace.targets;

  # Every module assertion, this one included, is wired into
  # `system.build.toplevel` itself - forcing anything shallower would
  # evaluate the module tree without ever reaching the check.
  candidateFails =
    modules:
    let
      candidate = host.extendModules { modules = modules; };
    in
    !(builtins.tryEval candidate.config.system.build.toplevel.drvPath).success;

  flatKeyBothTiers = candidateFails [
    { emubox.kiosk.ownedFiles.${retroarchFile}.seed.${retroarchEnforceKey} = "test-overlap"; }
  ];
  sectionedKeyBothTiers = candidateFails [
    { emubox.kiosk.ownedFiles.${iniFile}.seed.${iniSection}.${iniKey} = "test-overlap"; }
  ];
  targetKeyInSeed = candidateFails [
    {
      emubox.kiosk.ownedFiles.${retroarchTarget.keys.enabled.file}.seed.${retroarchTarget.keys.enabled.key} =
        "test-overlap";
    }
  ];
in
assert lib.assertMsg flatKeyBothTiers ''
  tests/owned-key-tiers.nix: a flat key declared under both enforce and seed
  of the same file must fail evaluation.
'';
assert lib.assertMsg sectionedKeyBothTiers ''
  tests/owned-key-tiers.nix: a sectioned section-and-key declared under both
  enforce and seed of the same file must fail evaluation.
'';
assert lib.assertMsg targetKeyInSeed ''
  tests/owned-key-tiers.nix: a RetroAchievements target key listed under its
  own file's seed must fail evaluation.
'';
pkgs.runCommand "emubox-owned-key-tiers" { } ''
  touch "$out"
''
