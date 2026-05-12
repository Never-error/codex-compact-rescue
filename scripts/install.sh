#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/install.sh --codex-bin PATH --patched-bin PATH [--backup-dir DIR] [--yes]

Back up an installed Codex bundled CLI and replace it with a patched binary.
USAGE
}

codex_bin=""
patched_bin=""
backup_dir=""
assume_yes="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex-bin)
      codex_bin="${2:-}"
      shift 2
      ;;
    --patched-bin)
      patched_bin="${2:-}"
      shift 2
      ;;
    --backup-dir)
      backup_dir="${2:-}"
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
[[ -n "$patched_bin" ]] || { echo "--patched-bin is required" >&2; exit 2; }
[[ -f "$codex_bin" ]] || { echo "codex binary not found: $codex_bin" >&2; exit 1; }
[[ -f "$patched_bin" ]] || { echo "patched binary not found: $patched_bin" >&2; exit 1; }

if [[ "$assume_yes" != "true" ]]; then
  echo "Refusing to replace $codex_bin without --yes" >&2
  exit 2
fi

if [[ -z "$backup_dir" ]]; then
  backup_dir="$(dirname "$codex_bin")"
fi
mkdir -p "$backup_dir"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_path="$backup_dir/$(basename "$codex_bin").backup-$timestamp"

cp -p "$codex_bin" "$backup_path"
install -m 0755 "$patched_bin" "$codex_bin"

echo "backup=$backup_path"
echo "installed=$codex_bin"
