# macOS Local Profile

The macOS installer creates an isolated Codex Desktop profile for a custom model
provider without modifying the original Codex app. It creates a separate app
bundle and a separate `CODEX_HOME`:

```text
~/Applications/Codex MiniMax.app
~/.codex-minimax
~/.local/bin/codex-minimax
~/.local/bin/codex-minimax-desktop
~/.local/bin/codex-minimax-proxy
~/Library/LaunchAgents/com.ademisler.codex-minimax.bridge.plist
```

It copies `/Applications/Codex.app` into your user Applications folder, patches
only the copied bundle, gives the helper apps and icon a custom identity, and
launches it with isolated environment variables. The original
`/Applications/Codex.app` and your normal `~/.codex` profile are left untouched.

The icon keeps the original Codex shape and white background. Only the saturated
blue/purple cloud area is recolored to red, so it stays visually related to
Codex while remaining easy to distinguish in the Dock.

## Requirements

- A working `/Applications/Codex.app` or `~/Applications/Codex.app`.
- The `codex` CLI on your `PATH`.
- `node` 18 or newer.
- `swift`, `iconutil`, `plutil`, `ditto`, and `codesign`.

## Install

```bash
export MINIMAX_API_KEY="<your-minimax-api-key>"

./scripts/install-minimax-profile-macos.sh \
  --id codex-minimax \
  --name "Codex MiniMax" \
  --model "MiniMax-M2.7" \
  --port 4007 \
  --webview-port 5176
```

If you do not export `MINIMAX_API_KEY`, the installer still creates the profile.
Edit this private file before testing the provider:

```text
~/.codex-minimax/minimax.env
```

## Test

```bash
codex-minimax-proxy start
codex-minimax-proxy test
codex-minimax-desktop
```

`codex-minimax-proxy start` runs the bridge as a user LaunchAgent on macOS, so
it stays alive independently of the terminal that launched it.

## Remove

```bash
codex-minimax-proxy stop
codex-minimax-proxy automations-stop
launchctl bootout "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.ademisler.codex-minimax.bridge.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.ademisler.codex-minimax.bridge.plist"
rm -rf "$HOME/Applications/Codex MiniMax.app"
rm -f "$HOME/.local/bin/codex-minimax" \
  "$HOME/.local/bin/codex-minimax-desktop" \
  "$HOME/.local/bin/codex-minimax-proxy"
```

The custom `CODEX_HOME` is kept by default. Remove `~/.codex-minimax` only if
you also want to delete the custom profile data.
