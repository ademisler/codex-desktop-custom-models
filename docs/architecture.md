# Architecture

Codex Desktop Custom Models is built around isolation. A custom app should feel
like the normal Codex Desktop app, but it must not share state, ports,
launchers, icons, or model configuration with the primary install.

![Architecture diagram](assets/diagrams/architecture.svg)

## Layers

1. **Base Codex Desktop**
   - Installed normally on macOS, or installed on Linux through an existing
     community package/build.
   - Provides Electron, the webview bundle, bundled runtime files, and launcher
     behavior.

2. **Custom App Clone**
   - On macOS, a copied `.app` bundle under `~/Applications`.
   - On Linux, a side-by-side app directory under `~/.local/opt/<app-id>`.
   - Files that need branding or app identity are copied or patched.
   - The clone gets a unique display name, bundle/app id, icon, and webview
     port.

3. **Custom Codex Home**
   - A separate `CODEX_HOME`, for example `~/.codex-minimax`.
   - Contains `config.toml`, provider env files, bridge scripts, automation
     definitions, and private state.

4. **Responses Bridge**
   - Local HTTP service that speaks the Codex Responses API shape.
   - Converts requests to an upstream OpenAI-compatible Chat Completions API.
   - Converts assistant text and tool calls back to Codex Responses output.

5. **MCP and Automations**
   - Optional MCP server exposes `automation_update`.
   - Runner executes due jobs with the custom Codex CLI wrapper.
   - Same-thread heartbeats use `codex exec resume <thread-id>`.

## Data Flow

```text
Codex Desktop UI
  -> custom CODEX_CLI_PATH
  -> custom CODEX_HOME/config.toml
  -> local bridge http://127.0.0.1:<port>/v1/responses
  -> upstream provider /chat/completions
```

Tool calls take the reverse path. The bridge flattens Codex namespace tools for
Chat Completions providers and restores the namespace before returning tool call
items to Codex.

## Why Copy Some Files

The Linux custom app can symlink most runtime files. A few files should be
copied so the app can have independent identity:

- `start.sh` because it contains the Linux app id, display name, icon name, and
  webview port.
- `electron` because Linux desktop shells often associate runtime windows with
  the executable path.
- `content/` when branding assets need to differ.
- `resources/` directory itself, while linking large inner files.

The macOS custom app copies the bundle because LaunchServices, helper app
names, bundle identifiers, and `.icns` assets are app-bundle concerns.

Both paths avoid confusing taskbar/Dock grouping, icon collisions, and shared
profile state.
