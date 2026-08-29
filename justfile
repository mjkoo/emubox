host := "emubox"

default:
    @just --list

# Format nix files
fmt:
    nix fmt

# Check nix formatting without writing (what CI runs)
fmt-check:
    nix fmt -- --ci

# Run every flake check for this machine's system
flake-check:
    nix flake check

# Evaluate the host closure without building it (works on macOS)
eval:
    nix eval --raw .#nixosConfigurations.{{host}}.config.system.build.toplevel.drvPath

# Build the host closure (needs an x86_64-linux builder)
build:
    nix build .#nixosConfigurations.{{host}}.config.system.build.toplevel --no-link --print-out-paths

# Build and run the VM test (x86_64-linux with KVM)
vm-test:
    nix build .#checks.x86_64-linux.vm --no-link

# Interactive VM for poking at the kiosk (x86_64-linux)
vm:
    nixos-rebuild build-vm --flake .#{{host}} && ./result/bin/run-{{host}}-vm

# Lint GitHub workflows
lint-actions:
    actionlint
    zizmor .github/workflows

# What CI runs
check-all: fmt-check flake-check eval lint-actions
