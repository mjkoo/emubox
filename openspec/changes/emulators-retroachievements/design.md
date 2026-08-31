## Context

See proposal.md - Why. What exists after E3: `emubox-prepare` runs
before every frontend launch with the invocation contract from the
kiosk-session design (one owned-values JSON argument, one custom-systems
path argument, `ESDE_APPDATA_DIR` from the environment), owning keys in
three formats (`esde-xml`, `ini`, `retroarch`); the kiosk capability's
custom-systems option exists and ships empty; `modules/emulators`
installs the cores bundle and the six standalones but asserts nothing.
The DuckStation package is the pinned upstream AppImage v0.1-11752,
unmodifiable by licence.

Facts this design leans on, verified against source on 2026-08-30:

- DuckStation v0.1-11752 stores the RetroAchievements token in
  `settings.ini [Cheevos] Token` encrypted: SHA-256 over the raw bytes
  of `/etc/machine-id` followed by the username, then 100 further
  SHA-256 rounds of the digest; AES-128-CBC with key = digest bytes
  0-15 and IV = bytes 16-31; the token zero-padded to 16-byte blocks;
  ciphertext base64-encoded. `Username` and `LoginTimestamp` (epoch
  seconds) are written beside it. A failed decrypt discards the saved
  login. The scheme has no randomness, so the ciphertext is a pure
  function of machine id, username and token - reproducible and
  idempotent to assert by string comparison.
- The box persists `/etc/machine-id` across the root wipe (an E1 test
  assertion), so the encrypted token stays valid for the life of the
  install.
- RetroArch persists `cheevos_username` and a plaintext `cheevos_token`
  in `retroarch.cfg` and logs in with the token when it is set, never
  needing `cheevos_password`; an invalid token is cleared and only then
  does it fall back to the password key. Hardcore is
  `cheevos_hardcore_mode_enable`, the master switch `cheevos_enable`.

### The system table

Which emulator serves each system, and whether its core needs firmware
from `/data/bios` to run anything at all. "No" families are the pool
the VM test's homebrew launches draw from (D7); "yes" systems are
hardware checklist lines. A flag is corrected as config data if pinning
the D6 inventory or a D7 fixture at apply time proves it wrong.

| System | Emulator | BIOS required |
|---|---|---|
| Atari 2600 | RetroArch: Stella | no |
| Atari 7800 | RetroArch: ProSystem | no (BIOS optional) |
| Atari Lynx | RetroArch: Handy | yes |
| NES | RetroArch: Mesen | no |
| Famicom Disk System | RetroArch: Mesen | yes |
| SNES | RetroArch: Snes9x | no |
| N64 | RetroArch: Mupen64Plus-Next | no |
| GB / GBC | RetroArch: Gambatte | no |
| GBA | RetroArch: mGBA | no (BIOS optional) |
| Virtual Boy | RetroArch: Beetle VB | no |
| WonderSwan | RetroArch: Beetle Cygne | no |
| Neo Geo Pocket | RetroArch: Beetle NeoPop | no |
| SMS / Game Gear / Genesis | RetroArch: Genesis Plus GX | no |
| Sega CD | RetroArch: Genesis Plus GX | yes |
| Sega 32X | RetroArch: PicoDrive | no |
| Saturn | RetroArch: Beetle Saturn | yes |
| Dreamcast | RetroArch: Flycast | no (HLE BIOS) |
| PS1 | DuckStation standalone; Beetle PSX HW core as alternate | yes |
| PC Engine / TurboGrafx-16 | RetroArch: Beetle PCE Fast | no |
| SuperGrafx | RetroArch: Beetle SuperGrafx | no |
| PCE CD / TurboGrafx-CD | RetroArch: Beetle PCE Fast | yes |
| Arcade | RetroArch: FBNeo | yes (board BIOS sets beside the ROMs) |
| Nintendo DS | RetroArch: melonDS | yes |
| PSP | PPSSPP standalone | no |
| GameCube / Wii | Dolphin standalone | no |
| PS2 | PCSX2 standalone | yes |
| 3DS | Azahar standalone | no |
| DOS | RetroArch: DOSBox Pure | no |
| ScummVM | ScummVM standalone | no |
| Amiga | RetroArch: PUAE | yes (Kickstart) |
| C64 | RetroArch: VICE | no |
| MSX | RetroArch: blueMSX | yes (machine ROMs) |
| Vectrex | RetroArch: vecx | no |
| Intellivision | RetroArch: FreeIntv | yes |
| ColecoVision | RetroArch: blueMSX | yes |

## Goals / Non-Goals

**Goals:**

- Every owned emulator setting flows through the existing prepare
  mechanism and anchor; no second configuration channel.
- RetroAchievements works with zero manual steps on the box, and its
  absence (offline, disabled, bad credentials) costs nothing but the
  achievements themselves.
- Everything the VM can prove is proven there; only BIOS-dependent
  cores and real performance are deferred to the E12 hardware
  checklist.

**Non-Goals:**

- Save and state path redirection (E5 owns those keys, including
  RetroArch's `savefile_directory`/`savestate_directory`).
- Controller mappings and hotkey *bindings* per pad (E6); this change
  pins which hotkey actions exist and their combos, not per-device
  button tables.
- Per-game tuning; a system that disappoints on hardware is a config
  data change at E12.

## Decisions

### D1. The owned-values JSON grows a second namespace

Prepare's invocation contract (two positional arguments, environment
root) is unchanged, but the owned-values JSON becomes
`{"files": {...}, "retroachievements": {...} | null}` instead of the
bare file map. `files` is exactly the old map, now also carrying the
emulator config files. `retroachievements`, when non-null, carries the
username file path, password file path, cache file path, the hardcore
flag, the API URL, and the per-emulator token targets. A null `retroachievements` means the
feature is disabled; there is no separate enabled flag inside the
namespace. Alternative
considered: encode credentials as values in the file map - rejected
because the JSON is a world-readable store path, so it may only carry
*paths* to secrets (`/run/secrets/...`), never their contents, and
because token values are computed at runtime, not declared.

### D2. Login lives in prepare, token cached on disk

Prepare resolves the token before building its owned tables: POST the
RA `login2` API on every run (5 second timeout); on success write or
refresh the cache (mode 0600, owned by `player`, under the appdata
root so the root wipe cannot eat it); on network failure fall back to
the cache if one exists; on network failure without one, log to stderr
and drop the account-name and token keys from the tables (the enabled
and hardcore keys are still written as declared, and the emulators
fail their own login harmlessly); on an
invalid-credentials response, log the rejection to stderr, delete the
cache and continue as if absent, so the next run against corrected
credentials logs in fresh.
The cache exists only to survive offline boots; it never pre-empts a
reachable API, which is what lets a token revoked by a password change
heal with no manual step. The API URL comes from the JSON (default the real service) so
the VM test points prepare at a mock without patching. Alternative - a
separate network-ordered oneshot writing the cache - was considered and
rejected with the user: it moves the same failure mode (first launch
without tokens) into the steady state and adds a unit and a race for no
gain, while the timeout bounds the cost of the in-path call.

### D3. DuckStation's token is encrypted by prepare, deterministically

Prepare implements the v0.1-11752 scheme from Context exactly, hashing
the machine-id file's raw bytes (trailing newline included, matching
DuckStation's whole-file read). Because the scheme is deterministic,
the encrypted value participates in the normal assert-and-compare flow;
no special idempotency handling. `python3Packages.cryptography`
provides AES (alternative: vendoring a pure-Python AES - rejected,
nixpkgs already carries the real thing). `LoginTimestamp` is written
only when the token value changes, so an unchanged token leaves the
file untouched. The AppImage bump runbook in `pkgs/duckstation` gains a
step: diff `src/core/achievements.cpp` token functions against the
recorded scheme before bumping. The wrapper is checked once at apply
time to confirm DuckStation does not consider itself portable (portable
mode would drop the machine key from the derivation).

### D4. Owned tables per emulator, key names verified at apply

RetroArch and each standalone get an owned-keys table in
`modules/emulators`, flowing into the kiosk module's owned-values
option. Settled values: RetroArch `libretro_directory` to the cores
bundle, `system_directory=/data/bios`, `autosave_interval=30`,
fullscreen, ozone menu, online-updater menu entries off, the uniform
hotkey combo set; Dolphin Wii dual core off and fullscreen; PCSX2
native internal resolution; DuckStation PGXP and a 1080p-appropriate
upscale; PPSSPP, Azahar, ScummVM fullscreen and quiet-start keys. The
exact key spellings and file paths are read from each emulator's source
at apply time, the way E3 read ES-DE's, and recorded in the module as
the table itself; the design fixes which knobs are owned, not their
spellings. PCSX2's split of achievements keys across `PCSX2.ini` and
`secrets.ini` is verified there too.

Read at apply time and recorded here because it changes the mechanism
rather than a spelling: PPSSPP does not keep its RetroAchievements token
in a settings key at all. `AchievementsToken` in `ppsspp.ini` is loaded
into the config struct but the login path never reads it; the token
PPSSPP actually uses is the entire contents of a separate raw file,
`PSP/SYSTEM/ppsspp_retroachievements.dat`, with no key-and-value framing
of any kind. Prepare therefore grows a third token encoding beside the
plain and DuckStation ones: a whole-file write of the token at mode
0600, deleted rather than left stale when no token resolves. The
requirement is untouched - the token still reaches PPSSPP "in the form
that emulator reads at rest" - but the claim that every owned value
flows through the three settings-file editors no longer holds, and one
file the flake writes is a credential rather than a settings file. Two
neighbouring findings that are only spellings, kept here because each
would otherwise look like a mistake: Dolphin keeps its achievements
keys in a separate `RetroAchievements.ini` beside `Dolphin.ini`, and
PCSX2 serialises `upscale_multiplier` as a shortest-decimal `1`, so
asserting `1.000000` would rewrite the file before every launch and
never converge.

### D5. Frontend overrides ride the existing custom-systems option

`modules/emulators` contributes entries to `emubox.kiosk.customSystems`
for every system whose assigned emulator differs from ES-DE 3.4.1's
bundled default - PS1 with DuckStation first and Beetle PSX HW kept as
the alternate, plus whatever the apply-time diff of the bundled
`es_systems.xml` against the design's system table turns up. The kiosk
capability's mechanism and its empty-definition semantics are untouched.

### D6. BIOS list is data, the checker is a tiny tool

The BIOS inventory is a nix attrset (path under `/data/bios`, a digest
with the algorithm that produced it, human name) rendered to JSON in the
store; `emubox-check-bios` is a
small self-contained Python script packaged beside prepare that reads
the JSON, hashes files, prints one line per entry and exits non-zero on
any miss - no options, no writes.

The algorithm is named per entry rather than fixed at sha256, which this
decision first assumed. Read at apply time: nobody publishes sha256 for
these files. DuckStation's own table is MD5, libretro's documented
requirements are MD5, the usable DS reference is CRC32, and PCSX2 does
not hash at all - it validates by file size and ROMVER string. Since a
digest cannot be converted between algorithms without the file, and
nobody involved may lawfully hold the files to compute one, fixing the
field at sha256 would mean an inventory that can never be populated from
a citable source, and a checker whose "everything declared matches"
scenario passes because nothing is declared. Naming the algorithm keeps
every published reference usable and lets a sha256 entry join later
without a second format. The requirement is untouched: it asks for a
name and checksum list, never for a particular algorithm. Files under `/data/bios` the
inventory does not declare are listed as informational extras and do
not affect the exit status. It ships in `environment.systemPackages`
for the admin over SSH; `emubox-status` (E5+) will consume the same
exit status.

### D7. VM assertions favour prepare-level truth over emulator-level ceremony

The kiosk VM test grows one assertion group (a sibling node only if
memory forces it): a mock RA endpoint (a python HTTP server on the test
network serving `login2` and a static token) with prepare's API URL
pointed at it; assertions that every supporting config carries the
token - DuckStation's by decrypting with an independent implementation
of the scheme in the test script - that no config carries the test
password, and both hardcore positions. Emulator launches: RetroArch
headless (`video_driver` overridden for the run) with one freely
redistributable homebrew ROM per BIOS-free core family, fetched by
URL and hash as test-only fixtures, asserting exit 0 and a core log
line; standalones smoke-launched just far enough to prove the binary
runs against the asserted config.

Read at apply time, and the reason the requirement now reads narrower
than this paragraph: four of the eighteen BIOS-free families are
exempt, not two. Atari 7800 and Neo Geo Pocket for licensing, as the
Open Questions record. N64 and Dreamcast for mechanism - RetroArch's
`video_driver_find_driver` forces a real GL driver whenever a core sets
a hardware render context, so the null-driver override is discarded and
the launch dies after the core log line is already printed (verified on
the x86_64-linux builder: mupen64plus-next segfaults, flycast exits on
"Cannot open video driver"). The log-line assertion also had to change:
the line the design first had in mind is echoed from the command line
before the core is opened at all, so it proved nothing, and the test now
requires a marker emitted only after content loads plus the absence of
the content-failure marker. And one standalone, ScummVM, cannot be
started far enough headless to read its config, so its smoke launch is
a version check that proves less; the requirement now says so, and the
test says which one and why. The group also proves the offline
path: a boot with no cached token and no route to the endpoint asserts
the frontend still arrives and the journal records the failed login.
Because `modules/emulators` now contributes custom-systems entries
unconditionally, the existing kiosk test's empty-definition assertions
must force `emubox.kiosk.customSystems` empty in their node instead of
relying on the shipped default. The emulators never talk to the mock:
what the VM proves is the configs, not the unlock ceremony, which is an
E12 line.

## Risks / Trade-offs

- [DuckStation changes the token scheme in a future release] → The
  version is pinned by hash, the bump runbook diffs the scheme first,
  and the VM test's independent decrypt breaks loudly if the recorded
  scheme and prepare ever disagree. Worst case is achievements lost on
  DuckStation until the transform is updated, never a broken launch.
- [RA API slow or flaky at boot] → 5 s timeout, one attempt per prepare
  run; every online boot pays the round-trip so the cache can stay a
  pure offline fallback. Worst case adds 5 s before the frontend on a
  half-up network.
- [Token cache under the appdata root reaches E5's backups] → Accepted
  for now; the token is revocable by password change and the E5 design
  decides inclusion or exclusion explicitly.
- [Homebrew fixture URLs rot] → Pinned by hash so rot is a loud fetch
  failure in CI, fixed by re-pinning; fixtures are test-only inputs,
  not part of the system closure.
- [Key spellings drift when an emulator is bumped] → The same risk E3
  accepted for ES-DE; prepare recreates unreadable files and asserts
  keys blindly, so a renamed key degrades to a default-behaviour bug
  caught by the VM assertions that read the configs.

## Open Questions

- Which homebrew title serves each BIOS-free core family, and the
  final override list D5's diff produces - both enumerable at apply
  time without changing the approach. Enumerated: 14 of the 18 BIOS-free
  families launch headless, seven of their fixtures from the 240p Test
  Suite and its ports. Four are exempt, for two different reasons, and
  the configuration records which reason applies to each. Atari 7800 and
  Neo Geo Pocket for licensing, after two independent searches: binaries
  exist, but none is paired with a written grant, and the fixtures are
  fetched by public CI and pushed through a public binary cache. N64 and
  Dreamcast for mechanism: their cores demand a hardware render context,
  which no VM can offer. All four move to the hardware checklist, which
  is what the vm-test requirement now says.
- The exact uniform hotkey combo set (menu, save, load, fast-forward,
  screenshot) - config data settled during apply with the controller
  layout in mind, before E6 maps it per pad. Settled: RetroArch's
  `input_<action>` keys hold keyboard names, and the gamepad `_btn` keys
  are written per pad by autoconfig, which is E6's table rather than
  this change's. So this change pins the keyboard names (f1 menu, f2
  save, f4 load, space fast-forward toggle, f8 screenshot) and the two
  device-independent gamepad combo enums, and touches no `_btn` key. A
  quit combo joins the set the design first listed: without one, a
  player who enters a core has no controller-only way back to the
  frontend.
