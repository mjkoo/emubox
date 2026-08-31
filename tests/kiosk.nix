# The kiosk test: the host's software modules booted as a plain node with a
# graphical stack, so CI can see the session the install test cannot.
#
# Why a second test rather than more assertions on the first: disko's install
# test starts the installed VM with a hard-coded 1 GB and exposes no memory
# knob, which is why the base layer forces SDDM off there. This node gives up
# the real boot path - no disk layout, no boot loader, no initrd rollback -
# and gets in exchange a memory size, a virtual GPU and a display manager.
# The two tests are complementary and both are enrolled in `nix flake check`:
# the install test owns the boot path, this one owns the session.
#
# What it proves is design D5's coverage table, which is the change's single
# enumeration of what proves each kiosk scenario. An assertion added or
# dropped here starts as an edit there. The emulator and RetroAchievements
# assertions appended at the end of this file are design D7's group instead -
# the vm-test and retroachievements specs' own enumeration of what a fresh
# box proves without hardware.
{ self }:
let
  # The one test hook the session script carries (design D5). A number here,
  # rendered into the node's environment and into the script's waits, so the
  # two cannot drift.
  crashWindow = 30;

  # The host's own package set (nixpkgsConfig, the overlay, unfree cores
  # allowed) rather than a bare `import <nixpkgs> {}`: the same trick
  # flake.nix's own `hostPkgs` uses, so a ROM fixture or the mock server
  # script is built with the exact packages the box itself would see, not a
  # second nixpkgs evaluation that happens to agree with it.
  pkgs = self.nixosConfigurations.emubox.pkgs;
  inherit (pkgs) lib;

  # The document `modules/emulators` actually ships (design D5), read from
  # the real host config rather than this file's own node - whose
  # `emubox.kiosk.customSystems` below is `mkForce`d to a 10-line test
  # document so the kiosk subtests can prove the custom-systems mechanism
  # against something they control (design D7). That `mkForce` is exactly
  # why nothing else in this file, or anywhere else, ever parses the
  # shipped 218-line document - finding IMPORTANT-6's "the shipped
  # custom-systems XML is never parsed by anything". `shippedCustomSystems`
  # exists so the standalone check near the top of `testScript` below can
  # do that, with no VM node needed.
  shippedCustomSystems = self.nixosConfigurations.emubox.config.emubox.kiosk.customSystems;

  # The single source for every plaintext test value (tests/values.nix's own
  # header); `raUsername`/`raPassword` are the mock RetroAchievements
  # account's credentials.
  values = import ./values.nix;

  # design D7's mock RA endpoint (below): a static token and a fixed port.
  # Not a secret - it is server-side data the mock always returns, never a
  # credential read from the secrets store - so it lives here rather than in
  # tests/values.nix, whose header reserves that file for actual test input
  # values.
  mockToken = "emubox-mock-ra-token-0123456789abcdef";
  mockPort = 8080;

  # The mock `login2` endpoint (design D7): a static Python HTTP server, on
  # the node's own loopback interface rather than a second VM node.
  #
  # Design D7 reads "a python HTTP server on the test network"; this project
  # has no KVM anywhere in its own toolchain (VM tests are CI-only, per the
  # repository's own working notes), so a second node's networking - vlans,
  # static addressing, NetworkManager's `unmanaged` interface list to keep it
  # off an interface this project has never exercised together before - is
  # exactly the kind of thing that would have to be debugged blind, one full
  # CI cycle at a time. Loopback and a systemd service this test starts and
  # stops explicitly gets the same three behaviours the specs actually ask
  # for - reachable-with-a-good-login, reachable-with-a-rejection (not used
  # by this change) and unreachable - with no networking surface this
  # project has not already proven elsewhere. `_login2`'s own error handling
  # (emubox_prepare.py) treats a connection refused identically to a routed
  # timeout: both are "unreachable", so the scenario this stands in for is
  # exercised faithfully, just not over a wire.
  mockServerScript = pkgs.writeText "emubox-mock-ra-server.py" ''
    import http.server
    import json

    TOKEN = ${builtins.toJSON mockToken}


    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            self.rfile.read(length)  # the login2 body is never inspected
            body = json.dumps({"Success": True, "Token": TOKEN}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *args):
            pass  # keep the journal free of one line per prepare run


    http.server.HTTPServer(("127.0.0.1", ${toString mockPort}), Handler).serve_forever()
  '';

  # --- Homebrew ROM fixtures (design D7; vm-test spec "Core families launch
  # headless") -----------------------------------------------------------
  #
  # One freely-redistributable ROM per BIOS-free RetroArch core family,
  # fetched by URL and SRI hash as a test-only input - never part of the
  # system closure (design's risk list: "fixtures are test-only inputs, not
  # part of the system closure"). Every hash below was independently
  # re-verified by actually building the `fetchurl`/`fetchzip` expression
  # against the live URL, not copied from a research note on trust; two of
  # them (Virtual Boy, Genesis Plus GX) turned out to need a different hash
  # than a plain `nix-prefetch-url --unpack` reports for the same archive -
  # `fetchzip`'s own unpack normalises permissions slightly differently for
  # those two zips, so the hash that actually matters is the one `fetchzip`
  # itself produces, confirmed by building it. `stripRoot = false` appears
  # wherever the archive is a flat file listing with no single wrapping
  # directory - `fetchzip`'s default strip errors on exactly that shape
  # ("zip file must contain a single file or directory"), confirmed by
  # trying the default first.
  #
  # Two families with no qualifying candidate after two independent searches
  # (below, `exemptFamilies`) are named exempt rather than silently skipped.

  # Shared between the two PC Engine-family cores below: the SuperGrafx core
  # is a PCE-compatible superset and ES-DE's own supergrafx extension list
  # already includes `.pce`, so one HuCard test ROM loads on both.
  pceHuCardTestSuite = "${
    pkgs.fetchzip {
      # GPL-2.0; GPLv2.txt is shipped inside the archive itself (Artemio
      # Urbina's 240p Test Suite, PC Engine HuCard port v1.10).
      url = "https://downloads.sourceforge.net/project/testsuite240p/OldFiles/PCE-TG16-SCD/240pSuite_1.10_HuCard.zip";
      stripRoot = false;
      hash = "sha256-POoV8MjrAxztetq2jxwh19Fp/ykgI1Dv5IcuL9sleq4=";
    }
  }/240pSuite.pce";

  # The zip holds two executables at its root (a Covox DAC build and a
  # PC-speaker build); DOSBox Pure shows an exe-picker menu instead of
  # auto-running when more than one is present, so the fixture is the single
  # PC-speaker build extracted on its own.
  dosboxPureFixture = "${
    pkgs.fetchzip {
      # MIT; the repo's LICENSE file (vsariola/tubiform, a 256-byte
      # demoscene intro released at Lovebyte 2022).
      url = "https://github.com/vsariola/tubiform/releases/download/rc1/tubiform.zip";
      stripRoot = false;
      hash = "sha256-O6nmc2kGp2mYDVCZzYXSh4c8q3p57Kwqz5wzX5fz8qM=";
    }
  }/spkrtubi.com";

  homebrewFixtures = [
    {
      family = "Atari 2600 (Stella)";
      core = "stella_libretro.so";
      rom = pkgs.fetchurl {
        # CC0-1.0; the repository's LICENSE file is the full CC0 legal text
        # (murilomgrosso/Core-Escape, commit 8cdce9b).
        url = "https://raw.githubusercontent.com/murilomgrosso/Core-Escape/8cdce9be1d4df120ba5a8fa3b8608876d287467f/bin/core-escape.asm.bin";
        hash = "sha256-4PZcSDXr/HCatnENeeBKc0HDfeKam7Q5p0DAL3ibDnU=";
      };
    }
    {
      family = "NES (Mesen)";
      core = "mesen_libretro.so";
      rom = pkgs.fetchurl {
        # GPL-2.0-or-later; pinobatch/240p-test-mini v0.23's LICENSE file
        # and its README both state the ports are free software under GPLv2
        # or later.
        url = "https://github.com/pinobatch/240p-test-mini/releases/download/v0.23/240pee.nes";
        hash = "sha256-BPAdc3L2bqK+/jJbm9ZVqfzDlaMfpG2UZihruPnS5i4=";
      };
    }
    {
      family = "GB/GBC (Gambatte)";
      core = "gambatte_libretro.so";
      rom = pkgs.fetchurl {
        # GPL-2.0-or-later, same 240p-test-mini v0.23 project as the NES entry.
        url = "https://github.com/pinobatch/240p-test-mini/releases/download/v0.23/gb240p.gb";
        hash = "sha256-cz625+wHGXUt3V/NpOcVwvLiD0rEvJccS9HUknL5uwQ=";
      };
    }
    {
      family = "GBA (mGBA)";
      core = "mgba_libretro.so";
      rom = pkgs.fetchurl {
        # GPL-2.0-or-later, same 240p-test-mini v0.23 project.
        url = "https://github.com/pinobatch/240p-test-mini/releases/download/v0.23/240pee_mb.gba";
        hash = "sha256-R4RPcUBzigb487wJeA2jqwlVOaJQuHD2FP7tVh2dbzQ=";
      };
    }
    {
      family = "Virtual Boy (Beetle VB)";
      core = "mednafen_vb_libretro.so";
      rom = "${
        pkgs.fetchzip {
          # MIT; the repo's LICENSE file (VUEngine/VUE-MASTER v1.1 demo
          # reel). A single-file zip, so no `stripRoot` override is
          # needed - but its hash, unusually, is NOT what
          # `nix-prefetch-url --unpack` reports for the same URL; the one
          # below is what `fetchzip` itself actually produces, confirmed
          # by building it (see the section comment above).
          url = "https://github.com/VUEngine/VUE-MASTER/releases/download/v1.1/VUE-MASTER-Demo-Reel_v1_1.vb.zip";
          hash = "sha256-9evcGjGfgci4JLTppBI41yjbhve0jB1QDvYOEfRqfv4=";
        }
      }/VUE-MASTER-Demo-Reel_v1_1.vb";
    }
    {
      family = "WonderSwan (Beetle Cygne)";
      core = "mednafen_wswan_libretro.so";
      rom = pkgs.fetchurl {
        # GPL-3.0-or-later; the project's README states it explicitly
        # (asiekierka/240p-test-ws v0.2.4).
        url = "https://github.com/asiekierka/240p-test-ws/releases/download/v0.2.4/144p-test-ws.wsc";
        hash = "sha256-BwXRDdz9B4SGYT9mZl4ANdRCkaf1JtTZcvZe8IPRaV8=";
      };
    }
    {
      family = "SMS/Game Gear/Genesis (Genesis Plus GX)";
      core = "genesis_plus_gx_libretro.so";
      rom = "${
        pkgs.fetchzip {
          # GPL-2.0, same 240p Test Suite project/version family as the
          # SNES and PC Engine entries (GPLv2.txt shipped in sibling
          # archives of the same suite). Its hash also had to be taken
          # from an actual `fetchzip` build rather than
          # `nix-prefetch-url --unpack`, the same VUE-MASTER situation
          # above.
          url = "https://downloads.sourceforge.net/project/testsuite240p/OldFiles/Sega_Genesis-MegaDrive-SegaCD_MegaCD/240pSuite-GenesisMD-1.21.zip";
          stripRoot = false;
          hash = "sha256-IzRRAJct+jrA+O8SLuc0qZ+hV5IlWSo7KoTDFjeE6FQ=";
        }
      }/240pSuite-1.21.bin";
    }
    {
      family = "Sega 32X (PicoDrive)";
      core = "picodrive_libretro.so";
      rom = pkgs.fetchurl {
        # MIT; the repo's LICENSE file (pw32x/barebones32xproject).
        url = "https://github.com/pw32x/barebones32xproject/releases/download/barebones32xproject/project.32x";
        hash = "sha256-fK5LqlSC2ZG84JOSJTu+yktymtXOVsVZLcPfLVMUNxs=";
      };
    }
    {
      family = "PC Engine/TurboGrafx-16 (Beetle PCE Fast)";
      core = "mednafen_pce_fast_libretro.so";
      rom = pceHuCardTestSuite;
    }
    {
      family = "SuperGrafx (Beetle SuperGrafx)";
      core = "mednafen_supergrafx_libretro.so";
      rom = pceHuCardTestSuite;
    }
    {
      family = "DOS (DOSBox Pure)";
      core = "dosbox_pure_libretro.so";
      # A looping demoscene intro with music that never exits on its own;
      # `--max-frames` (the test script, below) is what forces this fixture
      # to a clean exit, which is this design's practical form of "assert
      # liveness over frames rather than expecting a still image".
      rom = dosboxPureFixture;
    }
    {
      family = "C64 (VICE x64)";
      core = "vice_x64_libretro.so";
      rom = pkgs.fetchurl {
        # MIT; the repo's LICENSE file (celso/c64, "C64 Christmas Demo").
        url = "https://raw.githubusercontent.com/celso/c64/e16dcccf6e14d4fb8d0270600a19b4a17d8e587e/card.prg";
        hash = "sha256-j8G4Ud1YgWYM/Lr9aAlwFOFYblql4MWfP9rioyIJUwA=";
      };
    }
  ];

  # Named-exempt core families (vm-test spec: "the configuration SHALL name
  # each exempt family"). `kind` distinguishes the reasons an exemption is
  # allowed here: `"licensing"` (no homebrew ROM for the family carries an
  # explicit licence or redistribution grant, so fetching one through public
  # CI onto the public binary cache is not this project's call to make),
  # `"mechanism"` (the core cannot run headless at all under this test's
  # null-driver override, independent of any ROM - a forced hardware-render
  # context no VM can supply, CI-confirmed for the specific core), and
  # `"unresolved"` (this test observed a launch fail without exiting and
  # does not yet know whether the core or the fixture is at fault - a
  # strictly weaker claim than `"mechanism"`, on purpose: a review round
  # found the SNES entry below filed under `"mechanism"` on evidence that
  # only supports "something is wrong", not "this specific core cannot run
  # headless at all", and its own reason string already conceded the
  # ambiguity before its `kind` did). Every family here moves to the E12
  # hardware checklist instead (design D7: "an exempt family is a hardware
  # checklist item, like the BIOS-dependent cores"), and every entry below
  # also carries `recheck`: honest prose, read by nobody programmatically,
  # stating what would put the family back on the headless-launch side of
  # that line. Nothing else in this repository ever revisits an exemption
  # on its own, so without this field every exemption here is permanent by
  # construction - the field does not fix that on its own, but it is what
  # lets a human looking for stale exemptions know where to start.
  exemptFamilies = [
    {
      family = "Atari 7800 (ProSystem)";
      core = "prosystem_libretro.so";
      kind = "licensing";
      reason = "every compiled .a78 binary found sits in a repo with no LICENSE file and no redistribution statement; every repo with an explicit permissive licence ships source only, with no compiled ROM in the repo or in Releases";
      recheck = "a compiled .a78 ROM appearing (in a repo, or in that repo's Releases) paired with an explicit author licence or redistribution grant - not a third-party 'PD' tag on an existing find, which is cataloguing, not a grant";
    }
    {
      family = "Neo Geo Pocket / Color (Beetle NeoPop)";
      core = "mednafen_ngp_libretro.so";
      kind = "licensing";
      reason = "no NGP/NGPC homebrew was found that combines a real named title, an explicit author licence or redistribution statement, and a stable direct URL; 'PD' tags on individually found ROMs are third-party cataloguing, not author grants";
      recheck = "an NGP/NGPC ROM appearing with an explicit author licence or redistribution grant attached, the same bar the reason above already applies";
    }
    {
      # finding IMPORTANT-2. RetroArch 1.22.2's `video_driver_find_driver`
      # (`gfx/video_driver.c`) begins with `if
      # (video_driver_is_hw_context())` and then forces the HW-render-
      # capable driver, overwriting `video_driver` and logging "[Video]
      # Using HW render, ... driver forced." - discarding this test's
      # `video_driver = "null"` override for any core that requests a HW
      # render context. Confirmed on the x86_64-linux remote builder by
      # actually running `retroarch -L mupen64plus_next_libretro.so
      # <homebrew ROM> --appendconfig <the exact override set below>
      # --max-frames 60 --verbose` outside a VM: the log carries "[Video]
      # Using HW render, glcore driver forced." and the process then
      # segfaults (exit 139) trying to bind a GL context with no display
      # server, DRM device or `XDG_RUNTIME_DIR` present - the same headless
      # conditions this VM node's launches run under. `drivers_init` runs
      # after `CMD_EVENT_CORE_INIT`, so the positive marker this test's loop
      # looks for ("[Core] Geometry:") is already logged by the time this
      # happens; only the later video-driver failure is what would fail the
      # run.
      family = "N64 (Mupen64Plus-Next)";
      core = "mupen64plus_next_libretro.so";
      kind = "mechanism";
      reason = "forced to the glcore HW-render driver regardless of the null video_driver override, and glcore then segfaults (exit 139) in a headless environment with no display server, DRM device or XDG_RUNTIME_DIR - confirmed by reproducing the exact launch on the x86_64-linux remote builder outside a VM";
      recheck = "a headless GL path this VM's null-driver setup could satisfy - a software or off-screen GL context glcore would accept in place of a real display server, DRM device or XDG_RUNTIME_DIR";
    }
    {
      # Same mechanism as N64 above, reproduced the same way: Flycast
      # requests a Vulkan HW render context, RetroArch logs "[Video] Using
      # HW render, vulkan driver forced." and then fails cleanly with
      # "[ERROR] [Video] Cannot open video driver. Exiting..." (exit 1) for
      # want of a display server, rather than crashing the way the N64 core
      # does.
      family = "Dreamcast (Flycast)";
      core = "flycast_libretro.so";
      kind = "mechanism";
      reason = "forced to the vulkan HW-render driver regardless of the null video_driver override, and then exits with \"Cannot open video driver\" (exit 1) in a headless environment with no display server - confirmed by reproducing the exact launch on the x86_64-linux remote builder outside a VM";
      recheck = "a headless GL path this VM's null-driver setup could satisfy - the same shape of fix as N64's above, for Flycast's Vulkan requirement instead of glcore's";
    }
    {
      # CI has proven this one directly, not by the same forced-HW-render
      # mechanism as the three `"mechanism"` entries above: the
      # 240pSuite.sfc launch hangs under Snes9x rather than exiting, and CI
      # run 33359693788 killed it at the launch subtest's own 60 s
      # per-launch cap with exit 124. In an earlier run, before that
      # per-launch timeout existed, the same hang consumed the driver's
      # entire one-hour global timeout instead.
      #
      # `kind = "mechanism"` here was a review finding, not this entry's
      # original spelling: a hang killed at a timeout is evidence that
      # *something* is wrong, not evidence of *what* - unlike N64,
      # Dreamcast and Vectrex, nothing here pins the failure to
      # `video_driver_find_driver` or to any other specific mechanism this
      # test's override cannot reach, and this reason string already said
      # so ("specific to this core (or this particular port)") while the
      # `kind` field claimed otherwise. `"unresolved"` is the honest
      # spelling: it hung and was killed at the cap, and that is the whole
      # of what CI has actually shown. Mesen's fixture above is a port of
      # the same 240p Test Suite and passes, which rules out the suite
      # itself as the cause and narrows the remaining question to "this
      # core" vs. "this specific port of it" - not further than that.
      family = "SNES (Snes9x)";
      core = "snes9x_libretro.so";
      kind = "unresolved";
      reason = "the 240pSuite.sfc launch hangs rather than exiting and was killed at the launch subtest's 60 s per-launch cap with exit 124 in CI run 33359693788 (an earlier run, before that per-launch timeout existed, saw the same hang consume the driver's entire one-hour global timeout instead); it is not known whether the Snes9x core or this particular fixture/port is at fault - Mesen passes on the same 240p Test Suite, which rules out the suite itself but not which of the other two it is";
      recheck = "trying a second, licence-clean 240p-style fixture against Snes9x - a second hang would implicate the core; a clean run would implicate the first fixture or its port instead";
    }
    {
      # A builder sweep (x86_64-linux remote builder, not CI) found vecx
      # segfaults with "[Video] Using HW render, OpenGL driver forced." in
      # its log - the identical signature already confirmed in CI for N64
      # and Dreamcast above, where `video_driver_find_driver` forces a real
      # GL driver whenever a core sets a hardware render context, discarding
      # this test's null-driver override. That sweep is otherwise unusable
      # (it ran past the audio-init stage that later invalidates its
      # results), but this failure fires before that stage, and the
      # mechanism itself is already CI-confirmed for two other cores - which
      # is what makes it credible despite the sweep's other results not
      # being.
      #
      # What makes this specific observation trustworthy, stated plainly
      # rather than left implicit in "before that stage": the same sweep's
      # own controls - Stella (the Atari 2600 core `homebrewFixtures` above
      # already proves headless-clean) and Mesen (same, for NES) - aborted
      # LATER in the sweep, at the audio-init stage itself, not before it.
      # A sweep whose video stage was already broken would have taken down
      # Stella and Mesen at the same point vecx failed, or earlier; instead
      # they got past video and only fell over at audio, which is what
      # establishes the sweep's video stage was healthy at the moment vecx
      # hit it. vecx failing where two known-good controls did not fail
      # yet is the differential that makes this one result usable out of an
      # otherwise-discarded run, not just an assertion that it happens to
      # fire early.
      family = "Vectrex (vecx)";
      core = "vecx_libretro.so";
      kind = "mechanism";
      reason = "observed on the x86_64-linux remote builder, not in CI, during a sweep that is otherwise unusable - but the failure fires before the audio-init stage that invalidates the rest of that sweep, and its own controls (Stella, Mesen - both known headless-clean from homebrewFixtures above) got past video and only aborted at that later audio stage, which is what shows the sweep's video stage was still healthy when vecx hit it; it also carries the same forced-HW-render signature (\"[Video] Using HW render, OpenGL driver forced.\") already CI-confirmed for N64 and Dreamcast above";
      recheck = "confirming this in CI once a KVM runner exists for this project - the builder sweep is credible but was never a CI run, unlike N64 and Dreamcast's confirmations above";
    }
  ];

  # Named BIOS-dependent core families (design's system table's "yes" BIOS
  # rows whose assigned emulator is a RetroArch core, minus any core that
  # also serves a BIOS-free system and so is already reachable through a
  # `homebrewFixtures` entry above: Mesen covers both NES and FDS, Beetle
  # PCE Fast covers both PC Engine and PCE CD, Genesis Plus GX covers both
  # Genesis and Sega CD - one fixture per shared core, not two). Every core
  # `modules/emulators` bundles lands in exactly one of `homebrewFixtures`,
  # `exemptFamilies` or this list; the point of naming BIOS-dependent cores
  # here rather than leaving them merely absent from the other two lists is
  # that the "every installed core is accounted for" assertion below
  # (finding IMPORTANT-3) can then fail loudly the moment a core is added to
  # the bundle and left off all three, instead of the new family quietly
  # going untested and unnoticed. Confirmed against the actual installed
  # core filenames by building `retroarchWithCores` (below) on the
  # x86_64-linux remote builder and listing its cores directory - not typed
  # from the design table's emulator names, which name the emulator, not
  # the core's `.so` file.
  biosDependentCores = [
    "handy_libretro.so" # Atari Lynx
    "mednafen_saturn_libretro.so" # Saturn
    "mednafen_psx_hw_libretro.so" # PS1 alternate (DuckStation is the default)
    "fbneo_libretro.so" # Arcade
    "melonds_libretro.so" # Nintendo DS
    "puae_libretro.so" # Amiga
    "bluemsx_libretro.so" # MSX, ColecoVision
    "freeintv_libretro.so" # Intellivision
  ];
in
assert lib.assertMsg (lib.length homebrewFixtures == 12) ''
  tests/kiosk.nix: expected 12 pinned homebrew fixtures (the vm-test spec's
  core-family coverage minus the six families now exempt - two for
  licensing, N64 and Dreamcast for the forced-HW-render mechanism (finding
  IMPORTANT-2), Vectrex for the same mechanism (builder-sweep evidence),
  and SNES for an unresolved core-or-fixture hang, CI-observed), got
  ${toString (lib.length homebrewFixtures)}.
'';
assert lib.assertMsg (lib.length exemptFamilies == 6) ''
  tests/kiosk.nix: expected 6 named-exempt core families (2 licensing, 3
  mechanism, 1 unresolved), got ${toString (lib.length exemptFamilies)}.
'';
# MINOR finding: the count message just above claims a specific partition
# by `kind` (2 licensing, 3 mechanism, 1 unresolved) that nothing checked -
# `kind` and `reason` are never read by any assertion in this file, so a
# future edit that changes an entry's `kind` without updating that prose
# would leave a message that is simply wrong. This makes it true by
# construction: change the partition, and this assertion's own message
# (not just the one above) fails until both are updated together.
assert lib.assertMsg
  (
    let
      countKind = kind: lib.count (f: f.kind == kind) exemptFamilies;
    in
    countKind "licensing" == 2 && countKind "mechanism" == 3 && countKind "unresolved" == 1
  )
  ''
    tests/kiosk.nix: the exempt-family count message above claims 2
    licensing, 3 mechanism and 1 unresolved, but the actual partition by
    `kind` is licensing=${toString (lib.count (f: f.kind == "licensing") exemptFamilies)},
    mechanism=${toString (lib.count (f: f.kind == "mechanism") exemptFamilies)},
    unresolved=${toString (lib.count (f: f.kind == "unresolved") exemptFamilies)}.
    Update the message above and this assertion together.
  '';
{
  name = "emubox-kiosk";

  # DuckStation's token-decrypt round-trip (design D3, D7) is written from
  # scratch in the test script below rather than imported from
  # emubox_prepare.py - the whole point of an independent implementation -
  # so it needs its own `cryptography` in the driver's own Python, not the
  # guest's.
  extraPythonPackages = ps: [ ps.cryptography ];

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        self.nixosModules.emubox
        ../hosts/emubox/facts.nix
      ];

      system.stateVersion = "26.05";

      # No disko layout and no boot loader here, so the initrd units that
      # roll the root subvolume back and bind /persist have nothing to act
      # on. Their behaviour is the install test's subject, not this one's.
      #
      # `suppressedUnits`, emphatically not `services.<name>.enable = false`:
      # `enable = false` *masks* a unit (a symlink to /dev/null) but still
      # emits its `.requires` links, and `modules/persistence` declares
      # `requiredBy = [ "sysroot.mount" ]` and `requiredBy =
      # [ "initrd-nixos-activation.service" ]`. systemd refuses to enqueue a
      # job that Requires= a masked unit, so sysroot.mount would fail, the
      # initrd would drop to emergency, and the test node would never boot.
      boot.initrd.systemd.suppressedUnits = [
        "rollback-root.service"
        "persist-dirs.service"
        "persist-machine-id.service"
      ];

      # Memory-backed stand-ins for the two subvolumes the layout would
      # provide. neededForBoot because impermanence binds directories under
      # /persist before the switch to the real root.
      fileSystems."/persist" = {
        device = "tmpfs";
        fsType = "tmpfs";
        neededForBoot = true;
      };
      fileSystems."/data" = {
        device = "tmpfs";
        fsType = "tmpfs";
        neededForBoot = true;
      };

      # The committed test host key decrypts secrets/test.yaml, as the
      # install test does. Both mkForce, because modules/secrets defines the
      # same options for the box.
      sops = {
        defaultSopsFile = lib.mkForce ../secrets/test.yaml;
        age.sshKeyPaths = lib.mkForce [ ./test_host_ed25519_key ];
      };

      # No host key is injected here, so sshd's key generation would fail on
      # every run. Nothing in this test asserts on it.
      services.openssh.enable = lib.mkForce false;

      # SDDM, cage and ES-DE under llvmpipe. 2 GB and a virtio GPU are what
      # nixpkgs' own cage test uses; both are one-line adjustments if the
      # frontend turns out to need more.
      #
      # Bumped to 3 GB for emulators-retroachievements (design D7 explicitly
      # allows this): the RetroArch and standalone launches appended at the
      # end of this test run one process at a time, after the kiosk session
      # is already up (cage + es-de stay resident throughout), so the extra
      # headroom only has to cover one emulator's peak footprint on top of
      # the session, not the sum of all of them. Chosen without a way to
      # measure on real hardware - VM tests are CI-only for this project -
      # so a generous, round bump rather than a tightly tuned one; a second
      # node was the other option design D7 named, and was rejected because
      # it would double this test's boot cost in CI for every run, not just
      # the ones that touch emulators.
      virtualisation.memorySize = 3072;
      virtualisation.qemu.options = [ "-vga none -device virtio-gpu-pci" ];

      # The one test hook the session script carries. SDDM's PAM stack
      # exports environment.sessionVariables into the `player` session, so
      # the module needs no knowledge of tests. The value answers two
      # opposing constraints: the relaunch subtest needs one run longer than
      # the window before its kill, and the greeter subtest needs three runs
      # each shorter than it. 30 s rather than the 10 s first written here,
      # because `started=$SECONDS` is set before `cage -- es-de`, so a run's
      # measured length includes cage's wlroots and DRM initialisation and
      # ES-DE's start under llvmpipe; at 10 s a slow runner could push a
      # killed run past the window and stop it counting as a crash. Both
      # constraints scale with the value, so the cost of the larger number is
      # only the seconds the relaunch subtest waits out. The box's figure
      # stays the kiosk spec's unconditional 60 s.
      environment.sessionVariables.EMUBOX_CRASH_WINDOW = toString crashWindow;

      # ES-DE with no game files at all shows a "no game files were found"
      # screen and keeps running, which is all this test needs - but every
      # assertion here hangs off the frontend staying up, so one dummy file
      # removes the dependency on that behaviour rather than trusting it.
      systemd.tmpfiles.rules = [
        "d /data/roms/emuboxtest 0755 player player -"
        "f /data/roms/emuboxtest/dummy.test 0644 player player -"
      ];

      # Deliberately not ES-DE's default: a passkey assertion against the
      # default would pass whether or not the option is wired to anything.
      emubox.kiosk.passkey = "ablrablrud";

      # A complete es_systems.xml document, <systemList> wrapper included,
      # because the module writes the option verbatim and adds no wrapper.
      #
      # mkForce, load-bearing since emulators-retroachievements: `modules/emulators`
      # now contributes its own (non-empty) definition of this same option
      # (design D5), so two plain definitions would conflict and the kiosk
      # check would stop evaluating. This node deliberately proves the
      # custom-systems mechanism against a document it controls, not against
      # the shipped override list - design D7.
      emubox.kiosk.customSystems = lib.mkForce ''
        <?xml version="1.0"?>
        <systemList>
          <system>
            <name>emuboxtest</name>
            <fullname>emubox test system</fullname>
            <path>/data/roms/emuboxtest</path>
            <extension>.test</extension>
            <command>/bin/true %ROM%</command>
            <platform>test</platform>
            <theme>emuboxtest</theme>
          </system>
        </systemList>
      '';

      # design D7: prepare's login2 call is pointed at the mock server
      # above instead of the real service, with no patching. The service
      # itself starts stopped (below) - the test script starts it only for
      # the subtests that need a reachable endpoint - so every boot and
      # relaunch before that point in the test genuinely has no route to
      # it, which is what proves the offline-with-no-cache scenario without
      # a second, dedicated boot.
      emubox.retroachievements.apiUrl = "http://127.0.0.1:${toString mockPort}/dorequest.php";

      systemd.services.emubox-mock-retroachievements = {
        description = "Mock RetroAchievements login2 endpoint for the kiosk VM test (design D7)";
        # No `wantedBy`: this unit is never started at boot. The test script
        # starts and stops it explicitly, which is what makes "no route to
        # the endpoint" and "a reachable endpoint" both provable from the
        # same node.
        serviceConfig = {
          ExecStart = "${pkgs.python3.interpreter} ${mockServerScript}";
          Restart = "always";
          DynamicUser = true;
        };
      };
    };

  testScript =
    { nodes }:
    let
      inherit (nodes.machine.emubox.kiosk)
        appdataDir
        ownedValuesFile
        passkey
        customSystems
        ;
      inherit (nodes.machine.emubox.retroachievements) apiUrl;
      inherit (nodes.machine.users.users.player) home;
      py = builtins.toJSON;

      # The store path `modules/kiosk`'s own `customSystemsPath` computes
      # internally for this exact node (same `writeText` name, same
      # content) - recomputed here rather than exposed as a new option,
      # since this is the only place outside that module that ever needs a
      # custom-systems argument for a manual `emubox-prepare` invocation,
      # and it has to be the real one: passing "" here instead would repeat
      # the existing "empty definition removes the file" subtest by
      # accident, which is not what any of the group 5 subtests below are
      # about.
      customSystemsPath = pkgs.writeText "emubox-es_systems.xml" customSystems;
    in
    ''
      import base64
      import hashlib
      import json
      import re
      import shlex
      import xml.etree.ElementTree as ET

      from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

      APPDATA = ${py appdataDir}
      OWNED_VALUES = ${py ownedValuesFile}
      SETTINGS = f"{APPDATA}/settings/es_settings.xml"
      CUSTOM_SYSTEMS = f"{APPDATA}/custom_systems/es_systems.xml"
      CUSTOM_SYSTEMS_PATH = ${py customSystemsPath}
      PLAYER_HOME = ${py home}

      RA_API_URL = ${py apiUrl}
      RA_USERNAME = ${py values.raUsername}
      RA_PASSWORD = ${py values.raPassword}
      MOCK_TOKEN = ${py mockToken}

      # finding IMPORTANT-6: the document `modules/emulators` actually ships,
      # distinct from this node's own `emubox.kiosk.customSystems` (below,
      # `mkForce`d to a 10-line test document) - see `shippedCustomSystems`'s
      # own comment at the top of this file for why the two have to differ.
      SHIPPED_CUSTOM_SYSTEMS = ${py shippedCustomSystems}

      def esde_pids():
          rc, out = machine.execute("pgrep -x es-de")
          return [int(p) for p in out.split()] if rc == 0 else []

      def session_on_seat(user):
          """Is `user` holding an active session on seat0?

          `loginctl show-seat`/`show-session` rather than column indices into
          `list-sessions`, so a future column does not silently change what
          this reads.
          """
          rc, sid = machine.execute("loginctl show-seat seat0 -p ActiveSession --value")
          sid = sid.strip()
          if rc != 0 or not sid:
              return False
          rc, out = machine.execute(f"loginctl show-session {sid} -p Name -p Active --value")
          if rc != 0:
              return False
          fields = out.split()
          return fields[:2] == [user, "yes"] or fields[:2] == ["yes", user]

      def ancestry(pid):
          """The comm of every ancestor of `pid`, read in one guest command.

          One command rather than a `ps` per level: a process exiting between
          two round trips would otherwise fail the test rather than answer it.
          """
          # `line=$(...) || break` rather than testing readability first: the
          # process can exit between the test and the read, and under the
          # driver's `set -e` that would fail the command instead of ending
          # the walk, which is the opposite of the point.
          script = (
              "p=" + str(pid) + "; chain=; "
              "while [ \"$p\" -gt 1 ]; do "
              "line=$(awk '{print $2, $4}' /proc/$p/stat 2>/dev/null) || break; "
              "[ -n \"$line\" ] || break; "
              "set -- $line; "
              "chain=\"$chain $1\"; p=$2; "
              "done; echo \"$chain\""
          )
          return machine.succeed(script).split()

      def settings_elements():
          # ES-DE writes a rootless forest of typed elements, so the body is
          # wrapped before parsing (the same shape emubox-prepare reads).
          text = machine.succeed(f"cat {SETTINGS}")
          body = re.sub(r"^\s*<\?xml[^>]*\?>", "", text, count=1)
          return {
              e.get("name"): (e.tag, e.get("value"))
              for e in ET.fromstring(f"<r>{body}</r>")
          }

      def ini_value(text, section, key):
          """The value of one `key = value` line, or None if it is absent.

          `section=None` reads a sectionless file (RetroArch's flat config)
          by never leaving the "in section" state; otherwise only lines
          under the matching `[section]` header count, mirroring
          emubox-prepare's own `_ini_section_bounds` shape without importing
          it - this is a plain reader, not the independent-implementation
          concern (that is the DuckStation decrypt below).
          """
          in_section = section is None
          for line in text.splitlines():
              stripped = line.strip()
              if stripped.startswith("[") and stripped.endswith("]"):
                  in_section = stripped[1:-1] == section
                  continue
              if not in_section or "=" not in stripped:
                  continue
              k, _, v = stripped.partition("=")
              if k.strip() == key:
                  return v.strip()
          return None

      def resolve(root, value):
          """A path from the retroachievements namespace, root-relative or
          absolute - the same convention emubox_prepare.py's `_resolve_path`
          uses."""
          return value if value.startswith("/") else f"{root}/{value}"

      def owned_file_value(fmt, text, section, key):
          """The on-disk value for one owned key of an emulator config file
          (finding IMPORTANT-5), in the same string form the rendered
          owned-values JSON carries for it: `ini`'s writer never quotes
          (`emubox_prepare.py`'s `_render_ini`, `f"{k} = {v}"`), so the
          value read back needs no unwrapping there, but `retroarch`'s own
          flat format always quotes (`_render_retroarch`, `f'{key} =
          "{value}"'`), the same quoting `read_target_value` above already
          strips for the retroachievements namespace's plain-encoded
          targets.
          """
          value = ini_value(text, section, key)
          if fmt == "retroarch":
              return value if value is None else value.strip('"')
          return value

      def read_target_value(target, key_name):
          """The on-disk value for one retroachievements target's key.

          None if the target's table does not declare this key at all (e.g.
          "token" for the ppsspp target, which carries it in `token_file`
          instead), if the file does not have it written, or if the file
          itself does not exist at all. That last case is not a special
          case bolted on for one finding: a target's `keys` table only
          records where a value would live if it were ever written, and a
          file with nothing ever written to it - PCSX2's `secrets.ini`
          before any token has resolved, say, the file its only owned key
          is `token` - simply is not there yet, which this function's own
          docstring already treats the same as "does not have it written".
          RetroArch's flat format quotes its values; every other declared
          format here is `ini`, so the two are told apart by whether the
          entry carries a `section`, exactly as emubox_prepare.py's own
          validation does.
          """
          entry = target["keys"].get(key_name)
          if entry is None:
              return None
          rc, text = machine.execute(f"cat {resolve(APPDATA, entry['file'])}")
          if rc != 0:
              return None
          if "section" in entry:
              return ini_value(text, entry["section"], entry["key"])
          value = ini_value(text, None, entry["key"])
          return value if value is None else value.strip('"')

      def duckstation_decrypt(machine_id, username, ciphertext_b64):
          """The plaintext DuckStation v0.1-11752 would recover from
          `Cheevos.Token` - a second, from-scratch implementation of design
          D3's scheme (SHA-256 over the machine-id file's raw bytes and the
          username, 100 further rounds, AES-128-CBC with key = digest[0:16]
          and IV = digest[16:32], zero padding, base64), written without
          reading emubox_prepare.py's own encrypt_duckstation_token so a
          real scheme mismatch fails loudly instead of both sides agreeing
          with themselves. Verified locally against a fixed vector computed
          from prepare's own implementation before this file was committed:
          machine_id=b"deadbeefdeadbeefdeadbeefdeadbeef\\n",
          username="emubox-test-ra", token="emubox-mock-ra-token-0123456789abcdef"
          encrypts to "wsbpyqL9fPkm7teZx7BEZQ4FgEhRYZEC9uA8O2L6meiaDe2kFWrXHd1xX7k9h39f",
          and this function recovers the same token from it.
          """
          digest = hashlib.sha256(machine_id + username.encode()).digest()
          for _ in range(100):
              digest = hashlib.sha256(digest).digest()
          key, iv = digest[:16], digest[16:32]
          ciphertext = base64.b64decode(ciphertext_b64)
          decryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
          plaintext = decryptor.update(ciphertext) + decryptor.finalize()
          # DuckStation zero-pads to a 16-byte boundary rather than PKCS#7
          # (design D3), so the padding is stripped the same way.
          return plaintext.rstrip(b"\x00").decode()

      def rerun_prepare(owned_values_path):
          """Re-run prepare as `player` against a given owned-values JSON,
          with the real custom-systems path (not the empty-removal one the
          "empty definition" subtest above uses)."""
          cmd = (
              f"ESDE_APPDATA_DIR={APPDATA} emubox-prepare "
              f"{owned_values_path} {CUSTOM_SYSTEMS_PATH}"
          )
          machine.succeed(f"su player -s /bin/sh -c {shlex.quote(cmd)}")

      def sweep_for_password(owned):
          """Every file the flake owns a value in, plus the two credential
          files prepare writes outside that map (the ppsspp token file, the
          login cache) - none of them may ever contain the account
          password. A missing file (the cache before any successful login)
          is not an error here; there is simply nothing to check yet."""
          paths = {resolve(APPDATA, relative) for relative in owned["files"]}
          ra = owned["retroachievements"]
          paths.add(resolve(APPDATA, ra["cache_file"]))
          for target in ra["targets"]:
              if target.get("token_file"):
                  paths.add(resolve(APPDATA, target["token_file"]))
          for path in paths:
              rc, out = machine.execute(f"cat {shlex.quote(path)}")
              if rc == 0:
                  assert RA_PASSWORD not in out, f"{path} contains the RA password"

      # --- emulators: the shipped custom-systems document parses (design D5,
      # finding IMPORTANT-6) -------------------------------------------------
      #
      # No node, no boot: this runs on the driver host, before
      # `machine.wait_for_unit` below ever touches the VM, because the
      # `mkForce` on this node's own `emubox.kiosk.customSystems` (further
      # down this file) is deliberate for what the kiosk subtests prove, and
      # that leaves the 218-line document `modules/emulators` actually
      # contributes to a real box unparsed by anything else in this
      # repository. A malformed `<system>` block in it would otherwise
      # surface only as a file ES-DE silently ignores on hardware.
      with subtest("The shipped custom-systems document is well-formed and PS1 offers DuckStation first"):
          root = ET.fromstring(SHIPPED_CUSTOM_SYSTEMS)
          assert root.tag == "systemList", root.tag
          # No hard-coded system count: a concurrent change to
          # `modules/emulators` is adding `tg16`/`tg-cd` overrides, and a
          # count pinned here would just be one more thing to update for an
          # addition this test does not otherwise care about.
          systems = {s.findtext("name"): s for s in root.findall("system")}
          psx = systems.get("psx")
          assert psx is not None, sorted(systems)
          commands = psx.findall("command")
          assert commands, "psx system has no <command> at all"
          first_label = commands[0].get("label") or ""
          assert "DuckStation" in first_label, first_label
          labels = [c.get("label") or "" for c in commands]
          assert any("Beetle PSX HW" in label for label in labels), labels

      machine.wait_for_unit("multi-user.target")

      # --- vm-test: the session comes up ------------------------------------

      with subtest("Display manager is up and player holds the seat's session"):
          machine.wait_for_unit("display-manager.service")
          # Autologin proved by the session itself, not by the greeter's
          # absence: an active `player` session on seat0 is what "autologin
          # happened" actually means.
          retry(lambda _: session_on_seat("player"), timeout_seconds=120)

      with subtest("es-de runs inside the cage compositor"):
          # 120 s is this test's budget, chosen with headroom for ES-DE
          # starting under llvmpipe. It is not the box's figure, which stays
          # the kiosk spec's 60 s and is measured on hardware at bring-up.
          machine.wait_until_succeeds("pgrep -x es-de", timeout=120)
          chain = ancestry(esde_pids()[0])
          assert any("cage" in name for name in chain), chain

      with subtest("The crash window reached the session"):
          # Asserted rather than assumed: if environment.sessionVariables did
          # not reach the session the window would silently stay at 60, and
          # both timing subtests below would fail for a reason that points
          # nowhere near the cause.
          # Read off the frontend, not off cage: nixpkgs ships cage through a
          # wrapper, so its `comm` is `.cage-wrapped` and `pgrep -x cage`
          # matches nothing (which is how this assertion first failed in CI,
          # on `/proc//environ`). The frontend inherits the session's
          # environment just the same, and `pgrep -x es-de` already works.
          environ = machine.succeed(
              f"tr '\\0' '\\n' < /proc/{esde_pids()[0]}/environ"
          )
          assert "EMUBOX_CRASH_WINDOW=${toString crashWindow}" in environ, environ

      # --- kiosk: the settings the flake owns -------------------------------

      with subtest("Every owned key holds the flake's value"):
          # Two assertions, and they check different things. The first pins
          # the table itself against the spec's enumeration; the second walks
          # the settings file the frontend will read and checks it carries
          # what the table says. Neither alone is enough: the table could be
          # right and unapplied, or applied and wrong.
          owned = json.loads(machine.succeed(f"cat {OWNED_VALUES}"))
          # The document's shape itself is pinned here: `files` carries what
          # this test already checked. `retroachievements` is never null on
          # a shipped box (N2 fix: a null namespace would make prepare skip
          # credential removal along with the login, which is not what
          # switching the feature off is supposed to do to a token already
          # on disk) - `modules/emulators` always renders it, with its own
          # `enabled` field following `emubox.retroachievements.enable`
          # (default true, and this node never overrides it). Only the
          # namespace's own shape is pinned here - the api_url this node
          # set, the declared-off hardcore default, `enabled` itself, and
          # which five emulators own a target - not every key spelling,
          # which is what test_emubox_prepare.py's own unit tests already
          # pin per encoding (design D4: "verified at apply time").
          ra = owned["retroachievements"]
          assert ra is not None, owned["retroachievements"]
          assert ra["api_url"] == RA_API_URL, ra["api_url"]
          assert ra["hardcore"] is False, ra["hardcore"]
          assert ra["enabled"] is True, ra["enabled"]
          target_names = {t["name"] for t in ra["targets"]}
          assert target_names == {"retroarch", "dolphin", "pcsx2", "ppsspp", "duckstation"}, target_names

          keys = owned["files"]["settings/es_settings.xml"]["keys"]

          # Pinned here, literally, and deliberately not derived from the
          # module: the loop below compares the settings file against this
          # same rendered JSON, so on its own it would pass for whatever the
          # module happened to render, and dropping an owned key would break
          # no check anywhere. This is the kiosk spec's own enumeration -
          # "kiosk UI mode, the unlock sequence, the ROM and media
          # directories under /data, the theme, the en_US language and the
          # quit menu enabled" - so a key leaving the module has to be a
          # deliberate edit here too.
          assert keys == {
              "UIMode": {"type": "string", "value": "kiosk"},
              "UIMode_passkey": {"type": "string", "value": ${py passkey}},
              "ROMDirectory": {"type": "string", "value": "/data/roms"},
              "MediaDirectory": {"type": "string", "value": "/data/media"},
              "Theme": {"type": "string", "value": "linear-es-de"},
              "ApplicationLanguage": {"type": "string", "value": "en_US"},
              "ShowQuitMenu": {"type": "bool", "value": "true"},
          }, keys

          got = settings_elements()
          for name, spec in keys.items():
              assert got.get(name) == (spec["type"], spec["value"]), (
                  f"{name}: {got.get(name)} != {(spec['type'], spec['value'])}"
              )
          # Named separately because this is what proves the option is wired
          # rather than that ES-DE's own default happens to be in the file.
          assert got["UIMode_passkey"] == ("string", ${py passkey}), got["UIMode_passkey"]
          assert got["UIMode"] == ("string", "kiosk"), got["UIMode"]

      # PINNED_OWNED_KEYS: finding IMPORTANT-5. The emulators spec's
      # headline requirement - the owned values "SHALL pin at least" the
      # core directory, `/data/bios`, the 30 s autosave interval,
      # fullscreen, the two online/core-download menu entries disabled and
      # the uniform hotkey set for RetroArch, and fullscreen plus each
      # standalone's own performance choice for every standalone - was
      # unasserted by anything before this: the ES-DE settings file above
      # had its own pin-then-walk, but it was never extended to the ~150
      # keys `modules/emulators` owns across RetroArch and five
      # standalones. A literal, hand-typed subset here, not the loop's own
      # source of truth: dropping one of these keys from the module is
      # still a deliberate edit to this test (the same "the table could be
      # right and unapplied, or applied and wrong" reasoning the ES-DE pin
      # above already applies). `None` in place of a section name is
      # RetroArch's own flat, sectionless format (`ini_value`'s own
      # convention above).
      #
      # A later review round found this table guarded key PRESENCE only -
      # `names - actual.keys()` - never the value sitting behind a present
      # name. That is exactly the shape of the two shipped Criticals this
      # same round of review had already fixed below: `BIOS.SearchDirectory
      # = "bios"` (a relative path PS1 would happily resolve under its own
      # data root instead of `/data/bios`) or `SetupWizardIncomplete =
      # "true"` both pass a presence-only check as cleanly as the absent key
      # they replace, because the walk beneath this table only ever compares
      # the module's own rendered JSON against disk - the module agreeing
      # with itself, never against a value this test supplies independently.
      # Every value below is now that independent literal, hand-typed
      # against `modules/emulators` rather than read from it, so a wrong
      # value fails here exactly the way a dropped key already did.
      #
      # One exception: RetroArch's `libretro_directory`. Its value is
      # `coresDirectory`, a content-addressed Nix store path
      # (`modules/emulators`'s own `retroarchWithCores` build) - there is no
      # literal to hand-type for it that would not itself be a rebuild of
      # that same derivation under a different name, which would just be
      # the module agreeing with itself again, one layer further out. It
      # stays a presence-only pin (`UNPINNED_VALUE` below), the one key in
      # this table for which "guard presence, not value" is still the
      # honest thing to assert, not an oversight.
      #
      # DuckStation's `BIOS.SearchDirectory`, PCSX2's `Folders.Bios` and
      # both emulators' own `SetupWizardIncomplete` keys are pinned here
      # deliberately, not merely swept in by the walk below: an earlier
      # review round found PS1 and PS2 unable to find `/data/bios` while
      # `emubox-check-bios` reported everything present, and both
      # emulators showing their first-run setup wizard in the path from
      # choosing a game to playing it - shipped-behaviour Criticals, both
      # fixed in `modules/emulators`. Leaving these four to the walk's own
      # coverage would mean a later edit that drops one of them regresses
      # silently: the walk only checks whatever the rendered JSON still
      # contains, so a key removed from the module is a key the walk never
      # notices is gone. Pinning them here is what turns that removal into
      # a failure of this test rather than a Critical shipped quietly. A
      # key some other, unrelated change adds still needs no matching edit
      # here - the walk below reads whatever the rendered JSON actually
      # contains, not this literal set - but that reasoning no longer
      # covers these four now that their removal is load-bearing enough to
      # pin against.
      #
      # Azahar's `\default` keys are spelled with a literal backslash, not
      # a forward slash: `modules/emulators`'s own comment on
      # `azaharConfigFile` explains why (Qt's QSettings escapes `/` inside
      # a key name to `\` when it flattens a group path to an ini line),
      # and this pin has to use the same spelling QSettings itself reads
      # and writes, or a key spelled the wrong way would look "present"
      # here while Azahar's own writer created a second, differently-named
      # line the moment it next saved its own config. `check_for_update_on_start`
      # is not pinned here at all any more: `modules/emulators` dropped it
      # (its own comment on `azaharConfigFile` records why - the setting is
      # compiled out of this flake's Azahar build, so there was nothing
      # left to pin).
      UNPINNED_VALUE = ...  # presence only - see `libretro_directory` above

      PINNED_OWNED_KEYS = {
          f"{PLAYER_HOME}/.config/retroarch/retroarch.cfg": {
              None: {
                  "video_fullscreen": "true",
                  "libretro_directory": UNPINNED_VALUE,
                  "system_directory": "/data/bios",
                  "autosave_interval": "30",
                  "menu_driver": "ozone",
                  "menu_show_online_updater": "false",
                  "menu_show_core_updater": "false",
                  "input_menu_toggle": "f1",
                  "input_save_state": "f2",
                  "input_load_state": "f4",
                  "input_toggle_fast_forward": "space",
                  "input_screenshot": "f8",
                  "input_menu_toggle_gamepad_combo": "4",
                  "input_quit_gamepad_combo": "4",
              },
          },
          f"{PLAYER_HOME}/.config/dolphin-emu/Dolphin.ini": {
              "Display": {"Fullscreen": "True"},
              "Core": {"CPUThread": "False"},
          },
          f"{PLAYER_HOME}/.config/PCSX2/inis/PCSX2.ini": {
              "UI": {"StartFullscreen": "true", "SetupWizardIncomplete": "false"},
              "Folders": {"Bios": "/data/bios"},
              "EmuCore/GS": {"upscale_multiplier": "1"},
          },
          f"{PLAYER_HOME}/.config/ppsspp/PSP/SYSTEM/ppsspp.ini": {
              "Graphics": {"FullScreen": "True"},
          },
          f"{PLAYER_HOME}/.config/azahar-emu/qt-config.ini": {
              "UI": {
                  "fullscreen": "true",
                  "fullscreen\\default": "false",
                  "firstStart": "false",
                  "firstStart\\default": "false",
              },
          },
          f"{PLAYER_HOME}/.local/share/duckstation/settings.ini": {
              "Main": {"StartFullscreen": "true", "SetupWizardIncomplete": "false"},
              "GPU": {"PGXPEnable": "true", "ResolutionScale": "4"},
              "BIOS": {"SearchDirectory": "/data/bios"},
          },
          f"{PLAYER_HOME}/.config/scummvm/scummvm.ini": {
              "scummvm": {
                  "fullscreen": "true",
                  "confirm_exit": "false",
                  "gui_return_to_launcher_at_exit": "false",
              },
          },
      }

      with subtest("Every owned emulator config key holds the flake's value"):
          _MISSING = object()  # distinct from any real value, including None/False-ish strings
          for path, sections in PINNED_OWNED_KEYS.items():
              entry = owned["files"].get(path)
              assert entry is not None, f"{path}: pinned in this test but not in emubox.kiosk.ownedFiles at all"
              for section, keys in sections.items():
                  actual = entry["keys"] if section is None else entry["keys"].get(section, {})
                  for name, expected in keys.items():
                      got = actual.get(name, _MISSING)
                      if got is _MISSING:
                          raise AssertionError(f"{path} [{section}]: pinned key dropped from the module: {name}")
                      if expected is UNPINNED_VALUE:
                          continue  # presence only, see UNPINNED_VALUE's own comment above
                      assert got == expected, f"{path} [{section}]: {name}: {got!r} != {expected!r}"

          # The walk: every file the rendered JSON actually names (not just
          # the pinned subset above), so a key a concurrent change adds is
          # checked against disk automatically rather than silently
          # unverified until someone remembers to update this test.
          for path, entry in owned["files"].items():
              if path == "settings/es_settings.xml":
                  continue  # its own pin-then-walk above already covers it
              fmt = entry["format"]
              if fmt == "retroarch":
                  assertions = [(None, key, expected) for key, expected in entry["keys"].items()]
              elif fmt == "ini":
                  assertions = [
                      (section, key, expected)
                      for section, keys in entry["keys"].items()
                      for key, expected in keys.items()
                  ]
              else:
                  raise AssertionError(f"{path}: unhandled owned-file format {fmt!r}")

              if not assertions:
                  # A file the flake owns zero static keys in - PCSX2's
                  # `secrets.ini` and Dolphin's `RetroAchievements.ini`, both
                  # declared with `keys = { }` in modules/emulators because
                  # their only content is retroachievements namespace keys
                  # (token, or enabled/hardcore/username/token) written at
                  # runtime rather than through this static table (design
                  # D1-D4). There is nothing this walk could check here even
                  # if the file existed, and IMPORTANT-5's prepare-side fix
                  # (the ini/retroarch editors now leave a file alone
                  # entirely rather than touching it for zero keys) means
                  # such a file is legitimately absent until something
                  # actually needs writing into it - a `cat` here would fail
                  # on an absence that is correct, not a bug (this is what
                  # broke this subtest in CI against PCSX2's `secrets.ini`
                  # before a token had ever resolved). Skip it explicitly
                  # rather than loosen the walk to "cat if it exists" for
                  # every file: a file that DOES own a static key still has
                  # to exist and carry it, unconditionally, below.
                  #
                  # Not asserted absent here either, deliberately: Dolphin's
                  # `RetroAchievements.ini` has the same empty static table
                  # but is not reliably absent at this point - its
                  # enabled/hardcore keys are written unconditionally by
                  # `apply_retroachievements` regardless of network (design
                  # D2), unlike PCSX2's, whose only key is the token itself.
                  # A blanket "must be absent whenever there are no static
                  # keys" would be wrong for one of these two files, not
                  # merely early - so this walk stays silent on existence
                  # for a zero-key file rather than asserting either way.
                  continue

              text = machine.succeed(f"cat {shlex.quote(resolve(APPDATA, path))}")
              for section, key, expected in assertions:
                  got = owned_file_value(fmt, text, section, key)
                  assert got == expected, f"{path} [{section}]: {key}: {got!r} != {expected!r}"

      # --- kiosk: custom systems, both branches -----------------------------

      with subtest("The custom systems file holds exactly the definition"):
          assert machine.succeed(f"cat {CUSTOM_SYSTEMS}") == ${py customSystems}

      with subtest("An empty definition removes the file"):
          # Before any kill: a later loop iteration re-runs prepare with the
          # module's non-empty path and would recreate the file, so this
          # ordering is load-bearing rather than incidental.
          #
          # The binary is found by bare name on the system path, which is
          # also what proves the packages capability's program-path scenario,
          # and the JSON's path comes from the module's readonly option
          # rather than from scraping the session script.
          machine.succeed("test -x /run/current-system/sw/bin/emubox-prepare")
          prepare = f'ESDE_APPDATA_DIR={APPDATA} emubox-prepare {OWNED_VALUES} ""'
          machine.succeed(f"su player -s /bin/sh -c {shlex.quote(prepare)}")
          machine.fail(f"test -e {CUSTOM_SYSTEMS}")

      # --- kiosk: the frontend is kept up -----------------------------------

      with subtest("A frontend that ran longer than the window is relaunched"):
          # Outlast the window so this exit resets the counter rather than
          # counting as a crash.
          machine.sleep(${toString (crashWindow + 5)})
          # Re-read the pid here, not before the sleep: had the frontend
          # exited and relaunched on its own during it, killing the new
          # process while comparing against the old one would satisfy the
          # assertion with no relaunch having happened.
          before = esde_pids()[0]
          machine.succeed(f"kill {before}")
          # Proved by PID, not by presence: without waiting for the old
          # process to die, the dying process satisfies "es-de is running"
          # and the subtest passes with no relaunch having happened.
          machine.wait_until_fails(f"kill -0 {before}", timeout=60)

          def relaunched(_last):
              return any(p != before for p in esde_pids())

          # 15 s is the kiosk spec's own constant, asserted as written.
          retry(relaunched, timeout_seconds=15)

      with subtest("Three short runs in a row end at the greeter"):
          for _ in range(3):
              machine.wait_until_succeeds("pgrep -x es-de", timeout=120)
              # By pid, and waited out. `pkill -x es-de` in a tight loop
              # re-signals the process still shutting down from the previous
              # iteration - SIGTERM reaches SDL, which unwinds over seconds -
              # so three passes would land on one process and record one
              # crash, and the session would never give up.
              pid = esde_pids()[0]
              # SIGKILL, not SIGTERM. These kills land on a frontend that is
              # seconds old, and a starting ES-DE has SDL's SIGTERM handler
              # installed but is not yet polling the event queue, so the
              # SDL_QUIT it posts sits unread and the process does not exit
              # (CI run 2: a 60 s wait for a 4-second-old pid timed out).
              # SIGKILL is also the better model of what this subtest is
              # about - a crash, not a quit; the relaunch subtest above still
              # uses SIGTERM against a frontend that has been up 35 s, which
              # is the graceful-exit path.
              machine.succeed(f"kill -KILL {pid}")
              machine.wait_until_fails(f"kill -0 {pid}", timeout=60)

          # Longer than the loop's 2 s relaunch pause: without the grace
          # period "no frontend" is momentarily true after any kill and the
          # assertion would go green against a counter that never fired.
          machine.sleep(15)
          for _ in range(5):
              assert not esde_pids(), "the session relaunched after three crashes"
              machine.sleep(2)
          # The primary assertion is this pair: the frontend is gone and the
          # display manager is still there to serve a login.
          machine.succeed("systemctl is-active display-manager.service")
          # The greeter itself, asserted as a session on the seat rather than
          # by a process name. Design D5 allowed the process name to be
          # adjusted or dropped if it proved flaky, and it has now proved so
          # twice: nixpkgs wraps these binaries, so cage's comm is
          # `.cage-wrapped` and the greeter compositor's is
          # `.kwin_wayland-w` (15-char comm truncation), and `pgrep -f` is
          # worse than useless because it matches the driver's own command
          # line. An active `sddm` session on seat0 is what "the greeter is
          # shown" actually means, and it depends on no binary's name.
          def greeter_state():
              return machine.succeed(
                  "echo '--- sessions'; loginctl list-sessions --no-legend || true; "
                  "echo '--- seat'; loginctl show-seat seat0 || true; "
                  "echo '--- processes'; ps -eo user,pid,comm --no-headers "
                  "| grep -iE 'sddm|kwin|weston|cage|es-de|plasma' || true; "
                  "echo '--- display-manager'; "
                  "systemctl status display-manager.service --no-pager -n 40 || true"
              )

          try:
              retry(lambda _: session_on_seat("sddm"), timeout_seconds=120)
          except Exception:
              # Only on failure, so a green run stays quiet. This dump is what
              # identified the exit-code bug: it showed no sessions, no seat,
              # and only the sddm daemon itself still running.
              print(greeter_state())
              raise
          # The seat being the greeter's is also the other half of "no
          # automatic login while this display manager keeps running": it
          # cannot be player's at the same time.
          assert not session_on_seat("player")

      with subtest("A reboot from the greeter restores the kiosk"):
          # Last, so that the reboot is genuinely from the greeter and this
          # proves that ending there does not outlive the boot.
          #
          # shutdown()/start(), not machine.reboot(): the driver starts the
          # VM with `-no-reboot` unless it was started with allow_reboot, so
          # a reset would end QEMU and every later assertion would fail
          # against a dead machine. reboot() is also only a Ctrl-Alt-Del
          # keypress, which the greeter's compositor owns the VT for. This is
          # the same shape the install test already uses.
          machine.shutdown()
          machine.start()
          machine.wait_for_unit("display-manager.service")
          retry(lambda _: session_on_seat("player"), timeout_seconds=120)
          machine.wait_until_succeeds("pgrep -x es-de", timeout=120)

      # --- emulators/retroachievements: design D7 ---------------------------
      #
      # Everything below runs after the kiosk session mechanism above is
      # already proven, and deliberately never disturbs it: every manual
      # `emubox-prepare` re-run passes CUSTOM_SYSTEMS_PATH (the real,
      # non-empty document), not the empty string the "empty definition"
      # subtest used, and nothing here kills or restarts es-de itself.
      #
      # The mock server (emubox-mock-retroachievements.service) has not been
      # started by anything above, so every prepare run since the first boot
      # - many, across the relaunch, crash-loop and reboot subtests - has
      # already been attempting a login against an endpoint with nothing
      # listening on it. That is the retroachievements spec's "no route to
      # the endpoint" scenario, exercised for free rather than built
      # specially; the subtest below adds only the one thing that could not
      # come from ambient state - a deterministic, journal-connected proof
      # that the failure was actually logged.

      with subtest("Offline boot: no cached token, no route, frontend still up"):
          # `machine.succeed`/`.execute` only capture a command's stdout (the
          # driver pipes `bash -c command` into `base64`; stderr is not part
          # of that pipeline), so `emubox-prepare`'s own stderr notes are
          # otherwise invisible to this test. A transient systemd unit is
          # used instead of the `su player` idiom the rest of this file uses,
          # specifically so its stderr reaches the journal the normal way (no
          # `--pipe`, so systemd's own default output routing applies) and
          # `journalctl` can prove the spec's "the journal records the failed
          # login" - the one assertion that a residual, ambient log entry
          # from three es-de relaunches ago could not honestly stand in for.
          unit = "emubox-prepare-ra-offline-check"
          machine.succeed(
              f"systemd-run --unit={unit} --uid=player "
              f"--setenv=ESDE_APPDATA_DIR={APPDATA} --wait "
              f"-- emubox-prepare {OWNED_VALUES} {CUSTOM_SYSTEMS_PATH}"
          )
          exit_status = machine.succeed(
              f"systemctl show -p ExecMainStatus --value {unit}.service"
          ).strip()
          assert exit_status == "0", exit_status
          journal = machine.succeed(f"journalctl -u {unit}.service --no-pager -o cat")
          assert "could not reach the RetroAchievements API and no cached token exists" in journal, journal

          machine.succeed("pgrep -x es-de")

          owned = json.loads(machine.succeed(f"cat {OWNED_VALUES}"))
          ra = owned["retroachievements"]
          for target in ra["targets"]:
              booleans = target["booleans"]
              # Written as declared even with no login: enabled follows the
              # namespace being non-null, hardcore follows the (default off)
              # switch - design D2's "the enabled and hardcore keys are
              # still written as declared".
              assert read_target_value(target, "enabled") == booleans["true"], target["name"]
              assert read_target_value(target, "hardcore") == booleans["false"], target["name"]
              # No account name or token anywhere - the exact absence, not
              # merely "not the mock's value", since a stale value from an
              # earlier run would also fail this the moment one existed.
              assert read_target_value(target, "username") is None, target["name"]
              assert read_target_value(target, "token") is None, target["name"]
              if target.get("token_file"):
                  machine.fail(f"test -e {resolve(APPDATA, target['token_file'])}")

          sweep_for_password(owned)

      with subtest("Tokens asserted against the mock: hardcore off"):
          machine.succeed("systemctl start emubox-mock-retroachievements.service")
          # Not `wait_for_open_port`: it shells out to `nc`, which nothing in
          # this project's modules installs, so relying on it would be
          # betting on a package happening to be pulled in as someone else's
          # dependency. Bash's own `/dev/tcp` pseudo-device needs no extra
          # binary and every guest command already runs through bash.
          # 30 s, not a measured budget: the unit is a bare Python interpreter
          # starting a stdlib HTTP server with no dependencies of its own to
          # wait on, so the real wait is however long a loaded CI runner
          # takes to schedule one more systemd job - generous headroom for
          # that, not a number this test has ever seen come close to.
          machine.wait_until_succeeds(
              "echo > /dev/tcp/127.0.0.1/${toString mockPort}", timeout=30
          )

          rerun_prepare(OWNED_VALUES)

          owned = json.loads(machine.succeed(f"cat {OWNED_VALUES}"))
          ra = owned["retroachievements"]
          machine_id = machine.succeed("cat /etc/machine-id").encode()

          for target in ra["targets"]:
              booleans = target["booleans"]
              assert read_target_value(target, "enabled") == booleans["true"], target["name"]
              assert read_target_value(target, "hardcore") == booleans["false"], target["name"]
              assert read_target_value(target, "username") == RA_USERNAME, target["name"]

              if target["encoding"] == "duckstation":
                  ciphertext = read_target_value(target, "token")
                  recovered = duckstation_decrypt(machine_id, RA_USERNAME, ciphertext)
                  assert recovered == MOCK_TOKEN, (target["name"], recovered)
                  # LoginTimestamp is change-gated (design D3): it is written
                  # once the token changes from absent to present, which just
                  # happened.
                  assert read_target_value(target, "login_timestamp") is not None, target["name"]
              elif target["encoding"] == "plain":
                  assert read_target_value(target, "token") == MOCK_TOKEN, target["name"]
              elif target["encoding"] == "secret-file":
                  token_path = resolve(APPDATA, target["token_file"])
                  assert machine.succeed(f"cat {token_path}") == MOCK_TOKEN, target["name"]

          sweep_for_password(owned)

      with subtest("Both hardcore positions are reflected in every configuration"):
          # design D7's "re-render and re-run prepare inside the test with a
          # different owned-values document" option, chosen over a second
          # node: `ownedValuesFile` is exactly the readOnly option the kiosk
          # module exposes for this (its own description: "a test
          # interpolates one source of truth rather than scraping the
          # session script or re-rendering the JSON and agreeing with
          # itself"). Cheaper in VM memory than a second graphical node,
          # which would pay this whole file's session-boot cost twice for
          # one boolean.
          owned = json.loads(machine.succeed(f"cat {OWNED_VALUES}"))
          owned["retroachievements"]["hardcore"] = True
          payload = base64.b64encode(json.dumps(owned).encode()).decode()
          hardcore_path = "/tmp/emubox-owned-values-hardcore.json"
          machine.succeed(f"echo {payload} | base64 -d > {hardcore_path}")

          rerun_prepare(hardcore_path)

          for target in owned["retroachievements"]["targets"]:
              booleans = target["booleans"]
              assert read_target_value(target, "hardcore") == booleans["true"], target["name"]

          # Restore the off position (the module's own default) before the
          # emulator launches below, which assert nothing about hardcore but
          # should not leave the machine in a state a later subtest did not
          # itself choose.
          rerun_prepare(OWNED_VALUES)

      with subtest("A box that had a token then loses the endpoint carries no stale account name or token"):
          # finding IMPORTANT-7. Placed here, after "Tokens asserted against
          # the mock" and "Both hardcore positions" above, deliberately: this
          # is the one point in the file where every target already carries
          # a real username and token and a real cache file exists on disk -
          # only a prior successful login (the earlier subtest) produces
          # that. The "Offline boot" subtest at the top of this group
          # asserts the same `username is None` / `token is None` shape, but
          # there nothing had ever written a username at all, so it passed
          # for a reason unrelated to the behaviour it was meant to prove.
          # What this subtest actually proves is the retroachievements
          # spec's "no stale account name or token": a box that HAD a token,
          # then genuinely loses both the network route and its cache, must
          # not go on serving emulator configs that still name an account -
          # `emubox-prepare` has to actively remove those keys, not merely
          # stop refreshing them (design D2's "on network failure without
          # one [a cache], ... drop the account-name and token keys").
          #
          # Run before the emulator launches below so this subtest can
          # restore the ordinary state - route reachable, token present -
          # those neither need nor expect, the same reasoning the hardcore
          # subtest above already gives for its own restore.
          owned = json.loads(machine.succeed(f"cat {OWNED_VALUES}"))
          ra = owned["retroachievements"]
          cache_path = resolve(APPDATA, ra["cache_file"])
          machine.succeed(f"test -e {cache_path}")  # the prior login wrote one

          machine.succeed("systemctl stop emubox-mock-retroachievements.service")
          machine.succeed(f"rm -f {cache_path}")

          rerun_prepare(OWNED_VALUES)

          for target in ra["targets"]:
              booleans = target["booleans"]
              # Still written as declared, exactly as the "Offline boot"
              # subtest's own comment establishes: enabled follows the
              # namespace being non-null, hardcore follows the switch,
              # neither depends on the network.
              assert read_target_value(target, "enabled") == booleans["true"], target["name"]
              assert read_target_value(target, "hardcore") == booleans["false"], target["name"]
              assert read_target_value(target, "username") is None, target["name"]
              assert read_target_value(target, "token") is None, target["name"]
              if target.get("token_file"):
                  machine.fail(f"test -e {resolve(APPDATA, target['token_file'])}")

          sweep_for_password(owned)

          # Restore: the route back, then a fresh login so the cache and
          # every target's token exist again before the launches below,
          # which assert nothing about RetroAchievements but should not
          # inherit a route this subtest itself took away.
          machine.succeed("systemctl start emubox-mock-retroachievements.service")
          machine.wait_until_succeeds(
              "echo > /dev/tcp/127.0.0.1/${toString mockPort}", timeout=30
          )
          rerun_prepare(OWNED_VALUES)

      with subtest("Switching RetroAchievements off removes every credential from disk"):
          # N2: `enable = false` used to leave a stale username and a live
          # bearer token sitting in every supporting emulator's config,
          # PPSSPP's raw token file and the login cache - `raDisabledFiles`
          # (modules/emulators) only ever forced `enabled`/`hardcore` off,
          # and could not reach the other two files at all. Reached here
          # the same way the hardcore subtest above reaches its own
          # alternate document: the namespace's `enabled` field flipped to
          # false and prepare re-run against that document, rather than a
          # second VM node.
          #
          # Placed right after a subtest that ends with every target
          # holding a real, freshly-restored username and token and a real
          # cache file on disk - the state this subtest needs in order to
          # actually prove a removal happened, rather than passing because
          # nothing was ever there to remove.
          owned = json.loads(machine.succeed(f"cat {OWNED_VALUES}"))
          ra = owned["retroachievements"]
          cache_path = resolve(APPDATA, ra["cache_file"])
          machine.succeed(f"test -e {cache_path}")  # the prior login wrote one
          for target in ra["targets"]:
              if target.get("token_file"):
                  machine.succeed(f"test -e {resolve(APPDATA, target['token_file'])}")

          disabled = dict(owned)
          disabled["retroachievements"] = dict(ra, enabled=False)
          payload = base64.b64encode(json.dumps(disabled).encode()).decode()
          disabled_path = "/tmp/emubox-owned-values-ra-disabled.json"
          machine.succeed(f"echo {payload} | base64 -d > {disabled_path}")

          rerun_prepare(disabled_path)

          for target in ra["targets"]:
              assert read_target_value(target, "username") is None, target["name"]
              assert read_target_value(target, "token") is None, target["name"]
              if "login_timestamp" in target["keys"]:
                  assert read_target_value(target, "login_timestamp") is None, target["name"]
              if target.get("token_file"):
                  machine.fail(f"test -e {resolve(APPDATA, target['token_file'])}")
          machine.fail(f"test -e {cache_path}")

          sweep_for_password(owned)

          # Idempotency, the property this fix cares about most: every
          # config file this pass could have touched, stat-frozen, then
          # prepare re-run against the very same disabled document. Nothing
          # left to remove means nothing should be rewritten at all. Every
          # file any key entry of any target names, not just each target's
          # `username`/`token` file - PCSX2 keeps `Enabled` in PCSX2.ini
          # but `Username`/`Token` in a second file, `secrets.ini`, so the
          # union of every key's own file is what actually covers every
          # file this cleanup pass could touch.
          config_paths = sorted(
              {
                  resolve(APPDATA, entry["file"])
                  for target in ra["targets"]
                  for entry in target["keys"].values()
              }
          )
          before = {
              path: machine.succeed(f"stat -c '%i %Y %a' {shlex.quote(path)}")
              for path in config_paths
          }

          rerun_prepare(disabled_path)

          for path in config_paths:
              after = machine.succeed(f"stat -c '%i %Y %a' {shlex.quote(path)}")
              assert after == before[path], f"{path}: {before[path]!r} != {after!r}"
          machine.fail(f"test -e {cache_path}")
          for target in ra["targets"]:
              if target.get("token_file"):
                  machine.fail(f"test -e {resolve(APPDATA, target['token_file'])}")

          # Restore: a fresh login so every target's token and the cache
          # exist again before the launches below, which assert nothing
          # about RetroAchievements but should not inherit a disabled
          # namespace this subtest itself introduced.
          rerun_prepare(OWNED_VALUES)

      with subtest("emubox-check-bios reports the declared BIOS files as missing from an empty /data/bios"):
          # M4: the checker ships (design D6) but nothing ran it against the
          # inventory it actually reads on a real box. This node's
          # `/data/bios` is an empty tmpfs (no disko layout here, above), so
          # every declared file is legitimately missing - proving the PATH
          # claim (bare name, no store path needed) and the report's schema
          # (every declared file named, not merely "something is missing")
          # together. `rc != 0` is the exit-status half of the same
          # contract the design and spec both state ("exits ... unsuccessfully
          # otherwise").
          rc, out = machine.execute("emubox-check-bios /etc/emubox/bios-inventory.json /data/bios")
          assert rc != 0, out
          inventory = json.loads(machine.succeed("cat /etc/emubox/bios-inventory.json"))
          for entry in inventory.values():
              assert entry["path"] in out, (entry["path"], out)
          # No entry in the shipped inventory names an algorithm the tool
          # does not implement - the one way this run could otherwise pass
          # for the wrong reason (a malformed-inventory hard failure looks
          # the same as "everything is MISSING" at the exit-code level).
          assert "does not implement" not in out, out

      # --- emulators: BIOS-free core families launch headless (design D7) --

      with subtest("Every BIOS-free core family with a licensed ROM runs headless"):
          # Every driver RetroArch would otherwise try to open a real device
          # for is overridden to "null" (design D7's "video_driver
          # overridden for the run", extended here to every driver the pinned
          # 1.22.2 source shows has one): this VM has no GPU, no input
          # devices, no audio device and no ALSA sequencer, and RetroArch's
          # own drivers/*.c confirm each has a driver literally named
          # "null" for exactly this. video_driver alone was not enough - CI
          # proved it: `video_driver_init_internal()` also initialises the
          # input driver (input/input_driver.c's `input_driver_init`, called
          # from inside video init), so a null video driver with a real
          # input driver still fails with "Cannot initialize input driver."
          # input_joypad_driver is separate from input_driver (the pad
          # backend a real input driver would otherwise hand off to,
          # input/input_driver.c:4698) and midi_driver is separate again
          # (retroarch.c's `midi_drv`) - without it RetroArch tries the ALSA
          # sequencer directly (`snd_seq_open`) and this VM has no
          # /dev/snd/seq. menu_driver is included too though the pinned
          # source shows its own "null" driver failing to fully initialise
          # even so (menu/menu_driver.c's `rarch_menu_init` chain) - that
          # failure is logged and non-fatal (RetroArch continues into the
          # run loop regardless, confirmed by reproducing this exact
          # override set on the x86_64-linux builder outside the VM), so it
          # is left set to the semantically correct value rather than
          # omitted. `video_driver = "null"` itself does not hold for every
          # core, though: N64, Dreamcast and Vectrex are exempt above
          # (finding IMPORTANT-2, three of `exemptFamilies`' `kind =
          # "mechanism"` entries) because RetroArch forces a real HW-render
          # driver for them regardless of this override, confirmed the same
          # way. SNES is exempt above too, but for an unrelated reason - the
          # fixture launch hangs rather than exiting, confirmed in CI rather
          # than by this mechanism.
          override = "/tmp/emubox-retroarch-headless-override.cfg"
          machine.succeed(
              "printf '%s\\n' "
              "'video_driver = \"null\"' "
              "'audio_driver = \"null\"' "
              "'input_driver = \"null\"' "
              "'input_joypad_driver = \"null\"' "
              "'menu_driver = \"null\"' "
              "'midi_driver = \"null\"' "
              f"> {override}"
          )

          # Two markers, not the bare exit-0-and-a-log-line the pinned
          # source shows is vacuous: runloop.c:3712-3713 logs
          # "Loading dynamic libretro core from" by echoing straight back
          # the `-L` argument this test already passed in, before any dlopen
          # is even attempted, so its presence proves nothing about whether
          # the ROM matched the core - and tasks/task_content.c:2224-2229's
          # own comment records that `content_load()` can fail and still
          # return true, silently swapping in the dummy core, in which case
          # `--max-frames` still exits 0.
          #
          # The positive marker: runloop.c's `runloop_event_load_core`
          # logs "[Core] Geometry: ..." (from a real `retro_get_system_av_info()`
          # call into the dlopen'd core) only after
          # `event_init_content()` - which is what calls the core's real
          # `retro_load_game()` - has already returned true (runloop.c
          # ~4808-4817: `runloop_event_init_core` returns early, before ever
          # reaching `runloop_event_load_core`, the moment content
          # loading fails). So this line cannot appear for a truncated
          # fixture, a wrong core/ROM pairing, or any core that dlopens fine
          # but rejects the specific content handed to it - confirmed
          # empirically too: reproducing a real run on the x86_64-linux
          # builder (outside the VM, no KVM needed) shows this exact line.
          #
          # The negative marker: tasks/task_content.c's `content_init` logs
          # `RARCH_ERR("[Content] %s\n", ...)` with
          # `msg_hash_to_str(MSG_FAILED_TO_LOAD_CONTENT)` - "Failed to load
          # content." (intl/msg_hash_us.h) - exactly when `content_file_init`
          # fails, i.e. exactly the case the dummy-core-fallback comment
          # above describes. Asserting its absence is what closes that hole:
          # even if a future RetroArch version's fallback path let
          # `--max-frames` exit 0 with the dummy core silently substituted,
          # this line would still have been logged on the way there.
          for fixture in ${
            py (
              map (f: {
                inherit (f) family core;
                rom = "${f.rom}";
              }) homebrewFixtures
            )
          }:
              cmd = (
                  "retroarch "
                  f"-L /run/current-system/sw/lib/retroarch/cores/{fixture['core']} "
                  f"{shlex.quote(fixture['rom'])} "
                  f"--appendconfig {override} --max-frames 60 --verbose 2>&1"
              )
              # 60 frames is enough to prove the core loaded and ran without
              # paying more than a couple of seconds of CI time per family;
              # `--max-frames` is also what forces even the one fixture that
              # never exits on its own (DOSBox Pure's looping demo) to a
              # clean exit 0 - this design's "assert liveness over frames" in
              # practice, since RetroArch itself decides to quit, not the
              # content.
              # timeout=60: generous headroom over the "couple of seconds"
              # above for a slow CI runner and a cold dlopen of a core, while
              # still failing this one family by name - the driver's
              # `succeed` otherwise defaults to no timeout at all, so a core
              # that hangs (rather than crashing or exiting) would surface as
              # an unattributed global test timeout with no indication which
              # of the twelve families caused it.
              out = machine.succeed(
                  f"su player -s /bin/sh -c {shlex.quote(cmd)}", timeout=60
              )
              assert "[Core] Geometry:" in out, (
                  f"{fixture['family']}: the core never reached a real "
                  f"retro_get_system_av_info() call - content did not load\n{out}"
              )
              assert "[Content] Failed to load content." not in out, (
                  f"{fixture['family']}: RetroArch logged a content-load "
                  f"failure (dummy-core fallback territory)\n{out}"
              )

      with subtest("Every installed RetroArch core is tested, exempt, or a named BIOS checklist item"):
          # Finding IMPORTANT-3: the two length asserts above the node
          # definition (`homebrewFixtures`, `exemptFamilies`) only catch an
          # edit to those two lists themselves - nothing related them to the
          # cores `modules/emulators` actually installs, so
          # adding a core there left the counts unchanged and the new family
          # untested, unnamed and unnoticed. This assertion is the relation:
          # every `.so` this node's RetroArch build actually ships has to be
          # accounted for by one of the three lists, or the test fails and
          # names exactly which file is new.
          installed = set(
              machine.succeed(
                  "ls /run/current-system/sw/lib/retroarch/cores"
              ).split()
          )
          tested = ${py (map (f: f.core) homebrewFixtures)}
          exempt = ${py (map (f: f.core) exemptFamilies)}
          bios_only = ${py biosDependentCores}
          accounted = set(tested) | set(exempt) | set(bios_only)
          # Two assertions, not one `==`: an unaccounted core (the real
          # regression this finding is about) and a stale entry naming a
          # core no longer installed (a dead line in one of the three lists)
          # are different mistakes and should read as different failures.
          assert not (installed - accounted), (
              f"cores installed but not tested, exempt, or BIOS-checklisted: "
              f"{sorted(installed - accounted)}"
          )
          assert not (accounted - installed), (
              f"cores named in a list here but not actually installed: "
              f"{sorted(accounted - installed)}"
          )

      # --- standalones: smoke launch (design D7) ----------------------------

      # settle=5: long enough that a slow CI runner forking and execve-ing
      # a multi-hundred-megabyte Qt/SDL binary has time to get past its own
      # library loading and toolkit construction before the alive-check
      # samples it (short compared to the reboot/relaunch waits elsewhere in
      # this file because there is no compositor or session manager in this
      # path, only process startup) - not a measured figure, since no KVM
      # builder was available to time an actual run; if CI shows a genuine
      # binary needing longer, raising this one number covers all four.
      def standalone_smoke_launch(binary, settle=5):
          """Prove a standalone starts against its written configuration and
          stays up for `settle` seconds, then kill it.

          Not `retry(alive, timeout_seconds=settle)`: the driver's `retry`
          calls `fn(False)` once, immediately, before its first sleep, and
          returns the moment that call is `True` - so against a predicate
          that is already `True` a few hundred milliseconds after the fork
          it never sleeps at all, and `settle` is never actually spent. That
          would leave a standalone that execs, loads a few hundred MB of
          Qt/SDL, fails to construct a platform plugin and exits noisily
          1-5 s later completely unverified: `alive` would be sampled
          immediately after the launch, long before that failure, and pass.
          Sampling once after a plain `machine.sleep(settle)` instead is
          also not scheduling-dependent the way the `retry` shape was, since
          there is no longer a race between how fast the harness happens to
          call back in and how fast the binary happens to die.

          Not `--version`: this project has only source-verified that
          contract for one of these six binaries, ScummVM (below). es-de
          gets the same verification separately, in the install test - but
          es-de is the frontend, not one of these six, and DuckStation is
          not a second: an earlier version of this comment credited the
          install test with covering DuckStation's `--version` too, which
          was wrong twice over - the install test only ever asserts
          `test -x` for it, never runs it, and CI has since shown the
          binary does not survive construction far enough to look at argv
          at all (see the DuckStation comment in the subtest below).
          DuckStation is not passed to this function any more because of
          that. PCSX2's own command-line parser (read directly,
          pcsx2-qt/QtHost.cpp) is confirmed to exit 1 on `-version`/`-help`
          even though it printed the right thing first - so leaning on each
          remaining codebase's own flag-handling would be asserting more
          than this project actually knows. A background launch,
          alive-check and kill instead proves exactly what the spec asks
          for ("the process starts"), the same pgrep-based idiom this file
          already uses for es-de throughout.

          QT_QPA_PLATFORM=offscreen and SDL_VIDEODRIVER=dummy are set
          regardless of which toolkit a given binary actually uses - an
          unused environment variable is a no-op - because this VM's only
          display is the virtio-gpu console cage already owns for es-de (the
          install test's own header: "the AppImage's Qt would fail without
          one"), so a second GUI app needs a display it can construct
          without a real compositor. This combination is not verified
          against every one of these four specific derivations in an actual
          VM (no KVM builder was available while writing this test); if CI
          shows one of them still needing a display it cannot get, the fix
          is a per-binary invocation here, not a broader claim than this
          smoke launch actually proves.
          """
          log = f"/tmp/emubox-smoke-{binary.replace('/', '_')}.log"
          launch = (
              f"env QT_QPA_PLATFORM=offscreen SDL_VIDEODRIVER=dummy "
              f"{binary} > {log} 2>&1 & echo $!"
          )
          pid = machine.succeed(f"su player -s /bin/sh -c {shlex.quote(launch)}").strip()

          machine.sleep(settle)
          rc, _ = machine.execute(f"kill -0 {pid}")
          if rc != 0:
              print(machine.execute(f"cat {log}")[1])
              raise AssertionError(
                  f"{binary} exited within {settle}s of launch, before this "
                  "smoke launch even got to prove it stays up"
              )
          # SIGKILL, not SIGTERM, and this file already learned why one screen
          # up: a GUI process that has installed a toolkit's SIGTERM handler
          # but is not yet polling its event queue never sees the quit the
          # handler posts, so the signal sits unread and the process outlives
          # any wait put on it. The crash-loop subtest above records that
          # lesson for es-de; CI run 33367950351 then reproduced it here with
          # Azahar, which started correctly, held its settle window, and then
          # ignored a SIGTERM until the 30 s wait expired and failed the whole
          # subtest. Nothing about this teardown wants a graceful exit - the
          # assertion has already been made by the time the kill runs, and the
          # process only has to go away - so the signal it cannot ignore is
          # the right one.
          #
          # 30 s: the same figure the crash-loop subtest uses to wait out a
          # SIGKILL on es-de, reused rather than invented fresh, because a
          # multi-hundred-megabyte process unwinding SDL or Qt on a loaded CI
          # runner is the same class of wait.
          machine.succeed(f"kill -KILL {pid}")
          machine.wait_until_fails(f"kill -0 {pid}", timeout=30)

      with subtest("Standalones smoke launch against their asserted configuration"):
          for binary in ["dolphin-emu", "pcsx2-qt", "azahar", "ppsspp"]:
              standalone_smoke_launch(binary)

          # vm-test spec, "A standalone that cannot be launched headless":
          # DuckStation joins ScummVM below rather than the four background
          # launches above. CI run 33364207476 is what caught this - the
          # settle-then-sample liveness check above (this subtest used to
          # sample `alive` a few hundred milliseconds after fork, which
          # would have passed this crash silently; see that function's own
          # docstring) - with:
          #
          #   qt.qpa.plugin: Could not load the Qt platform plugin
          #   "offscreen" in "" even though it was found.
          #   ...
          #   *************** Unhandled SIGABRT ...
          #     main [../build/../src/duckstation-qt/qthost.cpp:3721]
          #
          # Read against the pinned v0.1-11752 source: `main`'s first
          # statement after `VeryEarlyProcessStartup()` returns is
          # `QApplication app(argc, argv);` (qthost.cpp:3714-3721) - argv is
          # not consulted at all until
          # `ParseCommandLineParametersAndInitializeConfig`, several lines
          # later - so the abort happens constructing Qt's own application
          # object, before any flag, `--version` included, could have
          # steered around it. That is a different failure from ScummVM's
          # below (a flag this project has simply never source-verified is
          # safe here, not a flag proven unable to help), but it lands in
          # the same place: nothing launched can prove more for this binary
          # than the install test already does - that it is present and
          # executable. Restated here, not just relied on there, so this
          # scenario's own record of "which one proves less and why" is
          # self-contained.
          machine.succeed("test -x /run/current-system/sw/bin/duckstation")

          # M8, honestly stated rather than fixed: this proves less than
          # the four background launches above (DuckStation's check just
          # above proves less again, for the unrelated reason its own
          # comment gives). `--version` is well-established as safe for
          # ScummVM specifically, with no display at all - it is handled
          # long before any toolkit init - but it never reads
          # `scummvm.ini`, so unlike the four background launches this is
          # not a launch "against the asserted configuration" (the vm-test
          # spec's own phrase for this scenario) at all, only proof the
          # binary itself runs on this box. Giving it the same
          # background-launch treatment as the four above was not attempted
          # here: no KVM builder was available while writing this test to
          # check whether ScummVM's own GUI launcher screen actually comes
          # up cleanly under `SDL_VIDEODRIVER=dummy` with no display, the
          # same caveat the `standalone_smoke_launch` docstring above
          # already states for the four it does cover - and unlike those
          # four, this one has never been reproduced even outside a VM.
          # Extending it here would be asserting more than this project
          # actually knows; the honest floor is `--version` runs and prints
          # "ScummVM", full stop.
          out = machine.succeed("su player -s /bin/sh -c 'scummvm --version'")
          assert "ScummVM" in out, out
    '';
}
