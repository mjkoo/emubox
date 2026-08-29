host := "emubox"

# The admin's age key. sops reads ~/.config/sops/age/keys.txt on Linux but
# ~/Library/Application Support/sops/age/keys.txt on macOS; pinning the
# path keeps one location on every machine. SOPS_AGE_KEY_FILE wins if set.
age_key := env("SOPS_AGE_KEY_FILE", home_directory() / ".config/sops/age/keys.txt")

# The box's pre-generated SSH host key: kept outside git, backed up with the
# age key, injected into /persist by `just install`.
host_key := home_directory() / ".config/emubox/ssh_host_ed25519_key"

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

# Build and run the VM test (x86_64-linux builder with KVM)
vm-test:
    nix build .#checks.x86_64-linux.vm --no-link

# Prove no test secret value is in the system closure (x86_64-linux builder)
closure-check:
    nix build .#checks.x86_64-linux.closure-no-secrets --no-link

# Interactive VM for poking at the kiosk (x86_64-linux)
vm:
    nixos-rebuild build-vm --flake .#{{host}} && ./result/bin/run-{{host}}-vm

# Lint GitHub workflows
lint-actions:
    actionlint
    zizmor .github/workflows

# What CI runs
check-all: fmt-check flake-check eval lint-actions

# Edit the box's secrets (admin age key)
secrets-edit:
    SOPS_AGE_KEY_FILE={{quote(age_key)}} sops secrets/secrets.yaml

# Re-encrypt the box's secrets to the recipients in .sops.yaml
secrets-rekey:
    SOPS_AGE_KEY_FILE={{quote(age_key)}} sops updatekeys secrets/secrets.yaml

# Edit the VM test's secrets (decrypts with the committed test host key)
test-secrets-edit:
    SOPS_AGE_KEY="$(ssh-to-age -private-key -i tests/test_host_ed25519_key)" sops secrets/test.yaml

# Generate the box's SSH host key if absent and print its age recipient
host-key path=host_key:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -e {{quote(path)}} ]; then
        mkdir -p "$(dirname {{quote(path)}})"
        ssh-keygen -t ed25519 -N "" -C "emubox host key" -f {{quote(path)}}
    fi
    echo "age recipient for .sops.yaml (&emubox): $(ssh-to-age < {{quote(path)}}.pub)"

# Install the box over Ethernet: partition, install, inject the host key, reboot
install target key=host_key:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -e {{quote(key)}} ]; then
        echo "no host key at {{key}}; run: just host-key" >&2
        exit 1
    fi
    staging="$(mktemp -d)"
    trap 'rm -rf "$staging"' EXIT
    install -d -m 755 "$staging/persist/etc/ssh"
    install -m 600 {{quote(key)}} "$staging/persist/etc/ssh/ssh_host_ed25519_key"
    install -m 644 {{quote(key)}}.pub "$staging/persist/etc/ssh/ssh_host_ed25519_key.pub"
    nixos-anywhere --flake .#{{host}} --extra-files "$staging" "root@{{target}}"
