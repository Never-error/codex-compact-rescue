# Patches

Source-level patches for the Codex CLI compact fallback behavior live here.

Patch files must:

- Name the compatible upstream Codex CLI version or commit.
- Modify the remote compact failure path, not normal user turns.
- Use an explicit fallback compact model.
- Emit a stable marker string for verification.
- Avoid embedding local paths, tokens, session content, or binaries.
