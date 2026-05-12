#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/restore.sh --codex-bin PATH --backup PATH [--yes]

Restore a previously backed-up Codex bundled CLI.
USAGE
}

codex_bin=""
backup=""
assume_yes="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex-bin)
      codex_bin="${2:-}"
      shift 2
      ;;
    --backup)
      backup="${2:-}"
      shift 2
      ;;
    --yes)
      assume_yes="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$codex_bin" ]] || { echo "--codex-bin is required" >&2; exit 2; }
[[ -n "$backup" ]] || { echo "--backup is required" >&2; exit 2; }
[[ -f "$backup" ]] || { echo "backup not found: $backup" >&2; exit 1; }

if [[ "$assume_yes" != "true" ]]; then
  echo "Refusing to restore $codex_bin without --yes" >&2
  exit 2
fi

install -m 0755 "$backup" "$codex_bin"

echo "restored=$codex_bin"
echo "backup=$backup"
