#!/usr/bin/env bash
# Refresh helper for lib/cost-rates.json.
# Spec: ${CLAUDE_PLUGIN_ROOT}/lib/cost.md
#
# Interactive. Prompts the dev to paste a rates JSON snippet (just the .rates
# object) copied from https://claude.com/pricing#api, validates it with jq,
# merges it into cost-rates.json, and bumps fetched_at. Lazy_fallback,
# currency, source, and ttl_days are preserved unless the dev passes flags.

set -eu

usage() {
  cat >&2 <<EOF
Usage: refresh-rates.sh [--rates-file <path>] [--from-stdin] [--ttl-days <N>]

Modes:
  default        Open an editor on a temp file pre-seeded with the current
                 .rates object; on exit, validate and merge.
  --from-stdin   Read the new .rates object as JSON from stdin (non-interactive).

Flags:
  --rates-file  Override the target file (default: \$CLAUDE_PLUGIN_ROOT/lib/cost-rates.json
                or auto-detected next to this script).
  --ttl-days    Update ttl_days as part of the refresh.
EOF
  exit 2
}

if ! command -v jq >/dev/null 2>&1; then
  echo "refresh-rates.sh requires jq" >&2
  exit 2
fi

RATES_FILE=""
FROM_STDIN=0
NEW_TTL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --rates-file) RATES_FILE="$2"; shift 2 ;;
    --from-stdin) FROM_STDIN=1; shift ;;
    --ttl-days) NEW_TTL="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

if [ -z "$RATES_FILE" ]; then
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/lib/cost-rates.json" ]; then
    RATES_FILE="${CLAUDE_PLUGIN_ROOT}/lib/cost-rates.json"
  else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -f "${SCRIPT_DIR}/../lib/cost-rates.json" ]; then
      RATES_FILE="${SCRIPT_DIR}/../lib/cost-rates.json"
    fi
  fi
fi
if [ -z "$RATES_FILE" ] || [ ! -f "$RATES_FILE" ]; then
  echo "refresh-rates.sh: rates file not found. Pass --rates-file <path>." >&2
  exit 2
fi

now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

INPUT_FILE=""
if [ "$FROM_STDIN" = "1" ]; then
  INPUT_FILE="$(mktemp)"
  cat > "$INPUT_FILE"
else
  INPUT_FILE="$(mktemp).json"
  jq '.rates' "$RATES_FILE" > "$INPUT_FILE"
  EDITOR_BIN="${EDITOR:-${VISUAL:-vi}}"
  cat >&2 <<EOF
Editing $INPUT_FILE in $EDITOR_BIN.
Paste the new .rates object from https://claude.com/pricing#api.
Shape per model: { "input_per_mtok": <USD>, "output_per_mtok": <USD> }.
Save and exit to apply, or leave unchanged to abort.
EOF
  ORIG_HASH="$(shasum "$INPUT_FILE" | awk '{print $1}')"
  "$EDITOR_BIN" "$INPUT_FILE"
  NEW_HASH="$(shasum "$INPUT_FILE" | awk '{print $1}')"
  if [ "$ORIG_HASH" = "$NEW_HASH" ]; then
    echo "refresh-rates.sh: no changes, aborted." >&2
    rm -f "$INPUT_FILE"
    exit 0
  fi
fi

if ! jq -e 'type == "object"' "$INPUT_FILE" >/dev/null 2>&1; then
  echo "refresh-rates.sh: input is not a JSON object." >&2
  rm -f "$INPUT_FILE"
  exit 1
fi
INVALID=$(jq -r '
  to_entries
  | map(select(
      (.value | type) != "object" or
      (.value.input_per_mtok | type) != "number" or
      (.value.output_per_mtok | type) != "number"
    ))
  | map(.key) | join(", ")
' "$INPUT_FILE")
if [ -n "$INVALID" ]; then
  echo "refresh-rates.sh: invalid model entries (need numeric input_per_mtok and output_per_mtok): $INVALID" >&2
  rm -f "$INPUT_FILE"
  exit 1
fi

TS=$(now_iso)
TMP="${RATES_FILE}.tmp"
if [ -n "$NEW_TTL" ]; then
  jq --slurpfile r "$INPUT_FILE" --arg ts "$TS" --argjson ttl "$NEW_TTL" \
    '.rates = $r[0] | .fetched_at = $ts | .ttl_days = $ttl' "$RATES_FILE" > "$TMP"
else
  jq --slurpfile r "$INPUT_FILE" --arg ts "$TS" \
    '.rates = $r[0] | .fetched_at = $ts' "$RATES_FILE" > "$TMP"
fi
mv "$TMP" "$RATES_FILE"
rm -f "$INPUT_FILE"

MODEL_COUNT=$(jq '.rates | length' "$RATES_FILE")
echo "refresh-rates.sh: updated $RATES_FILE ($MODEL_COUNT models, fetched_at $TS)."
