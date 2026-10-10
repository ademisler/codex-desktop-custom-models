#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

APP_ID=""
PURGE_HOME=0

usage() {
  cat <<USAGE
Usage: $0 --id APP_ID [--purge-home]

Removes launchers, wrappers, and the custom app shell. The custom CODEX_HOME is
kept unless --purge-home is passed.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --id) APP_ID="${2:?}"; shift 2 ;;
    --purge-home) PURGE_HOME=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$APP_ID" ] || die "--id is required"
valid_app_id "$APP_ID" || die "invalid app id: $APP_ID"

CUSTOM_HOME="$(default_custom_home "$APP_ID")"

systemctl --user stop "$APP_ID-bridge.service" 2>/dev/null || true
systemctl --user stop "$APP_ID-automations.service" 2>/dev/null || true
for pid_file in "$CUSTOM_HOME/bridge.pid" "$CUSTOM_HOME/automations/runner.pid"; do
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
done

rm -f "$HOME/.local/bin/$APP_ID" \
  "$HOME/.local/bin/$APP_ID-desktop" \
  "$HOME/.local/bin/$APP_ID-proxy" \
  "$HOME/.local/share/applications/$APP_ID.desktop"
rm -rf "$HOME/.local/opt/$APP_ID"

if [ "$PURGE_HOME" -eq 1 ]; then
  rm -rf "$CUSTOM_HOME"
elif [ -d "$CUSTOM_HOME" ]; then
  log "kept custom home: $CUSTOM_HOME"
fi

update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
log "removed custom app: $APP_ID"
