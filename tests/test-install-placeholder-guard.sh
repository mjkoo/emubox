#!/usr/bin/env bash
set -euo pipefail

guard=./scripts/emubox-install-placeholder-guard

printf '%s\n' \
  'b2_key_id: REPLACE-BEFORE-INSTALL' \
  'b2_application_key: REPLACE-BEFORE-INSTALL' \
  'restic_password: REPLACE-BEFORE-INSTALL' \
  | bash "$guard" false

if printf '%s\n' 'b2_key_id: REPLACE-BEFORE-INSTALL' | bash "$guard" true 2>/dev/null; then
  echo "enabled backup accepted its B2 placeholder" >&2
  exit 1
fi

if printf '%s\n' 'wifi_psk: REPLACE-BEFORE-INSTALL' | bash "$guard" false 2>/dev/null; then
  echo "disabled backup accepted a non-backup placeholder" >&2
  exit 1
fi

for key in screenscraper_username screenscraper_password; do
  for enabled in true false; do
    if message=$(printf '%s: REPLACE-BEFORE-INSTALL\n' "$key" | bash "$guard" "$enabled" 2>&1); then
      echo "accepted unresolved $key with backups=$enabled" >&2
      exit 1
    fi
    [[ "$message" == *"$key"* ]]
  done
done

for bad in '' maybe; do
  status=0
  if [ -z "$bad" ]; then
    message=$(bash "$guard" 2>&1) || status=$?
  else
    message=$(bash "$guard" "$bad" 2>&1) || status=$?
  fi
  [ "$status" -eq 2 ]
  [ "$message" = 'usage: emubox-install-placeholder-guard <true|false>' ]
done

# Execute the recipe's own expression, substituting its host template only.
# A separately written equivalent would miss a regression in the install path.
expression=$(sed -n 's/.*backup_enabled="$(\(nix eval .*\))"/\1/p' justfile)
expression=${expression//\{\{host\}\}/emubox}
[ -n "$expression" ]
# The expression is repository code, not caller input.
value=$(bash -c "$expression")
case "$value" in
  true|false) printf 'wifi_psk: configured\n' | bash "$guard" "$value" ;;
  *) echo "install emitted invalid backup flag: $value" >&2; exit 1 ;;
esac
