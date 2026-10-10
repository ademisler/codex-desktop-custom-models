#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

APP_ID="codex-minimax"
APP_NAME="Codex MiniMax"
MODEL="MiniMax-M2.7"
BRIDGE_PORT="4007"
WEBVIEW_PORT="5176"
API_BASE="https://api.minimax.io/v1"
CUSTOM_HOME=""
RECREATE_APP=0

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --id ID              App id, default codex-minimax
  --name NAME          Display name, default "Codex MiniMax"
  --model MODEL        Provider model, default MiniMax-M2.7
  --port PORT          Bridge port, default 4007
  --webview-port PORT  Desktop webview port, default 5176
  --api-base URL       Upstream API base, default https://api.minimax.io/v1
  --home PATH          Custom CODEX_HOME, default ~/.ID
  --recreate-app       Recreate the custom app shell
  -h, --help           Show help

Set MINIMAX_API_KEY in your environment before running, or edit the generated
env file manually.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --id) APP_ID="${2:?}"; shift 2 ;;
    --name) APP_NAME="${2:?}"; shift 2 ;;
    --model) MODEL="${2:?}"; shift 2 ;;
    --port) BRIDGE_PORT="${2:?}"; shift 2 ;;
    --webview-port) WEBVIEW_PORT="${2:?}"; shift 2 ;;
    --api-base) API_BASE="${2:?}"; shift 2 ;;
    --home) CUSTOM_HOME="${2:?}"; shift 2 ;;
    --recreate-app) RECREATE_APP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

valid_app_id "$APP_ID" || die "invalid app id: $APP_ID"
[[ "$BRIDGE_PORT" =~ ^[0-9]+$ ]] || die "bridge port must be numeric"
[[ "$WEBVIEW_PORT" =~ ^[0-9]+$ ]] || die "webview port must be numeric"

CUSTOM_HOME="$(expand_path "${CUSTOM_HOME:-$(default_custom_home "$APP_ID")}")"
APP_DIR="$HOME/.local/opt/$APP_ID/codex-app"
mkdir -p "$CUSTOM_HOME" "$HOME/.local/bin"
chmod 700 "$CUSTOM_HOME" 2>/dev/null || true

CREATE_ARGS=(--id "$APP_ID" --name "$APP_NAME" --home "$CUSTOM_HOME" --port "$WEBVIEW_PORT" --icon-color "#ef4444")
if [ "$RECREATE_APP" -eq 1 ]; then
  CREATE_ARGS+=(--replace)
fi
if [ ! -d "$APP_DIR" ] || [ "$RECREATE_APP" -eq 1 ]; then
  "$SCRIPT_DIR/create-custom-codex-app.sh" "${CREATE_ARGS[@]}"
fi

install -m 700 "$REPO_ROOT/bridges/openai-compatible-responses-bridge.mjs" "$CUSTOM_HOME/openai-compatible-responses-bridge.mjs"
install -m 700 "$REPO_ROOT/bridges/codex-automations-mcp.mjs" "$CUSTOM_HOME/codex-automations-mcp.mjs"
install -m 700 "$REPO_ROOT/bridges/codex-automations-runner.mjs" "$CUSTOM_HOME/codex-automations-runner.mjs"

ENV_FILE="$CUSTOM_HOME/minimax.env"
if [ -n "${MINIMAX_API_KEY:-}" ]; then
  ENV_MINIMAX_API_KEY="$(shell_single_quote "$MINIMAX_API_KEY")"
  ENV_API_BASE="$(shell_single_quote "$API_BASE")"
  ENV_MODEL="$(shell_single_quote "$MODEL")"
  ENV_SUPPORTED_MODELS="$(shell_single_quote "MiniMax-M2.7,MiniMax-M2.7-highspeed")"
  ENV_PROXY_PORT="$(shell_single_quote "$BRIDGE_PORT")"
  ENV_DEBUG_LOG="$(shell_single_quote "$CUSTOM_HOME/bridge-debug.log")"
  cat >"$ENV_FILE" <<ENV_EOF
# Private provider environment. Do not commit this file.
MINIMAX_API_KEY=$ENV_MINIMAX_API_KEY
CUSTOM_CODEX_PROVIDER_NAME='minimax'
CUSTOM_CODEX_API_BASE=$ENV_API_BASE
CUSTOM_CODEX_API_KEY="\$MINIMAX_API_KEY"
CUSTOM_CODEX_MODEL=$ENV_MODEL
CUSTOM_CODEX_SUPPORTED_MODELS=$ENV_SUPPORTED_MODELS
  CUSTOM_CODEX_PROXY_HOST='127.0.0.1'
  CUSTOM_CODEX_PROXY_PORT=$ENV_PROXY_PORT
  CUSTOM_CODEX_DEBUG_LOG=$ENV_DEBUG_LOG
CUSTOM_CODEX_MAX_TOKENS_FIELD='max_completion_tokens'
ENV_EOF
  chmod 600 "$ENV_FILE"
elif [ ! -f "$ENV_FILE" ]; then
  cp "$REPO_ROOT/templates/minimax.env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  log "created $ENV_FILE; edit it and set MINIMAX_API_KEY"
fi

CONFIG_FILE="$CUSTOM_HOME/config.toml"
cat >"$CONFIG_FILE" <<CONFIG_EOF
model = "$MODEL"
model_provider = "minimax_bridge"
model_context_window = 204800
model_auto_compact_token_limit = 180000
approval_policy = "on-request"
sandbox_mode = "workspace-write"
model_reasoning_effort = "none"

[model_providers.minimax_bridge]
name = "MiniMax M2.7 Responses Bridge"
base_url = "http://127.0.0.1:$BRIDGE_PORT/v1"
env_key = "MINIMAX_API_KEY"
wire_api = "responses"
requires_openai_auth = false
stream_idle_timeout_ms = 600000

[mcp_servers.codex-automations]
command = "node"
args = ["$CUSTOM_HOME/codex-automations-mcp.mjs"]
enabled = true
startup_timeout_sec = 10
default_tools_approval_mode = "approve"
env = { CODEX_AUTOMATIONS_HOME = "$CUSTOM_HOME", CODEX_CUSTOM_BIN = "$HOME/.local/bin/$APP_ID" }
CONFIG_EOF
chmod 600 "$CONFIG_FILE"

CLI_WRAPPER="$HOME/.local/bin/$APP_ID"
DESKTOP_WRAPPER="$HOME/.local/bin/$APP_ID-desktop"
PROXY_WRAPPER="$HOME/.local/bin/$APP_ID-proxy"

cat >"$CLI_WRAPPER" <<CLI_EOF
#!/usr/bin/env bash
set -euo pipefail
export CODEX_HOME="\${CODEX_HOME:-$CUSTOM_HOME}"
ENV_FILE="\$CODEX_HOME/minimax.env"
if [ -f "\$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "\$ENV_FILE"
  set +a
fi
exec "\${CODEX_UPSTREAM_CLI:-codex}" "\$@"
CLI_EOF
chmod +x "$CLI_WRAPPER"

cat >"$DESKTOP_WRAPPER" <<DESKTOP_EOF
#!/usr/bin/env bash
set -euo pipefail
CUSTOM_HOME="$CUSTOM_HOME"
ENV_FILE="\$CUSTOM_HOME/minimax.env"
"$PROXY_WRAPPER" start >/dev/null 2>&1 || true
if [ -f "\$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "\$ENV_FILE"
  set +a
fi
export CODEX_HOME="\$CUSTOM_HOME"
export CODEX_CLI_PATH="$CLI_WRAPPER"
export CODEX_WEBVIEW_PORT="\${CODEX_WEBVIEW_PORT:-$WEBVIEW_PORT}"
export CHROME_DESKTOP="$APP_ID.desktop"
exec "$APP_DIR/start.sh" "\$@"
DESKTOP_EOF
chmod +x "$DESKTOP_WRAPPER"

cat >"$PROXY_WRAPPER" <<PROXY_EOF
#!/usr/bin/env bash
set -euo pipefail
APP_ID="$APP_ID"
CUSTOM_HOME="$CUSTOM_HOME"
ENV_FILE="\$CUSTOM_HOME/minimax.env"
BRIDGE_UNIT="\$APP_ID-bridge"
AUTOMATIONS_UNIT="\$APP_ID-automations"
BRIDGE_LOG="\$CUSTOM_HOME/proxy.log"
BRIDGE_PID="\$CUSTOM_HOME/bridge.pid"
AUTOMATIONS_LOG="\$CUSTOM_HOME/automations/runner.log"
AUTOMATIONS_PID="\$CUSTOM_HOME/automations/runner.pid"

load_env() {
  if [ -f "\$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "\$ENV_FILE"
    set +a
  fi
  export CUSTOM_CODEX_PROVIDER_NAME="\${CUSTOM_CODEX_PROVIDER_NAME:-minimax}"
  export CUSTOM_CODEX_API_BASE="\${CUSTOM_CODEX_API_BASE:-$API_BASE}"
  export CUSTOM_CODEX_API_KEY="\${CUSTOM_CODEX_API_KEY:-\${MINIMAX_API_KEY:-}}"
  export CUSTOM_CODEX_MODEL="\${CUSTOM_CODEX_MODEL:-$MODEL}"
  export CUSTOM_CODEX_SUPPORTED_MODELS="\${CUSTOM_CODEX_SUPPORTED_MODELS:-MiniMax-M2.7,MiniMax-M2.7-highspeed}"
  export CUSTOM_CODEX_PROXY_HOST="\${CUSTOM_CODEX_PROXY_HOST:-127.0.0.1}"
  export CUSTOM_CODEX_PROXY_PORT="\${CUSTOM_CODEX_PROXY_PORT:-$BRIDGE_PORT}"
  export CUSTOM_CODEX_DEBUG_LOG="\${CUSTOM_CODEX_DEBUG_LOG:-\$CUSTOM_HOME/bridge-debug.log}"
  export CUSTOM_CODEX_MAX_TOKENS_FIELD="\${CUSTOM_CODEX_MAX_TOKENS_FIELD:-max_completion_tokens}"
}

systemd_available() {
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

stop_pid_file() {
  local pid_file="\$1"
  local pid
  pid="\$(cat "\$pid_file" 2>/dev/null || true)"
  if [ -n "\$pid" ] && kill -0 "\$pid" 2>/dev/null; then
    kill "\$pid" 2>/dev/null || true
  fi
  rm -f "\$pid_file"
}

status_pid_file() {
  local label="\$1"
  local pid_file="\$2"
  local pid
  pid="\$(cat "\$pid_file" 2>/dev/null || true)"
  if [ -n "\$pid" ] && kill -0 "\$pid" 2>/dev/null; then
    echo "\$label running with pid \$pid"
  else
    echo "\$label not running via pid file"
  fi
}

start_bridge() {
  load_env
  if [ -z "\${CUSTOM_CODEX_API_KEY:-}" ]; then
    echo "CUSTOM_CODEX_API_KEY or MINIMAX_API_KEY is required in \$ENV_FILE" >&2
    exit 1
  fi
  if systemd_available; then
    systemd-run --user --unit "\$BRIDGE_UNIT" --collect --quiet \
      env CUSTOM_CODEX_PROVIDER_NAME="\$CUSTOM_CODEX_PROVIDER_NAME" \
          CUSTOM_CODEX_API_BASE="\$CUSTOM_CODEX_API_BASE" \
          CUSTOM_CODEX_API_KEY="\$CUSTOM_CODEX_API_KEY" \
          CUSTOM_CODEX_MODEL="\$CUSTOM_CODEX_MODEL" \
          CUSTOM_CODEX_SUPPORTED_MODELS="\$CUSTOM_CODEX_SUPPORTED_MODELS" \
          CUSTOM_CODEX_PROXY_HOST="\$CUSTOM_CODEX_PROXY_HOST" \
          CUSTOM_CODEX_PROXY_PORT="\$CUSTOM_CODEX_PROXY_PORT" \
          CUSTOM_CODEX_DEBUG_LOG="\$CUSTOM_CODEX_DEBUG_LOG" \
          CUSTOM_CODEX_MAX_TOKENS_FIELD="\$CUSTOM_CODEX_MAX_TOKENS_FIELD" \
          node "\$CUSTOM_HOME/openai-compatible-responses-bridge.mjs" || true
  else
    mkdir -p "\$CUSTOM_HOME"
    nohup env CUSTOM_CODEX_PROVIDER_NAME="\$CUSTOM_CODEX_PROVIDER_NAME" \
      CUSTOM_CODEX_API_BASE="\$CUSTOM_CODEX_API_BASE" \
      CUSTOM_CODEX_API_KEY="\$CUSTOM_CODEX_API_KEY" \
      CUSTOM_CODEX_MODEL="\$CUSTOM_CODEX_MODEL" \
      CUSTOM_CODEX_SUPPORTED_MODELS="\$CUSTOM_CODEX_SUPPORTED_MODELS" \
      CUSTOM_CODEX_PROXY_HOST="\$CUSTOM_CODEX_PROXY_HOST" \
      CUSTOM_CODEX_PROXY_PORT="\$CUSTOM_CODEX_PROXY_PORT" \
      CUSTOM_CODEX_DEBUG_LOG="\$CUSTOM_CODEX_DEBUG_LOG" \
      CUSTOM_CODEX_MAX_TOKENS_FIELD="\$CUSTOM_CODEX_MAX_TOKENS_FIELD" \
      node "\$CUSTOM_HOME/openai-compatible-responses-bridge.mjs" >>"\$BRIDGE_LOG" 2>&1 &
    echo "\$!" >"\$BRIDGE_PID"
  fi
}

start_automations() {
  mkdir -p "\$CUSTOM_HOME/automations"
  if systemd_available; then
    systemd-run --user --unit "\$AUTOMATIONS_UNIT" --collect --quiet \
      env CODEX_AUTOMATIONS_HOME="\$CUSTOM_HOME" \
          CODEX_CUSTOM_BIN="$CLI_WRAPPER" \
          CODEX_HOME="\$CUSTOM_HOME" \
          node "\$CUSTOM_HOME/codex-automations-runner.mjs" || true
  else
    nohup env CODEX_AUTOMATIONS_HOME="\$CUSTOM_HOME" \
      CODEX_CUSTOM_BIN="$CLI_WRAPPER" \
      CODEX_HOME="\$CUSTOM_HOME" \
      node "\$CUSTOM_HOME/codex-automations-runner.mjs" >>"\$AUTOMATIONS_LOG" 2>&1 &
    echo "\$!" >"\$AUTOMATIONS_PID"
  fi
}

base_url() {
  load_env
  printf 'http://%s:%s' "\$CUSTOM_CODEX_PROXY_HOST" "\$CUSTOM_CODEX_PROXY_PORT"
}

case "\${1:-start}" in
  start) start_bridge ;;
  stop)
    systemctl --user stop "\$BRIDGE_UNIT.service" 2>/dev/null || true
    stop_pid_file "\$BRIDGE_PID"
    ;;
  restart) "\$0" stop; "\$0" start ;;
  status)
    systemctl --user status "\$BRIDGE_UNIT.service" --no-pager 2>/dev/null || true
    status_pid_file "bridge" "\$BRIDGE_PID"
    ;;
  logs) journalctl --user -u "\$BRIDGE_UNIT.service" -n 120 --no-pager 2>/dev/null || tail -n 120 "\$BRIDGE_LOG" ;;
  test)
    command -v curl >/dev/null 2>&1 || { echo "curl is required for test" >&2; exit 1; }
    start_bridge
    sleep 1
    URL="\$(base_url)"
    curl -fsS "\$URL/health"
    printf '\\n'
    curl -fsS "\$URL/v1/models"
    printf '\\n'
    curl -fsS "\$URL/v1/responses" \
      -H 'content-type: application/json' \
      -d '{"model":"$MODEL","input":"Say ok in one short sentence.","stream":false}'
    printf '\\n'
    ;;
  automations-start) start_automations ;;
  automations-stop)
    systemctl --user stop "\$AUTOMATIONS_UNIT.service" 2>/dev/null || true
    stop_pid_file "\$AUTOMATIONS_PID"
    ;;
  automations-status)
    systemctl --user status "\$AUTOMATIONS_UNIT.service" --no-pager 2>/dev/null || true
    status_pid_file "automations" "\$AUTOMATIONS_PID"
    ;;
  automations-log|automations-logs) journalctl --user -u "\$AUTOMATIONS_UNIT.service" -n 120 --no-pager 2>/dev/null || tail -n 120 "\$AUTOMATIONS_LOG" ;;
  *) echo "Usage: \$0 start|stop|restart|status|logs|test|automations-start|automations-stop|automations-status|automations-logs" >&2; exit 2 ;;
esac
PROXY_EOF
chmod +x "$PROXY_WRAPPER"

update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

log "MiniMax profile installed"
log "config: $CONFIG_FILE"
log "env: $ENV_FILE"
log "launch: $DESKTOP_WRAPPER"
log "test: $PROXY_WRAPPER test"
