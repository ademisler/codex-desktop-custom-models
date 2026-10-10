# Security

## Secret Handling

Never publish real API keys. Put secrets in the generated custom home, for
example:

```text
~/.codex-minimax/minimax.env
```

That file is intentionally ignored by this repository.

## Local Services

The bridge binds to `127.0.0.1` by default. Do not expose it to a public network
unless you add authentication, TLS, logging review, and rate limits.

## Data You Should Not Share

- Codex state databases.
- Codex log databases.
- Shell snapshots.
- Session indexes.
- Provider request/response debug logs.
- `AGENTS.md` files from private projects.

## Reporting Issues

If you find a security issue in this starter kit, open a private advisory or
contact the maintainer through GitHub. If the issue is in Codex Desktop, Codex
CLI, MiniMax, Ollama, or another upstream project, report it to that project.
