# Package set for both `packages.x86_64-linux` and the overlay: what this
# project builds itself. Two kinds live here - programs the pinned nixpkgs
# no longer carries, which are vendored, and programs of the project's own,
# which nixpkgs never carried. Each package's header records which it is,
# where it came from and why. `callPackage` resolves ES-DE's `freeimage`
# argument to the vendored one because the overlay puts this set on `final`.
{ pkgs }:
{
  freeimage = pkgs.callPackage ./freeimage/package.nix { };
  es-de = pkgs.callPackage ./es-de/package.nix { };
  duckstation = pkgs.callPackage ./duckstation/package.nix { };
  emubox-prepare = pkgs.callPackage ./emubox-prepare/package.nix { };
  emubox-check-bios = pkgs.callPackage ./emubox-check-bios/package.nix { };
}
