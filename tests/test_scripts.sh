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
PATCH_APP_ORIGINAL_BIN="$TMP_DIR/codex-patch-app-original"
TARGET_BIN="$TMP_DIR/codex"
BACKUP_DIR="$TMP_DIR/backups"
PACKAGE_OUT="$TMP_DIR/packages"
RELATIVE_PACKAGE_OUT="$TMP_DIR/relative-packages"
BUILD_SOURCE="$TMP_DIR/source-with-codex-rs"
BUILD_OUT="$TMP_DIR/build-out"
FAKE_BIN_DIR="$TMP_DIR/fake-bin"
BUILD_PATCH="$TMP_DIR/build.patch"
FAKE_APP="$TMP_DIR/FakeCodex.app"
PATCH_APP="$TMP_DIR/PatchCodex.app"

cat >"$ORIGINAL_BIN" <<'EOF_ORIGINAL'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "codex-cli test-original"
  exit 0
fi
echo original-codex
EOF_ORIGINAL
chmod 0755 "$ORIGINAL_BIN"
cp "$ORIGINAL_BIN" "$TARGET_BIN"

cat >"$PATCHED_BIN" <<'EOF_PATCHED'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "codex-cli test-patched"
  exit 0
fi
echo "retrying remote compaction with fallback model"
echo "gpt-5.4-mini"
echo "gpt-5.5"
EOF_PATCHED
chmod 0755 "$PATCHED_BIN"

cat >"$PATCH_APP_ORIGINAL_BIN" <<'EOF_PATCH_APP_ORIGINAL'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "codex-cli test-patched"
  exit 0
fi
echo original-codex-for-patch-app
EOF_PATCH_APP_ORIGINAL
chmod 0755 "$PATCH_APP_ORIGINAL_BIN"

"$ROOT_DIR/scripts/verify.sh" \
  --codex-bin "$TARGET_BIN" \
  --expect-marker absent >/tmp/codex-verify-absent.out
assert_file_contains /tmp/codex-verify-absent.out "codex_cli_version=codex-cli test-original"
assert_file_contains /tmp/codex-verify-absent.out "install_state=unpatched"

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
  --expect-marker present >/tmp/codex-verify-present.out
assert_file_contains /tmp/codex-verify-present.out "codex_cli_version=codex-cli test-patched"
assert_file_contains /tmp/codex-verify-present.out "install_state=patched"

"$ROOT_DIR/scripts/restore.sh" \
  --codex-bin "$TARGET_BIN" \
  --backup "$BACKUP_PATH" \
  --yes >/dev/null

assert_file_contains "$TARGET_BIN" "original-codex"
assert_file_not_contains "$TARGET_BIN" "retrying remote compaction with fallback model"

mkdir -p "$FAKE_APP/Contents/Resources"
cp "$ORIGINAL_BIN" "$FAKE_APP/Contents/Resources/codex"
if "$ROOT_DIR/scripts/install.sh" \
  --codex-bin "$FAKE_APP/Contents/Resources/codex" \
  --patched-bin "$PATCHED_BIN" \
  --backup-dir "$BACKUP_DIR" \
  --yes >/tmp/codex-install-app-refuse.out 2>/tmp/codex-install-app-refuse.err; then
  fail "macOS app bundle install should require explicit mode"
fi
assert_file_contains /tmp/codex-install-app-refuse.err "Refusing to mutate a signed macOS Codex.app bundle"

"$ROOT_DIR/scripts/install.sh" \
  --codex-bin "$FAKE_APP/Contents/Resources/codex" \
  --patched-bin "$PATCHED_BIN" \
  --backup-dir "$BACKUP_DIR" \
  --macos-app-mode no-resign \
  --yes >/tmp/codex-install-app-no-resign.out
assert_file_contains "$FAKE_APP/Contents/Resources/codex" "retrying remote compaction with fallback model"

mkdir -p "$PATCH_APP/Contents/Resources"
cat >"$PATCH_APP/Contents/Info.plist" <<'EOF_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key>
  <string>test-app-version</string>
  <key>CFBundleVersion</key>
  <string>test-build</string>
</dict>
</plist>
EOF_PLIST
cp "$PATCH_APP_ORIGINAL_BIN" "$PATCH_APP/Contents/Resources/codex"
cat >"$PATCH_APP/Contents/Resources/codex.backup-in-bundle" <<'EOF_BUNDLE_BACKUP'
stale in-bundle backup
EOF_BUNDLE_BACKUP

if "$ROOT_DIR/scripts/patch-macos-codex-app.sh" \
  --app-path "$PATCH_APP" \
  --patched-bin "$PATCHED_BIN" \
  --backup-root "$BACKUP_DIR/patch-app" \
  --skip-upstream-check >/tmp/codex-patch-app-no-yes.out 2>/tmp/codex-patch-app-no-yes.err; then
  fail "patch app script should require --yes"
fi
assert_file_contains /tmp/codex-patch-app-no-yes.err "Refusing to patch"

"$ROOT_DIR/scripts/patch-macos-codex-app.sh" \
  --app-path "$PATCH_APP" \
  --patched-bin "$PATCHED_BIN" \
  --backup-root "$BACKUP_DIR/patch-app" \
  --allow-invalid-signature \
  --move-bundle-backups \
  --skip-upstream-check \
  --yes >/tmp/codex-patch-app-test.out
assert_file_contains /tmp/codex-patch-app-test.out "install_state=patched"
assert_file_contains /tmp/codex-patch-app-test.out "runtime_state=no_running_app_server"
assert_file_contains /tmp/codex-patch-app-test.out "moved_bundle_backups=1"
assert_file_contains "$PATCH_APP/Contents/Resources/codex" "retrying remote compaction with fallback model"
test ! -f "$PATCH_APP/Contents/Resources/codex.backup-in-bundle" ||
  fail "patch app script did not move in-bundle backup out of app"
test -f "$BACKUP_DIR/patch-app/bundle-backups/codex.backup-in-bundle" ||
  fail "patch app script did not preserve moved in-bundle backup"
PATCH_APP_BACKUP="$(sed -n 's/^backup=//p' /tmp/codex-patch-app-test.out | tail -n 1)"
test -f "$PATCH_APP_BACKUP" || fail "patch app script did not create backup"

"$ROOT_DIR/release/package.sh" \
  --version test.1 \
  --platform macos-universal \
  --out-dir "$PACKAGE_OUT" >/tmp/codex-package-test.out

"$ROOT_DIR/release/package.sh" \
  --version test.1 \
  --platform linux-x64 \
  --out-dir "$PACKAGE_OUT" >/tmp/codex-package-test-linux.out

"$ROOT_DIR/release/package.sh" \
  --version test.1 \
  --platform windows-x64 \
  --out-dir "$PACKAGE_OUT" >/tmp/codex-package-test-windows.out

test -f "$PACKAGE_OUT/codex-compact-fallback-test.1-macos-universal.tar.gz" ||
  fail "missing release package"
test -f "$PACKAGE_OUT/codex-compact-fallback-test.1-linux-x64.tar.gz" ||
  fail "missing linux release package"
test -f "$PACKAGE_OUT/codex-compact-fallback-test.1-windows-x64.zip" ||
  fail "missing windows release package"
test -f "$PACKAGE_OUT/checksums.txt" || fail "missing checksums.txt"
assert_file_contains "$PACKAGE_OUT/checksums.txt" "codex-compact-fallback-test.1-macos-universal.tar.gz"
assert_file_contains "$PACKAGE_OUT/checksums.txt" "codex-compact-fallback-test.1-linux-x64.tar.gz"
assert_file_contains "$PACKAGE_OUT/checksums.txt" "codex-compact-fallback-test.1-windows-x64.zip"
tar -tzf "$PACKAGE_OUT/codex-compact-fallback-test.1-macos-universal.tar.gz" |
  rg -q 'README.zh-CN.md' || fail "release package missing README.zh-CN.md"
tar -tzf "$PACKAGE_OUT/codex-compact-fallback-test.1-macos-universal.tar.gz" |
  rg -q 'scripts/check-upstream-compat.sh' || fail "release package missing compatibility checker"
tar -tzf "$PACKAGE_OUT/codex-compact-fallback-test.1-macos-universal.tar.gz" |
  rg -q 'scripts/patch-macos-codex-app.sh' || fail "release package missing macOS patch script"
unzip -l "$PACKAGE_OUT/codex-compact-fallback-test.1-windows-x64.zip" |
  rg -q 'README.zh-CN.md' || fail "windows release package missing README.zh-CN.md"
unzip -l "$PACKAGE_OUT/codex-compact-fallback-test.1-windows-x64.zip" |
  rg -q 'scripts/check-upstream-compat.sh' || fail "windows release package missing compatibility checker"

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

mkdir -p "$BUILD_SOURCE/codex-rs" "$FAKE_BIN_DIR"
cat >"$BUILD_SOURCE/marker.txt" <<'EOF_MARKER'
before
EOF_MARKER
cat >"$BUILD_SOURCE/codex-rs/Cargo.toml" <<'EOF_CARGO'
[workspace]
members = []
EOF_CARGO
cat >"$BUILD_PATCH" <<'EOF_PATCH'
diff --git a/marker.txt b/marker.txt
index 1089609..21b779a 100644
--- a/marker.txt
+++ b/marker.txt
@@ -1 +1 @@
-before
+after
EOF_PATCH
cat >"$FAKE_BIN_DIR/cargo" <<'EOF_CARGO_BIN'
#!/usr/bin/env bash
mkdir -p target/release
cat > target/release/codex <<'EOF_FAKE_CODEX'
#!/usr/bin/env bash
echo built-from-codex-rs
EOF_FAKE_CODEX
chmod 0755 target/release/codex
EOF_CARGO_BIN
chmod 0755 "$FAKE_BIN_DIR/cargo"
PATH="$FAKE_BIN_DIR:$PATH" "$ROOT_DIR/scripts/build.sh" \
  --source-dir "$BUILD_SOURCE" \
  --patch-file "$BUILD_PATCH" \
  --out-dir "$BUILD_OUT" >/tmp/codex-build-layout-test.out

test -x "$BUILD_OUT/codex" || fail "build script did not copy codex-rs target binary"
assert_file_contains "$BUILD_SOURCE/marker.txt" "after"
assert_file_contains "$BUILD_OUT/codex" "built-from-codex-rs"

echo "ok"
