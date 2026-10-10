# Contributing

Thanks for improving Codex Desktop Custom Models.

Codex Desktop Custom Models is an open-source project. Contributions should
preserve the project's goal: isolated, provider-specific Codex Desktop apps
that are safe to publish and easy to inspect.

## Ground Rules

- Do not commit API keys, session databases, logs, shell snapshots, or personal
  Codex state.
- Keep provider-specific code behind examples or environment variables.
- Prefer small, reviewable scripts over large machine-specific installers.
- Test scripts with `bash -n` and bridge files with `node --check`.
- Keep the original Codex installation untouched by default.

## Development Checks

```bash
bash -n scripts/*.sh scripts/lib/*.sh
node --check bridges/*.mjs
make scan
```

The scan should not report committed secrets, local usernames, or Codex state.

## Pull Request Checklist

- The change works with an isolated `CODEX_HOME`.
- The original Codex app is not modified.
- New docs explain how to undo the change.
- Provider examples use `.env.example` files only.
- Screenshots are real or sanitized and contain no private project data.
