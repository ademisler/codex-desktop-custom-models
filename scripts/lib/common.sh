#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[codex-desktop-custom-models] %s\n' "$*" >&2
}

die() {
  printf '[codex-desktop-custom-models] error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

repo_root() {
  local source="${BASH_SOURCE[0]}"
  local dir
  while [ -L "$source" ]; do
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    case "$source" in
      /*) ;;
      *) source="$dir/$source" ;;
    esac
  done
  cd -P "$(dirname "$source")/../.." && pwd
}

expand_path() {
  local value="$1"
  case "$value" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s/%s\n' "$HOME" "${value#~/}" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

real_path_if_exists() {
  local value="$1"
  if [ -e "$value" ]; then
    readlink -f "$value"
  else
    printf '%s\n' "$value"
  fi
}

default_custom_home() {
  local app_id="$1"
  printf '%s/.%s\n' "$HOME" "$app_id"
}

valid_app_id() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

detect_base_app_dir() {
  if [ -n "${CODEX_BASE_APP_DIR:-}" ]; then
    local explicit
    explicit="$(expand_path "$CODEX_BASE_APP_DIR")"
    [ -d "$explicit" ] || die "CODEX_BASE_APP_DIR does not exist: $explicit"
    printf '%s\n' "$(readlink -f "$explicit")"
    return
  fi

  local candidates=(
    "$HOME/.local/opt/codex/codex-app"
    "$HOME/.local/opt/codex-app/codex-app"
    "$HOME/.local/opt/codex-desktop/codex-app"
    "$HOME/.local/opt/codex-desktop-linux/codex-app"
    "$HOME/.local/share/codex-app-linux/codex-app"
    "/opt/codex/codex-app"
    "/opt/codex-desktop/codex-app"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if is_codex_app_dir "$candidate"; then
      readlink -f "$candidate"
      return
    fi
  done

  local found
  found="$(
    find "$HOME/.local/opt" "$HOME/.cache" "$HOME/Downloads" "$HOME/İndirilenler" \
      -maxdepth 5 -type f -name start.sh 2>/dev/null \
      | while IFS= read -r start; do
          local dir
          dir="$(dirname "$start")"
          if is_codex_app_dir "$dir"; then
            printf '%s\n' "$dir"
            break
          fi
        done
  )"

  [ -n "$found" ] || die "could not detect a Codex Linux app directory; set CODEX_BASE_APP_DIR=/path/to/codex-app"
  readlink -f "$found"
}

is_codex_app_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  [ -f "$dir/start.sh" ] || return 1
  [ -e "$dir/electron" ] || return 1
  [ -d "$dir/content/webview" ] || return 1
  [ -e "$dir/resources/app.asar" ] || return 1
}

desktop_escape() {
  printf '%s\n' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

shell_quote() {
  printf '%q' "$1"
}

shell_single_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
