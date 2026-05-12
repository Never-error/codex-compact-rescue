#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  rg -q "$pattern" "$file" || fail "expected $file to contain $pattern"
}

assert_file_not_contains() {
  local file="$1"
  local pattern="$2"
  if rg -q "$pattern" "$file"; then
    fail "expected $file not to contain $pattern"
  fi
}

ORIGINAL_BIN="$TMP_DIR/codex-original"
PATCHED_BIN="$TMP_DIR/codex-patched"
TARGET_BIN="$TMP_DIR/codex"
BACKUP_DIR="$TMP_DIR/backups"
PACKAGE_OUT="$TMP_DIR/packages"
RELATIVE_PACKAGE_OUT="$TMP_DIR/relative-packages"

cat >"$ORIGINAL_BIN" <<'EOF_ORIGINAL'
#!/usr/bin/env bash
echo original-codex
EOF_ORIGINAL
chmod 0755 "$ORIGINAL_BIN"
cp "$ORIGINAL_BIN" "$TARGET_BIN"

cat >"$PATCHED_BIN" <<'EOF_PATCHED'
#!/usr/bin/env bash
echo "retrying remote compaction with fallback model"
echo "gpt-5.4-mini"
echo "gpt-5.5"
EOF_PATCHED
chmod 0755 "$PATCHED_BIN"

"$ROOT_DIR/scripts/verify.sh" \
  --codex-bin "$TARGET_BIN" \
  --expect-marker absent >/dev/null

"$ROOT_DIR/scripts/install.sh" \
  --codex-bin "$TARGET_BIN" \
  --patched-bin "$PATCHED_BIN" \
  --backup-dir "$BACKUP_DIR" \
  --yes >/tmp/codex-install-test.out

test -x "$TARGET_BIN" || fail "installed target is not executable"
assert_file_contains "$TARGET_BIN" "retrying remote compaction with fallback model"

BACKUP_PATH="$(sed -n 's/^backup=//p' /tmp/codex-install-test.out | tail -n 1)"
test -n "$BACKUP_PATH" || fail "install did not print backup path"
test -f "$BACKUP_PATH" || fail "backup path does not exist: $BACKUP_PATH"
assert_file_contains "$BACKUP_PATH" "original-codex"

"$ROOT_DIR/scripts/verify.sh" \
  --codex-bin "$TARGET_BIN" \
  --expect-marker present >/dev/null

"$ROOT_DIR/scripts/restore.sh" \
  --codex-bin "$TARGET_BIN" \
  --backup "$BACKUP_PATH" \
  --yes >/dev/null

assert_file_contains "$TARGET_BIN" "original-codex"
assert_file_not_contains "$TARGET_BIN" "retrying remote compaction with fallback model"

"$ROOT_DIR/release/package.sh" \
  --version test.1 \
  --platform macos-universal \
  --out-dir "$PACKAGE_OUT" >/tmp/codex-package-test.out

"$ROOT_DIR/release/package.sh" \
  --version test.1 \
  --platform linux-x64 \
  --out-dir "$PACKAGE_OUT" >/tmp/codex-package-test-linux.out

test -f "$PACKAGE_OUT/codex-compact-fallback-test.1-macos-universal.tar.gz" ||
  fail "missing release package"
test -f "$PACKAGE_OUT/codex-compact-fallback-test.1-linux-x64.tar.gz" ||
  fail "missing linux release package"
test -f "$PACKAGE_OUT/checksums.txt" || fail "missing checksums.txt"
assert_file_contains "$PACKAGE_OUT/checksums.txt" "codex-compact-fallback-test.1-macos-universal.tar.gz"
assert_file_contains "$PACKAGE_OUT/checksums.txt" "codex-compact-fallback-test.1-linux-x64.tar.gz"

(
  cd "$TMP_DIR"
  "$ROOT_DIR/release/package.sh" \
    --version test.2 \
    --platform macos-universal \
    --out-dir "relative-packages" >/tmp/codex-package-relative-test.out
)

test -f "$RELATIVE_PACKAGE_OUT/codex-compact-fallback-test.2-macos-universal.tar.gz" ||
  fail "missing package for relative out dir"
test -f "$RELATIVE_PACKAGE_OUT/checksums.txt" || fail "missing checksums for relative out dir"

echo "ok"
