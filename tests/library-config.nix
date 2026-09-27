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
assert lib.assertMsg (cfg.emubox.library.threads == 1) "the scraper thread count defaults to one";
assert lib.assertMsg (
  renderedMap == cfg.emubox.library.platformMap
) "the rendered platform map matches the option";
assert lib.assertMsg (
  renderedMap.genesis == "megadrive" && renderedMap.n3ds == "3ds"
) "folders map to Skyscraper's platform names";
assert lib.assertMsg (lib.elem "a+ /data/roms - - - - d:g:player:rwx" rules)
  "the ROM root carries the default ACL rule";
assert lib.assertMsg (
  !(lib.any (r: lib.hasPrefix "A" r && lib.hasInfix "/data/roms" r) rules)
) "no recursive ACL rule walks the ROM tree";
assert lib.assertMsg (lib.elem "d /data/cache/skyscraper 0755 player player -" rules)
  "the scraper cache is 0755 player:player";
assert lib.assertMsg (
  !(lib.any (p: lib.hasInfix "/data/roms" (builtins.toJSON p.pathConfig)) (
    lib.attrValues cfg.systemd.paths
  ))
) "no path unit watches the ROM root";
assert lib.assertMsg (
  settings.bundled_systems == "${host.pkgs.es-de}/share/es-de/resources/systems/linux/es_systems.xml"
) "the library reads the frontend's bundled systems document";
assert lib.assertMsg (
  settings.custom_systems == cfg.emubox.kiosk.customSystemsFile
) "the library reads the rendered custom systems";
assert lib.assertMsg (
  settings.scraper_config == template.path
) "the library reads the sops-rendered scraper config";
assert lib.assertMsg (
  template.owner == "player" && template.mode == "0400"
) "the scraper config is player-only";
assert lib.assertMsg (lib.hasInfix "regionPrios=\"us,eu,jp\"" template.content)
  "region priority is US, EU, JP";
assert lib.assertMsg (lib.hasInfix "lang=\"en\"" template.content)
  "the scraper language is English";
assert lib.assertMsg (lib.hasInfix "threads=1" template.content)
  "the scraper config carries the thread count";
assert lib.assertMsg (lib.elem host.pkgs.emubox-library cfg.environment.systemPackages)
  "the library commands are installed";
assert lib.assertMsg
  (lib.hasInfix (builtins.unsafeDiscardStringContext "${host.pkgs.coreutils}/bin/timeout") step)
  "the session step bounds generation with coreutils timeout";
assert lib.assertMsg
  (lib.hasInfix (builtins.unsafeDiscardStringContext "${host.pkgs.foot}/bin/foot") step)
  "the session step opens its window with foot";
assert lib.assertMsg (lib.hasInfix "emubox-library-generate" step)
  "the session step runs generation";
assert lib.assertMsg (lib.any (
  s: lib.hasInfix "<name>emubox-tools</name>" s
) cfg.emubox.kiosk.customSystems) "the Tools system is contributed";
assert lib.assertMsg (
  lib.length reporters == 1
) "exactly one library status reporter is registered";
assert lib.assertMsg (
  (lib.head reporters).command == [ "${host.pkgs.emubox-library}/bin/emubox-library-report" ]
) "the library reporter runs emubox-library-report";
assert lib.assertMsg (
  cfg.users.users.player.extraGroups == without.users.users.player.extraGroups
) "the library adds no group to the player account";
assert lib.assertMsg (
  cfg.users.users.player.group == without.users.users.player.group
) "the library leaves the player account's primary group alone";
assert lib.assertMsg (
  cfg.security.sudo.configFile == without.security.sudo.configFile
) "the library adds no sudo rule";
assert lib.assertMsg (
  cfg.security.polkit.extraConfig == without.security.polkit.extraConfig
) "the library adds no polkit rule";
assert lib.assertMsg (
  cfg.security.polkit.enable == without.security.polkit.enable
) "the library does not toggle polkit";
assert lib.assertMsg (
  cfg.security.polkit.adminIdentities == without.security.polkit.adminIdentities
) "the library adds no polkit admin";
pkgs.runCommand "emubox-library-config" { } ''
  touch "$out"
''
