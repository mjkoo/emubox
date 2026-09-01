#!/usr/bin/env bash
# Restricted operator interface for the same restic environment automation
# uses.  The Nix module sets EMUBOX_RESTIC_ENV to a root-only sops template.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "emubox-restic: root only" >&2
  exit 77
fi

: "${EMUBOX_RESTIC_ENV:?emubox-restic requires EMUBOX_RESTIC_ENV}"
set -a
# shellcheck source=/dev/null
. "$EMUBOX_RESTIC_ENV"
set +a

operation="${1:-}"
[ -n "$operation" ] || {
  echo "usage: emubox-restic {snapshots|stats|ls|find|restore --verify SNAPSHOT --target DIR}" >&2
  exit 64
}
shift

reject_option() {
  for argument in "$@"; do
    case "$argument" in
      -*)
        echo "emubox-restic: global options are not accepted" >&2
        exit 64
        ;;
    esac
  done
}

case "$operation" in
  snapshots|stats)
    [ "$#" -eq 0 ] || exit 64
    exec restic "$operation"
    ;;
  ls|find)
    [ "$#" -gt 0 ] || exit 64
    reject_option "$@"
    exec restic "$operation" "$@"
    ;;
  restore)
    [ "$#" -eq 4 ] && [ "$1" = "--verify" ] && [ "$3" = "--target" ] || exit 64
    case "$2" in -*) exit 64 ;; esac
    case "$4" in /*) ;; *) exit 64 ;; esac
    exec restic restore --verify "$2" --target "$4"
    ;;
  *)
    echo "emubox-restic: command is not allowed" >&2
    exit 64
    ;;
esac
