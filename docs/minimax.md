# MiniMax M2.7 Profile

MiniMax is the reference provider profile in this repository. The profile uses a
local bridge because Codex Desktop expects the Responses API, while many custom
providers expose an OpenAI-compatible Chat Completions API.

## macOS Install

```bash
export MINIMAX_API_KEY="<your-minimax-api-key>"

./scripts/install-minimax-profile-macos.sh \
  --id codex-minimax \
  --name "Codex MiniMax" \
  --model "MiniMax-M2.7" \
  --port 4007 \
  --webview-port 5176
```

The macOS installer writes the custom app to:

```text
~/Applications/Codex MiniMax.app
```

## Linux Install

```bash
export MINIMAX_API_KEY="<your-minimax-api-key>"

./scripts/install-minimax-profile.sh \
  --id codex-minimax \
  --name "Codex MiniMax" \
  --model "MiniMax-M2.7" \
  --port 4007 \
  --webview-port 5176
```

Both installers write:

```text
~/.codex-minimax/config.toml
~/.codex-minimax/minimax.env
~/.codex-minimax/openai-compatible-responses-bridge.mjs
~/.codex-minimax/codex-automations-mcp.mjs
~/.codex-minimax/codex-automations-runner.mjs
~/.local/bin/codex-minimax
~/.local/bin/codex-minimax-desktop
~/.local/bin/codex-minimax-proxy
```

The Linux installer also creates the desktop-shell app under:

```text
~/.local/opt/codex-minimax/codex-app
```

## Test

```bash
codex-minimax-proxy start
codex-minimax-proxy test
codex-minimax-desktop
```

The test checks `/health`, `/v1/models`, and a small `/v1/responses` request.

## Environment

The generated `minimax.env` uses the generic bridge variables:

```bash
CUSTOM_CODEX_PROVIDER_NAME="minimax"
CUSTOM_CODEX_API_BASE="https://api.minimax.io/v1"
CUSTOM_CODEX_API_KEY="$MINIMAX_API_KEY"
CUSTOM_CODEX_MODEL="MiniMax-M2.7"
CUSTOM_CODEX_SUPPORTED_MODELS="MiniMax-M2.7,MiniMax-M2.7-highspeed"
CUSTOM_CODEX_PROXY_PORT="4007"
```

You can reuse the same bridge for another provider by changing the base URL,
API key, model list, and app id.

## Model Choice

The Codex UI may show default OpenAI model labels in some places. The effective
model comes from `CODEX_HOME/config.toml` and the provider bridge. If Codex sends
an unknown model name, the bridge maps it back to `CUSTOM_CODEX_MODEL`.
