# Patches

Source-level patches for the Codex CLI compact fallback behavior live here.

Current patch:

- `openai-codex-compact-fallback.patch`
- Target file: `openai/codex` `codex-rs/core/src/compact_remote.rs`
- Checked date: 2026-05-23
- Locally observed Codex Desktop bundled CLI: `codex-cli 0.133.0-alpha.1`

Verified upstream compatibility:

| Upstream ref | Target blob | Result |
| --- | --- | --- |
| `main` | `30d1e5f0e84129ac5d3da3f327c8a24c6a199717` | `patch_applies_with_drift` |
| `rust-v0.133.0` | `c7ba1a314f611d59a0181403115a051f2ff32b3b` | `patch_applies_with_drift` |
| `rust-v0.133.0-alpha.1` | `c7ba1a314f611d59a0181403115a051f2ff32b3b` | `patch_applies_with_drift` |
| `rust-v0.131.0-alpha.18` | `cc31d50b13268417fa34d8262a7c3682cda8912e` | `patch_applies` |
| `rust-v0.130.0` | `35b8a01fc32fff7944b75670acbd5e33dff161af` | `patch_applies_with_drift` |

Run `scripts/check-upstream-compat.sh --ref REF` or `git apply --check
patches/openai-codex-compact-fallback.patch` against the target checkout before
building.

Patch files must:

- Name the compatible upstream Codex CLI version or commit.
- Modify the remote compact failure path, not normal user turns.
- Use an explicit fallback compact model.
- Emit a stable marker string for verification.
- Avoid embedding local paths, tokens, session content, or binaries.
