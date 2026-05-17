#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build.sh --source-dir PATH [--patch-file PATH] [--out-dir DIR] [--cargo-args ARGS]

Apply the compact fallback source patch to an OpenAI Codex checkout and build the
codex CLI binary.
USAGE
}

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir=""
patch_file="$root_dir/patches/openai-codex-compact-fallback.patch"
out_dir="$root_dir/dist/$(uname -s | tr '[:upper:]' '[:lower:]')"
cargo_args="build -p codex-cli --bin codex --release"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir)
      source_dir="${2:-}"
      shift 2
      ;;
    --patch-file)
      patch_file="${2:-}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:-}"
      shift 2
      ;;
    --cargo-args)
      cargo_args="${2:-}"
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

[[ -n "$source_dir" ]] || { echo "--source-dir is required" >&2; exit 2; }
[[ -d "$source_dir" ]] || { echo "source dir not found: $source_dir" >&2; exit 1; }
[[ -f "$patch_file" ]] || { echo "patch file not found: $patch_file" >&2; exit 1; }

cargo_dir="$source_dir"
if [[ ! -f "$cargo_dir/Cargo.toml" && -f "$source_dir/codex-rs/Cargo.toml" ]]; then
  cargo_dir="$source_dir/codex-rs"
fi
[[ -f "$cargo_dir/Cargo.toml" ]] || {
  echo "Cargo.toml not found in $source_dir or $source_dir/codex-rs" >&2
  exit 1
}

(
  cd "$source_dir"
  git apply --check "$patch_file"
  git apply "$patch_file"
)

(
  cd "$cargo_dir"
  # shellcheck disable=SC2086
  cargo $cargo_args
)

mkdir -p "$out_dir"
binary_name="codex"
if [[ "$(uname -s)" == "MINGW"* || "$(uname -s)" == "MSYS"* || "$(uname -s)" == "CYGWIN"* ]]; then
  binary_name="codex.exe"
fi

cp "$cargo_dir/target/release/$binary_name" "$out_dir/$binary_name"
echo "built=$out_dir/$binary_name"
