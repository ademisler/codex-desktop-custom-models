#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

APP_ID="codex-custom"
APP_NAME="Codex Custom"
CUSTOM_HOME=""
WEBVIEW_PORT="5176"
BASE_APP_DIR=""
INSTALL_DIR=""
ICON_COLOR="#ef4444"
REPLACE=0

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --id ID                 Unique app id, for example codex-minimax
  --name NAME             Display name
  --home PATH             Custom CODEX_HOME, default ~/.ID
  --port PORT             Webview port, default 5176
  --base-app PATH         Existing Linux Codex app directory
  --install-dir PATH      Custom app directory, default ~/.local/opt/ID/codex-app
  --icon-color COLOR      Hex color used when ImageMagick is available
  --replace               Replace an existing custom app shell
  -h, --help              Show help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --id) APP_ID="${2:?}"; shift 2 ;;
    --name) APP_NAME="${2:?}"; shift 2 ;;
    --home) CUSTOM_HOME="${2:?}"; shift 2 ;;
    --port|--webview-port) WEBVIEW_PORT="${2:?}"; shift 2 ;;
    --base-app) BASE_APP_DIR="${2:?}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:?}"; shift 2 ;;
    --icon-color) ICON_COLOR="${2:?}"; shift 2 ;;
    --replace) REPLACE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

valid_app_id "$APP_ID" || die "invalid app id: $APP_ID"
[[ "$WEBVIEW_PORT" =~ ^[0-9]+$ ]] || die "port must be numeric"
[ "$WEBVIEW_PORT" -ge 1 ] && [ "$WEBVIEW_PORT" -le 65535 ] || die "port must be 1..65535"

if [ -z "$BASE_APP_DIR" ]; then
  BASE_APP_DIR="$(detect_base_app_dir)"
else
  BASE_APP_DIR="$(expand_path "$BASE_APP_DIR")"
fi
is_codex_app_dir "$BASE_APP_DIR" || die "not a usable Codex app directory: $BASE_APP_DIR"
BASE_APP_DIR="$(readlink -f "$BASE_APP_DIR")"

CUSTOM_HOME="$(expand_path "${CUSTOM_HOME:-$(default_custom_home "$APP_ID")}")"
INSTALL_DIR="$(expand_path "${INSTALL_DIR:-$HOME/.local/opt/$APP_ID/codex-app}")"
DESKTOP_FILE="$HOME/.local/share/applications/$APP_ID.desktop"
WRAPPER="$HOME/.local/bin/$APP_ID-desktop"

if [ -e "$INSTALL_DIR" ]; then
  if [ "$REPLACE" -ne 1 ]; then
    die "$INSTALL_DIR already exists; pass --replace to recreate the custom shell"
  fi
  rm -rf "$INSTALL_DIR"
fi

mkdir -p "$INSTALL_DIR" "$CUSTOM_HOME" "$(dirname "$DESKTOP_FILE")" "$HOME/.local/bin"
chmod 700 "$CUSTOM_HOME" 2>/dev/null || true

log "base app: $BASE_APP_DIR"
log "custom app: $INSTALL_DIR"
log "custom home: $CUSTOM_HOME"

shopt -s dotglob nullglob
for item in "$BASE_APP_DIR"/* "$BASE_APP_DIR"/.[!.]* "$BASE_APP_DIR"/..?*; do
  [ -e "$item" ] || continue
  name="$(basename "$item")"
  case "$name" in
    start.sh|electron|content|resources|.codex-linux) continue ;;
  esac
  ln -s "$item" "$INSTALL_DIR/$name"
done
shopt -u dotglob nullglob

cp -a "$BASE_APP_DIR/start.sh" "$INSTALL_DIR/start.sh"
cp -a "$BASE_APP_DIR/electron" "$INSTALL_DIR/electron"
chmod +x "$INSTALL_DIR/start.sh" "$INSTALL_DIR/electron" 2>/dev/null || true

cp -a "$BASE_APP_DIR/content" "$INSTALL_DIR/content"

mkdir -p "$INSTALL_DIR/resources"
for item in "$BASE_APP_DIR/resources"/*; do
  [ -e "$item" ] || continue
  ln -s "$item" "$INSTALL_DIR/resources/$(basename "$item")"
done

mkdir -p "$INSTALL_DIR/.codex-linux"
if [ -d "$BASE_APP_DIR/.codex-linux" ]; then
  cp -a "$BASE_APP_DIR/.codex-linux/." "$INSTALL_DIR/.codex-linux/"
fi

SHELL_NAME="$(shell_single_quote "$APP_NAME")"
sed -i -E "s/^CODEX_LINUX_APP_ID=.*/CODEX_LINUX_APP_ID=$APP_ID/" "$INSTALL_DIR/start.sh"
sed -i -E "s/^CODEX_LINUX_APP_DISPLAY_NAME=.*/CODEX_LINUX_APP_DISPLAY_NAME=$SHELL_NAME/" "$INSTALL_DIR/start.sh"
sed -i -E "s#^CODEX_LINUX_WEBVIEW_PORT=.*#CODEX_LINUX_WEBVIEW_PORT=\\\${CODEX_WEBVIEW_PORT:-$WEBVIEW_PORT}#" "$INSTALL_DIR/start.sh"

BASE_ICON=""
for candidate in \
  "$BASE_APP_DIR/.codex-linux/codex-desktop.png" \
  "$BASE_APP_DIR/.codex-linux/codex.png" \
  "$BASE_APP_DIR/assets/codex.png"; do
  if [ -f "$candidate" ]; then
    BASE_ICON="$candidate"
    break
  fi
done

ICON_PNG="$INSTALL_DIR/.codex-linux/$APP_ID.png"
ICON_SVG="$INSTALL_DIR/.codex-linux/$APP_ID.svg"
cp "$REPO_ROOT/docs/assets/icons/custom-codex-red.svg" "$ICON_SVG"

if command -v magick >/dev/null 2>&1 && [ -n "$BASE_ICON" ]; then
  magick "$BASE_ICON" -alpha set -fill "$ICON_COLOR" -colorize 85 "$ICON_PNG" || cp "$BASE_ICON" "$ICON_PNG"
elif [ -n "$BASE_ICON" ]; then
  cp "$BASE_ICON" "$ICON_PNG"
fi

if command -v magick >/dev/null 2>&1; then
  for png in "$INSTALL_DIR/content/webview/assets"/app-*.png; do
    [ -f "$png" ] || continue
    magick "$png" -alpha set -fill "$ICON_COLOR" -colorize 85 "$png" || true
  done
fi

if [ ! -x "$WRAPPER" ]; then
  cat >"$WRAPPER" <<WRAPPER_EOF
#!/usr/bin/env bash
set -euo pipefail
export CODEX_HOME="\${CODEX_HOME:-$CUSTOM_HOME}"
export CODEX_CLI_PATH="\${CODEX_CLI_PATH:-\$(command -v codex || true)}"
export CODEX_WEBVIEW_PORT="\${CODEX_WEBVIEW_PORT:-$WEBVIEW_PORT}"
export CHROME_DESKTOP="$APP_ID.desktop"
exec "$INSTALL_DIR/start.sh" "\$@"
WRAPPER_EOF
  chmod +x "$WRAPPER"
fi

DESKTOP_ICON="$ICON_PNG"
[ -f "$DESKTOP_ICON" ] || DESKTOP_ICON="$ICON_SVG"

cat >"$DESKTOP_FILE" <<DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=Custom isolated Codex Desktop profile
Exec=$WRAPPER %U
Icon=$DESKTOP_ICON
Terminal=false
Categories=Development;Utility;
StartupNotify=true
StartupWMClass=$APP_ID
DESKTOP_EOF

update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

log "created desktop entry: $DESKTOP_FILE"
log "launch wrapper: $WRAPPER"
