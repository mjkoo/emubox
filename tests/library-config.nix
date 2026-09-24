# Library configuration, dependency paths and unchanged privilege boundaries.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  host = self.nixosConfigurations.emubox;
  cfg = host.config;
  without =
    (host.extendModules {
      modules = [ { disabledModules = [ ../modules/library ]; } ];
    }).config;
  settings = builtins.fromJSON (
    builtins.unsafeDiscardStringContext cfg.environment.etc."emubox/library.json".source.text
  );
  template = cfg.sops.templates."skyscraper.ini";
  rules = cfg.systemd.tmpfiles.rules;
  step = cfg.emubox.kiosk.preFrontendStep;
  renderedMap = builtins.fromJSON (
    builtins.unsafeDiscardStringContext cfg.environment.etc."emubox/library-platforms.json".source.text
  );
  reporters = lib.filter (r: r.name == "library") cfg.emubox.status.reporters;
in
assert cfg.emubox.library.threads == 1;
assert renderedMap == cfg.emubox.library.platformMap;
assert renderedMap.genesis == "megadrive" && renderedMap.n3ds == "3ds";
assert lib.elem "a+ /data/roms - - - - d:g:player:rwx" rules;
assert !(lib.any (r: lib.hasPrefix "A" r && lib.hasInfix "/data/roms" r) rules);
assert lib.elem "d /data/cache/skyscraper 0755 player player -" rules;
assert
  !(lib.any (p: lib.hasInfix "/data/roms" (builtins.toJSON p.pathConfig)) (
    lib.attrValues cfg.systemd.paths
  ));
assert
  settings.bundled_systems == "${host.pkgs.es-de}/share/es-de/resources/systems/linux/es_systems.xml";
assert settings.custom_systems == cfg.emubox.kiosk.customSystemsFile;
assert settings.scraper_config == template.path;
assert template.owner == "player" && template.mode == "0400";
assert lib.hasInfix "regionPrios=\"us,eu,jp\"" template.content;
assert lib.hasInfix "lang=\"en\"" template.content;
assert lib.hasInfix "threads=1" template.content;
assert lib.elem host.pkgs.emubox-library cfg.environment.systemPackages;
assert lib.hasInfix (builtins.unsafeDiscardStringContext "${host.pkgs.coreutils}/bin/timeout") step;
assert lib.hasInfix (builtins.unsafeDiscardStringContext "${host.pkgs.foot}/bin/foot") step;
assert lib.hasInfix "emubox-library-generate" step;
assert lib.any (s: lib.hasInfix "<name>emubox-tools</name>" s) cfg.emubox.kiosk.customSystems;
assert lib.length reporters == 1;
assert (lib.head reporters).command == [ "${host.pkgs.emubox-library}/bin/emubox-library-report" ];
assert cfg.security.sudo.configFile == without.security.sudo.configFile;
assert cfg.security.polkit.extraConfig == without.security.polkit.extraConfig;
assert cfg.security.polkit.enable == without.security.polkit.enable;
assert cfg.security.polkit.adminIdentities == without.security.polkit.adminIdentities;
pkgs.runCommand "emubox-library-config" { } ''
  touch "$out"
''
