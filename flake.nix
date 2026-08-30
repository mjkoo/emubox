{
  description = "emubox: a NixOS retro-emulation appliance for a Beelink EQ14";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    impermanence.url = "github:nix-community/impermanence";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
      # The one target the appliance builds for.
      hostSystem = "x86_64-linux";
      # One configuration for the host's package set and, through hostPkgs
      # below, for the standalone packages: they are the same store paths.
      nixpkgsConfig = {
        # Emulator cores such as libretro-snes9x are unfree-redistributable.
        allowUnfree = true;
        # FreeImage (pkgs/freeimage) is the derivation nixpkgs removed over
        # its unpatched CVEs; ES-DE has no other image backend. The risk is
        # accepted because FreeImage only ever decodes images the admin put
        # on the box (art scraped from ScreenScraper, bundled theme assets):
        # no untrusted input reaches it. CI builds it whenever its inputs
        # change, so a library bump that breaks it surfaces before the box.
        # If the source build becomes unmaintainable, the fallback is
        # wrapping ES-DE's own AppImage and dropping this permission. The
        # name is pname-version, as nixpkgs matches it. The overlay puts
        # this freeimage on the whole package set, so the permission is
        # host-wide; ES-DE is the only consumer, and the scope the risk was
        # accepted for.
        permittedInsecurePackages = [ "freeimage-3.18.0-unstable-2024-04-18" ];
      };
      # The host and its package set: nixpkgsConfig and the overlay applied,
      # the one set the standalone packages and cache-roots read (design
      # D3). The assertion keeps `packages.${hostSystem}` honest if the host
      # ever changes platform.
      host = self.nixosConfigurations.emubox;
      hostPkgs =
        assert host.pkgs.stdenv.hostPlatform.system == hostSystem;
        host.pkgs;
      vendored = import ./pkgs { pkgs = hostPkgs; };
    in
    {
      # Vendored packages (ES-DE, freeimage, DuckStation) live in pkgs/ and are
      # exposed both as an overlay and as flake packages so CI can push them to
      # the public binary cache on their own, without the system closure.
      overlays.default = import ./overlays { inherit inputs; };

      # Only for the host's system: the vendored packages are Linux-only, and
      # `nix flake check` on the Mac would evaluate (and reject) anything
      # offered under its own system. Built from the host's own package set,
      # which carries nixpkgsConfig and the overlay, so `nix build
      # .#packages.x86_64-linux.es-de` is the host's store path by
      # construction, not a second build that happens to agree with it.
      packages.${hostSystem} = vendored // {
        # What the binary cache holds: the store paths cache.nixos.org never
        # has, so every consumer without the cache (CI, the Mac's builder,
        # the box) would compile them. Hydra builds no unfree package, which
        # is every RetroArch core the emulators module selects that carries
        # a non-free license; the vendored packages under pkgs/ are ours and
        # are pushed whole: the cache is kept licence-clean by what is
        # vendored, not by a filter here (design). DuckStation's licence
        # (CC-BY-NC-ND 4.0) reads `redistributable = false` in nixpkgs'
        # metadata; pkgs/duckstation/package.nix records why pushing its
        # unmodified upstream contents is within that licence. CI pushes
        # exactly this closure (`just cache-push` does the same by hand),
        # never a system toplevel, so the cache stays small.
        cache-roots =
          let
            licenses = p: lib.toList (p.meta.license or [ ]);
            isUnfree = p: lib.any (l: !(l.free or true)) (licenses p);
            # `free` is not the field that governs redistribution; nixpkgs
            # carries `redistributable` separately, and the two differ
            # exactly where it matters (cc-by-nc-nd-40 is free = false,
            # redistributable = false). `lib.all`, deliberately, and not the
            # `lib.any` its neighbour uses: a core one of whose licences
            # forbids redistribution must not reach a public cache, which is
            # the hole this guard exists to close. A core dropped here is
            # built by whoever needs it and no closure changes (design D7).
            isRedistributable = p: lib.all (l: l.redistributable or l.free or false) (licenses p);
            retroarchs = lib.filter (p: p ? cores) host.config.environment.systemPackages;
            unfreeCores = lib.unique (
              lib.filter (p: isUnfree p && isRedistributable p) (lib.concatMap (r: r.cores) retroarchs)
            );
          in
          hostPkgs.linkFarm "emubox-cache-roots" (
            map (p: {
              name = p.name;
              path = p;
            }) (unfreeCores ++ lib.attrValues vendored)
          );
      };

      # Everything that is not tied to the physical disk: importable by a
      # future second host. Consumers supply a nixpkgs with `overlays.default`
      # applied.
      nixosModules.emubox = {
        imports = [
          inputs.impermanence.nixosModules.impermanence
          inputs.sops-nix.nixosModules.sops
          ./modules
        ];
      };

      nixosConfigurations.emubox = lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          {
            nixpkgs.overlays = [ self.overlays.default ];
            nixpkgs.config = nixpkgsConfig;
          }
          inputs.disko.nixosModules.disko
          self.nixosModules.emubox
          ./hosts/emubox
        ];
      };

      # One expression per system rather than a `checks.${hostSystem}`
      # assignment beside a `forAllSystems` one, which would collide on
      # x86_64-linux. That system carries both sets; every other system
      # carries only emubox-prepare, which is the point of checking it
      # per-system: the admin's Mac runs the Python tests, lint and type
      # check natively, with no VM involved (design D4).
      checks = forAllSystems (
        system:
        let
          # `pkgsFor` is bare legacyPackages - no nixpkgsConfig, no overlay -
          # so the package is reached by callPackage on the file rather than
          # by importing ./pkgs, whose other entries are Linux-only.
          perSystem.emubox-prepare = (pkgsFor system).callPackage ./pkgs/emubox-prepare/package.nix { };

          # The host configuration extended with the test module: the VM
          # test installs and boots its toplevel, and the closure check greps
          # that same toplevel, so a test override reaches both.
          testHost = self.nixosConfigurations.emubox.extendModules { modules = [ ./tests ]; };

          # Built from hostPkgs, so a VM node's package set is the host's,
          # nixpkgsConfig and overlay included.
          hostOnly = {
            toplevel = self.nixosConfigurations.emubox.config.system.build.toplevel;
            # disko's install test: format the real layout, install, boot
            # through the boot loader, then run tests/default.nix's checks.
            vm = testHost.config.system.build.installTest;
            # The host's software modules as a plain node with a graphical
            # stack: the session, its crash counter and the greeter.
            kiosk = hostPkgs.testers.runNixOSTest (import ./tests/kiosk.nix { inherit self; });
            # No test secret value in any store path of the test closure.
            closure-no-secrets = import ./tests/closure-no-secrets.nix {
              pkgs = testHost.pkgs;
              toplevel = testHost.config.system.build.toplevel;
            };
          };
        in
        perSystem // lib.optionalAttrs (system == hostSystem) hostOnly
      );

      # nixfmt-tree with ruff added, so `nix fmt` and `nix fmt -- --ci` (what
      # CI and `just fmt-check` run) cover Python as well as Nix. `ruff check`
      # is not a formatter - it would need --fix to be one, and this
      # project's checks never mutate - so it lives in the package's
      # checkPhase instead (design D4).
      formatter = forAllSystems (
        system:
        (pkgsFor system).nixfmt-tree.override {
          runtimeInputs = [ (pkgsFor system).ruff ];
          settings.formatter.ruff-format = {
            command = "ruff";
            options = [ "format" ];
            includes = [ "*.py" ];
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              just
              # secrets and the host key
              sops
              age
              ssh-to-age
              openssh
              # install and deploy
              nixos-anywhere
              nixos-rebuild-ng
              # CI lint
              actionlint
              shellcheck
              zizmor
              # emubox-prepare: what its checkPhase runs, so the same
              # commands are available by hand. `nix fmt` reaches ruff
              # through the formatter override, but only for formatting.
              python3
              python3.pkgs.pytest
              ruff
              ty
              # binary cache (`just cache-push`)
              cachix
            ];
          };
        }
      );
    };
}
