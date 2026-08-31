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
      family = "SNES (Snes9x)";
      core = "snes9x_libretro.so";
      rom = "${
        pkgs.fetchzip {
          # GPL-2.0; GPLv2.txt is shipped inside the archive itself (the
          # same 240p Test Suite project as the NES entry, SNES port v1.03).
          url = "https://downloads.sourceforge.net/project/testsuite240p/OldFiles/SNES_SFC/240pSuite-SNES-1.03.zip";
          stripRoot = false;
          hash = "sha256-/XXd3avvbpk+NJjsiy2oq4Sw4ZehWRNRJzU9PIgXRoI=";
        }
      }/240pSuite.sfc";
    }
    {
      family = "N64 (Mupen64Plus-Next)";
      core = "mupen64plus_next_libretro.so";
      rom = pkgs.fetchurl {
        # Unlicense (public domain dedication); the repo's LICENSE file
        # (PeterLemon/N64, a bare-metal demo collection).
        url = "https://raw.githubusercontent.com/PeterLemon/N64/334d939e8c217df63cc99748b7346f3bcc5f9e14/CP1/Fractal/32BPP/320X240/Mandelbrot/Single/Mandelbrot32BPP320X240.N64";
        hash = "sha256-8V/5PxRnq/iy3Ntprb3v8j7ljgZ930xqsLaw+NlyOds=";
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
      family = "Dreamcast (Flycast)";
      core = "flycast_libretro.so";
      rom = "${
        pkgs.fetchzip {
          # GPL-2.0, same 240p Test Suite project/version family.
          url = "https://downloads.sourceforge.net/project/testsuite240p/OldFiles/Dreamcast/240p-DC-PVR-1.25.zip";
          stripRoot = false;
          hash = "sha256-zAyHR5ivzjZxNAjYFt1jiFjyL0oU0jkoIc3vc+WRLnI=";
        }
      }/240pSuite.cdi";
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
      # `--max-frames` (the test script, below) is what forces every
      # fixture - including this one and Vectrex's - to a clean exit, which
      # is this design's practical form of "assert liveness over frames
      # rather than expecting a still image".
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
    {
      family = "Vectrex (vecx)";
      core = "vecx_libretro.so";
      # A continuously-animating bouncing-box demo, not a static screen
      # (verified from the fetched bytes' own cartridge header and the
      # tutorial series' description) - same "assert liveness over frames"
      # treatment as DOSBox Pure above.
      rom = pkgs.fetchurl {
        # GPL-3.0; both the repo's LICENSE file and the source file's own
        # header comment agree (JoakimLarsson/VectrexTutorial, "bouncer6").
        url = "https://raw.githubusercontent.com/JoakimLarsson/VectrexTutorial/82170ef24864f30957eb55af919fda8dcc51fd98/bin/bouncer6.bin";
        hash = "sha256-MOMfxdG40RCouhj1XzKNVaZnErXymlFBVgh8V3ymreQ=";
      };
    }
  ];

  # Named-exempt core families (vm-test spec: "the configuration SHALL name
  # each exempt family"). After two independent searches, no homebrew ROM
  # for either family carries an explicit licence or redistribution grant
  # from its author, and these fixtures would be fetched by a public CI run
  # and pushed through a public binary cache - so neither gets a headless
  # launch here. Both move to the E12 hardware checklist instead (design D7:
  # "an exempt family is a hardware checklist item, like the BIOS-dependent
  # cores").
  exemptFamilies = [
    {
      family = "Atari 7800 (ProSystem)";
      reason = "every compiled .a78 binary found sits in a repo with no LICENSE file and no redistribution statement; every repo with an explicit permissive licence ships source only, with no compiled ROM in the repo or in Releases";
    }
    {
      family = "Neo Geo Pocket / Color (Beetle NeoPop)";
      reason = "no NGP/NGPC homebrew was found that combines a real named title, an explicit author licence or redistribution statement, and a stable direct URL; 'PD' tags on individually found ROMs are third-party cataloguing, not author grants";
    }
  ];
in
assert lib.assertMsg (lib.length homebrewFixtures == 16) ''
  tests/kiosk.nix: expected 16 pinned homebrew fixtures (the vm-test spec's
  core-family coverage), got ${toString (lib.length homebrewFixtures)}.
'';
assert lib.assertMsg (lib.length exemptFamilies == 2) ''
  tests/kiosk.nix: expected 2 named-exempt core families, got
  ${toString (lib.length exemptFamilies)}.
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

      def read_target_value(target, key_name):
          """The on-disk value for one retroachievements target's key.

          None if the target's table does not declare this key at all (e.g.
          "token" for the ppsspp target, which carries it in `token_file`
          instead) or if the file does not have it written. RetroArch's flat
          format quotes its values; every other declared format here is
          `ini`, so the two are told apart by whether the entry carries a
          `section`, exactly as emubox_prepare.py's own validation does.
          """
          entry = target["keys"].get(key_name)
          if entry is None:
              return None
          text = machine.succeed(f"cat {resolve(APPDATA, entry['file'])}")
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
          # this test already checked. `retroachievements` is no longer null
          # since emulators-retroachievements (design D1): `modules/emulators`
          # defaults `emubox.retroachievements.enable` to true, so this node
          # carries a real namespace rather than the disabled sentinel. Only
          # the namespace's own shape is pinned here - the api_url this node
          # set, the declared-off hardcore default, and which five emulators
          # own a target - not every key spelling, which is what
          # test_emubox_prepare.py's own unit tests already pin per encoding
          # (design D4: "verified at apply time").
          ra = owned["retroachievements"]
          assert ra is not None, owned["retroachievements"]
          assert ra["api_url"] == RA_API_URL, ra["api_url"]
          assert ra["hardcore"] is False, ra["hardcore"]
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

      # --- emulators: BIOS-free core families launch headless (design D7) --

      with subtest("Every BIOS-free core family with a licensed ROM runs headless"):
          # video_driver overridden per run (design D7), not baked into the
          # frontend's own owned copy of retroarch.cfg, which stays
          # fullscreen for the box; only this ad hoc run needs a driver that
          # produces no GPU output at all. audio_driver is overridden the
          # same way - this VM has no real audio device, and RetroArch's
          # default driver would otherwise just log an ALSA failure and
          # continue, noise this test has no reason to invite.
          override = "/tmp/emubox-retroarch-headless-override.cfg"
          machine.succeed(
              f"printf '%s\\n' 'video_driver = \"null\"' 'audio_driver = \"null\"' > {override}"
          )
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
              # `--max-frames` is also what forces even the two fixtures that
              # never exit on their own (DOSBox Pure's looping demo,
              # Vectrex's free-running animation) to a clean exit 0 - this
              # design's "assert liveness over frames" in practice, since
              # RetroArch itself decides to quit, not the content.
              out = machine.succeed(f"su player -s /bin/sh -c {shlex.quote(cmd)}")
              assert fixture["core"] in out, (
                  f"{fixture['family']}: expected {fixture['core']!r} in the RetroArch log\n{out}"
              )

      # --- standalones: smoke launch (design D7) ----------------------------

      def standalone_smoke_launch(binary, settle=5):
          """Prove a standalone starts against its written configuration and
          stays up, then kill it.

          Not `--version`: this project has only source-verified that
          contract for two of these six binaries (ScummVM below, and
          separately for es-de/duckstation in the install test), and PCSX2's
          own command-line parser (read directly, pcsx2-qt/QtHost.cpp) is
          confirmed to exit 1 on `-version`/`-help` even though it printed
          the right thing first - so leaning on six different codebases'
          individual flag-handling would be asserting more than this project
          actually knows. A background launch, alive-check and kill instead
          proves exactly what the spec asks for ("the process starts"), the
          same pgrep-based idiom this file already uses for es-de throughout.

          QT_QPA_PLATFORM=offscreen and SDL_VIDEODRIVER=dummy are set
          regardless of which toolkit a given binary actually uses - an
          unused environment variable is a no-op - because this VM's only
          display is the virtio-gpu console cage already owns for es-de (the
          install test's own header: "the AppImage's Qt would fail without
          one"), so a second GUI app needs a display it can construct
          without a real compositor. This combination is not verified
          against every one of these five specific derivations in an actual
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

          def alive(_last):
              rc, _ = machine.execute(f"kill -0 {pid}")
              return rc == 0

          try:
              retry(alive, timeout_seconds=settle)
          except Exception:
              print(machine.execute(f"cat {log}")[1])
              raise
          machine.succeed(f"kill {pid}")
          machine.wait_until_fails(f"kill -0 {pid}", timeout=30)

      with subtest("Standalones smoke launch against their asserted configuration"):
          for binary in ["duckstation", "dolphin-emu", "pcsx2-qt", "azahar", "ppsspp"]:
              standalone_smoke_launch(binary)

          # ScummVM's CLI is well-established as safe with no display at all
          # (its `--version` is handled long before any toolkit init), so its
          # floor is the install test's own "nothing beyond --version"
          # pattern rather than the background-launch idiom above.
          out = machine.succeed("su player -s /bin/sh -c 'scummvm --version'")
          assert "ScummVM" in out, out
    '';
}
