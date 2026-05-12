#!/usr/bin/env bash
set -euo pipefail

MARKER="retrying remote compaction with fallback model"
FALLBACK_MODEL="gpt-5.4-mini"
SOURCE_MODEL="gpt-5.5"

usage() {
  cat <<'USAGE'
Usage: scripts/verify.sh --codex-bin PATH [--expect-marker present|absent|any] [--logs-db PATH]

Verify patch marker strings and optionally inspect local Codex compact logs.
USAGE
}

codex_bin=""
expect_marker="present"
logs_db=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex-bin)
      codex_bin="${2:-}"
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

marker_present="false"
if strings "$codex_bin" | rg -q "$MARKER" &&
   strings "$codex_bin" | rg -q "$FALLBACK_MODEL" &&
   strings "$codex_bin" | rg -q "$SOURCE_MODEL"; then
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
echo "patch_marker=$marker_present"
shasum -a 256 "$codex_bin" | awk '{print "sha256="$1}'

if [[ -n "$logs_db" && -f "$logs_db" ]]; then
  sqlite3 "$logs_db" \
    "select id, datetime(timestamp, 'unixepoch'), level, target, substr(feedback_log_body, 1, 240)
     from logs
     where target = 'codex_core::compact_remote'
       and feedback_log_body like '%fallback model%'
     order by id desc
     limit 20;"
fi
