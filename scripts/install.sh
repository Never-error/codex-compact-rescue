#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/install.sh --codex-bin PATH --patched-bin PATH [--backup-dir DIR] [--no-resign-app] [--yes]

Back up an installed Codex bundled CLI and replace it with a patched binary.
When installing into a macOS .app bundle, the outer app bundle is ad-hoc signed
after replacement so CodeResources accepts the new Resources/codex hash.
USAGE
}

codex_bin=""
patched_bin=""
backup_dir=""
assume_yes="false"
resign_app="auto"

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
    --no-resign-app)
      resign_app="false"
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
target_dir="$(dirname "$codex_bin")"
tmp_path="$target_dir/$(basename "$codex_bin").patched-$timestamp"
original_group="$(stat -f '%Sg' "$codex_bin" 2>/dev/null || stat -c '%G' "$codex_bin" 2>/dev/null || true)"

cleanup_tmp() {
  rm -f "$tmp_path"
}
trap cleanup_tmp EXIT

cp -p "$codex_bin" "$backup_path"
cp "$patched_bin" "$tmp_path"
chmod --reference="$codex_bin" "$tmp_path" 2>/dev/null || chmod 0755 "$tmp_path"
xattr -c "$tmp_path" 2>/dev/null || true
mv "$tmp_path" "$codex_bin"
if [[ -n "$original_group" ]]; then
  chgrp "$original_group" "$codex_bin" 2>/dev/null || true
fi

echo "backup=$backup_path"
echo "installed=$codex_bin"

if [[ "$resign_app" == "auto" &&
      "$(uname -s)" == "Darwin" &&
      "$codex_bin" == *.app/Contents/Resources/codex ]]; then
  app_path="${codex_bin%/Contents/Resources/codex}"
  if command -v codesign >/dev/null; then
    codesign --force --sign - --preserve-metadata=entitlements,requirements,flags,runtime "$app_path" >/dev/null
    echo "resigned_app=$app_path"
  else
    echo "codesign not found; app bundle was not re-signed" >&2
    exit 1
  fi
fi
