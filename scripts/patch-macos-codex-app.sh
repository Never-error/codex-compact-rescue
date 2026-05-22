#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
marker="retrying remote compaction with fallback model"
fallback_model="gpt-5.4-mini"
source_model="gpt-5.5"

usage() {
  cat <<'USAGE'
Usage: scripts/patch-macos-codex-app.sh --patched-bin PATH [options] --yes

Apply the compact fallback patched Codex bundled CLI to a local macOS
Codex.app using the no-resign replacement flow.

Options:
  --app-path PATH              Codex.app path. Default: /Applications/Codex.app
  --patched-bin PATH           Patched codex binary to install.
  --backup-root DIR            External backup directory. Default: ~/.codex/codex-app-backups/<timestamp>
  --upstream-ref REF           Upstream ref for patch compatibility check. Default: rust-v<codex-cli-version>
  --quit-app                   Ask Codex and Sparkle updater processes to exit before replacing the binary.
  --open-app                   Open Codex.app after installation.
  --move-bundle-backups        Move Contents/Resources/codex.backup-* to the external backup directory first.
  --skip-upstream-check        Skip openai/codex patch apply check.
  --allow-invalid-signature    Continue if the app is not currently official-signed.
  --force                      Continue even if the installed binary already has patch markers.
  --yes                        Actually patch the app.

This script intentionally uses --macos-app-mode no-resign. It does not ad-hoc
sign the outer app bundle, because that can make Codex Desktop fail GUI launch
on recent builds.
USAGE
}

app_path="/Applications/Codex.app"
patched_bin=""
backup_root=""
upstream_ref=""
quit_app="false"
open_app_after="false"
move_bundle_backups="false"
skip_upstream_check="false"
allow_invalid_signature="false"
force="false"
assume_yes="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      app_path="${2:-}"
      shift 2
      ;;
    --patched-bin)
      patched_bin="${2:-}"
      shift 2
      ;;
    --backup-root)
      backup_root="${2:-}"
      shift 2
      ;;
    --upstream-ref)
      upstream_ref="${2:-}"
      shift 2
      ;;
    --quit-app)
      quit_app="true"
      shift
      ;;
    --open-app)
      open_app_after="true"
      shift
      ;;
    --move-bundle-backups)
      move_bundle_backups="true"
      shift
      ;;
    --skip-upstream-check)
      skip_upstream_check="true"
      shift
      ;;
    --allow-invalid-signature)
      allow_invalid_signature="true"
      shift
      ;;
    --force)
      force="true"
      shift
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

[[ "$assume_yes" == "true" ]] || {
  echo "Refusing to patch without --yes" >&2
  exit 2
}
[[ "$(uname -s)" == "Darwin" ]] || {
  echo "this script only supports macOS" >&2
  exit 2
}
[[ -n "$patched_bin" ]] || { echo "--patched-bin is required" >&2; exit 2; }
[[ -d "$app_path" ]] || { echo "Codex.app not found: $app_path" >&2; exit 1; }
[[ -f "$patched_bin" ]] || { echo "patched binary not found: $patched_bin" >&2; exit 1; }

codex_bin="$app_path/Contents/Resources/codex"
resources_dir="$(dirname "$codex_bin")"
info_plist="$app_path/Contents/Info.plist"
[[ -f "$codex_bin" ]] || { echo "bundled codex binary not found: $codex_bin" >&2; exit 1; }

timestamp="$(date +%Y%m%d-%H%M%S)"
if [[ -z "$backup_root" ]]; then
  backup_root="$HOME/.codex/codex-app-backups/$timestamp"
fi
mkdir -p "$backup_root"

if [[ "$quit_app" == "true" ]]; then
  osascript -e 'quit app "Codex"' >/dev/null 2>&1 || true
  pkill -f 'Sparkle.framework/Versions/.*/Autoupdate|org.sparkle-project.Sparkle/Launcher/.*/Updater.app' 2>/dev/null || true
fi

bundle_backup_count=0
if [[ "$move_bundle_backups" == "true" ]]; then
  shopt -s nullglob
  bundle_backups=("$resources_dir"/codex.backup-*)
  if ((${#bundle_backups[@]} > 0)); then
    mkdir -p "$backup_root/bundle-backups"
    for bundle_backup in "${bundle_backups[@]}"; do
      mv "$bundle_backup" "$backup_root/bundle-backups/"
      bundle_backup_count=$((bundle_backup_count + 1))
    done
  fi
  shopt -u nullglob
fi

run_version() {
  local bin="$1"
  local out_file="$2"
  local err_file="$3"
  rm -f "$out_file" "$err_file"
  "$bin" --version >"$out_file" 2>"$err_file" &
  local pid="$!"
  for _ in {1..50}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 124
  fi
  wait "$pid"
}

current_version_out="$(mktemp)"
current_version_err="$(mktemp)"
patched_version_out="$(mktemp)"
patched_version_err="$(mktemp)"
current_strings="$(mktemp)"
patched_strings="$(mktemp)"
cleanup() {
  rm -f "$current_version_out" "$current_version_err" \
    "$patched_version_out" "$patched_version_err" \
    "$current_strings" "$patched_strings"
}
trap cleanup EXIT

app_version="unknown"
app_build="unknown"
if [[ -f "$info_plist" && -x /usr/libexec/PlistBuddy ]]; then
  app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null || echo unknown)"
  app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist" 2>/dev/null || echo unknown)"
fi

current_version_status="ok"
if ! run_version "$codex_bin" "$current_version_out" "$current_version_err"; then
  current_version_status="error"
fi
current_cli_version="$(head -n 1 "$current_version_out" || true)"
[[ -n "$current_cli_version" ]] || current_cli_version="unknown"
if [[ "$current_version_status" != "ok" || "$current_cli_version" == "unknown" ]]; then
  echo "current codex --version failed or timed out" >&2
  sed -n '1,20p' "$current_version_err" >&2 || true
  exit 1
fi

patched_version_status="ok"
if ! run_version "$patched_bin" "$patched_version_out" "$patched_version_err"; then
  patched_version_status="error"
fi
patched_cli_version="$(head -n 1 "$patched_version_out" || true)"
[[ -n "$patched_cli_version" ]] || patched_cli_version="unknown"
if [[ "$patched_version_status" != "ok" || "$patched_cli_version" == "unknown" ]]; then
  echo "patched codex --version failed or timed out" >&2
  sed -n '1,20p' "$patched_version_err" >&2 || true
  exit 1
fi

if [[ "$current_cli_version" != "$patched_cli_version" ]]; then
  echo "version mismatch: installed=$current_cli_version patched=$patched_cli_version" >&2
  exit 1
fi

strings "$codex_bin" >"$current_strings"
strings "$patched_bin" >"$patched_strings"

current_marker="false"
if rg -q "$marker" "$current_strings" &&
   rg -q "$fallback_model" "$current_strings" &&
   rg -q "$source_model" "$current_strings"; then
  current_marker="true"
fi

patched_marker="false"
if rg -q "$marker" "$patched_strings" &&
   rg -q "$fallback_model" "$patched_strings" &&
   rg -q "$source_model" "$patched_strings"; then
  patched_marker="true"
fi
[[ "$patched_marker" == "true" ]] || {
  echo "patched binary does not contain expected fallback marker strings" >&2
  exit 1
}

if [[ "$current_marker" == "true" && "$force" != "true" ]]; then
  echo "installed codex already appears patched; use --force to replace anyway" >&2
  exit 2
fi

signature_state="valid_official"
signature_before_verify="$backup_root/codesign-before-verify.txt"
if ! codesign --verify --deep --strict "$app_path" >"$signature_before_verify" 2>&1; then
  signature_state="invalid"
  if [[ "$allow_invalid_signature" != "true" ]]; then
    echo "app signature is not valid before patching:" >&2
    sed -n '1,40p' "$signature_before_verify" >&2
    echo "use --allow-invalid-signature only if this is expected" >&2
    exit 1
  fi
fi

if [[ -z "$upstream_ref" && "$current_cli_version" == codex-cli\ * ]]; then
  upstream_ref="rust-v${current_cli_version#codex-cli }"
fi

if [[ "$skip_upstream_check" != "true" ]]; then
  [[ -n "$upstream_ref" ]] || {
    echo "could not infer upstream ref; pass --upstream-ref or --skip-upstream-check" >&2
    exit 2
  }
  compat_output="$("$root_dir/scripts/check-upstream-compat.sh" --ref "$upstream_ref")"
  echo "$compat_output" >"$backup_root/upstream-compat.txt"
  echo "$compat_output" | rg -q '^patch_apply=ok$' || {
    echo "$compat_output" >&2
    echo "patch does not apply cleanly to $upstream_ref" >&2
    exit 1
  }
fi

cp -p "$codex_bin" "$backup_root/codex.current-before-patch"
if [[ -f "$info_plist" ]]; then
  cp -p "$info_plist" "$backup_root/Info.plist"
fi
codesign -dv --verbose=4 "$app_path" >"$backup_root/codesign-before.txt" 2>&1 || true
shasum -a 256 "$codex_bin" "$patched_bin" >"$backup_root/sha256-before.txt"

install_output="$("$root_dir/scripts/install.sh" \
  --codex-bin "$codex_bin" \
  --patched-bin "$patched_bin" \
  --backup-dir "$backup_root" \
  --macos-app-mode no-resign \
  --yes)"
echo "$install_output"
backup_path="$(echo "$install_output" | sed -n 's/^backup=//p' | tail -n 1)"

verify_args=(--codex-bin "$codex_bin" --expect-marker present)
if [[ "$skip_upstream_check" != "true" && -n "$upstream_ref" ]]; then
  verify_args+=(--upstream-ref "$upstream_ref")
fi
"$root_dir/scripts/verify.sh" "${verify_args[@]}"

installed_sha="$(shasum -a 256 "$codex_bin" | awk '{print $1}')"
patched_sha="$(shasum -a 256 "$patched_bin" | awk '{print $1}')"
if [[ "$installed_sha" != "$patched_sha" ]]; then
  echo "installed hash does not match patched binary" >&2
  exit 1
fi

post_signature_state="valid"
post_signature_output="$(mktemp)"
if ! codesign --verify --deep --strict "$app_path" >"$post_signature_output" 2>&1; then
  post_signature_state="invalid_expected_after_no_resign"
fi
cp "$post_signature_output" "$backup_root/codesign-after.txt"
rm -f "$post_signature_output"

disk_inode="$(stat -f '%i' "$codex_bin" 2>/dev/null || echo unknown)"
runtime_state="no_running_app_server"
runtime_details="$backup_root/runtime-processes.txt"
: >"$runtime_details"
while IFS= read -r process_line; do
  if [[ "$process_line" == *"$codex_bin app-server"* ]]; then
    printf '%s\n' "$process_line" >>"$runtime_details"
  fi
done < <(ps -axo pid=,ppid=,lstart=,command=)

if [[ -s "$runtime_details" ]]; then
  runtime_state="running_app_server_state_unknown"
  while read -r pid _; do
    [[ -n "$pid" ]] || continue
    mapped="$(lsof -p "$pid" 2>/dev/null | awk -v path="$codex_bin" '$NF == path {print $0}' || true)"
    if [[ -n "$mapped" ]]; then
      echo "$mapped" >>"$backup_root/runtime-lsof.txt"
      if echo "$mapped" | rg -q " $disk_inode "; then
        runtime_state="running_app_server_uses_patched_inode"
      else
        runtime_state="running_app_server_uses_previous_inode"
      fi
    fi
  done <"$runtime_details"
fi

if [[ "$open_app_after" == "true" ]]; then
  open "$app_path" >/dev/null 2>&1 || true
fi

echo "app_path=$app_path"
echo "app_version=$app_version"
echo "app_build=$app_build"
echo "backup_root=$backup_root"
echo "backup=${backup_path:-unknown}"
echo "moved_bundle_backups=$bundle_backup_count"
echo "quit_app=$quit_app"
echo "open_app=$open_app_after"
echo "signature_before=$signature_state"
echo "signature_after=$post_signature_state"
echo "installed_sha256=$installed_sha"
echo "patched_sha256=$patched_sha"
echo "disk_inode=$disk_inode"
echo "runtime_state=$runtime_state"
echo "restart_required=true"
echo "rollback_command=$root_dir/scripts/restore.sh --codex-bin \"$codex_bin\" --backup \"${backup_path:-$backup_root/codex.current-before-patch}\" --yes"
