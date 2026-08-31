host := "emubox"

# The admin's age key. sops reads ~/.config/sops/age/keys.txt on Linux but
# ~/Library/Application Support/sops/age/keys.txt on macOS; pinning the
# path keeps one location on every machine. SOPS_AGE_KEY_FILE wins if set.
age_key := env("SOPS_AGE_KEY_FILE", home_directory() / ".config/sops/age/keys.txt")

# The box's pre-generated SSH host key: kept outside git, backed up with the
# age key, injected into /persist by `just install`. EMUBOX_HOST_KEY
# overrides the path for both `host-key` and `install`.
host_key := env("EMUBOX_HOST_KEY", home_directory() / ".config/emubox/ssh_host_ed25519_key")

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

# Evaluate the host closure and the x86_64-linux checks without building (works on macOS)
eval:
    nix eval --raw .#nixosConfigurations.{{host}}.config.system.build.toplevel.drvPath
    nix eval --raw .#checks.x86_64-linux.vm.drvPath
    nix eval --raw .#checks.x86_64-linux.kiosk.drvPath
    nix eval --raw .#checks.x86_64-linux.session.drvPath
    nix eval --raw .#checks.x86_64-linux.closure-no-secrets.drvPath

# Build the host closure (needs an x86_64-linux builder)
build:
    nix build .#nixosConfigurations.{{host}}.config.system.build.toplevel --no-link --print-out-paths

# Build and run the install VM test (x86_64-linux builder with KVM)
vm-test:
    nix build .#checks.x86_64-linux.vm --no-link

# Build and run the kiosk VM test (x86_64-linux builder with KVM)
kiosk-test:
    nix build .#checks.x86_64-linux.kiosk --no-link

# Build the kiosk session script, which is what runs its shellcheck
# (x86_64-linux builder, no KVM needed). writeShellApplication shellchecks in
# its check phase, and `just check-all` is evaluation-only, so without this an
# edit to emubox-session can pass every check runnable on macOS and still fail
# CI. Seconds, unlike `just build`.
session-check:
    nix build .#checks.x86_64-linux.session --no-link

# Prove no test secret value is in the system closure (x86_64-linux builder)
closure-check:
    nix build .#checks.x86_64-linux.closure-no-secrets --no-link

# Push the cache roots (redistributable unfree cores, the packages pkgs/
# builds) to the emubox Cachix
# cache, as CI does; needs CACHIX_AUTH_TOKEN and an x86_64-linux builder
cache-push:
    nix build .#packages.x86_64-linux.cache-roots --no-link --print-out-paths | xargs cachix push emubox

# Interactive VM for poking at the kiosk (x86_64-linux)
vm:
    nixos-rebuild build-vm --flake .#{{host}} && ./result/bin/run-{{host}}-vm

# Lint GitHub workflows
lint-actions:
    actionlint
    zizmor .github/workflows

# Everything that can run on this machine: what CI runs (formatting, flake
# check, evaluation) plus the workflow lint
check-all: fmt-check flake-check eval lint-actions

# Edit the box's secrets (admin age key)
secrets-edit:
    SOPS_AGE_KEY_FILE={{quote(age_key)}} sops secrets/secrets.yaml

# Re-encrypt the box's secrets to the recipients in .sops.yaml
secrets-rekey:
    SOPS_AGE_KEY_FILE={{quote(age_key)}} sops updatekeys secrets/secrets.yaml

# Edit the VM tests' secrets (decrypts with the committed test host key)
test-secrets-edit:
    SOPS_AGE_KEY="$(ssh-to-age -private-key -i tests/test_host_ed25519_key)" sops secrets/test.yaml

# Generate the box's SSH host key if absent and print its age recipient
host-key path=host_key:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -e {{quote(path)}} ]; then
        mkdir -p "$(dirname {{quote(path)}})"
        ssh-keygen -q -t ed25519 -N "" -C "emubox host key" -f {{quote(path)}}
    fi
    if [ ! -e {{quote(path)}}.pub ]; then
        ssh-keygen -y -f {{quote(path)}} > {{quote(path)}}.pub
    fi
    echo "age recipient for .sops.yaml (&emubox): $(ssh-to-age < {{quote(path)}}.pub)"

# Install the box over Ethernet: partition, install, inject the host key, reboot
# (extra arguments go to nixos-anywhere, e.g. `just install <box> --build-on remote`)
install target *args:
    #!/usr/bin/env bash
    set -euo pipefail
    key={{quote(host_key)}}
    for f in "$key" "$key.pub"; do
        if [ ! -e "$f" ]; then
            echo "no host key at $f; run: just host-key" >&2
            exit 1
        fi
    done
    if [ ! -e {{quote(age_key)}} ]; then
        echo "no admin age key at {{age_key}}; see secrets/README.md" >&2
        exit 1
    fi
    # Refuse to install placeholder secrets. Decrypting into a variable
    # first makes a failed decrypt a loud failure, not a skipped check.
    plain="$(SOPS_AGE_KEY_FILE={{quote(age_key)}} sops decrypt secrets/secrets.yaml)"
    if printf '%s' "$plain" | grep -q REPLACE-BEFORE-INSTALL; then
        echo "secrets/secrets.yaml still holds placeholders; run: just secrets-edit" >&2
        exit 1
    fi
    staging="$(mktemp -d)"
    trap 'rm -rf "$staging"' EXIT
    install -d -m 755 "$staging/persist/etc/ssh"
    install -m 600 "$key" "$staging/persist/etc/ssh/ssh_host_ed25519_key"
    install -m 644 "$key.pub" "$staging/persist/etc/ssh/ssh_host_ed25519_key.pub"
    nixos-anywhere --flake .#{{host}} --extra-files "$staging" {{args}} "root@{{target}}"
