# The emulator layer: which program plays each system, how it is
# configured, and what firmware it needs.
#
# Design section 6 gives the shape - RetroArch cores for everything through
# the disc generations, standalone only where the core is weak or absent -
# but this file has grown well past that one sentence. Its sections, in the
# order they appear:
#
# 1. Paths and packages. Each emulator's own config file path, verified
#    against that emulator's source at the pinned revision, bound exactly
#    once so no two call sites can drift apart; the RetroArch build and the
#    cores directory that follows from it.
# 2. Frontend overrides. Every system whose assigned emulator
#    differs from ES-DE's bundled default, copied verbatim from the pinned
#    upstream `es_systems.xml` with only the command order rewritten, and
#    contributed to `emubox.kiosk.customSystems`.
# 3. BIOS inventory. One entry per firmware-required system
#    that has a citable published checksum, rendered to
#    `/etc/emubox/bios-inventory.json` for `emubox-check-bios`.
# 4. RetroAchievements tables. `raEmulators` names, per
#    emulator, where each credential and switch lives; `raDisabledFiles`
#    is the static half of the disabled path.
# 5. `config`. The packages, the owned-values tables that
#    `emubox-prepare` asserts before every launch, and the
#    retroachievements namespace handed to `modules/kiosk`.
#
# If this file is ever split, those five are the seams: 2, 3 and 4 each
# stand alone and are consumed through a single binding
# (`customSystems`, `biosInventoryFile`, `raEmulators`), while 1 and 5 are
# what actually need to stay together.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.emubox.retroachievements;

  # `players`'s home, read from the same option modules/kiosk sets rather
  # than repeated here, so a future change to it cannot silently desync one
  # module's config paths from the other's.
  playerHome = config.users.users.player.home;

  # Config file paths, verified against each emulator's own source at the
  # pinned nixpkgs revision this flake locks (and, for DuckStation, the
  # pinned upstream AppImage source - see pkgs/duckstation) on 2026-08-30.
  # Every one of them takes the XDG basedir branch on a fresh kiosk home
  # with no `XDG_*` override and no legacy dotfile/dotdir already present -
  # true on this appliance, whose home is created empty by `createHome`
  # every time the disk is laid down (modules/kiosk). None of these programs
  # is run in portable mode: that would need a marker file
  # (`portable.txt`/`portable.ini`) sitting beside the binary in the Nix
  # store, which none of these derivations puts there.
  retroarchConfigFile = "${playerHome}/.config/retroarch/retroarch.cfg";
  dolphinConfigFile = "${playerHome}/.config/dolphin-emu/Dolphin.ini";
  # Dolphin keeps its RetroAchievements settings in a *second* ini beside
  # Dolphin.ini, not inside it (Core/Config/AchievementSettings.cpp reads
  # and writes a config layer scoped to this file's own name) - both files
  # need their own `format` entry in ownedFiles below.
  dolphinAchievementsFile = "${playerHome}/.config/dolphin-emu/RetroAchievements.ini";
  pcsx2ConfigFile = "${playerHome}/.config/PCSX2/inis/PCSX2.ini";
  # PCSX2 keeps the RA token only here, in a second file, never in
  # PCSX2.ini itself (Achievements.cpp's SetSecretsSettingsLayer) - both
  # files share the literal section name `Achievements`.
  pcsx2SecretsFile = "${playerHome}/.config/PCSX2/inis/secrets.ini";
  ppssppConfigFile = "${playerHome}/.config/ppsspp/PSP/SYSTEM/ppsspp.ini";
  # Not in `ownedFiles`: this holds the RA token as raw bytes with no
  # `key=value` framing at all, so none of prepare's file-format editors
  # can touch it. See the `ppsspp` entry in `raEmulators` below.
  ppssppTokenFile = "${playerHome}/.config/ppsspp/PSP/SYSTEM/ppsspp_retroachievements.dat";
  azaharConfigFile = "${playerHome}/.config/azahar-emu/qt-config.ini";
  # DuckStation is the one emulator here whose data root is NOT under
  # `.config`: `Core::SetDataRoot` falls back to a *hardcoded*
  # `$HOME/.local/share/duckstation` on Linux when `XDG_CONFIG_HOME` is
  # unset - it never consults `XDG_DATA_HOME` at all, a genuine quirk of
  # this emulator's own source (src/core/core.cpp), not a typo here.
  #
  # Portable-mode verdict, checked against the actual built extraction of
  # this flake's pinned AppImage (pkgs/duckstation), not just the source
  # logic: `appimageTools.wrapType2`'s FHS wrapper execs `AppRun` directly
  # and never sets `APPIMAGE` on that path, so DuckStation's own
  # `IsRunningInPortableMode()` check (`AppRoot == DataRoot`) sees its
  # read-only Nix store extraction as `AppRoot` and this home-relative path
  # as `DataRoot` - they differ, so portable mode is off and the machine-id
  # key stays in the token derivation, exactly as the encryption scheme
  # below assumes. A
  # future DuckStation bump could change this wrapper's behaviour; if it
  # ever starts setting `APPIMAGE`, or nixpkgs switches this package off
  # `wrapType2`, this verdict needs rechecking before the bump lands.
  duckstationConfigFile = "${playerHome}/.local/share/duckstation/settings.ini";
  scummvmConfigFile = "${playerHome}/.config/scummvm/scummvm.ini";

  # DuckStation's token encryption keys off the raw bytes of this file;
  # it is not under the appdata root because the base system already keeps
  # it stable across the root wipe on its own, so a second copy here would
  # just be another place for the same fact to drift.
  machineIdFile = "/etc/machine-id";

  # Where every emulator on this box looks for firmware. Bound once, like
  # every config path above it, because this literal is a config *value* in
  # three separate owned-key tables below (RetroArch's `system_directory`,
  # PCSX2's `Folders.Bios`, DuckStation's `BIOS.SearchDirectory`) and three
  # copies of a path is three chances for two of them to disagree.
  #
  # It is deliberately not an option shared with `modules/library`, which is
  # where the directory is actually created (its `systemd.tmpfiles.rules`
  # entry `d /data/bios 2775 player player -`). A read-only option plumbed
  # between two modules to carry one string constant costs more than it
  # saves; what it buys - one place to change - is bought here by this
  # comment instead. Change one and change the other. The kiosk VM test
  # spells the path a third time on purpose and must NOT be pointed at this
  # binding: a test that derives its expectation from the module under test
  # proves only that the module agrees with itself.
  biosDirectory = "/data/bios";

  # The flake's own cores bundle - the one source `libretro_directory`
  # below is allowed to name (spec: "the flake's packaged cores and no
  # other source"). Every `libretro-*` core derivation installs its .so
  # into `$out/lib/retroarch/cores` by default (mkLibretroCore.nix); with
  # no cores of its own, `symlinkJoin` folds every core named here plus
  # retroarch-bare into one `$out`, so this literal subpath is where all of
  # them land together - not a path this module invents.
  retroarchWithCores = pkgs.retroarch.withCores (
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
  );
  coresDirectory = "${retroarchWithCores}/lib/retroarch/cores";

  # ---------------------------------------------------------------------
  # Frontend overrides: every system whose assigned emulator
  # differs from ES-DE 3.4.1's bundled default, contributed to
  # `emubox.kiosk.customSystems`.
  #
  # Read directly from the pinned upstream tarball `pkgs/es-de/package.nix`
  # fetches (v3.4.1, `sha256-MVmJIdxwEG3wgvwbhuIEYCxKaYss/3hq9xszGLjZ1Xw=`),
  # specifically `resources/systems/linux/es_systems.xml`. ES-DE's own rule
  # (`FileData::findEmulator`, `es-app/src/FileData.cpp`) treats a system's
  # *first* `<command>` as the default when no per-game preference is
  # saved, so overriding an assignment means rewriting command order, not
  # inventing new command text. Its custom-systems loader
  # (`SystemData::loadConfig`, `es-app/src/SystemData.cpp`) skips any
  # `<system>` missing a `<fullname>`, `<path>`, `<extension>` or at least
  # one `<command>` - there is no partial-override form that names only the
  # one command to change - and replaces a bundled system with a custom one
  # by matching `<path>` text exactly ("systems with identical <path> tags
  # will be overwritten by the last occurrence"). Every entry below is
  # therefore the bundled system copied in full and verbatim - every field,
  # every `<command label>` string, every `%EMULATOR_X%`/`%CORE_RETROARCH%`
  # placeholder - with only the command order rewritten. `<path>` is never
  # touched, since that identity is what makes the override take effect at
  # all.
  #
  # The placeholders resolve with no override needed: every standalone this
  # flake installs lands in `environment.systemPackages`, which puts it on
  # `player`'s PATH via `/run/current-system/sw/bin`, and ES-DE's bundled
  # `es_find_rules.xml` resolves `%EMULATOR_X%` by an exact, literal search
  # of PATH for one of a short list of binary names - `duckstation`,
  # `ppsspp`, `dolphin-emu`, `pcsx2-qt`, `azahar` and `scummvm` are each a
  # literal entry in that list, confirmed by inspecting each derivation's
  # `bin/` directly rather than assumed from the attribute name.
  # `%CORE_RETROARCH%` resolves the same way against
  # `/run/current-system/sw/lib/retroarch/cores`, the exact path
  # `pkgs/es-de/package.nix`'s `postInstall` guard already asserts is
  # present in the shipped find rules.
  #
  # Every alternate command ES-DE ships is kept, reordered but never
  # trimmed - including the handful naming a core or standalone this flake
  # does not install (SD Beetle PSX, PCSX ReARMed, SwanStation, ares and
  # Mednafen for PS1; the MAME family for Arcade; Citra/DeSmuME/NooDS/SkyEmu
  # for DS; Citra/Mandarine/Lime3DS/Panda3DS for 3DS, and so on). Selecting
  # one of those is no worse than on vanilla ES-DE - the frontend reports
  # "emulator not found" - and dropping them would mean maintaining a
  # curated list the design never asked for; the design's ask is only which
  # command comes first.
  psxOverride = ''
    <system>
      <name>psx</name>
      <fullname>Sony PlayStation</fullname>
      <path>%ROMPATH%/psx</path>
      <extension>.bin .BIN .cbn .CBN .ccd .CCD .chd .CHD .cue .CUE .ecm .ECM .exe .EXE .img .IMG .iso .ISO .m3u .M3U .mdf .MDF .mds .MDS .minipsf .MINIPSF .pbp .PBP .psexe .PSEXE .psf .PSF .toc .TOC .z .Z .znx .ZNX .7z .7Z .zip .ZIP</extension>
      <command label="DuckStation (Standalone)">%EMULATOR_DUCKSTATION% -batch %ROM%</command>
      <command label="Beetle PSX HW">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mednafen_psx_hw_libretro.so %ROM%</command>
      <command label="Beetle PSX">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mednafen_psx_libretro.so %ROM%</command>
      <command label="PCSX ReARMed">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/pcsx_rearmed_libretro.so %ROM%</command>
      <command label="SwanStation">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/swanstation_libretro.so %ROM%</command>
      <command label="ares (Standalone)">%EMULATOR_ARES% --fullscreen --system "PlayStation" %ROM%</command>
      <command label="Mednafen (Standalone)">%EMULATOR_MEDNAFEN% -force_module psx %ROM%</command>
      <platform>psx</platform>
      <theme>psx</theme>
    </system>'';

  # This flake's RetroArch build (see `retroarchWithCores` above) installs
  # `beetle-pce-fast` (`mednafen_pce_fast_libretro.so`), not the SD
  # `beetle-pce` ES-DE defaults to. Same override, same reason, across all
  # FOUR ES-DE systems this affects: ES-DE 3.4.1 ships the PC Engine and PC
  # Engine CD families as two independently-named pairs sharing one command
  # list each - `pcengine`/`pcenginecd` (the design table's own names for
  # this row) and, separately, `tg16`/`tg-cd` (the TurboGrafx-branded North
  # American release of the exact same hardware, a distinct `<path>` and so
  # a distinct ROM folder in ES-DE's own model, not an alias of the other
  # pair). Missing either half of a pair leaves that folder's games pointed
  # at a core this flake never installs ("emulator not found"); this
  # comment used to claim covering `pcengine`/`pcenginecd` was "both the
  # cartridge and CD systems", which was true of those two names but wrong
  # about there being only two - verified by diffing every bundled system's
  # first command against this flake's installed core set, which is what
  # turned up the missing `tg16`/`tg-cd` pair in the first place.
  pcengineOverride = ''
    <system>
      <name>pcengine</name>
      <fullname>NEC PC Engine</fullname>
      <path>%ROMPATH%/pcengine</path>
      <extension>.ccd .CCD .chd .CHD .cue .CUE .img .IMG .iso .ISO .m3u .M3U .pce .PCE .rom .ROM .sgx .SGX .toc .TOC .7z .7Z .zip .ZIP</extension>
      <command label="Beetle PCE FAST">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mednafen_pce_fast_libretro.so %ROM%</command>
      <command label="Beetle PCE">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mednafen_pce_libretro.so %ROM%</command>
      <command label="Beetle SuperGrafx">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mednafen_supergrafx_libretro.so %ROM%</command>
      <command label="Geargrafx">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/geargrafx_libretro.so %ROM%</command>
      <command label="Geargrafx (Standalone)">%EMULATOR_GEARGRAFX% %ROM%</command>
      <command label="Mednafen (Standalone)">%EMULATOR_MEDNAFEN% -force_module pce %ROM%</command>
      <command label="Mesen (Standalone)">%EMULATOR_MESEN% --fullscreen %ROM%</command>
      <command label="ares (Standalone)">%EMULATOR_ARES% --fullscreen --system "PC Engine" %ROM%</command>
      <platform>pcengine</platform>
      <theme>pcengine</theme>
    </system>'';

  pcenginecdOverride = ''
    <system>
      <name>pcenginecd</name>
      <fullname>NEC PC Engine CD</fullname>
      <path>%ROMPATH%/pcenginecd</path>
      <extension>.ccd .CCD .chd .CHD .cue .CUE .img .IMG .iso .ISO .m3u .M3U .pce .PCE .sgx .SGX .toc .TOC .7z .7Z .zip .ZIP</extension>
      <command label="Beetle PCE FAST">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mednafen_pce_fast_libretro.so %ROM%</command>
      <command label="Beetle PCE">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mednafen_pce_libretro.so %ROM%</command>
      <command label="Beetle SuperGrafx">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mednafen_supergrafx_libretro.so %ROM%</command>
      <command label="Geargrafx">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/geargrafx_libretro.so %ROM%</command>
      <command label="Geargrafx (Standalone)">%EMULATOR_GEARGRAFX% %ROM%</command>
      <command label="Mednafen (Standalone)">%EMULATOR_MEDNAFEN% -force_module pce %ROM%</command>
      <command label="Mesen (Standalone)">%EMULATOR_MESEN% --fullscreen %ROM%</command>
      <command label="ares (Standalone)">%EMULATOR_ARES% --fullscreen --system "PC Engine CD" %ROM%</command>
      <platform>pcenginecd</platform>
      <theme>pcenginecd</theme>
    </system>'';

  # The TurboGrafx-branded North American release of the same hardware as
  # `pcengineOverride` above - ES-DE 3.4.1 ships it as a genuinely separate
  # system (its own `<path>`, so its own ROM folder) with an identical
  # command list, not an alias of `pcengine`. Same core substitution, same
  # reason: this flake installs `beetle-pce-fast`, not the SD `beetle-pce`
  # ES-DE defaults to.
  tg16Override = ''
    <system>
      <name>tg16</name>
      <fullname>NEC TurboGrafx-16</fullname>
      <path>%ROMPATH%/tg16</path>
      <extension>.ccd .CCD .chd .CHD .cue .CUE .img .IMG .iso .ISO .m3u .M3U .pce .PCE .rom .ROM .sgx .SGX .toc .TOC .7z .7Z .zip .ZIP</extension>
      <command label="Beetle PCE FAST">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mednafen_pce_fast_libretro.so %ROM%</command>
      <command label="Beetle PCE">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mednafen_pce_libretro.so %ROM%</command>
      <command label="Beetle SuperGrafx">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mednafen_supergrafx_libretro.so %ROM%</command>
      <command label="Geargrafx">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/geargrafx_libretro.so %ROM%</command>
      <command label="Geargrafx (Standalone)">%EMULATOR_GEARGRAFX% %ROM%</command>
      <command label="Mednafen (Standalone)">%EMULATOR_MEDNAFEN% -force_module pce %ROM%</command>
      <command label="Mesen (Standalone)">%EMULATOR_MESEN% --fullscreen %ROM%</command>
      <command label="ares (Standalone)">%EMULATOR_ARES% --fullscreen --system "PC Engine" %ROM%</command>
      <platform>pcengine</platform>
      <theme>tg16</theme>
    </system>'';

  # The TurboGrafx-branded release of `pcenginecdOverride`'s system, same
  # relationship as `tg16Override` to `pcengineOverride` above.
  tgCdOverride = ''
    <system>
      <name>tg-cd</name>
      <fullname>NEC TurboGrafx-CD</fullname>
      <path>%ROMPATH%/tg-cd</path>
      <extension>.ccd .CCD .chd .CHD .cue .CUE .img .IMG .iso .ISO .m3u .M3U .pce .PCE .sgx .SGX .toc .TOC .7z .7Z .zip .ZIP</extension>
      <command label="Beetle PCE FAST">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mednafen_pce_fast_libretro.so %ROM%</command>
      <command label="Beetle PCE">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mednafen_pce_libretro.so %ROM%</command>
      <command label="Beetle SuperGrafx">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mednafen_supergrafx_libretro.so %ROM%</command>
      <command label="Geargrafx">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/geargrafx_libretro.so %ROM%</command>
      <command label="Geargrafx (Standalone)">%EMULATOR_GEARGRAFX% %ROM%</command>
      <command label="Mednafen (Standalone)">%EMULATOR_MEDNAFEN% -force_module pce %ROM%</command>
      <command label="Mesen (Standalone)">%EMULATOR_MESEN% --fullscreen %ROM%</command>
      <command label="ares (Standalone)">%EMULATOR_ARES% --fullscreen --system "PC Engine CD" %ROM%</command>
      <platform>pcenginecd</platform>
      <theme>tg-cd</theme>
    </system>'';

  # No MAME core is installed at all; FinalBurn Neo is the design's pick and
  # is `fbneo` in `retroarchWithCores` above.
  arcadeOverride = ''
    <system>
      <name>arcade</name>
      <fullname>Arcade</fullname>
      <path>%ROMPATH%/arcade</path>
      <extension>.cmd .CMD .desktop .gam .GAM .lindbergh .neo .NEO .sh .7z .7Z .zip .ZIP</extension>
      <command label="FinalBurn Neo">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/fbneo_libretro.so %ROM%</command>
      <command label="MAME - Current">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mame_libretro.so %ROM%</command>
      <command label="MAME 2010">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mame2010_libretro.so %ROM%</command>
      <command label="MAME 2003-Plus">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mame2003_plus_libretro.so %ROM%</command>
      <command label="MAME 2003">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mame2003_libretro.so %ROM%</command>
      <command label="MAME 2000">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/mame2000_libretro.so %ROM%</command>
      <command label="MAME (Standalone)">%STARTDIR%=~/.mame %EMULATOR_MAME% -rompath %GAMEDIR%\;%ROMPATH%/arcade %BASENAME%</command>
      <command label="FinalBurn Neo (Standalone)">%EMULATOR_FINALBURN-NEO% -fullscreen %BASENAME%</command>
      <command label="FB Alpha 2012">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/fbalpha2012_libretro.so %ROM%</command>
      <command label="Geolith">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/geolith_libretro.so %ROM%</command>
      <command label="Flycast">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/flycast_libretro.so %ROM%</command>
      <command label="Flycast (Standalone)">%EMULATOR_FLYCAST% %ROM%</command>
      <command label="Flycast Dojo (Standalone)">%EMULATOR_FLYCAST-DOJO% %ROM%</command>
      <command label="Kronos">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/kronos_libretro.so %ROM%</command>
      <command label="DICE">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/dice_libretro.so %ROM%</command>
      <command label="Supermodel (Standalone)">%STARTDIR%=%GAMEDIR% %EMULATOR_SUPERMODEL% -log-output=%GAMEDIR%/Config/Supermodel.log %INJECT%=%BASENAME%.commands %ROM%</command>
      <command label="Lindbergh Loader (Standalone)">%STARTDIR%=%GAMEENTRYDIR% %EMULATOR_LINDBERGH-LOADER% %INJECT%=%BASENAME%/%BASENAME%.commands</command>
      <command label="MFME (Wine)">%PRECOMMAND_WINE% %EMULATOR_MFME-WINDOWS% "%ROMRAWWIN%"</command>
      <command label="MFME (Proton)">%PRECOMMAND_PROTON% %EMULATOR_MFME-WINDOWS% "%ROMRAWWIN%"</command>
      <command label="Shortcut or script">%ENABLESHORTCUTS% %EMULATOR_OS-SHELL% %ROM%</command>
      <platform>arcade</platform>
      <theme>arcade</theme>
    </system>'';

  # This flake installs `melonds` (the older DS+DSi core, `melonds_libretro.so`),
  # not `melondsds` (the newer DS-only core) ES-DE defaults to.
  ndsOverride = ''
    <system>
      <name>nds</name>
      <fullname>Nintendo DS</fullname>
      <path>%ROMPATH%/nds</path>
      <extension>.app .APP .bin .BIN .nds .NDS .7z .7Z .zip .ZIP</extension>
      <command label="melonDS">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/melonds_libretro.so %ROM%</command>
      <command label="melonDS DS">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/melondsds_libretro.so %ROM%</command>
      <command label="melonDS (Standalone)">%EMULATOR_MELONDS% -f %ROM%</command>
      <command label="DeSmuME">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/desmume_libretro.so %ROM%</command>
      <command label="DeSmuME 2015">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/desmume2015_libretro.so %ROM%</command>
      <command label="DeSmuME (Standalone)">%EMULATOR_DESMUME% %ROM%</command>
      <command label="NooDS">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/noods_libretro.so %ROM%</command>
      <command label="NooDS (Standalone)">%EMULATOR_NOODS% %ROM%</command>
      <command label="SkyEmu">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/skyemu_libretro.so %ROM%</command>
      <command label="SkyEmu (Standalone)">%EMULATOR_SKYEMU% %ROM%</command>
      <platform>nds</platform>
      <theme>nds</theme>
    </system>'';

  # Only the standalone `ppsspp` package is installed, not the RetroArch
  # PPSSPP core ES-DE defaults to.
  pspOverride = ''
    <system>
      <name>psp</name>
      <fullname>Sony PlayStation Portable</fullname>
      <path>%ROMPATH%/psp</path>
      <extension>.chd .CHD .cso .CSO .elf .ELF .iso .ISO .pbp .PBP .prx .PRX .7z .7Z .zip .ZIP</extension>
      <command label="PPSSPP (Standalone)">%EMULATOR_PPSSPP% %ROM%</command>
      <command label="PPSSPP">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/ppsspp_libretro.so %ROM%</command>
      <platform>psp</platform>
      <theme>psp</theme>
    </system>'';

  # Only the standalone `dolphin-emu` package is installed, not the
  # RetroArch Dolphin core ES-DE defaults to. Same override, same reason,
  # for both GameCube and Wii - ES-DE ships them as separate systems with
  # identical command lists.
  gcOverride = ''
    <system>
      <name>gc</name>
      <fullname>Nintendo GameCube</fullname>
      <path>%ROMPATH%/gc</path>
      <extension>.ciso .CISO .dff .DFF .dol .DOL .elf .ELF .gcm .GCM .gcz .GCZ .iso .ISO .json .JSON .m3u .M3U .rvz .RVZ .tgc .TGC .wad .WAD .wbfs .WBFS .wia .WIA .7z .7Z .zip .ZIP</extension>
      <command label="Dolphin (Standalone)">%INJECT%=%BASENAME%.esprefix %EMULATOR_DOLPHIN% -b -e %ROM%</command>
      <command label="Dolphin">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/dolphin_libretro.so %ROM%</command>
      <command label="PrimeHack (Standalone)">%INJECT%=%BASENAME%.esprefix %EMULATOR_PRIMEHACK% -b -e %ROM%</command>
      <command label="Triforce (Standalone)">%INJECT%=%BASENAME%.esprefix %EMULATOR_TRIFORCE% -b -e %ROM%</command>
      <platform>gc</platform>
      <theme>gc</theme>
    </system>'';

  wiiOverride = ''
    <system>
      <name>wii</name>
      <fullname>Nintendo Wii</fullname>
      <path>%ROMPATH%/wii</path>
      <extension>.ciso .CISO .dff .DFF .dol .DOL .elf .ELF .gcm .GCM .gcz .GCZ .iso .ISO .json .JSON .m3u .M3U .rvz .RVZ .tgc .TGC .wad .WAD .wbfs .WBFS .wia .WIA .7z .7Z .zip .ZIP</extension>
      <command label="Dolphin (Standalone)">%INJECT%=%BASENAME%.esprefix %EMULATOR_DOLPHIN% -b -e %ROM%</command>
      <command label="Dolphin">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/dolphin_libretro.so %ROM%</command>
      <command label="PrimeHack (Standalone)">%INJECT%=%BASENAME%.esprefix %EMULATOR_PRIMEHACK% -b -e %ROM%</command>
      <platform>wii</platform>
      <theme>wii</theme>
    </system>'';

  # Only the standalone `pcsx2` package (its binary is `pcsx2-qt`) is
  # installed, not the RetroArch PCSX2 core (labelled "LRPS2" first and
  # "PCSX2" second for the same core file) ES-DE defaults to.
  ps2Override = ''
    <system>
      <name>ps2</name>
      <fullname>Sony PlayStation 2</fullname>
      <path>%ROMPATH%/ps2</path>
      <extension>.bin .BIN .chd .CHD .ciso .CISO .cso .CSO .desktop .dump .DUMP .elf .ELF .gz .GZ .m3u .M3U .mdf .MDF .img .IMG .iso .ISO .isz .ISZ .ngr .NRG .zso .ZSO</extension>
      <command label="PCSX2 (Standalone)">%EMULATOR_PCSX2% -batch %ROM%</command>
      <command label="LRPS2">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/pcsx2_libretro.so %ROM%</command>
      <command label="PCSX2">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/pcsx2_libretro.so %ROM%</command>
      <command label="PCSX2 Legacy (Standalone)">%EMULATOR_PCSX2-LEGACY% --nogui %ROM%</command>
      <command label="Play! (Standalone)">%EMULATOR_PLAY!% --fullscreen --disc %ROM%</command>
      <command label="Shortcut or script">%ENABLESHORTCUTS% %EMULATOR_OS-SHELL% %ROM%</command>
      <platform>ps2</platform>
      <theme>ps2</theme>
    </system>'';

  # Only the standalone `azahar` package is installed, not the RetroArch
  # Azahar core ES-DE defaults to.
  n3dsOverride = ''
    <system>
      <name>n3ds</name>
      <fullname>Nintendo 3DS</fullname>
      <path>%ROMPATH%/n3ds</path>
      <extension>.3ds .3DS .3dsx .3DSX .app .APP .axf .AXF .cci .CCI .cxi .CXI .desktop .elf .ELF .z3dsx .Z3DSX .zcci .ZCCI .zcxi .ZCXI .7z .7Z .zip .ZIP</extension>
      <command label="Azahar (Standalone)">%EMULATOR_AZAHAR% %ROM%</command>
      <command label="Azahar">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/azahar_libretro.so %ROM%</command>
      <command label="Azahar Shortcut (Standalone)">%ENABLESHORTCUTS% %EMULATOR_OS-SHELL% %ROM%</command>
      <command label="AzaharPlus (Standalone)">%EMULATOR_AZAHARPLUS% %ROM%</command>
      <command label="Citra">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/citra_libretro.so %ROM%</command>
      <command label="Citra 2018">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/citra2018_libretro.so %ROM%</command>
      <command label="Citra (Standalone)">%EMULATOR_CITRA% %ROM%</command>
      <command label="Mandarine (Standalone)">%EMULATOR_MANDARINE% %ROM%</command>
      <command label="Lime3DS (Standalone)">%EMULATOR_LIME3DS% %ROM%</command>
      <command label="Panda3DS (Standalone)">%EMULATOR_PANDA3DS% %ROM%</command>
      <platform>n3ds</platform>
      <theme>n3ds</theme>
    </system>'';

  # Only the standalone `scummvm` package is installed, not the RetroArch
  # ScummVM core ES-DE defaults to.
  scummvmOverride = ''
    <system>
      <name>scummvm</name>
      <fullname>ScummVM Game Engine</fullname>
      <path>%ROMPATH%/scummvm</path>
      <extension>.scummvm .SCUMMVM .svm .SVM</extension>
      <command label="ScummVM (Standalone)">%STARTDIR%=%GAMEDIR% %EMULATOR_SCUMMVM% %BASENAME%</command>
      <command label="ScummVM">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/scummvm_libretro.so %ROM%</command>
      <command label="DREAMM (Standalone)">%STARTDIR%=%GAMEDIR% %EMULATOR_DREAMM% .</command>
      <platform>scummvm</platform>
      <theme>scummvm</theme>
    </system>'';

  # This flake's RetroArch build installs `vice-x64`, confirmed by build to
  # produce `vice_x64_libretro.so` ("VICE x64 Fast"), not the
  # `vice_x64sc_libretro.so` ("VICE x64sc Accurate") core ES-DE defaults to.
  c64Override = ''
    <system>
      <name>c64</name>
      <fullname>Commodore 64</fullname>
      <path>%ROMPATH%/c64</path>
      <extension>.bin .BIN .cmd .CMD .crt .CRT .d2m .D2M .d4m .D4M .d64 .D64 .d6z .D6Z .d71 .D71 .d7z .D7Z .d80 .D80 .d81 .D81 .d82 .D82 .d8z .D8Z .g41 .G41 .g4z .G4Z .g64 .G64 .g6z .G6Z .gz .GZ .lnx .LNX .m3u .M3U .nbz .NBZ .nib .NIB .p00 .P00 .prg .PRG .t64 .T64 .tap .TAP .vfl .VFL .vsf .VSF .x64 .X64 .x6z .X6Z .7z .7Z .zip .ZIP</extension>
      <command label="VICE x64 Fast">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/vice_x64_libretro.so %ROM%</command>
      <command label="VICE x64sc Accurate">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/vice_x64sc_libretro.so %ROM%</command>
      <command label="VICE x64sc Accurate (Standalone)">%EMULATOR_VICE-X64SC% %ROM%</command>
      <command label="VICE x64 SuperCPU">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/vice_xscpu64_libretro.so %ROM%</command>
      <command label="VICE x128">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/vice_x128_libretro.so %ROM%</command>
      <command label="Frodo">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/frodo_libretro.so %ROM%</command>
      <platform>c64</platform>
      <theme>c64</theme>
    </system>'';

  customSystems = ''
    <?xml version="1.0"?>
    <systemList>
    ${lib.concatStringsSep "\n" [
      psxOverride
      pcengineOverride
      pcenginecdOverride
      tg16Override
      tgCdOverride
      arcadeOverride
      ndsOverride
      pspOverride
      gcOverride
      wiiOverride
      ps2Override
      n3dsOverride
      scummvmOverride
      c64Override
    ]}
    </systemList>
  '';

  # ---------------------------------------------------------------------
  # BIOS inventory: path under /data/bios, a digest with the
  # algorithm that produced it, and a human name, for every system that
  # requires firmware to run anything at all and has a citable checksum
  # at all.
  #
  # D6's first draft fixed the digest field at sha256; corrected because
  # nobody publishes a sha256 for any of these files, which would have kept
  # this inventory permanently empty. `algorithm` is named per entry
  # (`"md5"`, `"sha256"` or `"crc32"`) rather than inferred from digest
  # length, since a 32-hex MD5 and a 32-hex digest from some other algorithm
  # are indistinguishable by length alone - `emubox-check-bios` treats an
  # entry naming any other algorithm as a hard, whole-inventory failure, not
  # a silently skipped one.
  #
  # Every digest below was read directly on 2026-08-30, either from
  # docs.libretro.com's own per-core "BIOS" table (each core's page at
  # https://docs.libretro.com/library/<core>/) or, for PS1, cross-checked
  # against DuckStation's own source. All of them are MD5:
  #
  # - Atari Lynx: docs.libretro.com/library/handy/, `lynxboot.img`.
  # - Famicom Disk System: docs.libretro.com/library/mesen/, `disksys.rom`.
  # - Sega CD: docs.libretro.com/library/genesis_plus_gx/, the US variant
  #   `bios_CD_U.bin` (EU and JP variants are documented there too, under
  #   `bios_CD_E.bin`/`bios_CD_J.bin`, and are equally citable additions).
  # - Saturn: docs.libretro.com/library/beetle_saturn/, the US/EU variant
  #   `mpr-17933.bin` (a separate JP-region `sega_101.bin` is documented
  #   there too).
  # - PS1: the US variant `scph5501.bin`, doubly sourced - it is both
  #   DuckStation's own `src/core/bios.cpp` (`s_image_info_by_hash[]`,
  #   built through `MakeHashFromString` from `common/md5_digest.h`, read
  #   directly rather than taken from a secondary source) and
  #   docs.libretro.com/library/beetle_psx_hw/'s own BIOS table, and the two
  #   agree exactly.
  # - PC Engine CD: docs.libretro.com/library/beetle_pce_fast/,
  #   `syscard3.pce` (Super CD-ROM2 System V3.xx, the common case; older
  #   System Card versions are documented there without a checksum).
  # - Nintendo DS: docs.libretro.com/library/melonds/ (the `melonds` core
  #   this flake installs, not `melondsds`) publishes MD5 directly for the
  #   ARM7 and ARM9 BIOS images, `bios7.bin` and `bios9.bin` - a better,
  #   more directly comparable source than the CRC32-only third-party
  #   reference an earlier pass of this research had settled for, since
  #   every other entry here is already MD5 from the same site. The third
  #   file NDS needs, `firmware.bin`, is intentionally left out: that page
  #   publishes no checksum for it, and unlike the two BIOS images it is
  #   not one fixed correct file to begin with - genuine DS/DS Lite
  #   firmware is a per-console dump carrying that console's own Wi-Fi and
  #   user-settings data, so there is no single "correct" digest for it to
  #   declare.
  # - Amiga: docs.libretro.com/library/puae/, the Kickstart v1.3 rev 34.005
  #   A500 ROM `kick34005.A500` (the page documents many more Kickstart
  #   revisions for other Amiga models, each equally citable).
  # - Intellivision: docs.libretro.com/library/freeintv/, both required
  #   files - the Executive ROM `exec.bin` and the Graphics ROM `grom.bin`.
  #
  # Left out, each for a reason that is a property of the system rather
  # than a gap in this research:
  #
  # - Arcade: its BIOS is a per-game board ROM set beside each game's own
  #   files, not a single fixed firmware image an inventory entry (one
  #   path, one digest) can name.
  # - PS2: PCSX2's own `pcsx2/ps2/BiosTools.cpp` - read directly - validates
  #   a candidate BIOS only by file size and an internal "ROMVER" string;
  #   it carries no hash of any kind, of any algorithm, to borrow.
  # - MSX and ColecoVision (blueMSX): there is no single hashable BIOS file
  #   at all - blueMSX needs whole `Databases`/`Machines` folders copied
  #   from a full standalone blueMSX install, which is a directory tree,
  #   not an entry this inventory's shape can express.
  #
  # A digest with no provenance is worse than no entry - nobody could ever
  # audit it - so every entry above is traceable to a specific published
  # page or source file, and every system left out has a specific, honest
  # reason rather than a guess standing in for one.
  biosInventory = {
    atari-lynx = {
      path = "lynxboot.img";
      algorithm = "md5";
      digest = "fcd403db69f54290b51035d82f835e7b";
      name = "Atari Lynx boot ROM";
    };
    fds = {
      path = "disksys.rom";
      algorithm = "md5";
      digest = "ca30b50f880eb660a320674ed365ef7a";
      name = "Famicom Disk System BIOS";
    };
    sega-cd = {
      path = "bios_CD_U.bin";
      algorithm = "md5";
      digest = "854b9150240a198070150e4566ae1290";
      name = "Sega CD BIOS (US)";
    };
    saturn = {
      path = "mpr-17933.bin";
      algorithm = "md5";
      digest = "3240872c70984b6cbfda1586cab68dbe";
      name = "Saturn BIOS (US/EU)";
    };
    psx = {
      path = "scph5501.bin";
      algorithm = "md5";
      digest = "490f666e1afb15b7362b406ed1cea246";
      name = "PS1 BIOS (SCPH-5501, NTSC-U)";
    };
    pcenginecd = {
      path = "syscard3.pce";
      algorithm = "md5";
      digest = "38179df8f4ac870017db21ebcbf53114";
      name = "PC Engine CD System Card (Super CD-ROM2 V3.xx)";
    };
    nds-bios7 = {
      path = "bios7.bin";
      algorithm = "md5";
      digest = "df692a80a5b1bc90728bc3dfc76cd948";
      name = "Nintendo DS ARM7 BIOS";
    };
    nds-bios9 = {
      path = "bios9.bin";
      algorithm = "md5";
      digest = "a392174eb3e572fed6447e956bde4b25";
      name = "Nintendo DS ARM9 BIOS";
    };
    amiga = {
      path = "kick34005.A500";
      algorithm = "md5";
      digest = "82a21c1890cae844b3df741f2762d48d";
      name = "Amiga Kickstart v1.3 rev 34.005 (A500)";
    };
    intellivision-exec = {
      path = "exec.bin";
      algorithm = "md5";
      digest = "62e761035cb657903761800f4437b8af";
      name = "Intellivision Executive ROM";
    };
    intellivision-grom = {
      path = "grom.bin";
      algorithm = "md5";
      digest = "0cd5946c6473e42e8e4c2137785e427f";
      name = "Intellivision Graphics ROM";
    };
  };
  biosInventoryFile = pkgs.writeText "emubox-bios-inventory.json" (builtins.toJSON biosInventory);

  # RetroAchievements' per-emulator tables. One attrset per
  # supporting emulator, each shaped exactly as `emubox-prepare`'s
  # `retroachievements.targets[]` entries minus the `name`
  # field, which `retroachievementsNamespace` below adds when it renders
  # the enabled JSON. The same attrset also drives the disabled fallback in
  # `raDisabledFiles`, which is what keeps every key spelling here typed
  # exactly once rather than twice and liable to drift apart. Azahar and
  # ScummVM have no entry: exhaustive source greps for every RA-related
  # identifier (`achievement`, `cheevos`, `rc_client`, `retroachiev`, ...)
  # across both trees, vendored dependencies included, found nothing.
  raEmulators = {
    # RetroArch logs in with a plaintext token straight from retroarch.cfg
    # (configuration.c:1596-1598) and never needs the password once one is
    # set; the same three keys are also called out together as a group
    # configuration.c excludes from per-game overrides (:5878-5883), a
    # second, independent confirmation of their exact spelling.
    retroarch = {
      encoding = "plain";
      booleans = {
        "true" = "true";
        "false" = "false";
      };
      keys = {
        enabled = {
          file = retroarchConfigFile;
          key = "cheevos_enable";
        };
        hardcore = {
          file = retroarchConfigFile;
          key = "cheevos_hardcore_mode_enable";
        };
        username = {
          file = retroarchConfigFile;
          key = "cheevos_username";
        };
        token = {
          file = retroarchConfigFile;
          key = "cheevos_token";
        };
      };
    };

    # Dolphin's token is plaintext at rest too - no encryption wraps the
    # write at AchievementManager.cpp:961 - and Dolphin never persists a
    # password at all, only ever the token a successful login yields
    # (AchievementSettings.cpp has no `Password` key).
    dolphin = {
      encoding = "plain";
      booleans = {
        "true" = "True";
        "false" = "False";
      };
      keys = {
        enabled = {
          file = dolphinAchievementsFile;
          section = "Achievements";
          key = "Enabled";
        };
        hardcore = {
          file = dolphinAchievementsFile;
          section = "Achievements";
          key = "HardcoreEnabled";
        };
        username = {
          file = dolphinAchievementsFile;
          section = "Achievements";
          key = "Username";
        };
        token = {
          file = dolphinAchievementsFile;
          section = "Achievements";
          key = "ApiToken";
        };
      };
    };

    # `ChallengeMode`, not `HardcoreMode`, is the on-disk key even though
    # the C++ field is named `HardcoreMode`
    # (`SettingsWrapBitBoolEx(HardcoreMode, "ChallengeMode")`,
    # Pcsx2Config.cpp:1879) - the field name is not the ini spelling here.
    pcsx2 = {
      encoding = "plain";
      booleans = {
        "true" = "true";
        "false" = "false";
      };
      keys = {
        enabled = {
          file = pcsx2ConfigFile;
          section = "Achievements";
          key = "Enabled";
        };
        hardcore = {
          file = pcsx2ConfigFile;
          section = "Achievements";
          key = "ChallengeMode";
        };
        username = {
          file = pcsx2ConfigFile;
          section = "Achievements";
          key = "Username";
        };
        token = {
          file = pcsx2SecretsFile;
          section = "Achievements";
          key = "Token";
        };
      };
    };

    # PPSSPP's ini has an `AchievementsToken` key, but it is a decoy for
    # login purposes: Core/Config.h documents it as unused by the real path,
    # and `TryLoginByToken` (Core/RetroAchievements.cpp) reads a *separate*
    # raw secret file instead (`NativeLoadSecret("retroachievements")`,
    # UI/NativeApp.cpp) holding the token's bare bytes with no `key=value`
    # framing at all. `encoding = "secret-file"` is what routes the token
    # through `token_file` below instead of an ini key; prepare's own
    # validation forbids a `token` entry under `keys` for this encoding, so
    # there is none here on purpose. Enabled/hardcore/username are ordinary
    # ini keys - only the token needs the raw file. At the locked
    # pkgs.ppsspp.version 1.20.4 the key is also never written: it is
    # declared with `ConfigSetting("AchievementsToken", ..., CfgFlag::DONT_SAVE)`
    # (Core/Config.cpp:383), and Core/Config.h:677 comments that setting
    # "Not saved" - so PPSSPP's own writer never persists a token line into
    # ppsspp.ini. Nothing accumulates there now that unowned keys survive
    # edits, and no removal needs declaring for it.
    ppsspp = {
      encoding = "secret-file";
      booleans = {
        "true" = "True";
        "false" = "False";
      };
      token_file = ppssppTokenFile;
      keys = {
        enabled = {
          file = ppssppConfigFile;
          section = "Achievements";
          key = "AchievementsEnable";
        };
        hardcore = {
          file = ppssppConfigFile;
          section = "Achievements";
          key = "AchievementsChallengeMode";
        };
        username = {
          file = ppssppConfigFile;
          section = "Achievements";
          key = "AchievementsUserName";
        };
      };
    };

    # The one target `emubox-prepare` cannot write as a plain string:
    # DuckStation's `Cheevos.Token` holds the login2 token AES-128-CBC
    # encrypted with a key and IV both derived from `/etc/machine-id` and
    # the account name (src/core/achievements.cpp), which is
    # what `encoding = "duckstation"` and `machine_id_file` exist for.
    # `ChallengeMode`, not `HardcoreMode`, mirrors PCSX2's same
    # field-vs-ini-key split (settings.cpp:530,881).
    duckstation = {
      encoding = "duckstation";
      booleans = {
        "true" = "true";
        "false" = "false";
      };
      machine_id_file = machineIdFile;
      keys = {
        enabled = {
          file = duckstationConfigFile;
          section = "Cheevos";
          key = "Enabled";
        };
        hardcore = {
          file = duckstationConfigFile;
          section = "Cheevos";
          key = "ChallengeMode";
        };
        username = {
          file = duckstationConfigFile;
          section = "Cheevos";
          key = "Username";
        };
        token = {
          file = duckstationConfigFile;
          section = "Cheevos";
          key = "Token";
        };
        login_timestamp = {
          file = duckstationConfigFile;
          section = "Cheevos";
          key = "LoginTimestamp";
        };
      };
    };
  };

  # The retroachievements spec's Disabled scenario ("each supporting
  # emulator's configuration has achievements disabled") is split across
  # two mechanisms that both run unconditionally, regardless of
  # `cfg.enable`. This table is the static half: `enabled` and `hardcore`
  # forced off as ordinary owned keys, folded into `emubox.kiosk.ownedFiles`
  # below with no dynamic step involved at all, so those two keys are
  # already right before `emubox-prepare` has read anything. Built from
  # `raEmulators` above rather than a second copy of the same key
  # spellings.
  #
  # Those two keys are all this table can reach, and used to be the whole
  # story: a stale `username`/`token` was left exactly where a prior login
  # wrote it, on the theory that this matched "prepare's own behaviour when
  # a login simply does not resolve one" - which stopped being true once
  # prepare started actively removing those keys on that path (see
  # `emubox_prepare.py`'s own module docstring, "When no token resolves
  # at all, the login keys are removed from every target").
  # `enable = false` left a live bearer token sitting in every supporting
  # emulator's config, PPSSPP's raw token file and the login cache, with no
  # way for this static table to reach the latter two at all (they are not
  # ordinary owned keys `emubox.kiosk.ownedFiles` can name). The other half
  # is `retroachievementsNamespace` below, which now always renders a
  # non-null namespace with its own `enabled` field following `cfg.enable`:
  # `emubox-prepare`'s `apply_retroachievements` branches on it, and false
  # skips the login entirely and instead removes every credential the
  # namespace's `targets` can name - the account name and token in each
  # target's own config, PPSSPP's whole-file token, and the cached login
  # token. `enable = false` now means the account's credentials come off
  # the box, not merely that their refresh stops.
  raDisabledFiles =
    let
      off =
        ra: keyDef:
        if keyDef ? section then
          { ${keyDef.file}.keys.${keyDef.section}.${keyDef.key} = ra.booleans."false"; }
        else
          { ${keyDef.file}.keys.${keyDef.key} = ra.booleans."false"; };
    in
    lib.foldl' (
      acc: ra:
      lib.recursiveUpdate (lib.recursiveUpdate acc (off ra ra.keys.enabled)) (off ra ra.keys.hardcore)
    ) { } (lib.attrValues raEmulators);
in
{
  options.emubox.retroachievements = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the box logs in to RetroAchievements and writes the
        session token into every supporting emulator's configuration
        before each launch of the frontend. Default true: the
        retroachievements spec's fresh-box scenario is that credentials in
        the secrets store and a working network unlock achievements with
        nobody touching a menu, which only holds if the feature does not
        also need to be switched on first.
      '';
    };

    hardcore = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        The single hardcore switch every supporting emulator's
        configuration follows (retroachievements spec, "Hardcore mode is
        one switch"). Off, the default, keeps save states, rewind and
        cheats available in every supporting emulator.
      '';
    };

    apiUrl = lib.mkOption {
      # Constrained to a URL with a scheme, not a bare `str`: prepare hands
      # this value straight to `urllib.request.urlopen`, which
      # raises `ValueError: unknown url type` on a schemeless host - a
      # hard, unrecoverable prepare failure that strands the box at the
      # greeter (a bug in prepare should stop at a greeter the admin can log
      # into - not the fresh-box, working-network path
      # the retroachievements spec promises to leave achievements-only
      # broken) - and, unconstrained, would also accept `file://`, which
      # `urlopen` follows just as readily as `http(s)://`.
      #
      # `http://` is still accepted, not narrowed to `https://` only,
      # because the VM test points prepare at a plain `python
      # http.server` mock with no TLS - the one place this box is ever
      # meant to run the login over an unencrypted connection, and the
      # documented exception the URL-scheme constraint below was written
      # to allow. An admin who points this at a real `http://` endpoint gets
      # the account password crossing the network in clear text on every
      # prepare run (the `login2` POST carries it) - the
      # description below says so, since the type alone cannot forbid a
      # legitimately reachable but insecure host.
      type = lib.types.strMatching "https?://.*";
      default = "https://retroachievements.org/dorequest.php";
      description = ''
        The RetroAchievements API endpoint `emubox-prepare` posts its
        `login2` request to. An option rather than a literal buried in
        this module, because the VM test points prepare at a
        mock server here instead of patching the module to do it. Must
        start with `http://` or `https://`; an `http://` endpoint carries
        the RetroAchievements account password across the network in
        clear text on every prepare run, so only the VM test's local mock
        server should ever use one.
      '';
    };
  };

  config = {
    environment.systemPackages = [
      retroarchWithCores
      pkgs.ppsspp
      pkgs.dolphin-emu
      pkgs.pcsx2
      pkgs.azahar
      pkgs.scummvm
      pkgs.duckstation
      # For the admin over SSH; the planned `emubox-status` is the only
      # other consumer of this inventory, and it is not built yet.
      pkgs.emubox-check-bios
    ];

    # A stable path, not the inventory's own hash-addressed store path: an
    # admin who has to look up a nix store hash before they can run the
    # checker is exactly the manual step this project avoids everywhere
    # else. `emubox-check-bios /etc/emubox/bios-inventory.json /data/bios`
    # is the whole admin-facing command (no options, no writes - and this file itself is one of `environment.etc`'s writes,
    # not the checker's).
    environment.etc."emubox/bios-inventory.json".source = biosInventoryFile;

    # The performance and hotkey tables always apply; the
    # `enabled`/`hardcore` RetroAchievements keys only get folded in
    # statically here, and only when the feature is off (`raDisabledFiles`)
    # - when it is on, prepare's own `apply_retroachievements` writes them
    # at runtime instead, from `retroachievementsNamespace` below, and this
    # module never touches them directly. Every other RetroAchievements
    # credential - the account name, the token, PPSSPP's whole-file token,
    # the login cache - is prepare's alone either way: written at runtime
    # when the feature is on, removed at runtime when it is off, and never
    # a static key in this table (`raDisabledFiles`'s own comment has the
    # full reasoning for why removal has to be prepare's job).

    emubox.kiosk.ownedFiles = lib.recursiveUpdate {
      "${retroarchConfigFile}" = {
        format = "retroarch";
        keys = {
          video_fullscreen = "true";
          libretro_directory = coresDirectory;
          # The literal "default" is magic in RetroArch's own parser and
          # gets cleared back to empty (configuration.c:4346-4347) - never
          # spell the BIOS directory that way.
          system_directory = biosDirectory;
          # The save-route declaration owns these destinations. Migration is
          # ordered before emubox-prepare writes this file at kiosk startup.
          savefile_directory = "/data/saves/retroarch/saves";
          savestate_directory = "/data/saves/retroarch/states";
          autosave_interval = "30";
          menu_driver = "ozone";
          # Both entries a family could otherwise use to pull unvetted
          # cores or content onto the box over the network - the "Online
          # Updater" submenu and the separate top-level "Core Downloader"
          # shortcut.
          menu_show_online_updater = "false";
          menu_show_core_updater = "false";
          # The uniform hotkey set, uniform across every emulator on purpose.
          # These are *keyboard* key-name strings - RetroArch's separate
          # per-pad `_btn` keys are written by autoconfig per controller,
          # which is controller work still to come, so none appears here
          # on purpose.
          input_menu_toggle = "f1";
          input_save_state = "f2";
          input_load_state = "f4";
          # The toggle variant, not `input_hold_fast_forward`: a
          # press-once switch is the right semantics for a couch box, and
          # RetroArch has no single key that means both.
          input_toggle_fast_forward = "space";
          input_screenshot = "f8";
          # The gamepad-combo counterparts, device-independent (no `_btn`
          # binding needed). Both keys are plain `SETTING_UINT`s against
          # RetroArch's `enum input_combo_type` (configuration.c:2558,2560),
          # whose full membership, read at the pinned v1.22.2 source
          # (`input/input_defines.h:211-225`), is: `NONE`=0,
          # `DOWN_Y_L_R`=1, `L3_R3`=2, `L1_R1_START_SELECT`=3,
          # `START_SELECT`=4, `L3_R`=5, `L_R`=6, `HOLD_START`=7,
          # `HOLD_SELECT`=8, `DOWN_SELECT`=9, `L2_R2`=10, `LAST`=11.
          # The desktop build's own default for both is `INPUT_COMBO_NONE`
          # (config.def.h:939,942) - with nothing pinned here a player who
          # entered a core would have no controller-only way back to the
          # frontend, which is exactly the gap a quit combo exists to close.
          #
          # The two values must differ, and not merely for tidiness.
          # `runloop.c` evaluates them independently against the same frame's
          # button bits: the menu combo sets `RARCH_MENU_TOGGLE`
          # (runloop.c:5648-5653) and the quit combo sets `trig_quit_key`
          # (runloop.c:5889-5895) with no exclusion between them, and the
          # quit block runs first (line 5880 vs. the menu-toggle hotkey's
          # own check at line 6003). Giving both keys `4` therefore made
          # Start+Select quit and left the menu combo dead - one knob doing
          # nothing while looking configured.
          #
          # Menu toggle is `L3_R3` = 2: the two stick clicks share no button
          # with Start+Select, so no single press can satisfy both bindings
          # and the collision cannot come back. That rules out the three
          # values that do share one (`L1_R1_START_SELECT`=3 is a superset
          # of the quit combo, `HOLD_START`=7 and `HOLD_SELECT`=8 each hold
          # one of its two buttons), and among the remaining disjoint ones
          # `L_R`=6 and `L2_R2`=10 are shoulder pairs games press constantly
          # and `DOWN_Y_L_R`=1 needs four buttons at once; L3+R3 is both the
          # least likely to fire mid-game and RetroArch's own default menu
          # combo on the console platforms that have two sticks
          # (config.def.h:930-931). It does need a pad with clickable
          # sticks; a pad without them still reaches the frontend through
          # the quit combo, which is the route the design actually requires.
          input_menu_toggle_gamepad_combo = "2";
          input_quit_gamepad_combo = "4";
        };
      };

      "${dolphinConfigFile}" = {
        format = "ini";
        keys = {
          Display.Fullscreen = "True";
          # "Wii dual core off": Dolphin's own writer emits `True`/`False`
          # capitalized (StringUtil.cpp:290-293); `CPUThread = False` is
          # dual core *off* - the UI's "Enable Dual Core" checkbox is this
          # same key inverted (DolphinQt/Settings/GeneralPane.cpp:144).
          Core.CPUThread = "False";
          # Dolphin's first-run analytics consent dialog, the third
          # instance of the same shape PCSX2's `UI.SetupWizardIncomplete`
          # and DuckStation's `Main.SetupWizardIncomplete` already close:
          # something modal standing between choosing a game and playing
          # it, on a box whose only input device is a controller.
          #
          # Verified at the tag this flake's nixpkgs actually locks,
          # dolphin-emu `2603a` (`pkgs.dolphin-emu.src.rev` is
          # `refs/tags/2603a`):
          #
          # - `Source/Core/DolphinQt/Main.cpp:266-284` shows
          #   `ShowAnalyticsPrompt(&win)` whenever
          #   `!Config::Get(Config::MAIN_ANALYTICS_PERMISSION_ASKED)`. Its
          #   only guard is `#if defined(USE_ANALYTICS) && USE_ANALYTICS`.
          #   Batch mode does NOT skip it: the block immediately below, at
          #   lines 286-291, is the one wrapped in
          #   `if (!Settings::Instance().IsBatchModeEnabled())`, and that
          #   wraps the `Updater`, not this. ES-DE launches Dolphin as
          #   `-b -e %ROM%` (the frontend override table above), so `-b`
          #   buys nothing here.
          # - `Source/Core/DolphinQt/QtUtils/AnalyticsPrompt.cpp:15-41`
          #   is a `ModalMessageBox` with Yes/No and a blocking `exec()`.
          # - `Source/Core/Core/Config/MainSettings.cpp:451-454` declares
          #   `MAIN_ANALYTICS_ENABLED{{System::Main, "Analytics",
          #   "Enabled"}, false}` and `MAIN_ANALYTICS_PERMISSION_ASKED{...
          #   "PermissionAsked"}, false}`, and
          #   `Core/ConfigLoaders/BaseConfigLoader.cpp:129` maps
          #   `System::Main` to `F_DOLPHINCONFIG_IDX`, i.e.
          #   `Dolphin.ini` (`Common/CommonPaths.h:104`) - so these are
          #   `[Analytics] PermissionAsked` / `Enabled` in the file bound
          #   above, both defaulting false.
          # - `CMakeLists.txt:107` is `option(ENABLE_ANALYTICS "..." ON)`
          #   and lines 585-587 turn it into `-DUSE_ANALYTICS=1`. The
          #   locked nixpkgs `dolphin-emu` passes no
          #   `-DENABLE_ANALYTICS=OFF` (its `cmakeFlags` are only
          #   `DISTRIBUTOR`, `DOLPHIN_WC_DESCRIBE`, `DOLPHIN_WC_BRANCH`
          #   and `CMAKE_POLICY_VERSION_MINIMUM`) and carries no patches,
          #   so this flake's build really does compile the prompt in.
          #   This is the check the earlier Azahar comment skipped and had
          #   to be corrected for; it is done here first.
          #
          # `PermissionAsked = True` is what suppresses the dialog.
          # `Enabled = False` is owned alongside it for the same reason
          # ScummVM's `confirm_exit` is: the prompt is the only thing that
          # would ever have set the value, so suppressing the prompt
          # without pinning the answer would leave the box's reporting
          # posture to whatever Dolphin's default happened to be at the
          # next bump. False is also what `ShowAnalyticsPrompt` writes for
          # a "No", so this is the declined answer, stated declaratively.
          # `True`/`False` capitalized, per `Core.CPUThread`'s own citation
          # of `StringUtil.cpp:290-293` above - the same writer emits both.
          Analytics.PermissionAsked = "True";
          Analytics.Enabled = "False";
        };
      };
      # No performance keys of its own - see the comment on
      # `dolphinAchievementsFile` above for why this file exists at all.
      "${dolphinAchievementsFile}" = {
        format = "ini";
        keys = { };
      };

      "${pcsx2ConfigFile}" = {
        format = "ini";
        keys = {
          UI.StartFullscreen = "true";
          # UI.SetupWizardIncomplete: PCSX2/pcsx2 pcsx2-qt/QtHost.cpp
          # (v2.6.3) sets this true whenever the base settings layer is
          # (re)created from nothing, and OR's it into `s_run_setup_wizard`
          # on every startup (`s_run_setup_wizard = s_run_setup_wizard ||
          # GetBoolValue("UI", "SetupWizardIncomplete", false)`) - a check
          # that runs whether or not `-batch` was passed, so the batch flag
          # does not save a fresh box from the wizard's first page (BIOS
          # configuration) blocking every launch until an admin clicks
          # through it. Forcing it false here is the same fix Azahar's
          # `firstStart = false` already applies for the same reason.
          UI.SetupWizardIncomplete = "false";
          # Folders.Bios: PCSX2/pcsx2 pcsx2/Pcsx2Config.cpp (v2.6.3),
          # `EmuFolders::LoadPathFromSettings(si, DataRoot, "Bios", "bios")`
          # reads `[Folders] Bios` and uses it as-is when it is already
          # absolute (`Path::IsAbsolute`), so this literal path needs no
          # relative resolution against PCSX2's own data root. Without this
          # key PCSX2 falls back to its own `bios` folder under its data
          # root, never `/data/bios`, so `emubox-check-bios` reporting OK
          # would not mean PS2 can actually boot a game.
          Folders.Bios = biosDirectory;
          # Native internal resolution. PCSX2 serializes this float with
          # plain `ostringstream` formatting - the shortest decimal, `1`,
          # never `1.000000` - so this exact literal is what has to be
          # asserted, or every launch would see a spurious diff and rewrite
          # the file (Pcsx2Config.cpp:908,1021; INISettingsInterface.cpp).
          "EmuCore/GS".upscale_multiplier = "1";
        };
      };
      # No performance keys of its own - see the comment on
      # `pcsx2SecretsFile` above; only the RA token, when enabled, ever
      # lands here. Kept declared with an empty `keys` table rather than
      # dropped from `ownedFiles` even though nothing here is ever static:
      # prepare's `_target_validation_error` requires every retroachievements
      # target key's `file` to already be a key of the rendered `files` map
      # (emubox_prepare.py), and the pcsx2 target's `token` key names this
      # file - removing the declaration would fail that check the moment RA
      # is enabled, not just leave a spurious-write cost when it is off. The
      # spurious recreate-on-every-launch this empty declaration causes when
      # no token resolves is prepare's to fix (its own file-format editor
      # deciding "no static keys and nothing merged in" means "no write"),
      # not this module's.
      "${pcsx2SecretsFile}" = {
        format = "ini";
        keys = { };
      };

      "${ppssppConfigFile}" = {
        format = "ini";
        keys = {
          Graphics.FullScreen = "True";
          # No suppressible splash or first-run dialog exists in PPSSPP's
          # source to own a "quiet-start" key for, checked rather than
          # skipped: at the locked `pkgs.ppsspp.version` 1.20.4 the only
          # reader of the `FirstRun` setting (`Core/Config.cpp:231`) is
          # `UI/EmuScreen.cpp:397-401`, which shows a self-dismissing OSD
          # toast ("Press ESC to open the pause menu") through `g_OSD.Show`
          # - not a `screenManager()->push` of any dialog, and nothing that
          # blocks the boot it sits inside. So there is no Dolphin- or
          # PCSX2-shaped consent or wizard key to own here.
        };
      };

      "${azaharConfigFile}" = {
        format = "ini";
        # Every Azahar-initiated save also writes a sibling `<key>/default`
        # bool (config.cpp:189-212); on read, `<key>/default = true` makes
        # Azahar *ignore* the literal `key = ...` value and use its
        # compiled default instead (config.cpp:128-134). Forcing
        # `/default = false` alongside every key this module owns is what
        # keeps a value from silently reverting the first time Azahar
        # itself saves the file.
        #
        # The on-disk key is spelled with a BACKSLASH, `key\default`, not
        # the forward slash `key/default` the C++ source uses to build the
        # QSettings key path: Azahar is Qt/QSettings (`config.cpp`'s
        # `qt_config` is a `QSettings`), and QSettings' own IniFormat writer
        # escapes a literal `/` inside a key name to `\` when it flattens a
        # key to an ini line, because `/` is QSettings' own group-nesting
        # separator. Confirmed empirically: `QSettings(path,
        # QSettings.IniFormat)` with `setValue("fullscreen/default", ...)`
        # inside `beginGroup("UI")` writes the line `fullscreen\default=...`
        # to the file, not `fullscreen/default=...`. Writing the forward-
        # slash spelling here only worked by accident - QSettings' *reader*
        # accepts either separator, and prepare seeds a missing key into the
        # section it belongs to, so on a box where Azahar has never
        # itself saved the file this module's `key/default` line came
        # first and was the only one; the moment Azahar wrote its own
        # `key\default` line, both existed and the later one (Azahar's,
        # read last) governed by coincidence, and every further launch
        # would see the mismatched `key/default` line as still unowned by
        # this module's own idempotency check and never clean it up. The
        # backslash spelling is what prepare must actually assert to be
        # the same key QSettings itself reads and writes.
        keys = {
          UI = {
            fullscreen = "true";
            "fullscreen\\default" = "false";
            # Suppresses the first-run welcome/setup flow.
            firstStart = "false";
            "firstStart\\default" = "false";
          };
          # No `[Miscellaneous] check_for_update_on_start` key here, on
          # purpose. A prior version of this comment pinned it, citing
          # azahar-emu/azahar tag "2124" and calling the setting "a real,
          # live setting" - re-verified at the currently locked nixpkgs
          # revision (`pkgs.azahar.version` = "2125.1.2", the exact source
          # `pkgs/by-name/az/azahar/package.nix` fetches), the setting is
          # still there under that same name
          # (`src/citra_qt/uisettings.h:93`) and still read/written by
          # `QtConfig::ReadMiscellaneousValues`/`SaveMiscellaneousValues`
          # (`config.cpp:581,1164`) - but the prior comment never checked
          # whether this flake's build actually compiles any of that in,
          # and it does not. Every one of those call sites, and the one
          # place the value is ever acted on -
          # `if (UISettings::values.check_for_update_on_start)` in
          # `citra_qt.cpp:499` - sits behind `#ifdef
          # ENABLE_QT_UPDATE_CHECKER` (`src/citra_qt/CMakeLists.txt:214-217`
          # gates the `#define` on a CMake option that defaults OFF,
          # `CMakeLists.txt:117`). Upstream's own release CI turns that
          # option on (`.ci/linux.sh:20`); nixpkgs' `azahar` package.nix
          # never passes `-DENABLE_QT_UPDATE_CHECKER=ON` or any equivalent,
          # so this flake's binary has no update-checker code path compiled
          # in at all - there is nothing here for the key to suppress.
          # Writing it anyway would be inert configuration for a feature
          # that cannot run, which is worse than no comment: it would read
          # as this module having verified the setting matters when the one
          # fact that would have shown it does not was never checked. If a
          # future bump ever turns `ENABLE_QT_UPDATE_CHECKER` on - in
          # nixpkgs' package.nix, or by this flake overriding it - this key
          # needs to come back.
        };
      };

      "${duckstationConfigFile}" = {
        format = "ini";
        keys = {
          Main.StartFullscreen = "true";
          # Main.SetupWizardIncomplete: stenzek/duckstation
          # src/duckstation-qt/qthost.cpp (v0.1-11752),
          # `s_state.run_setup_wizard = s_state.run_setup_wizard ||
          # Core::GetBaseBoolSettingValue("Main", "SetupWizardIncomplete",
          # false)` runs on every startup regardless of `-batch` - that flag
          # only sets `s_state.batch_mode`, a separate variable `-setupwizard`
          # is the only command-line switch that touches
          # `run_setup_wizard`. On a config prepare has never seeded before,
          # `InitializeBaseSettingsLayer`'s "neither key present" branch
          # forces this true, so the very first launch would land on the
          # wizard's BIOS page rather than the game the player chose.
          # Forcing it false here is the same fix Azahar's
          # `firstStart = false` already applies for the same reason.
          Main.SetupWizardIncomplete = "false";
          GPU = {
            # "PGXP geometry correction": `PGXPEnable` is the one setting
            # that key names in the design - `PGXPCulling` etc. are
            # distinct add-ons layered on top of it, not part of it.
            PGXPEnable = "true";
            # A 1080p-appropriate upscale: PS1 renders natively around
            # 320x240 (up to 512x480 in hi-res modes), and 4x lands around
            # 1280x960-2048x1920 - close to 1080p without wildly
            # overshooting it. Config data, not a source-verified fact;
            # revisit at the hardware bring-up checklist if it disappoints.
            ResolutionScale = "4";
          };
          # BIOS.SearchDirectory: stenzek/duckstation src/core/settings.cpp
          # (v0.1-11752), `Bios = LoadPathFromSettings(si, DataRoot, "BIOS",
          # "SearchDirectory", "bios")`, and `LoadPathFromSettings` uses the
          # value as-is once `Path::IsAbsolute` is true, so this literal
          # path needs no resolution against DuckStation's own data root.
          # Without this key DuckStation falls back to its hardcoded
          # `$HOME/.local/share/duckstation/bios` (settings.cpp:172's
          # section default plus the `"bios"` fallback), never
          # `/data/bios`, so `emubox-check-bios` reporting OK would not mean
          # PS1 can actually boot a game.
          BIOS.SearchDirectory = biosDirectory;
        };
      };

      "${scummvmConfigFile}" = {
        format = "ini";
        keys = {
          scummvm = {
            fullscreen = "true";
            savepath = "/data/saves/scummvm/saves";
            # No first-run key here, and it was checked rather than
            # skipped. ScummVM 2026.1.0 (the locked `pkgs.scummvm.version`)
            # has exactly one startup-time modal that fires on a config
            # with no prior state: `base/main.cpp:621-625`'s
            # `GUI::UpdatesDialog` ("check for updates?"), shown when
            # `!ConfMan.hasKey("updates_check")`. It is compiled out here.
            # `configure:7291-7301` only defines `USE_UPDATES` when
            # `_sparkle` is `yes`, and `_sparkle` is only ever probed
            # under `case $_host_os in darwin*|mingw*` (configure:5910
            # onward) - on Linux it keeps its `configure:170` initial
            # value `auto`, so `--enable-release` (the one flag nixpkgs
            # passes) setting `_updates=yes` at configure:1584 is undone
            # again at 7295. The guard is doubled anyway:
            # `OSystem::getUpdateManager` (`common/system.h:1781`) returns
            # null on this backend, which the same `if` also requires.
            # `main.cpp:592`'s "Bad config file format. overwrite?" is not
            # a first-run dialog - it needs an already-corrupt config, and
            # prepare's recreate policy is what answers that case.
            #
            # PPSSPP was checked the same way; see its own `keys` block
            # above for the verdict (an OSD toast, not a dialog).
            # Suppresses the "really quit?" confirmation dialog.
            confirm_exit = "false";
            # false is what makes quitting a game exit the process (and so
            # return control to the frontend) instead of bouncing back to
            # ScummVM's own launcher UI - the kiosk has no use for that
            # second launcher ever appearing.
            gui_return_to_launcher_at_exit = "false";
          };
        };
      };
    } (lib.optionalAttrs (!cfg.enable) raDisabledFiles);

    # `modules/kiosk` defines the option itself and owns its
    # empty-means-no-file semantics; this is the one place that ever sets
    # it to a non-empty value on the shipped box.
    emubox.kiosk.customSystems = customSystems;

    # Always a non-null namespace, with `enabled` following `cfg.enable`
    # rather than the namespace itself going null when the feature is off:
    # `username_file`/`password_file`/`api_url` come from options and
    # secrets that exist regardless of whether the feature is on, so there
    # is nothing this object needs that only an enabled box could supply.
    # Rendering `null` when disabled - the shape this used to have - made
    # `emubox-prepare` skip the namespace entirely, which left it with no
    # way to remove the credentials a prior, enabled run had already
    # written; see `raDisabledFiles`'s own comment above for the full
    # reasoning. `emubox-prepare`'s own module docstring covers what
    # `enabled: false` makes it do instead of logging in.
    emubox.kiosk.retroachievementsNamespace = {
      api_url = cfg.apiUrl;
      username_file = config.sops.secrets.retroachievements_username.path;
      password_file = config.sops.secrets.retroachievements_password.path;
      # Relative, so it resolves under the appdata root (the root wipe must
      # not be able to eat it) rather than under `/data` generally, whose
      # backup inclusion is not yet settled.
      cache_file = "retroachievements/token-cache";
      inherit (cfg) hardcore;
      enabled = cfg.enable;
      targets = lib.mapAttrsToList (name: ra: ra // { inherit name; }) raEmulators;
    };
  };
}
