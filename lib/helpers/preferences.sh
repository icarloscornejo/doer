#!/usr/bin/env bash
# wk plugin: locale and preferences helper.
# Spec: ${CLAUDE_PLUGIN_ROOT}/lib/narration.md and lib/migrations.md.
#
# Storage: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json
# (override with $WK_PREFERENCES_FILE for tests). One file per Claude
# Code config, lives outside the versioned plugin cache so it survives
# uninstall, install, and version upgrades.

set -eu

usage() {
  cat >&2 <<EOF
Usage: preferences.sh <command> [args...]

Commands:
  get-locale                            Print resolved locale code (e.g. "es"). Falls back to "en".
  set-locale <code>                     Persist locale to the global preferences file.
  get-flag <flag-name>                  Print boolean/value for an opt-in flag. Empty if unset.
  set-flag <flag-name> <value>          Persist a flag value (string, bool, or JSON literal).
  path                                  Print resolved preferences file path.
  init                                  Create the preferences file with defaults if missing.
  detect-locale <text>                  Heuristic: print "es" or "en" based on Spanish keyword density.
  migrate-from-md <markdown-path>       Best-effort import of a legacy preferences.md into the JSON file.

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
    cat > "$path" <<'JSON'
{
  "locale": null,
  "stage4_per_task_gate": false,
  "stage4_parallel_subagents": false,
  "stage5_advisor_personas": []
}
JSON
  fi
}

read_json() {
  local path="$1"
  if [ -f "$path" ]; then
    cat "$path"
  else
    printf '%s\n' '{}'
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

  get-flag)
    [ $# -ge 1 ] || { echo "get-flag requires <flag-name>" >&2; exit 2; }
    FLAG="$1"
    PATH_FILE="$(resolve_prefs_file)"
    if [ ! -f "$PATH_FILE" ]; then
      exit 0
    fi
    jq -r --arg k "$FLAG" '
      if has($k) then
        (.[$k]
          | if type == "boolean" then (if . then "true" else "false" end)
            elif type == "array"   then (map(tostring) | join(","))
            elif type == "null"    then ""
            else tostring
            end)
      else "" end
    ' "$PATH_FILE"
    ;;

  set-flag)
    [ $# -ge 2 ] || { echo "set-flag requires <flag-name> <value>" >&2; exit 2; }
    FLAG="$1"
    VAL="$2"
    PATH_FILE="$(resolve_prefs_file)"
    ensure_file "$PATH_FILE"
    # Try parsing VAL as JSON literal first (true/false/numbers/arrays/objects).
    # Fall back to a JSON string.
    if printf '%s' "$VAL" | jq -e . >/dev/null 2>&1; then
      NEW="$(jq --arg k "$FLAG" --argjson v "$VAL" '.[$k] = $v' "$PATH_FILE")"
    else
      NEW="$(jq --arg k "$FLAG" --arg v "$VAL" '.[$k] = $v' "$PATH_FILE")"
    fi
    write_json_atomic "$PATH_FILE" "$NEW"
    ;;

  detect-locale)
    [ $# -ge 1 ] || { echo "detect-locale requires <text>" >&2; exit 2; }
    TEXT="$1"
    LOWER="$(printf '%s' "$TEXT" | tr '[:upper:]' '[:lower:]')"
    HITS=0
    for kw in que hola gracias porfavor por favor hazlo dale claro tambien tambi ya esta ahora para con sin pero mira oye bueno este pues jaja jeja perdon perdona perdóna por que cómo cuándo dónde sí; do
      case " $LOWER " in
        *" $kw "*) HITS=$((HITS+1));;
      esac
    done
    if [ "$HITS" -ge 2 ]; then
      printf '%s\n' "es"
    else
      printf '%s\n' "en"
    fi
    ;;

  migrate-from-md)
    [ $# -ge 1 ] || { echo "migrate-from-md requires <path>" >&2; exit 2; }
    SRC="$1"
    [ -f "$SRC" ] || { exit 0; }
    PATH_FILE="$(resolve_prefs_file)"
    ensure_file "$PATH_FILE"
    LOC="$(grep -E '^[[:space:]]*locale[[:space:]]*:' "$SRC" | head -n1 | sed -E 's/^[[:space:]]*locale[[:space:]]*:[[:space:]]*//; s/[[:space:]]+$//' || true)"
    GATE="$(grep -E '^[[:space:]]*stage4_per_task_gate[[:space:]]*:' "$SRC" | head -n1 | awk '{print $2}' || true)"
    PARALLEL="$(grep -E '^[[:space:]]*stage4_parallel_subagents[[:space:]]*:' "$SRC" | head -n1 | awk '{print $2}' || true)"
    PERSONAS="$(grep -E '^[[:space:]]*stage5_advisor_personas[[:space:]]*:' "$SRC" | head -n1 | sed -E 's/^[^:]+:[[:space:]]*//' || true)"
    UPDATED="$(cat "$PATH_FILE")"
    if [ -n "$LOC" ] && [ "$LOC" != "null" ]; then
      UPDATED="$(printf '%s' "$UPDATED" | jq --arg c "$LOC" '.locale = (.locale // $c)')"
    fi
    if [ "$GATE" = "true" ] || [ "$GATE" = "false" ]; then
      UPDATED="$(printf '%s' "$UPDATED" | jq --argjson v "$GATE" '.stage4_per_task_gate = $v')"
    fi
    if [ "$PARALLEL" = "true" ] || [ "$PARALLEL" = "false" ]; then
      UPDATED="$(printf '%s' "$UPDATED" | jq --argjson v "$PARALLEL" '.stage4_parallel_subagents = $v')"
    fi
    if [ -n "$PERSONAS" ]; then
      if printf '%s' "$PERSONAS" | jq -e . >/dev/null 2>&1; then
        UPDATED="$(printf '%s' "$UPDATED" | jq --argjson v "$PERSONAS" '.stage5_advisor_personas = $v')"
      fi
    fi
    write_json_atomic "$PATH_FILE" "$UPDATED"
    ;;

  *)
    usage
    ;;
esac
