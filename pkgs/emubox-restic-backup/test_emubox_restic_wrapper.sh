#!/usr/bin/env bash
set -euo pipefail

wrapper="${1:?wrapper path required}"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/logs"

cat > "$test_root/environment" <<'EOF'
RESTIC_REPOSITORY=s3:https://example.invalid/emubox
AWS_ACCESS_KEY_ID=key-id
AWS_SECRET_ACCESS_KEY=application-key
RESTIC_PASSWORD_FILE=/root/restic-password
EOF

cat > "$test_root/bin/id" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${EMUBOX_RESTIC_TEST_UID:?}"
EOF
chmod +x "$test_root/bin/id"

cat > "$test_root/bin/restic" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$RESTIC_REPOSITORY" > "$EMUBOX_RESTIC_TEST_LOG/env"
printf '%s\n' "$@" > "$EMUBOX_RESTIC_TEST_LOG/args"
EOF
chmod +x "$test_root/bin/restic"

run_wrapper() {
  PATH="$test_root/bin:$PATH" \
    EMUBOX_RESTIC_ENV="$test_root/environment" \
    EMUBOX_RESTIC_TEST_LOG="$test_root/logs" \
    EMUBOX_RESTIC_TEST_UID="$1" \
    "$wrapper" "${@:2}"
}

run_wrapper 0 snapshots
test "$(cat "$test_root/logs/args")" = "snapshots"
test "$(cat "$test_root/logs/env")" = "s3:https://example.invalid/emubox"

run_wrapper 0 restore --verify known-snapshot --target /tmp/restored
test "$(paste -sd ' ' "$test_root/logs/args")" = "restore --verify known-snapshot --target /tmp/restored"

rm -f "$test_root/logs/args"
if run_wrapper 0 snapshots --repo s3:https://attacker.invalid/repo; then
  echo "wrapper accepted arbitrary global option injection" >&2
  exit 1
fi
test ! -e "$test_root/logs/args"

if run_wrapper 1000 snapshots; then
  echo "wrapper allowed non-root invocation" >&2
  exit 1
fi
