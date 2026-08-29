# Design section 6: RetroArch cores for everything through the disc
# generations, standalone only where the core is weak or absent.
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    (retroarch.withCores (
      cores: with cores; [
        stella
        prosystem
        handy
        mesen
        snes9x
        mupen64plus
        gambatte
        mgba
        beetle-vb
        beetle-wswan
        beetle-ngp
        genesis-plus-gx
        picodrive
        beetle-saturn
        flycast
        beetle-psx-hw
        beetle-pce-fast
        beetle-supergrafx
        fbneo
        melonds
        dosbox-pure
        puae
        vice-x64
        bluemsx
        vecx
        freeintv
      ]
    ))
    ppsspp
    dolphin-emu
    pcsx2
    azahar
    scummvm
    # TODO(pkgs/duckstation): vendored DuckStation via the overlay.
  ];

  # TODO(design 6): retroarch.cfg keys asserted by emubox-prepare, the
  # es_systems.xml overrides, emubox-check-bios.
}
