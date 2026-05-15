#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REPO="openai/codex"
DEFAULT_REF="main"
DEFAULT_TARGET_PATH="codex-rs/core/src/compact_remote.rs"
DEFAULT_EXPECTED_BLOB="cc31d50b13268417fa34d8262a7c3682cda8912e"

usage() {
  cat <<'USAGE'
Usage: scripts/check-upstream-compat.sh [--repo OWNER/REPO] [--ref REF] [--target-path PATH] [--patch-file PATH] [--expected-blob SHA]

Fetch the upstream compact target file through GitHub and verify that the local
compact fallback patch still applies.
USAGE
}

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$DEFAULT_REPO"
ref="$DEFAULT_REF"
target_path="$DEFAULT_TARGET_PATH"
patch_file="$root_dir/patches/openai-codex-compact-fallback.patch"
expected_blob="$DEFAULT_EXPECTED_BLOB"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo="${2:-}"
      shift 2
      ;;
    --ref)
      ref="${2:-}"
      shift 2
      ;;
    --target-path)
      target_path="${2:-}"
      shift 2
      ;;
    --patch-file)
      patch_file="${2:-}"
      shift 2
      ;;
    --expected-blob)
      expected_blob="${2:-}"
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

[[ -n "$repo" ]] || { echo "--repo is required" >&2; exit 2; }
[[ -n "$ref" ]] || { echo "--ref is required" >&2; exit 2; }
[[ -n "$target_path" ]] || { echo "--target-path is required" >&2; exit 2; }
[[ -f "$patch_file" ]] || { echo "patch file not found: $patch_file" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }
command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
command -v base64 >/dev/null || { echo "base64 is required" >&2; exit 1; }

api_path="repos/$repo/contents/$target_path?ref=$ref"
target_blob="$(gh api "$api_path" --jq '.sha')"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$tmp_dir/$(dirname "$target_path")"
gh api "$api_path" --jq '.content' | base64 --decode >"$tmp_dir/$target_path"

expected_blob_match="unknown"
if [[ -n "$expected_blob" ]]; then
  if [[ "$target_blob" == "$expected_blob" ]]; then
    expected_blob_match="true"
  else
    expected_blob_match="false"
  fi
fi

echo "upstream_repo=$repo"
echo "upstream_ref=$ref"
echo "target_path=$target_path"
echo "target_blob=$target_blob"
echo "expected_blob=$expected_blob"
echo "expected_blob_match=$expected_blob_match"
echo "patch_file=$patch_file"

if (
  cd "$tmp_dir"
  git apply --check "$patch_file"
); then
  echo "patch_apply=ok"
  if [[ "$expected_blob_match" == "false" ]]; then
    echo "compatibility=patch_applies_with_drift"
  else
    echo "compatibility=patch_applies"
  fi
else
  echo "patch_apply=failed"
  echo "compatibility=patch_rebase_required"
  exit 1
fi
