# Package set for both `packages.<system>` and the overlay.
# TODO(design 5, 6): vendor from nixpkgs history and bump:
#   freeimage      nixpkgs 8451347 pkgs/by-name/fr/freeimage (keep CVE patches
#                  and knownVulnerabilities; permittedInsecurePackages names it)
#   es-de          nixpkgs 8451347 pkgs/by-name/em/emulationstation-de -> 3.4.1
#   duckstation    nixpkgs nixos-25.11 pkgs/by-name/du/duckstation (+ sources.json, update.sh)
{ pkgs }:
{
}
