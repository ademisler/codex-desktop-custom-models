# Troubleshooting

## The Linux App Opens With The Original Icon

Make sure the custom app has:

- A unique desktop file, for example `codex-minimax.desktop`.
- `StartupWMClass=<app-id>`.
- A patched `start.sh` with `CODEX_LINUX_APP_ID=<app-id>`.
- A copied `content/` directory if you recolored bundled web assets.

Then refresh desktop caches:

```bash
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
```

Log out and back in if your desktop shell still caches the old icon.

## The macOS App Opens With The Original Icon

Recreate the copied app bundle so the installer can rebuild `electron.icns`:

```bash
./scripts/install-minimax-profile-macos.sh --replace-app
```

The macOS installer recolors only the blue/purple cloud area from the copied
Codex icon. It intentionally keeps the white background, terminal glyph,
shadows, and rounded-square shape.

## Missing `.pak` Errors

Electron needs Chromium runtime support files next to the executable:

- `chrome_100_percent.pak`
- `chrome_200_percent.pak`
- `resources.pak`
- `version`
- `locales/`

Recreate the custom shell with the latest script. It links these files from the
base app.

## Unknown Model

If Codex sends a model label your provider does not recognize, add it to:

```bash
CUSTOM_CODEX_SUPPORTED_MODELS="MiniMax-M2.7,MiniMax-M2.7-highspeed,my-alias"
```

The bridge will still fall back to `CUSTOM_CODEX_MODEL`.

## Tools Do Not Work

Check that the provider supports Chat Completions tool calls. The bridge can
translate tool call formats, but it cannot make a model use tools if the
upstream provider ignores the `tools` field.

Then inspect bridge logs:

```bash
codex-minimax-proxy logs
```

## Automations Are Created But Do Not Run

Check the runner:

```bash
codex-minimax-proxy automations-status
codex-minimax-proxy automations-logs
```

Run once with force:

```bash
CODEX_AUTOMATIONS_HOME="$HOME/.codex-minimax" \
CODEX_CUSTOM_BIN="$HOME/.local/bin/codex-minimax" \
node "$HOME/.codex-minimax/codex-automations-runner.mjs" --once --force
```

For same-thread delivery, confirm the automation TOML contains
`destination = "thread"` and a real `target_thread_id`.
