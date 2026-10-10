# Publishing Checklist

Use this before creating a public GitHub repository.

## Cleanliness

```bash
make scan
```

Expected result: no matches.

## Ownership

Present the project as an open-source starter kit. Keep the README author line,
MIT license, security policy, contribution guide, and public repository metadata
consistent.

## Syntax

```bash
bash -n scripts/*.sh scripts/lib/*.sh
node --check bridges/*.mjs
```

## Recommended First Commit

```bash
git init
git add .
git status
git commit -m "Initial Codex Desktop Custom Models starter kit"
```

## Suggested GitHub Description

Open-source starter kit for isolated Codex Desktop apps for custom model
providers on macOS and Linux, with provider bridges, custom icons, and local
automations.

## Suggested Topics

```text
codex
codex-app
codex-desktop
custom-models
linux
macos
electron
minimax
openai-compatible
responses-api
mcp
automation
```
