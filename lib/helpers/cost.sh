#!/usr/bin/env bash
# wk plugin: per-ticket cost helper.
# Spec: ${CLAUDE_PLUGIN_ROOT}/lib/cost.md

set -eu

usage() {
  cat >&2 <<EOF
Usage: cost.sh <command> <TICKET-ID> [args...]

Commands:
  record <ID> --model <id> --input <tokens> --output <tokens> [--stage <N>] [--agent <name>]
  total  <ID>
  status <ID>

Notes:
  - Requires jq.
  - Rates resolved from \$WK_COST_RATES_FILE, else \$CLAUDE_PLUGIN_ROOT/lib/cost-rates.json,
    else <script-dir>/../cost-rates.json.
  - Unknown models use lazy_fallback and warn once per model per session.
  - WK_COST_DISABLED=1 makes 'record' a no-op (still exits 0).
EOF
  exit 2
}

[ $# -ge 2 ] || usage
CMD="$1"
TICKET_ID="$2"
shift 2

if ! command -v jq >/dev/null 2>&1; then
  echo "cost.sh requires jq" >&2
  exit 2
fi

META_DIR=".doer/tickets/${TICKET_ID}"
META="${META_DIR}/metadata.json"

if [ ! -f "$META" ]; then
  echo "metadata.json not found at $META" >&2
  exit 2
fi

resolve_rates_file() {
  if [ -n "${WK_COST_RATES_FILE:-}" ] && [ -f "$WK_COST_RATES_FILE" ]; then
    printf '%s\n' "$WK_COST_RATES_FILE"
    return 0
  fi
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/lib/cost-rates.json" ]; then
    printf '%s\n' "${CLAUDE_PLUGIN_ROOT}/lib/cost-rates.json"
    return 0
  fi
  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  if [ -f "${script_dir}/../cost-rates.json" ]; then
    printf '%s\n' "${script_dir}/../cost-rates.json"
    return 0
  fi
  return 1
}

now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
now_epoch() { date -u +%s; }

iso_to_epoch() {
  local iso="$1"
  if date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null; then return 0; fi
  date -d "$iso" +%s 2>/dev/null
}

write_meta() {
  local tmp="${META}.tmp"
  jq "$1" "$META" > "$tmp" && mv "$tmp" "$META"
}

case "$CMD" in
  record)
    if [ "${WK_COST_DISABLED:-0}" = "1" ]; then
      exit 0
    fi
    MODEL="" IN_TOK="" OUT_TOK="" STAGE="" AGENT=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --model) MODEL="$2"; shift 2 ;;
        --input) IN_TOK="$2"; shift 2 ;;
        --output) OUT_TOK="$2"; shift 2 ;;
        --stage) STAGE="$2"; shift 2 ;;
        --agent) AGENT="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
      esac
    done
    [ -n "$MODEL" ] && [ -n "$IN_TOK" ] && [ -n "$OUT_TOK" ] || usage

    RATES_FILE=$(resolve_rates_file) || {
      echo "cost.sh: rates file not found, skipping record." >&2
      exit 0
    }

    KNOWN=$(jq -r --arg m "$MODEL" '.rates | has($m)' "$RATES_FILE")
    if [ "$KNOWN" = "true" ]; then
      IN_RATE=$(jq -r --arg m "$MODEL" '.rates[$m].input_per_mtok' "$RATES_FILE")
      OUT_RATE=$(jq -r --arg m "$MODEL" '.rates[$m].output_per_mtok' "$RATES_FILE")
      UNKNOWN=0
    else
      IN_RATE=$(jq -r '.lazy_fallback.input_per_mtok' "$RATES_FILE")
      OUT_RATE=$(jq -r '.lazy_fallback.output_per_mtok' "$RATES_FILE")
      UNKNOWN=1
      WARN_FLAG="${TMPDIR:-/tmp}/wk-cost-warned-${MODEL//\//_}-$$"
      if [ ! -f "$WARN_FLAG" ]; then
        : > "$WARN_FLAG"
        echo "cost.sh: unknown model '${MODEL}', using lazy_fallback. Refresh rates with scripts/refresh-rates.sh." >&2
      fi
    fi

    USD=$(jq -n \
      --argjson i "$IN_TOK" --argjson o "$OUT_TOK" \
      --argjson ir "$IN_RATE" --argjson or "$OUT_RATE" \
      '(($i / 1000000) * $ir) + (($o / 1000000) * $or) | . * 1000000 | round / 1000000')

    FETCHED_AT=$(jq -r '.fetched_at' "$RATES_FILE")
    TS=$(now_iso)
    if [ -n "$STAGE" ]; then STAGE_KEY="$STAGE"; else STAGE_KEY="unassigned"; fi

    write_meta "
      .cost = (.cost // {
        currency: \"USD\",
        rates_fetched_at: \"${FETCHED_AT}\",
        total_input_tokens: 0,
        total_output_tokens: 0,
        total_usd: 0,
        by_model: {},
        by_stage: {},
        unknown_models: []
      })
      | .cost.total_input_tokens  += ${IN_TOK}
      | .cost.total_output_tokens += ${OUT_TOK}
      | .cost.total_usd = ((.cost.total_usd + ${USD}) * 1000000 | round / 1000000)
      | .cost.by_model[\"${MODEL}\"] = (
          (.cost.by_model[\"${MODEL}\"] // {calls:0, input_tokens:0, output_tokens:0, usd:0})
          | .calls += 1
          | .input_tokens  += ${IN_TOK}
          | .output_tokens += ${OUT_TOK}
          | .usd = ((.usd + ${USD}) * 1000000 | round / 1000000)
        )
      | .cost.by_stage[\"${STAGE_KEY}\"] = (
          (.cost.by_stage[\"${STAGE_KEY}\"] // {calls:0, usd:0})
          | .calls += 1
          | .usd = ((.usd + ${USD}) * 1000000 | round / 1000000)
        )
      $(if [ "$UNKNOWN" = "1" ]; then
          printf '%s' "
          | (if (.cost.unknown_models | map(.model) | index(\"${MODEL}\")) == null
             then .cost.unknown_models += [{model: \"${MODEL}\", calls: 1, first_seen: \"${TS}\"}]
             else .cost.unknown_models = (.cost.unknown_models | map(if .model == \"${MODEL}\" then .calls += 1 else . end))
             end)
          "
        fi)
    "
    ;;

  total)
    jq '.cost // {}' "$META"
    ;;

  status)
    RATES_FILE=$(resolve_rates_file) || true
    if [ -n "$RATES_FILE" ]; then
      FETCHED_AT=$(jq -r '.fetched_at' "$RATES_FILE")
      TTL_DAYS=$(jq -r '.ttl_days' "$RATES_FILE")
      FETCHED_EPOCH=$(iso_to_epoch "$FETCHED_AT" 2>/dev/null || echo 0)
      AGE_DAYS=$(( ( $(now_epoch) - FETCHED_EPOCH ) / 86400 ))
      if [ "$AGE_DAYS" -ge "$TTL_DAYS" ]; then
        echo "cost.sh: rates file is ${AGE_DAYS}d old (TTL ${TTL_DAYS}d). Refresh with scripts/refresh-rates.sh." >&2
      fi
    fi

    jq -r '
      if (.cost // null) == null then
        "No cost recorded for this ticket yet."
      else
        (.cost) as $c
        | ($c.by_model // {} | to_entries | sort_by(-.value.usd) | .[0:3]
            | map("\(.key)=$\(.value.usd)") | join(", ")) as $top_models
        | ($c.by_stage // {} | to_entries | sort_by(-.value.usd) | .[0:3]
            | map("stage \(.key)=$\(.value.usd)") | join(", ")) as $top_stages
        | ($c.unknown_models // [] | map(.model) | join(", ")) as $unknown
        | "Cost: $\($c.total_usd) USD (input \($c.total_input_tokens) tok, output \($c.total_output_tokens) tok). "
          + (if $top_models == "" then "" else "Top models: \($top_models). " end)
          + (if $top_stages == "" then "" else "Top stages: \($top_stages). " end)
          + (if $unknown == "" then "" else "Unknown models seen: \($unknown). " end)
          + "Rates fetched_at \($c.rates_fetched_at)."
      end
    ' "$META"
    ;;

  *)
    usage
    ;;
esac
