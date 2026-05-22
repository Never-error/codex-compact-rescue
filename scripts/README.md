# Scripts

Platform scripts for building, installing, restoring, and verifying the patch
live here.

Expected script contracts:

- `build.sh` / `build.ps1`: build a patched bundled CLI from source and patches.
- `install.sh` / `install.ps1`: back up the installed bundled CLI, then replace it.
- `patch-macos-codex-app.sh`: recommended macOS Codex.app wrapper around
  `install.sh`; keeps backups outside the app bundle, verifies version and
  marker strings, avoids ad-hoc signing, records signature/runtime state, and
  prints a rollback command.
- `restore.sh` / `restore.ps1`: restore a selected backup.
- `verify.sh` / `verify.ps1`: check app metadata, CLI version, hash, marker strings,
  local logs, optional upstream compatibility, and install state.
  Default marker expectation is `any` for post-update health checks; pass
  `--expect-marker present` / `-ExpectMarker present` after installation.
- `check-upstream-compat.sh`: fetch the upstream compact target file and verify that
  the source patch still applies.

Scripts must not upload or publish Codex binaries.
