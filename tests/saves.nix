# Evaluation-only guard for the closed save table and backup path model.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  host = self.nixosConfigurations.emubox;
  saves = host.config.emubox.saves;
  home = host.config.users.users.player.home;
  owned = host.config.emubox.kiosk.ownedFiles;
  routes = saves.saveRoutes;
  names = map (r: r.store) routes;
  expectedNames = [
    "RetroArch saves"
    "RetroArch states"
    "Dolphin memory cards"
    "Dolphin Wii data"
    "Dolphin states"
    "DuckStation memory cards"
    "DuckStation states"
    "PCSX2 memory cards"
    "PCSX2 states"
    "PPSSPP savedata"
    "PPSSPP states and metadata"
    "Azahar NAND"
    "Azahar SD card"
    "ScummVM saves"
  ];
  bindRoutes = lib.filter (r: r.mechanism == "bind") routes;
  expectedRoots = [
    "/data/saves"
    "/data/es-de"
    "/data/bios"
    home
  ];
  # Copied from the capability spec rather than derived from the module: this
  # catches an emulator route changing while its implementation remains
  # internally self-consistent.
  expectedRouteFields = [
    [
      ".config/retroarch/saves"
      "/data/saves/retroarch/saves"
      "setting"
      "savefile_directory"
    ]
    [
      ".config/retroarch/states"
      "/data/saves/retroarch/states"
      "setting"
      "savestate_directory"
    ]
    [
      ".local/share/dolphin-emu/GC"
      "/data/saves/dolphin/GC"
      "bind"
      null
    ]
    [
      ".local/share/dolphin-emu/Wii"
      "/data/saves/dolphin/Wii"
      "bind"
      null
    ]
    [
      ".local/share/dolphin-emu/StateSaves"
      "/data/saves/dolphin/StateSaves"
      "bind"
      null
    ]
    [
      ".local/share/duckstation/memcards"
      "/data/saves/duckstation/memcards"
      "bind"
      null
    ]
    [
      ".local/share/duckstation/savestates"
      "/data/saves/duckstation/savestates"
      "bind"
      null
    ]
    [
      ".config/PCSX2/memcards"
      "/data/saves/pcsx2/memcards"
      "bind"
      null
    ]
    [
      ".config/PCSX2/sstates"
      "/data/saves/pcsx2/sstates"
      "bind"
      null
    ]
    [
      ".config/ppsspp/PSP/SAVEDATA"
      "/data/saves/ppsspp/SAVEDATA"
      "bind"
      null
    ]
    [
      ".config/ppsspp/PSP/PPSSPP_STATE"
      "/data/saves/ppsspp/PPSSPP_STATE"
      "bind"
      null
    ]
    [
      ".local/share/azahar-emu/nand"
      "/data/saves/azahar/nand"
      "bind"
      null
    ]
    [
      ".local/share/azahar-emu/sdmc"
      "/data/saves/azahar/sdmc"
      "bind"
      null
    ]
    [
      ".local/share/scummvm/saves"
      "/data/saves/scummvm/saves"
      "setting"
      "scummvm.savepath"
    ]
  ];
  actualRouteFields = map (route: [
    (lib.removePrefix "${home}/" (builtins.head route.legacyPaths))
    route.destination
    route.mechanism
    route.setting
  ]) routes;
  expectedEvidence = [
    "parsed owned-key assertion and deterministic core save write"
    "parsed owned-key assertion and deterministic state write"
    "mount-source assertion and deterministic card fixture"
    "mount-source assertion and deterministic Wii fixture or fixture exemption naming the unavailable title"
    "mount-source assertion and deterministic state write"
    "mount-source assertion and deterministic card fixture"
    "mount-source assertion and deterministic state write"
    "mount-source assertion and deterministic card fixture"
    "mount-source assertion and deterministic state write"
    "mount-source assertion and deterministic savedata fixture"
    "mount-source assertion and deterministic state plus metadata fixture"
    "mount-source assertion and deterministic NAND fixture or fixture exemption naming the unavailable title"
    "mount-source assertion and deterministic SD fixture or fixture exemption naming the unavailable title"
    "parsed owned-key assertion and deterministic save fixture or fixture exemption naming the unavailable game engine"
  ];
  expectedPreparation =
    route:
    "create destination, migrate legacy tree, then ${
      if route.mechanism == "bind" then "mount" else "write key"
    }";
  invalidExclusion =
    value:
    let
      candidate = host.extendModules {
        modules = [ { emubox.saves.homeCacheExclusions = lib.mkForce value; } ];
      };
    in
    !(builtins.tryEval candidate.config.system.build.toplevel.drvPath).success;
  cloudEnabled = host.extendModules {
    modules = [
      {
        emubox.backups = {
          enable = true;
          b2 = {
            endpoint = "https://s3.us-west-004.backblazeb2.com";
            bucket = "emubox-test-backups";
          };
        };
      }
    ];
  };
  rollback = cloudEnabled.extendModules {
    modules = [ { emubox.backups.enable = lib.mkForce false; } ];
  };
  cloudUnits = [
    "emubox-restic-init"
    "emubox-restic-backup"
    "emubox-restic-maintenance"
  ];
in
assert lib.assertMsg (saves.backupRoots == expectedRoots) ''
  tests/saves.nix: backup roots must be exactly saves, complete ES-DE, BIOS,
  and player home. ROMs, media, cache, and snapshots are outside these roots.
'';
assert lib.assertMsg (names == expectedNames) ''
  tests/saves.nix: saveRoutes differs from the authoritative fourteen-row
  table, including ScummVM.
'';
assert lib.assertMsg (actualRouteFields == expectedRouteFields) ''
  tests/saves.nix: a legacy path, destination, mechanism, or owned-setting
  field differs from the authoritative save-route table.
'';
assert lib.assertMsg
  (
    map (route: route.evidence) routes == expectedEvidence
    && lib.all (route: route.preparation == expectedPreparation route) routes
  )
  ''
    tests/saves.nix: route preparation order or required evidence differs from
    the authoritative save-route table.
  '';
assert lib.assertMsg (lib.length saves.bindMappings == lib.length bindRoutes) ''
  tests/saves.nix: every and only bind route must have a mandatory mount.
'';
assert lib.assertMsg
  (
    host.config.systemd.targets.emubox-save-routes.wantedBy == [ "multi-user.target" ]
    && host.config.systemd.services.display-manager.requires == [ "emubox-save-routes.target" ]
  )
  ''
    tests/saves.nix: declared save routes must start before the kiosk, and a
    missing required mount must prevent display-manager startup.
  '';
assert lib.assertMsg
  (lib.all (
    mapping:
    lib.any (
      mount: mount.where == mapping.where && lib.elem "emubox-save-migrate.service" mount.after
    ) host.config.systemd.mounts
  ) saves.bindMappings)
  ''
    tests/saves.nix: migration must complete before every mandatory save bind
    mount can activate.
  '';
assert lib.assertMsg
  (
    owned."${home}/.config/retroarch/retroarch.cfg".keys.savefile_directory
    == "/data/saves/retroarch/saves"
    &&
      owned."${home}/.config/retroarch/retroarch.cfg".keys.savestate_directory
      == "/data/saves/retroarch/states"
    && owned."${home}/.config/scummvm/scummvm.ini".keys.scummvm.savepath == "/data/saves/scummvm/saves"
  )
  ''
    tests/saves.nix: every setting-directed route must have its owned setting.
  '';
assert lib.assertMsg (lib.all (path: lib.hasPrefix "${home}/" path && path != home)
  saves.homeCacheExclusions
) "tests/saves.nix: home cache exclusions must be strict player-home descendants";
assert lib.assertMsg
  (lib.all invalidExclusion [
    [
      "${home}/.cache"
      "${home}/.cache"
    ]
    [ "${home}/../escape" ]
    [ home ]
    [ "${home}/.cache/../saves-alias" ]
    [ "${home}/.config/retroarch/saves" ]
  ])
  ''
    tests/saves.nix: duplicate, traversal, home-root, alias-shaped, and
    save-route-overlapping cache exclusions must all fail evaluation.
  '';
assert lib.assertMsg
  (
    lib.all (name: !(builtins.hasAttr name rollback.config.systemd.services)) cloudUnits
    && rollback.config.emubox.saves.saveRoutes == routes
    && rollback.config.emubox.saves.bindMappings == saves.bindMappings
    && rollback.config.emubox.kiosk.ownedFiles == owned
  )
  ''
    tests/saves.nix: disabling off-site services must preserve every save
    setting and bind route without reverse migration or deletion.
  '';
pkgs.runCommand "emubox-saves" { } ''
  touch "$out"
''
