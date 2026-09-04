# Design section 8: /data layout, Skyscraper scrape passes, gamelist refresh.
{ pkgs, ... }:
{
  systemd.tmpfiles.rules = [
    "d /data/home 0755 root root -"
    "d /data/roms 2775 player player -"
    "d /data/bios 2775 player player -"
    "d /data/saves 0755 player player -"
    "d /data/es-de 0755 player player -"
    "d /data/media 0755 player player -"
    "d /data/cache 0755 player player -"
  ];

  environment.systemPackages = [ pkgs.skyscraper ];

  # TODO: path unit + daily timer for scrape pass 1 (cache fill),
  # pass 2 inside emubox-prepare, emubox-library report.
}
