#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: release/package.sh --version VERSION --platform PLATFORM [--out-dir DIR]

Build a patcher release archive containing scripts, patches, docs, and checksums.
USAGE
}

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version=""
platform=""
out_dir="$root_dir/dist/release"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    --platform)
      platform="${2:-}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:-}"
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

[[ -n "$version" ]] || { echo "--version is required" >&2; exit 2; }
[[ -n "$platform" ]] || { echo "--platform is required" >&2; exit 2; }

mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
package_name="codex-compact-fallback-$version-$platform"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

mkdir -p "$staging/$package_name"
cp "$root_dir/README.md" "$root_dir/README.zh-CN.md" "$root_dir/LICENSE" "$root_dir/release/RELEASE_NOTES.md" "$staging/$package_name/"
cp -R "$root_dir/docs" "$root_dir/patches" "$root_dir/scripts" "$staging/$package_name/"

if [[ "$platform" == windows-* ]]; then
  (
    cd "$staging"
    zip -qr "$out_dir/$package_name.zip" "$package_name"
  )
  artifact="$package_name.zip"
else
  (
    cd "$staging"
    tar -czf "$out_dir/$package_name.tar.gz" "$package_name"
  )
  artifact="$package_name.tar.gz"
fi

(
  cd "$out_dir"
  shopt -s nullglob
  artifacts=(codex-compact-fallback-*.tar.gz codex-compact-fallback-*.zip)
  shasum -a 256 "${artifacts[@]}" > checksums.txt
)

echo "package=$out_dir/$artifact"
echo "checksums=$out_dir/checksums.txt"
