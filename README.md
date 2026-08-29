# emubox

A NixOS retro-emulation appliance for a Beelink EQ14 (Intel N150): boots
straight into a controller-driven ES-DE game library, ephemeral OS root
with persistent family data on `/data`, RetroAchievements, versioned
off-site save backups, and remote administration over a Cloudflare Tunnel.

## Layout

```
flake.nix          inputs, nixosConfigurations.emubox, packages, checks, devShell
hosts/emubox/      the physical box: hardware facts, disko layout
modules/           the software stack, one directory per concern
overlays/, pkgs/   vendored packages (ES-DE, freeimage, DuckStation)
tests/             NixOS VM test
secrets/           sops file (encrypted) and its recipients in .sops.yaml
```

## Development

`direnv allow` (or `nix develop`) provides every tool the justfile needs;
`just` lists the recipes. `just check-all` runs what CI runs. Evaluating
the host works from macOS; building it or the VM test needs an
`x86_64-linux` builder.

## Install

`nixos-anywhere --flake .#emubox root@<box>` over Ethernet, then restore
`/data` from backup or start empty.
