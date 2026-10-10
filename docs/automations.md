# Automations

Custom Codex profiles do not automatically inherit host-provided automation
tools. This repository includes a small MCP server and runner so the custom app
can create and execute local automations.

## Components

- `bridges/codex-automations-mcp.mjs`
  - Exposes an `automation_update` tool.
  - Writes `automation.toml` files under the custom home.
  - Mirrors enough metadata into a local SQLite database for app visibility.

- `bridges/codex-automations-runner.mjs`
  - Polls due automations.
  - Runs the custom Codex CLI wrapper.
  - Supports inbox/background jobs and same-thread heartbeat jobs.

## Config

The MiniMax installer adds this to the generated `config.toml`:

```toml
[mcp_servers.codex-automations]
command = "node"
args = ["<custom-home>/codex-automations-mcp.mjs"]
enabled = true
startup_timeout_sec = 10
default_tools_approval_mode = "approve"
env = { CODEX_AUTOMATIONS_HOME = "<custom-home>", CODEX_CUSTOM_BIN = "<custom-bin>" }
```

The path is generated for your actual home directory. Do not hardcode it in a
public template.

## Same-Thread Follow-Ups

When the user asks for a reminder or recurring message in the same chat, the MCP
tool stores:

```toml
kind = "heartbeat"
destination = "thread"
target_thread_id = "<current-thread-id>"
```

The runner later executes:

```bash
codex exec resume <target-thread-id> ...
```

This is the critical difference between "automation was created" and "automation
actually appears in the chat".

## Run Manually

```bash
CODEX_AUTOMATIONS_HOME="$HOME/.codex-minimax" \
CODEX_CUSTOM_BIN="$HOME/.local/bin/codex-minimax" \
node "$HOME/.codex-minimax/codex-automations-runner.mjs" --once --force
```

For background execution use the generated proxy:

```bash
codex-minimax-proxy automations-start
codex-minimax-proxy automations-status
codex-minimax-proxy automations-logs
```

## Limits

This runner intentionally keeps scheduling simple. It supports minutely, hourly,
and daily RRULE patterns used by common reminders and monitors. For complex
calendaring, use an external scheduler and call Codex from there.
