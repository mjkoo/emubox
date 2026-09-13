# Evaluation-only guard that pkgs/emubox-status's single entry in
# pkgs/default.nix really does what every program this project writes
# owes: reachable through the overlay on the host's own package set,
# offered as a standalone x86_64-linux package output, and gathered into
# the store paths the cache roots push to the public cache - the same store
# path each time, not three separate builds that happen to agree.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  host = self.nixosConfigurations.emubox;
  standalone = self.packages.x86_64-linux.emubox-status;
  cacheRoots = self.packages.x86_64-linux.cache-roots;
in
assert lib.assertMsg (host.pkgs.emubox-status.pname == "emubox-status") ''
  tests/emubox-status-packaging.nix: pkgs.emubox-status must be reachable
  through the overlay on the host's own package set.
'';
assert lib.assertMsg (standalone.drvPath == host.pkgs.emubox-status.drvPath) ''
  tests/emubox-status-packaging.nix: the standalone x86_64-linux package
  output must be the exact same derivation the host's package set carries,
  not a second build that happens to agree with it.
'';
assert lib.assertMsg
  (lib.any (entry: entry.outPath == host.pkgs.emubox-status.outPath) (
    lib.attrValues cacheRoots.entries
  ))
  ''
    tests/emubox-status-packaging.nix: the cache roots linkFarm must gather
    emubox-status's own store path, so CI pushes it to the public cache
    and no consumer without the cache has to rebuild it.
  '';
pkgs.runCommand "emubox-status-packaging" { } ''
  touch "$out"
''
