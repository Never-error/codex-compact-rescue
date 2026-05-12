# Scripts

Platform scripts for building, installing, restoring, and verifying the patch
live here.

Expected script contracts:

- `build`: build a patched bundled CLI from source and patches.
- `install`: back up the installed bundled CLI, then replace it.
- `restore`: restore a selected backup.
- `verify`: check hash, marker strings, local logs, and basic install state.

Scripts must not upload or publish Codex binaries.
