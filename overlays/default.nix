# What pkgs/ builds, against the flake's own nixpkgs (design section 5:
# not a second pinned nixpkgs, which would drag a stale closure along).
{ inputs }:
final: prev: import ../pkgs { pkgs = final; }
