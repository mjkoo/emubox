#!/usr/bin/env bash
set -euo pipefail

guard=./scripts/emubox-install-placeholder-guard

printf '%s\n' \
  'b2_key_id: REPLACE-BEFORE-INSTALL' \
  'b2_application_key: REPLACE-BEFORE-INSTALL' \
  'restic_password: REPLACE-BEFORE-INSTALL' \
  | bash "$guard" false

if printf '%s\n' 'b2_key_id: REPLACE-BEFORE-INSTALL' | bash "$guard" true; then
  echo "enabled backup accepted its B2 placeholder" >&2
  exit 1
fi

if printf '%s\n' 'wifi_psk: REPLACE-BEFORE-INSTALL' | bash "$guard" false; then
  echo "disabled backup accepted a non-backup placeholder" >&2
  exit 1
fi
