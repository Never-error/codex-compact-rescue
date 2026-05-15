# GitHub Actions Templates

`upstream-compatibility.yml` is a workflow template for checking whether the
compact fallback patch still applies to upstream `openai/codex`.

To enable it, copy the file to:

```text
.github/workflows/upstream-compatibility.yml
```

GitHub rejects workflow file changes unless the publishing token has the
`workflow` scope. If a push fails with a workflow-scope error, refresh the GitHub
CLI token with that scope and push the workflow in a separate commit.
