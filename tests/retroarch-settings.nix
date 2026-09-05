# Builder-side proof that the RetroArch package this box actually installs
# delivers its launch-time settings the way `modules/emulators` intends.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  host = self.nixosConfigurations.emubox;

  # The same predicate flake.nix's own `cache-roots` uses to pick "the
  # RetroArch build" out of `environment.systemPackages`: `cores` is a
  # passthru attribute only `wrapRetroArch`/`withCores`
  # (retroarch-bare's own wrapper.nix) ever attaches, so nothing else this
  # box installs can match it by accident. The package is read back out of
  # the host configuration rather than built again here from
  # `modules/emulators`'s own core list and settings: a `wrapRetroArch`
  # call made inside this file would only ever prove that second copy
  # agrees with itself, never that the module's real call site still
  # builds what it is supposed to.
  retroarchPkgs = lib.filter (p: p ? cores) host.config.environment.systemPackages;

  retroarch =
    if lib.length retroarchPkgs == 1 then
      lib.head retroarchPkgs
    else
      throw ''
        tests/retroarch-settings.nix: expected exactly one RetroArch package
        (matching `p ? cores`) in environment.systemPackages, found ${toString (lib.length retroarchPkgs)}: ${
          toString (map (p: p.name) retroarchPkgs)
        }
      '';

  # The design's chosen core set, hand-typed and independent of
  # `modules/emulators`'s own list - the same independent-literal rule
  # tests/kiosk.nix applies to its own pins (`homebrewFixtures`,
  # `biosDependentCores`): comparing against a list read back out of the
  # module under test would only prove the module agrees with itself, so
  # the design's core set is restated here by hand instead, and a core
  # silently dropped or substituted at the call site fails this too.
  # `passthru.cores` is a list of *derivations*; each core's name lives at
  # `.core`, not `.pname` or `.name`
  # (`pkgs/applications/emulators/libretro/mkLibretroCore.nix`'s own
  # `passthru = { inherit core libretroCore; ... }`, confirmed against the
  # pinned nixpkgs source). Both sides are sorted before comparing, since
  # neither list is written in the other's order.
  sortStrings = lib.sort (a: b: a < b);
  expectedCores = sortStrings [
    "bluemsx"
    "dosbox-pure"
    "fbneo"
    "flycast"
    "freeintv"
    "gambatte"
    "genesis-plus-gx"
    "handy"
    "mednafen-ngp"
    "mednafen-pce-fast"
    "mednafen-psx-hw"
    "mednafen-saturn"
    "mednafen-supergrafx"
    "mednafen-vb"
    "mednafen-wswan"
    "melonds"
    "mesen"
    "mgba"
    "mupen64plus-next"
    "picodrive"
    "prosystem"
    "puae"
    "snes9x"
    "stella"
    "vecx"
    "vice-x64"
  ];
  actualCores = sortStrings (map (c: c.core) retroarch.passthru.cores);
in
assert lib.assertMsg (retroarch.passthru.cores != [ ]) ''
  tests/retroarch-settings.nix: the selected RetroArch package's
  `passthru.cores` is empty - either the wrapper dropped it or the host
  installs a coreless build. `cache-roots` filters the unfree core closure
  it pushes to the binary cache on this same attribute, so an empty list
  here would shrink that closure to nothing with no failure anywhere else.
'';
assert lib.assertMsg (actualCores == expectedCores) ''
  tests/retroarch-settings.nix: RetroArch's installed core set does not
  match the pinned expectation.
  expected: ${toString expectedCores}
  actual:   ${toString actualCores}
'';
pkgs.runCommand "emubox-retroarch-settings" { } ''
  binary="${retroarch}/bin/retroarch"

  # The rendered append-config file is not an attribute of the wrapped
  # package - retroarch-bare's own wrapper.nix binds it as a private `let`
  # and exposes only `cores`, `unwrapped` and `withCores` through
  # `passthru`. It exists only as the `--appendconfig=/nix/store/...`
  # argument `makeBinaryWrapper` compiles into this binary, so it has to be
  # recovered from the binary itself.
  #
  # A raw match count is *not* what to assert on: `makeBinaryWrapper`
  # repeats the flag on purpose for any correctly-built wrapper, once as
  # the NUL-terminated argv literal it actually execs and once more inside
  # its own generator docstring (embedded in the binary as a comment
  # restating the `--add-flags '--appendconfig=...'` call that produced
  # it) - so two raw occurrences of the *same* path is the expected,
  # healthy case, and tightening this to a raw count of one would fail
  # every correctly-built wrapper. What must never happen is two
  # *different* paths, so every match is deduplicated before counting.
  # The terminator excludes whitespace and quote characters so the
  # docstring's own closing quote is never captured into the path.
  # Both greps below are guarded: a zero-match `grep` exits non-zero, and
  # under the `set -e`/`pipefail` every check phase inherits that would
  # abort the assignment itself, losing the count message to a bare
  # pipeline failure. A wrapper carrying no `--appendconfig` at all is
  # precisely the regression worth naming out loud, so the guards let
  # control reach the count check with its diagnostic intact.
  distinct_paths="$(
    tr '\0' '\n' < "$binary" \
      | { grep -a -o -- '--appendconfig=/nix/store/[^[:space:]'"'"'"]*' || true; } \
      | sed -e 's/^--appendconfig=//' \
      | sort -u
  )"
  path_count="$(printf '%s\n' "$distinct_paths" | { grep -c . || true; })"
  if [ "$path_count" -ne 1 ]; then
    echo "expected exactly one distinct --appendconfig path in $binary, found $path_count:" >&2
    printf '%s\n' "$distinct_paths" >&2
    exit 1
  fi
  settings="$distinct_paths"

  # Read the recovered path itself, never a re-rendered copy: a second
  # `writeText` built from the same settings attrset would land on the
  # same store path whenever the rendering agrees, which would again only
  # prove the module agrees with itself. Reading the exact path this
  # binary carries is what proves the wrapper the node actually runs
  # passes this file.
  fail() {
    echo "$1" >&2
    echo "--- $settings ---" >&2
    cat "$settings" >&2
    exit 1
  }

  # The eight static settings this box pins ahead of every launch, with
  # the flake's own values pinned literally.
  if ! grep -qxF 'video_fullscreen = "true"' "$settings"; then
    fail "video_fullscreen missing or wrong"
  fi
  if ! grep -qxF 'libretro_directory = "/run/current-system/sw/lib/retroarch/cores"' "$settings"; then
    fail "libretro_directory missing or wrong"
  fi
  if ! grep -qxF 'system_directory = "/data/bios"' "$settings"; then
    fail "system_directory missing or wrong"
  fi
  if ! grep -qxF 'autosave_interval = "30"' "$settings"; then
    fail "autosave_interval missing or wrong"
  fi
  if ! grep -qxF 'menu_show_online_updater = "false"' "$settings"; then
    fail "menu_show_online_updater missing or wrong"
  fi
  if ! grep -qxF 'menu_show_core_updater = "false"' "$settings"; then
    fail "menu_show_core_updater missing or wrong"
  fi
  if ! grep -qxF 'input_menu_toggle_gamepad_combo = "2"' "$settings"; then
    fail "input_menu_toggle_gamepad_combo missing or wrong"
  fi
  if ! grep -qxF 'input_quit_gamepad_combo = "4"' "$settings"; then
    fail "input_quit_gamepad_combo missing or wrong"
  fi

  # The wrapper's own three defaults (retroarch-bare's package.nix), named
  # but not value-pinned: their values are store paths nixpkgs picks, not
  # this flake's concern.
  for key in assets_directory joypad_autoconfig_dir libretro_info_path; do
    if ! grep -q "^$key = " "$settings"; then
      fail "wrapper default $key missing"
    fi
  done

  # No RetroAchievements credential: a leaked cheevos_username or
  # cheevos_token in a file delivered on every launch would put a bearer
  # credential in the world-readable Nix store on every rebuild, not just
  # a config value.
  if grep -q '^cheevos_username = ' "$settings"; then
    fail "cheevos_username present in append-config settings"
  fi
  if grep -q '^cheevos_token = ' "$settings"; then
    fail "cheevos_token present in append-config settings"
  fi

  # None of the six seeded RetroArch keys: a seeded key that slipped into
  # this file would be delivered ahead of retroarch.cfg on every launch and
  # override a player's own tuning, which is the one outcome the seed tier
  # exists to prevent. Presence and value checks on the eight intended
  # keys above cannot detect this on their own.
  for key in menu_driver input_menu_toggle input_save_state input_load_state input_toggle_fast_forward input_screenshot; do
    if grep -q "^$key = " "$settings"; then
      fail "seeded key $key present in append-config settings"
    fi
  done

  # Neither save-directory key: one that slipped into this file would be
  # delivered ahead of the parsed, migration-ordered write the saves
  # route table requires.
  if grep -q '^savefile_directory = ' "$settings"; then
    fail "savefile_directory present in append-config settings"
  fi
  if grep -q '^savestate_directory = ' "$settings"; then
    fail "savestate_directory present in append-config settings"
  fi

  echo "retroarch append-config settings verified at $settings"
  touch "$out"
''
