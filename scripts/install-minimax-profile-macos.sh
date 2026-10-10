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
BASE_APP=""
APP_DIR=""
REPLACE_APP=0

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
  --base-app PATH      Existing macOS Codex.app, default /Applications/Codex.app
  --app-dir PATH       Custom app path, default ~/Applications/NAME.app
  --replace-app        Replace an existing custom app bundle
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
    --base-app) BASE_APP="${2:?}"; shift 2 ;;
    --app-dir) APP_DIR="${2:?}"; shift 2 ;;
    --replace-app) REPLACE_APP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "this installer is for macOS"
valid_app_id "$APP_ID" || die "invalid app id: $APP_ID"
[[ "$BRIDGE_PORT" =~ ^[0-9]+$ ]] || die "bridge port must be numeric"
[[ "$WEBVIEW_PORT" =~ ^[0-9]+$ ]] || die "webview port must be numeric"

need_cmd codex
need_cmd node
need_cmd plutil
need_cmd ditto
need_cmd codesign
need_cmd swift
need_cmd iconutil

detect_base_app() {
  local candidates=(
    "/Applications/Codex.app"
    "$HOME/Applications/Codex.app"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -d "$candidate/Contents/MacOS" ] && [ -f "$candidate/Contents/Info.plist" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  die "could not detect Codex.app; pass --base-app /path/to/Codex.app"
}

CUSTOM_HOME="$(expand_path "${CUSTOM_HOME:-$(default_custom_home "$APP_ID")}")"
BASE_APP="$(expand_path "${BASE_APP:-$(detect_base_app)}")"
APP_DIR="$(expand_path "${APP_DIR:-$HOME/Applications/$APP_NAME.app}")"
CODEX_CLI_BIN="$(command -v codex)"
NODE_BIN="$(command -v node)"
LOCAL_BIN="$HOME/.local/bin"
CLI_WRAPPER="$LOCAL_BIN/$APP_ID"
DESKTOP_WRAPPER="$LOCAL_BIN/$APP_ID-desktop"
PROXY_WRAPPER="$LOCAL_BIN/$APP_ID-proxy"

[ -d "$BASE_APP" ] || die "base app does not exist: $BASE_APP"
[ -f "$BASE_APP/Contents/Info.plist" ] || die "not a macOS app bundle: $BASE_APP"

mkdir -p "$CUSTOM_HOME" "$LOCAL_BIN" "$HOME/Applications"
chmod 700 "$CUSTOM_HOME" 2>/dev/null || true

install -m 700 "$REPO_ROOT/bridges/openai-compatible-responses-bridge.mjs" "$CUSTOM_HOME/openai-compatible-responses-bridge.mjs"
install -m 700 "$REPO_ROOT/bridges/codex-automations-mcp.mjs" "$CUSTOM_HOME/codex-automations-mcp.mjs"
install -m 700 "$REPO_ROOT/bridges/codex-automations-runner.mjs" "$CUSTOM_HOME/codex-automations-runner.mjs"

ENV_FILE="$CUSTOM_HOME/minimax.env"
ENV_NEEDS_KEY=0
if [ -n "${MINIMAX_API_KEY:-}" ]; then
  ENV_MINIMAX_API_KEY="$(shell_single_quote "$MINIMAX_API_KEY")"
else
  ENV_MINIMAX_API_KEY='"replace-me"'
  ENV_NEEDS_KEY=1
fi

ENV_API_BASE="$(shell_single_quote "$API_BASE")"
ENV_MODEL="$(shell_single_quote "$MODEL")"
ENV_SUPPORTED_MODELS="$(shell_single_quote "MiniMax-M2.7,MiniMax-M2.7-highspeed")"
ENV_PROXY_PORT="$(shell_single_quote "$BRIDGE_PORT")"
ENV_DEBUG_LOG="$(shell_single_quote "$CUSTOM_HOME/bridge-debug.log")"

if [ -n "${MINIMAX_API_KEY:-}" ] || [ ! -f "$ENV_FILE" ]; then
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
command = "$NODE_BIN"
args = ["$CUSTOM_HOME/codex-automations-mcp.mjs"]
enabled = true
startup_timeout_sec = 10
default_tools_approval_mode = "approve"
env = { CODEX_AUTOMATIONS_HOME = "$CUSTOM_HOME", CODEX_CUSTOM_BIN = "$CLI_WRAPPER" }
CONFIG_EOF
chmod 600 "$CONFIG_FILE"

cat >"$CLI_WRAPPER" <<CLI_EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
export CODEX_HOME="\${CODEX_HOME:-$CUSTOM_HOME}"
ENV_FILE="\$CODEX_HOME/minimax.env"
if [ -f "\$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "\$ENV_FILE"
  set +a
fi
exec "\${CODEX_UPSTREAM_CLI:-$CODEX_CLI_BIN}" "\$@"
CLI_EOF
chmod +x "$CLI_WRAPPER"

cat >"$PROXY_WRAPPER" <<PROXY_EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
APP_ID="$APP_ID"
CUSTOM_HOME="$CUSTOM_HOME"
ENV_FILE="\$CUSTOM_HOME/minimax.env"
BRIDGE_LOG="\$CUSTOM_HOME/proxy.log"
BRIDGE_PID="\$CUSTOM_HOME/bridge.pid"
BRIDGE_LABEL="com.ademisler.$APP_ID.bridge"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
BRIDGE_PLIST="\$LAUNCH_AGENTS_DIR/\$BRIDGE_LABEL.plist"
AUTOMATIONS_LOG="\$CUSTOM_HOME/automations/runner.log"
AUTOMATIONS_PID="\$CUSTOM_HOME/automations/runner.pid"
NODE_BIN="$NODE_BIN"

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

pid_running() {
  local pid_file="\$1"
  local pid
  pid="\$(cat "\$pid_file" 2>/dev/null || true)"
  [ -n "\$pid" ] && kill -0 "\$pid" 2>/dev/null
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
    echo "\$label not running"
  fi
}

launchctl_available() {
  command -v launchctl >/dev/null 2>&1 && [ "\$(uname -s)" = "Darwin" ]
}

launchctl_domain() {
  printf 'gui/%s' "\$(id -u)"
}

write_bridge_launch_agent() {
  local launch_command
  launch_command="set -a; source \"\$ENV_FILE\"; set +a; exec \"\$NODE_BIN\" \"\$CUSTOM_HOME/openai-compatible-responses-bridge.mjs\""

  mkdir -p "\$LAUNCH_AGENTS_DIR"
  rm -f "\$BRIDGE_PLIST"
  plutil -create xml1 "\$BRIDGE_PLIST"
  plutil -insert Label -string "\$BRIDGE_LABEL" "\$BRIDGE_PLIST"
  plutil -insert ProgramArguments -array "\$BRIDGE_PLIST"
  plutil -insert ProgramArguments.0 -string "/bin/bash" "\$BRIDGE_PLIST"
  plutil -insert ProgramArguments.1 -string "-lc" "\$BRIDGE_PLIST"
  plutil -insert ProgramArguments.2 -string "\$launch_command" "\$BRIDGE_PLIST"
  plutil -insert WorkingDirectory -string "\$CUSTOM_HOME" "\$BRIDGE_PLIST"
  plutil -insert StandardOutPath -string "\$BRIDGE_LOG" "\$BRIDGE_PLIST"
  plutil -insert StandardErrorPath -string "\$BRIDGE_LOG" "\$BRIDGE_PLIST"
  plutil -insert RunAtLoad -bool false "\$BRIDGE_PLIST"
  plutil -insert EnvironmentVariables -dictionary "\$BRIDGE_PLIST"
  plutil -insert EnvironmentVariables.PATH -string "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "\$BRIDGE_PLIST"
}

start_bridge_launch_agent() {
  local domain
  domain="\$(launchctl_domain)"
  write_bridge_launch_agent
  launchctl bootout "\$domain" "\$BRIDGE_PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "\$domain" "\$BRIDGE_PLIST" >/dev/null 2>&1 || true
  launchctl kickstart -k "\$domain/\$BRIDGE_LABEL" >/dev/null 2>&1
}

stop_bridge_launch_agent() {
  local domain
  domain="\$(launchctl_domain)"
  if [ -f "\$BRIDGE_PLIST" ]; then
    launchctl bootout "\$domain" "\$BRIDGE_PLIST" >/dev/null 2>&1 || true
  else
    launchctl kill TERM "\$domain/\$BRIDGE_LABEL" >/dev/null 2>&1 || true
  fi
}

status_bridge_launch_agent() {
  local domain output pid
  domain="\$(launchctl_domain)"
  output="\$(launchctl print "\$domain/\$BRIDGE_LABEL" 2>/dev/null || true)"
  [ -n "\$output" ] || return 1
  pid="\$(printf '%s\n' "\$output" | awk -F'= ' '/pid =/{print \$2; exit}')"
  if [ -n "\$pid" ]; then
    echo "bridge running with pid \$pid"
  else
    echo "bridge loaded via launchctl"
  fi
  return 0
}

start_bridge() {
  load_env
  if [ "\${CUSTOM_CODEX_API_KEY:-}" = "replace-me" ] || [ -z "\${CUSTOM_CODEX_API_KEY:-}" ]; then
    echo "Set MINIMAX_API_KEY in \$ENV_FILE before starting the bridge." >&2
    exit 1
  fi
  if pid_running "\$BRIDGE_PID"; then
    return
  fi
  if launchctl_available && start_bridge_launch_agent; then
    rm -f "\$BRIDGE_PID"
    return
  fi
  mkdir -p "\$CUSTOM_HOME"
  nohup env CUSTOM_CODEX_PROVIDER_NAME="\$CUSTOM_CODEX_PROVIDER_NAME" \\
    CUSTOM_CODEX_API_BASE="\$CUSTOM_CODEX_API_BASE" \\
    CUSTOM_CODEX_API_KEY="\$CUSTOM_CODEX_API_KEY" \\
    CUSTOM_CODEX_MODEL="\$CUSTOM_CODEX_MODEL" \\
    CUSTOM_CODEX_SUPPORTED_MODELS="\$CUSTOM_CODEX_SUPPORTED_MODELS" \\
    CUSTOM_CODEX_PROXY_HOST="\$CUSTOM_CODEX_PROXY_HOST" \\
    CUSTOM_CODEX_PROXY_PORT="\$CUSTOM_CODEX_PROXY_PORT" \\
    CUSTOM_CODEX_DEBUG_LOG="\$CUSTOM_CODEX_DEBUG_LOG" \\
    CUSTOM_CODEX_MAX_TOKENS_FIELD="\$CUSTOM_CODEX_MAX_TOKENS_FIELD" \\
    "\$NODE_BIN" "\$CUSTOM_HOME/openai-compatible-responses-bridge.mjs" >>"\$BRIDGE_LOG" 2>&1 &
  echo "\$!" >"\$BRIDGE_PID"
}

start_automations() {
  mkdir -p "\$CUSTOM_HOME/automations"
  if pid_running "\$AUTOMATIONS_PID"; then
    return
  fi
  nohup env CODEX_AUTOMATIONS_HOME="\$CUSTOM_HOME" \\
    CODEX_CUSTOM_BIN="$CLI_WRAPPER" \\
    CODEX_HOME="\$CUSTOM_HOME" \\
    "\$NODE_BIN" "\$CUSTOM_HOME/codex-automations-runner.mjs" >>"\$AUTOMATIONS_LOG" 2>&1 &
  echo "\$!" >"\$AUTOMATIONS_PID"
}

base_url() {
  load_env
  printf 'http://%s:%s' "\$CUSTOM_CODEX_PROXY_HOST" "\$CUSTOM_CODEX_PROXY_PORT"
}

case "\${1:-start}" in
  start) start_bridge ;;
  stop)
    if launchctl_available; then
      stop_bridge_launch_agent
    fi
    stop_pid_file "\$BRIDGE_PID"
    ;;
  restart) "\$0" stop; "\$0" start ;;
  status)
    if launchctl_available && status_bridge_launch_agent; then
      exit 0
    fi
    status_pid_file "bridge" "\$BRIDGE_PID"
    ;;
  logs) tail -n 120 "\$BRIDGE_LOG" ;;
  test)
    command -v curl >/dev/null 2>&1 || { echo "curl is required for test" >&2; exit 1; }
    start_bridge
    sleep 1
    URL="\$(base_url)"
    curl -fsS "\$URL/health"
    printf '\\n'
    curl -fsS "\$URL/v1/models"
    printf '\\n'
    curl -fsS "\$URL/v1/responses" \\
      -H 'content-type: application/json' \\
      -d '{"model":"$MODEL","input":[{"role":"user","content":[{"type":"input_text","text":"Reply with ok."}]}],"stream":false}'
    printf '\\n'
    ;;
  automations-start) start_automations ;;
  automations-stop) stop_pid_file "\$AUTOMATIONS_PID" ;;
  automations-status) status_pid_file "automations" "\$AUTOMATIONS_PID" ;;
  automations-log|automations-logs) tail -n 120 "\$AUTOMATIONS_LOG" ;;
  *) echo "usage: \$0 {start|stop|restart|status|logs|test|automations-start|automations-stop|automations-status|automations-logs}" >&2; exit 2 ;;
esac
PROXY_EOF
chmod +x "$PROXY_WRAPPER"

cat >"$DESKTOP_WRAPPER" <<DESKTOP_EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
"$PROXY_WRAPPER" start >/dev/null 2>&1 || true
open -n "$APP_DIR" --args "\$@"
DESKTOP_EOF
chmod +x "$DESKTOP_WRAPPER"

if [ -e "$APP_DIR" ]; then
  if [ "$REPLACE_APP" -ne 1 ]; then
    die "$APP_DIR already exists; pass --replace-app to recreate it"
  fi
  rm -rf "$APP_DIR"
fi

log "base app: $BASE_APP"
log "custom app: $APP_DIR"
log "custom home: $CUSTOM_HOME"

ditto "$BASE_APP" "$APP_DIR"

PLIST="$APP_DIR/Contents/Info.plist"
plutil -replace CFBundleName -string "$APP_NAME" "$PLIST"
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$PLIST"
plutil -replace CFBundleIdentifier -string "com.ademisler.$APP_ID" "$PLIST"
plutil -replace CFBundleExecutable -string "Codex" "$PLIST"
if plutil -extract CFBundleURLTypes json -o /dev/null "$PLIST" >/dev/null 2>&1; then
  plutil -replace CFBundleURLTypes.0.CFBundleURLName -string "$APP_NAME" "$PLIST" || true
  plutil -replace CFBundleURLTypes.0.CFBundleURLSchemes.0 -string "$APP_ID" "$PLIST" || true
fi

/usr/libexec/PlistBuddy -c "Delete :LSEnvironment" "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:PATH string /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:CODEX_HOME string $CUSTOM_HOME" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:CODEX_CLI_PATH string $CLI_WRAPPER" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:CODEX_WEBVIEW_PORT string $WEBVIEW_PORT" "$PLIST"

FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
for suffix in "" " (GPU)" " (Plugin)" " (Renderer)"; do
  OLD_HELPER="Codex Helper$suffix"
  NEW_HELPER="$APP_NAME Helper$suffix"
  OLD_HELPER_APP="$FRAMEWORKS_DIR/$OLD_HELPER.app"
  NEW_HELPER_APP="$FRAMEWORKS_DIR/$NEW_HELPER.app"
  [ -d "$OLD_HELPER_APP" ] || continue

  if [ -f "$OLD_HELPER_APP/Contents/MacOS/$OLD_HELPER" ]; then
    mv "$OLD_HELPER_APP/Contents/MacOS/$OLD_HELPER" "$OLD_HELPER_APP/Contents/MacOS/$NEW_HELPER"
  fi

  HELPER_PLIST="$OLD_HELPER_APP/Contents/Info.plist"
  plutil -replace CFBundleExecutable -string "$NEW_HELPER" "$HELPER_PLIST"
  plutil -replace CFBundleDisplayName -string "$NEW_HELPER" "$HELPER_PLIST"
  if [ -z "$suffix" ]; then
    plutil -replace CFBundleName -string "$APP_NAME" "$HELPER_PLIST"
    plutil -replace CFBundleIdentifier -string "com.ademisler.$APP_ID.helper" "$HELPER_PLIST"
  else
    HELPER_KIND="$(printf '%s' "$suffix" | tr '[:upper:] ()' '[:lower:].' | tr -s '.' | sed 's/^\\.//; s/\\.$//')"
    plutil -replace CFBundleName -string "$NEW_HELPER" "$HELPER_PLIST"
    plutil -replace CFBundleIdentifier -string "com.ademisler.$APP_ID.helper.$HELPER_KIND" "$HELPER_PLIST"
  fi

  mv "$OLD_HELPER_APP" "$NEW_HELPER_APP"
done

ICON_WORK="$CUSTOM_HOME/icon-build"
BASE_ICON="$BASE_APP/Contents/Resources/electron.icns"
BASE_ICONSET="$ICON_WORK/base.iconset"
ICONSET="$ICON_WORK/$APP_ID-red.iconset"
ICON_ICNS="$ICON_WORK/$APP_ID.icns"
if [ -f "$BASE_ICON" ]; then
  rm -rf "$ICON_WORK"
  mkdir -p "$ICON_WORK"
  iconutil -c iconset "$BASE_ICON" -o "$BASE_ICONSET"
  cp -R "$BASE_ICONSET" "$ICONSET"
  for png in "$ICONSET"/*.png; do
    swift - "$png" "$png" <<'SWIFT_ICON_TINT'
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("usage: tint input output") }
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("cannot load image")
}

let width = image.width
let height = image.height
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("cannot create context") }

context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

func rgbToHsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
    let maxValue = max(r, g, b)
    let minValue = min(r, g, b)
    let delta = maxValue - minValue
    var hue = 0.0
    if delta != 0 {
        if maxValue == r {
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6.0)
        } else if maxValue == g {
            hue = ((b - r) / delta) + 2.0
        } else {
            hue = ((r - g) / delta) + 4.0
        }
        hue *= 60.0
        if hue < 0 { hue += 360.0 }
    }
    let saturation = maxValue == 0 ? 0 : delta / maxValue
    return (hue, saturation, maxValue)
}

func hsvToRgb(_ h: Double, _ s: Double, _ v: Double) -> (r: Double, g: Double, b: Double) {
    let c = v * s
    let x = c * (1.0 - abs((h / 60.0).truncatingRemainder(dividingBy: 2.0) - 1.0))
    let m = v - c
    let hp = h / 60.0
    let rgb: (Double, Double, Double)
    switch hp {
    case 0..<1: rgb = (c, x, 0)
    case 1..<2: rgb = (x, c, 0)
    case 2..<3: rgb = (0, c, x)
    case 3..<4: rgb = (0, x, c)
    case 4..<5: rgb = (x, 0, c)
    default: rgb = (c, 0, x)
    }
    return (rgb.0 + m, rgb.1 + m, rgb.2 + m)
}

for i in stride(from: 0, to: pixels.count, by: 4) {
    let alpha = pixels[i + 3]
    if alpha < 20 { continue }
    let r = Double(pixels[i]) / 255.0
    let g = Double(pixels[i + 1]) / 255.0
    let b = Double(pixels[i + 2]) / 255.0
    let hsv = rgbToHsv(r, g, b)

    // Recolor the saturated blue/purple Codex cloud while preserving the
    // white background, white terminal glyph, shadows, and highlights.
    let isBlueCloud = hsv.s > 0.205 && hsv.v > 0.22 && hsv.h >= 205.0 && hsv.h <= 275.0
    if !isBlueCloud { continue }

    let out = hsvToRgb(356.0, min(1.0, hsv.s * 1.03), min(1.0, hsv.v * 1.01))
    pixels[i] = UInt8((out.r * 255.0).rounded())
    pixels[i + 1] = UInt8((out.g * 255.0).rounded())
    pixels[i + 2] = UInt8((out.b * 255.0).rounded())
}

guard let outImage = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("cannot create output")
}
CGImageDestinationAddImage(destination, outImage, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("cannot write output") }
SWIFT_ICON_TINT
  done
  iconutil -c icns "$ICONSET" -o "$ICON_ICNS"
  cp "$ICON_ICNS" "$APP_DIR/Contents/Resources/electron.icns"
  cp "$ICON_ICNS" "$APP_DIR/Contents/Resources/icon.icns"
  plutil -replace CFBundleIconFile -string "electron.icns" "$PLIST"
  plutil -replace CFBundleIconName -string "$APP_ID" "$PLIST"
else
  log "warning: could not find $BASE_ICON; keeping copied Codex icon"
fi

rm -rf "$APP_DIR/Contents/_CodeSignature"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || log "warning: ad-hoc codesign failed; the copied app may need manual approval in macOS Privacy & Security"
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true
touch "$APP_DIR"
/usr/bin/mdimport "$APP_DIR" >/dev/null 2>&1 || true

if [ "$ENV_NEEDS_KEY" -eq 1 ] && grep -q 'replace-me' "$ENV_FILE" 2>/dev/null; then
  log "provider env needs MINIMAX_API_KEY before testing: $ENV_FILE"
fi
log "CLI wrapper: $CLI_WRAPPER"
log "desktop wrapper: $DESKTOP_WRAPPER"
log "proxy wrapper: $PROXY_WRAPPER"
log "app bundle: $APP_DIR"
