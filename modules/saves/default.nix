# Declared save placement and conflict-safe migration. Backup consumers use
# these typed roots and do not infer paths from emulator names.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.emubox.saves;
  playerHome = config.users.users.player.home;
  route = store: legacy: destination: mechanism: setting: evidence: {
    inherit
      store
      destination
      mechanism
      setting
      evidence
      ;
    legacyPaths = [ "${playerHome}/${legacy}" ];
    preparation = "create destination, migrate legacy tree, then ${
      if mechanism == "bind" then "mount" else "write setting"
    }";
  };
  routeTable = [
    (route "RetroArch saves" ".config/retroarch/saves" "/data/saves/retroarch/saves" "setting"
      "savefile_directory"
      "parsed owned-key assertion and deterministic core save write"
    )
    (route "RetroArch states" ".config/retroarch/states" "/data/saves/retroarch/states" "setting"
      "savestate_directory"
      "parsed owned-key assertion and deterministic state write"
    )
    (route "Dolphin memory cards" ".local/share/dolphin-emu/GC" "/data/saves/dolphin/GC" "bind" null
      "mount-source assertion and deterministic card fixture"
    )
    (route "Dolphin Wii data" ".local/share/dolphin-emu/Wii" "/data/saves/dolphin/Wii" "bind" null
      "mount-source assertion and deterministic Wii fixture or named exemption"
    )
    (route "Dolphin states" ".local/share/dolphin-emu/StateSaves" "/data/saves/dolphin/StateSaves"
      "bind"
      null
      "mount-source assertion and deterministic state write"
    )
    (route "DuckStation memory cards" ".local/share/duckstation/memcards"
      "/data/saves/duckstation/memcards"
      "bind"
      null
      "mount-source assertion and deterministic card fixture"
    )
    (route "DuckStation states" ".local/share/duckstation/savestates"
      "/data/saves/duckstation/savestates"
      "bind"
      null
      "mount-source assertion and deterministic state write"
    )
    (route "PCSX2 memory cards" ".config/PCSX2/memcards" "/data/saves/pcsx2/memcards" "bind" null
      "mount-source assertion and deterministic card fixture"
    )
    (route "PCSX2 states" ".config/PCSX2/sstates" "/data/saves/pcsx2/sstates" "bind" null
      "mount-source assertion and deterministic state write"
    )
    (route "PPSSPP savedata" ".config/ppsspp/PSP/SAVEDATA" "/data/saves/ppsspp/SAVEDATA" "bind" null
      "mount-source assertion and deterministic savedata fixture"
    )
    (route "PPSSPP states and metadata" ".config/ppsspp/PSP/PPSSPP_STATE"
      "/data/saves/ppsspp/PPSSPP_STATE"
      "bind"
      null
      "mount-source assertion and deterministic state plus metadata fixture"
    )
    (route "Azahar NAND" ".local/share/azahar-emu/nand" "/data/saves/azahar/nand" "bind" null
      "mount-source assertion and deterministic NAND fixture or named exemption"
    )
    (route "Azahar SD card" ".local/share/azahar-emu/sdmc" "/data/saves/azahar/sdmc" "bind" null
      "mount-source assertion and deterministic SD fixture or named exemption"
    )
    (route "ScummVM saves" ".local/share/scummvm/saves" "/data/saves/scummvm/saves" "setting"
      "scummvm.savepath"
      "parsed owned-key assertion and deterministic save fixture or named exemption"
    )
  ];
  backupRoots = [
    "/data/saves"
    "/data/es-de"
    "/data/bios"
    playerHome
  ];
  homeCacheExclusions = [
    "${playerHome}/.cache"
    "${playerHome}/.local/cache"
  ];
  bindMappings = map (r: {
    what = r.destination;
    where = builtins.head r.legacyPaths;
  }) (lib.filter (r: r.mechanism == "bind") cfg.saveRoutes);
  mountUnit = mapping: "${utils.escapeSystemdPath mapping.where}.mount";
  normalize = path: lib.removeSuffix "/" path;
  descendants = parent: path: path != parent && lib.hasPrefix "${parent}/" path;
  overlaps =
    left: right:
    let
      l = normalize left;
      r = normalize right;
    in
    l == r || lib.hasPrefix "${l}/" r || lib.hasPrefix "${r}/" l;
  routePaths = lib.concatMap (r: [ r.destination ] ++ r.legacyPaths) cfg.saveRoutes;
  invalidExclusions = lib.filter (
    path:
    let
      normalized = normalize path;
    in
    !(descendants playerHome normalized)
    || lib.elem ".." (lib.splitString "/" normalized)
    || lib.hasInfix "//" normalized
    || lib.any (routePath: overlaps normalized routePath) routePaths
  ) cfg.homeCacheExclusions;
  duplicateExclusions =
    lib.length cfg.homeCacheExclusions != lib.length (lib.unique cfg.homeCacheExclusions);
  routesJson = pkgs.writeText "emubox-save-routes.json" (builtins.toJSON cfg.saveRoutes);
in
{
  options.emubox.saves = {
    saveRoutes = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      description = "The closed, authoritative emulator save-route table.";
    };
    bindMappings = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      description = "Mandatory legacy-path bind mounts, derived only from saveRoutes.";
    };
    backupRoots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "The exact roots sent to off-site backup.";
    };
    homeCacheExclusions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = homeCacheExclusions;
      description = "Finite reconstructible cache paths strictly below player home.";
    };
  };

  config = {
    emubox.saves = {
      saveRoutes = routeTable;
      inherit bindMappings backupRoots;
    };

    assertions = [
      {
        assertion =
          cfg.backupRoots == [
            "/data/saves"
            "/data/es-de"
            "/data/bios"
            playerHome
          ];
        message = "emubox.saves.backupRoots must be exactly the four typed roots, never ROM, media, cache, or snapshots";
      }
      {
        assertion = !duplicateExclusions && invalidExclusions == [ ];
        message = "emubox.saves.homeCacheExclusions must be unique, normalized strict descendants of player home, and cannot overlap save routes: ${builtins.toJSON invalidExclusions}";
      }
      {
        assertion = lib.all (r: lib.hasPrefix "/data/saves/" r.destination) cfg.saveRoutes;
        message = "every declared save route must resolve beneath /data/saves";
      }
      {
        assertion =
          lib.length cfg.saveRoutes == 14 && lib.any (r: r.store == "ScummVM saves") cfg.saveRoutes;
        message = "saveRoutes must retain every authoritative table row, including ScummVM";
      }
      {
        assertion = cfg.bindMappings == bindMappings;
        message = "bindMappings must be derived exactly from bind saveRoutes";
      }
    ];

    systemd.tmpfiles.rules =
      (map (r: "d ${r.destination} 0755 player player -") cfg.saveRoutes)
      ++ (map (mapping: "d ${mapping.where} 0755 player player -") cfg.bindMappings);

    environment.etc."emubox/save-routes.json".source = routesJson;

    systemd.services.emubox-save-migrate = {
      description = "Migrate declared emulator saves before route activation";
      wantedBy = [ "emubox-save-routes.target" ];
      before = map mountUnit cfg.bindMappings ++ [
        "emubox-save-routes.target"
        "display-manager.service"
      ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.emubox-save-migrate}/bin/emubox-save-migrate ${routesJson}";
      };
    };

    systemd.mounts = map (mapping: {
      what = mapping.what;
      where = mapping.where;
      type = "none";
      options = "bind";
      requiredBy = [ "emubox-save-routes.target" ];
      after = [ "emubox-save-migrate.service" ];
      requires = [ "emubox-save-migrate.service" ];
      before = [ "emubox-save-routes.target" ];
    }) cfg.bindMappings;

    systemd.targets.emubox-save-routes = {
      description = "All declared emulator save routes";
      wantedBy = [ "multi-user.target" ];
      requires = [ "emubox-save-migrate.service" ] ++ map mountUnit cfg.bindMappings;
      after = [ "emubox-save-migrate.service" ] ++ map mountUnit cfg.bindMappings;
      before = [ "display-manager.service" ];
    };

    systemd.services.display-manager = {
      requires = [ "emubox-save-routes.target" ];
      after = [ "emubox-save-routes.target" ];
    };
  };
}
