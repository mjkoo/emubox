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
      # Emulator cores such as libretro-snes9x are unfree-redistributable.
      nixpkgsConfig.allowUnfree = true;
    in
    {
      # Vendored packages (ES-DE, freeimage, DuckStation) live in pkgs/ and are
      # exposed both as an overlay and as flake packages so CI can push them to
      # the public binary cache on their own, without the system closure.
      overlays.default = import ./overlays { inherit inputs; };

      packages = lib.recursiveUpdate (forAllSystems (system: import ./pkgs { pkgs = pkgsFor system; })) {
        # What the binary cache holds: the store paths cache.nixos.org never
        # has, so every consumer without the cache (CI, the Mac's builder,
        # the box) would compile them. Hydra builds no unfree package, which
        # is every RetroArch core the emulators module selects that carries
        # a non-free license; the vendored packages under pkgs/ are ours.
        # CI pushes exactly this closure (`just cache-push` does the same by
        # hand), never a system toplevel, so the cache stays small.
        ${hostSystem}.cache-roots =
          let
            host = self.nixosConfigurations.emubox;
            inherit (host) pkgs;
            licenses = p: lib.toList (p.meta.license or [ ]);
            isUnfree = p: lib.any (l: !(l.free or true)) (licenses p);
            retroarchs = lib.filter (p: p ? cores) host.config.environment.systemPackages;
            unfreeCores = lib.unique (lib.filter isUnfree (lib.concatMap (r: r.cores) retroarchs));
            vendored = lib.attrValues (import ./pkgs { inherit pkgs; });
          in
          pkgs.linkFarm "emubox-cache-roots" (
            map (p: {
              name = p.name;
              path = p;
            }) (unfreeCores ++ vendored)
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

      checks.${hostSystem} =
        let
          # The host configuration extended with the test module: the VM
          # test installs and boots its toplevel, and the closure check greps
          # that same toplevel, so a test override reaches both.
          testHost = self.nixosConfigurations.emubox.extendModules { modules = [ ./tests ]; };
        in
        {
          toplevel = self.nixosConfigurations.emubox.config.system.build.toplevel;
          # disko's install test: format the real layout, install, boot
          # through the boot loader, then run tests/default.nix's checks.
          vm = testHost.config.system.build.installTest;
          # No test secret value in any store path of the test closure.
          closure-no-secrets = import ./tests/closure-no-secrets.nix {
            pkgs = testHost.pkgs;
            toplevel = testHost.config.system.build.toplevel;
          };
        };

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);

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
              # binary cache (`just cache-push`)
              cachix
            ];
          };
        }
      );
    };
}
