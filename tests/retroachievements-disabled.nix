# retroachievements spec's Disabled scenario ("each supporting emulator's
# configuration has achievements disabled"), asserted at eval time with no
# VM. When `emubox.retroachievements.enable = false`,
# `modules/emulators`'s `raDisabledFiles` - static owned keys folded into
# `emubox.kiosk.ownedFiles` - is the ONLY thing in the repository that turns
# `enabled`/`hardcore` off for these five emulators, with no runtime step
# involved at all. Nothing else touches those two keys: not a unit test
# (owned by `pkgs/emubox-prepare/`'s own suite, which only ever exercises
# `apply_retroachievements` directly, never through this module's rendered
# document), not the kiosk VM test (whose node leaves the option at its true
# default throughout). Flipping the off spelling in that one
# helper would ship a box with achievements enabled while the option says
# disabled, and every other check in the repository would stay green - this
# is the one that would not.
#
# `emubox.kiosk.retroachievementsNamespace` is checked here too, for the
# other half of the same scenario - credential removal, not just the two
# disabled switches. It used to go null when the feature was off, which
# made `emubox-prepare` skip the whole namespace - login *and* credential
# removal - so a box that had been enabled once kept a live account name
# and token on disk after being switched off. It is never null now;
# instead it carries its own `enabled` field, which this file asserts is
# `false` here, the same way the load-bearing off-spelling check above
# catches a regression in `raDisabledFiles`. A regression that flips it
# back to null, or reintroduces a null-when-disabled branch, would
# silently reopen the credential-removal gap with every other check in the
# repository staying green - the eval-only half of that guard; the
# VM-level proof that credential removal actually happens on disk is
# tests/kiosk.nix's own "Switching RetroAchievements off removes
# every credential from disk" subtest, which this cheap, no-VM check cannot
# reach on its own.
#
# No VM and no cross-system build needed: `emubox.kiosk.ownedFiles` is
# plain Nix data once the module tree is evaluated - file paths and
# key/value strings, no derivation ever gets built to answer this question
# - so the assertion below is cheap enough to run as part of every `nix
# flake check`, on any system, the same way `checks.<system>.emubox-prepare`
# already lets the admin's Mac check the Python side natively with no
# x86_64-linux builder involved. `pkgs` here is deliberately the *calling*
# system's own package set (`pkgsFor system` in flake.nix, matching
# `emubox-prepare`'s own per-system checks), used only for `lib` and the
# trivial marker derivation below; the NixOS module tree evaluated for the
# actual assertion is always the x86_64-linux host's, reached through
# `self`, and evaluating its config carries no obligation to build
# anything for that system.
{ self, pkgs }:
let
  inherit (pkgs) lib;

  disabledHost = self.nixosConfigurations.emubox.extendModules {
    modules = [ { emubox.retroachievements.enable = false; } ];
  };
  owned = disabledHost.config.emubox.kiosk.ownedFiles;
  home = disabledHost.config.users.users.player.home;
  raNamespace = disabledHost.config.emubox.kiosk.retroachievementsNamespace;

  # One (file, key path, off-spelling) expectation per supporting
  # emulator's enabled/hardcore pair. File paths, section names, key
  # spellings and off-value spellings are typed here independently of
  # `modules/emulators`'s own `raEmulators`/`raDisabledFiles` tables -
  # copying them here instead of deriving this check from that same code
  # is what makes it a real check rather than the module agreeing with
  # itself, the same reasoning the kiosk VM test's independent DuckStation
  # decrypt already applies to the encrypted case.
  expectations = [
    {
      name = "retroarch";
      file = "${home}/.config/retroarch/retroarch.cfg";
      get = keys: {
        inherit (keys) cheevos_enable cheevos_hardcore_mode_enable;
      };
      want = {
        cheevos_enable = "false";
        cheevos_hardcore_mode_enable = "false";
      };
    }
    {
      name = "dolphin";
      file = "${home}/.config/dolphin-emu/RetroAchievements.ini";
      get = keys: {
        inherit (keys.Achievements) Enabled HardcoreEnabled;
      };
      want = {
        Enabled = "False";
        HardcoreEnabled = "False";
      };
    }
    {
      name = "pcsx2";
      file = "${home}/.config/PCSX2/inis/PCSX2.ini";
      get = keys: {
        inherit (keys.Achievements) Enabled ChallengeMode;
      };
      want = {
        Enabled = "false";
        ChallengeMode = "false";
      };
    }
    {
      name = "ppsspp";
      file = "${home}/.config/ppsspp/PSP/SYSTEM/ppsspp.ini";
      get = keys: {
        inherit (keys.Achievements) AchievementsEnable AchievementsChallengeMode;
      };
      want = {
        AchievementsEnable = "False";
        AchievementsChallengeMode = "False";
      };
    }
    {
      name = "duckstation";
      file = "${home}/.local/share/duckstation/settings.ini";
      get = keys: {
        inherit (keys.Cheevos) Enabled ChallengeMode;
      };
      want = {
        Enabled = "false";
        ChallengeMode = "false";
      };
    }
  ];

  failures = lib.concatMap (
    e:
    let
      got =
        if owned ? ${e.file} then
          e.get owned.${e.file}.keys
        else
          throw "tests/retroachievements-disabled.nix: ${e.name}'s file ${e.file} is not in emubox.kiosk.ownedFiles at all with RetroAchievements disabled";
    in
    lib.optional (
      got != e.want
    ) "${e.name} (${e.file}): got ${builtins.toJSON got}, want ${builtins.toJSON e.want}"
  ) expectations;
in
assert lib.assertMsg (failures == [ ]) ''
  tests/retroachievements-disabled.nix: emubox.retroachievements.enable = false
  did not turn achievements off in every supporting emulator's owned keys:
  ${lib.concatStringsSep "\n" failures}
'';
assert lib.assertMsg (raNamespace != null && raNamespace.enabled == false) ''
  tests/retroachievements-disabled.nix: emubox.retroachievements.enable = false
  did not leave emubox.kiosk.retroachievementsNamespace non-null with its own
  `enabled` field false - got ${builtins.toJSON raNamespace}. A null
  namespace here would make emubox-prepare skip credential removal along
  with the login, leaving a token from an earlier, enabled run on disk.
'';
# A trivial, always-succeeding build: the check is already fully decided by
# the assertion above, which runs during evaluation of this derivation
# (before `runCommand`'s builder is even invoked) and aborts the whole
# evaluation with the message above if it fails. The build itself exists
# only because `nix flake check` requires every `checks.<system>.<name>`
# entry to be a derivation.
pkgs.runCommand "emubox-retroachievements-disabled" { } ''
  touch "$out"
''
