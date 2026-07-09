#!/usr/bin/env bash
# wk plugin: locale preferences helper.
# Spec: ${CLAUDE_PLUGIN_ROOT}/lib/narration.md and lib/state.md.
#
# Storage: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json
# (override with $WK_PREFERENCES_FILE for tests). One file per Claude
# Code config, lives outside the versioned plugin cache so it survives
# uninstall, install, and version upgrades. Locale is the only thing
# that belongs here: it's a personal preference, same in every repo.
# Jira config is per-project instead (see lib/helpers/jira.sh).

set -eu

usage() {
  cat >&2 <<EOF
Usage: preferences.sh <command> [args...]

Commands:
  get-locale                     Print resolved locale code (e.g. "es"). Falls back to "en".
  set-locale <code>              Persist locale to the global preferences file.
  path                           Print resolved preferences file path.
  init                           Create the preferences file with defaults if missing.

Notes:
  - Requires jq.
  - Storage path: \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/wk/preferences.json
  - Override with \$WK_PREFERENCES_FILE.
  - All writes are atomic (write to .tmp then mv).
EOF
  exit 2
}

[ $# -ge 1 ] || usage

if ! command -v jq >/dev/null 2>&1; then
  echo "preferences.sh requires jq" >&2
  exit 2
fi

resolve_prefs_file() {
  if [ -n "${WK_PREFERENCES_FILE:-}" ]; then
    printf '%s\n' "$WK_PREFERENCES_FILE"
    return 0
  fi
  local config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  printf '%s\n' "${config_dir}/wk/preferences.json"
}

ensure_file() {
  local path="$1"
  local dir
  dir="$(dirname "$path")"
  [ -d "$dir" ] || mkdir -p "$dir"
  if [ ! -f "$path" ]; then
    printf '%s\n' '{"locale": null}' > "$path"
  fi
}

write_json_atomic() {
  local path="$1"
  local content="$2"
  local dir
  dir="$(dirname "$path")"
  [ -d "$dir" ] || mkdir -p "$dir"
  printf '%s\n' "$content" > "$path.tmp"
  mv "$path.tmp" "$path"
}

CMD="$1"
shift

case "$CMD" in
  path)
    resolve_prefs_file
    ;;

  init)
    PATH_FILE="$(resolve_prefs_file)"
    ensure_file "$PATH_FILE"
    printf '%s\n' "$PATH_FILE"
    ;;

  get-locale)
    PATH_FILE="$(resolve_prefs_file)"
    if [ ! -f "$PATH_FILE" ]; then
      printf '%s\n' "en"
      exit 0
    fi
    LOC="$(jq -r '.locale // empty' "$PATH_FILE" 2>/dev/null || true)"
    if [ -z "$LOC" ] || [ "$LOC" = "null" ]; then
      printf '%s\n' "en"
    else
      printf '%s\n' "$LOC"
    fi
    ;;

  set-locale)
    [ $# -ge 1 ] || { echo "set-locale requires <code>" >&2; exit 2; }
    CODE="$1"
    PATH_FILE="$(resolve_prefs_file)"
    ensure_file "$PATH_FILE"
    NEW="$(jq --arg c "$CODE" '.locale = $c' "$PATH_FILE")"
    write_json_atomic "$PATH_FILE" "$NEW"
    printf '%s\n' "$CODE"
    ;;

  *)
    usage
    ;;
esac
