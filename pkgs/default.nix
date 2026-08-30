# Package set for both `packages.x86_64-linux` and the overlay: what this
# project builds itself because the pinned nixpkgs no longer carries it.
# Each package's header records where it came from and why it is here.
# `callPackage` resolves ES-DE's `freeimage` argument to the vendored one
# because the overlay puts this set on `final`.
{ pkgs }:
{
  freeimage = pkgs.callPackage ./freeimage/package.nix { };
  es-de = pkgs.callPackage ./es-de/package.nix { };
  duckstation = pkgs.callPackage ./duckstation/package.nix { };
}
