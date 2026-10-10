#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

need_cmd bash
need_cmd node
need_cmd sqlite3
need_cmd sed
need_cmd find

if ! command -v codex >/dev/null 2>&1; then
  log "warning: codex CLI was not found on PATH"
fi

if ! command -v systemctl >/dev/null 2>&1; then
  log "warning: systemctl not found; proxy wrappers will fall back to nohup"
fi

if ! command -v curl >/dev/null 2>&1; then
  log "warning: curl not found; generated proxy test command will be limited"
fi

if ! command -v magick >/dev/null 2>&1; then
  log "warning: ImageMagick 'magick' not found; icon recoloring will fall back to bundled SVG or source icon"
fi

BASE_APP_DIR="$(detect_base_app_dir)"
log "base app: $BASE_APP_DIR"

required=(
  start.sh
  electron
  content/webview
  resources/app.asar
)

for path in "${required[@]}"; do
  [ -e "$BASE_APP_DIR/$path" ] || die "base app is missing $path"
done

optional=(
  chrome_100_percent.pak
  chrome_200_percent.pak
  resources.pak
  version
  locales
)

for path in "${optional[@]}"; do
  if [ ! -e "$BASE_APP_DIR/$path" ]; then
    log "warning: base app is missing optional Chromium support path: $path"
  fi
done

log "bootstrap check passed"
