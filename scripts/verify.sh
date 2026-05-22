#!/usr/bin/env bash
set -euo pipefail

MARKER="retrying remote compaction with fallback model"
FALLBACK_MODEL="gpt-5.4-mini"
SOURCE_MODEL="gpt-5.5"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: scripts/verify.sh --codex-bin PATH [--app-path PATH] [--expect-marker present|absent|any] [--logs-db PATH] [--upstream-ref REF]

Run a post-update health check for a Codex bundled CLI. Verifies hash, CLI
version, patch marker strings, optional app metadata, optional upstream patch
compatibility, and optional local compact logs.

Default marker expectation is "any". Use --expect-marker present after install.
USAGE
}

codex_bin=""
app_path=""
expect_marker="any"
logs_db=""
upstream_ref=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex-bin)
      codex_bin="${2:-}"
      shift 2
      ;;
    --app-path)
      app_path="${2:-}"
      shift 2
      ;;
    --expect-marker)
      expect_marker="${2:-}"
      shift 2
      ;;
    --logs-db)
      logs_db="${2:-}"
      shift 2
      ;;
    --upstream-ref)
      upstream_ref="${2:-}"
      shift 2
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
[[ -f "$codex_bin" ]] || { echo "codex binary not found: $codex_bin" >&2; exit 1; }

if [[ -z "$app_path" && "$codex_bin" == */Contents/Resources/codex ]]; then
  app_path="$(cd "$(dirname "$codex_bin")/../.." && pwd)"
fi

app_version="unknown"
app_build="unknown"
if [[ -n "$app_path" && -f "$app_path/Contents/Info.plist" ]] &&
   command -v /usr/libexec/PlistBuddy >/dev/null; then
  app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist" 2>/dev/null || echo unknown)"
  app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist" 2>/dev/null || echo unknown)"
fi

strings_file="$(mktemp)"
version_stdout_file="$(mktemp)"
version_stderr_file="$(mktemp)"
cleanup() {
  rm -f "$strings_file" "$version_stdout_file" "$version_stderr_file"
}
trap cleanup EXIT

cli_version_status="ok"
"$codex_bin" --version >"$version_stdout_file" 2>"$version_stderr_file" &
version_pid="$!"
for _ in {1..50}; do
  if ! kill -0 "$version_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if kill -0 "$version_pid" 2>/dev/null; then
  kill "$version_pid" 2>/dev/null || true
  wait "$version_pid" 2>/dev/null || true
  cli_version_status="timeout"
else
  if ! wait "$version_pid"; then
    cli_version_status="error"
  fi
fi

cli_version="$(head -n 1 "$version_stdout_file" || true)"
[[ -n "$cli_version" ]] || cli_version="unknown"
strings "$codex_bin" >"$strings_file"

marker_present="false"
if rg -q "$MARKER" "$strings_file" &&
   rg -q "$FALLBACK_MODEL" "$strings_file" &&
   rg -q "$SOURCE_MODEL" "$strings_file"; then
  marker_present="true"
fi

case "$expect_marker" in
  present)
    [[ "$marker_present" == "true" ]] || {
      echo "patch_marker=missing" >&2
      exit 1
    }
    ;;
  absent)
    [[ "$marker_present" == "false" ]] || {
      echo "patch_marker=present" >&2
      exit 1
    }
    ;;
  any)
    ;;
  *)
    echo "--expect-marker must be present, absent, or any" >&2
    exit 2
    ;;
esac

echo "codex_bin=$codex_bin"
echo "app_path=${app_path:-unknown}"
echo "app_version=$app_version"
echo "app_build=$app_build"
echo "codex_cli_version=$cli_version"
echo "codex_cli_version_status=$cli_version_status"
echo "patch_marker=$marker_present"
shasum -a 256 "$codex_bin" | awk '{print "sha256="$1}'

if [[ "$marker_present" == "true" ]]; then
  echo "install_state=patched"
else
  echo "install_state=unpatched"
fi

if [[ -n "$upstream_ref" ]]; then
  echo "upstream_ref=$upstream_ref"
  "$root_dir/scripts/check-upstream-compat.sh" --ref "$upstream_ref"
fi

if [[ -n "$logs_db" && -f "$logs_db" ]]; then
  sqlite3 "$logs_db" \
    "select id, datetime(timestamp, 'unixepoch'), level, target, substr(feedback_log_body, 1, 240)
     from logs
     where target = 'codex_core::compact_remote'
       and feedback_log_body like '%fallback model%'
     order by id desc
     limit 20;"
fi
