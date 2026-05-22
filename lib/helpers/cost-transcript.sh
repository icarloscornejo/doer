#!/usr/bin/env bash
# wk plugin: transcript-based cost reconciliation helper.
# Spec: ${CLAUDE_PLUGIN_ROOT}/lib/cost.md
#
# Reads Claude Code session JSONL transcripts and sums real token usage
# (including cache tokens) for all sessions associated with a ticket.
# Writes results to metadata.cost.transcript_reconciled.
#
# This is best-effort: any failure prints a warning to stderr and exits 0.
# It never aborts the pipeline.

set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: cost-transcript.sh reconcile <TICKET-ID>

Commands:
  reconcile <ID>  Read metadata.session_ids[], locate JSONL transcripts,
                  sum tokens (input, output, cache_creation, cache_read),
                  apply rates including cache multipliers, write
                  metadata.cost.transcript_reconciled. Best-effort.

Notes:
  - Requires jq.
  - Reads CLAUDE_CONFIG_DIR (or ~/.claude) for transcript paths.
  - CLAUDE_CODE_SESSION_ID is the preferred session identifier.
  - WK_COST_DISABLED=1 makes this a no-op.
  - WK_TRANSCRIPT_DIR overrides the transcript search base for testing.
EOF
  exit 2
}

[ $# -ge 2 ] || usage
CMD="$1"
TICKET_ID="$2"
shift 2

if ! command -v jq >/dev/null 2>&1; then
  echo "cost-transcript.sh: jq is required" >&2
  exit 0
fi

META_DIR=".doer/tickets/${TICKET_ID}"
META="${META_DIR}/metadata.json"

# Best-effort wrapper: on any error, warn and exit 0.
die_graceful() {
  echo "cost-transcript.sh: warning: $*. Skipping transcript reconciliation." >&2
  exit 0
}

if [ ! -f "$META" ]; then
  die_graceful "metadata.json not found at ${META}"
fi

if [ "${WK_COST_DISABLED:-0}" = "1" ]; then
  exit 0
fi

now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

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

# Resolve the base directory for JSONL transcripts.
# WK_TRANSCRIPT_DIR overrides (used in tests).
resolve_transcript_base() {
  if [ -n "${WK_TRANSCRIPT_DIR:-}" ]; then
    printf '%s\n' "$WK_TRANSCRIPT_DIR"
    return 0
  fi
  local claude_cfg
  claude_cfg="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
  local proj_slug
  proj_slug="$(pwd | sed 's|/|-|g')"
  local base="${claude_cfg}/projects/${proj_slug}"
  if [ -d "$base" ]; then
    printf '%s\n' "$base"
    return 0
  fi
  return 1
}

case "$CMD" in
  reconcile)
    # Read session IDs from metadata. Gracefully exit if none recorded.
    SESSION_IDS="$(jq -r '(.session_ids // []) | .[]' "$META" 2>/dev/null || true)"
    if [ -z "$SESSION_IDS" ]; then
      echo "cost-transcript.sh: no session_ids in metadata for ${TICKET_ID}; skipping." >&2
      exit 0
    fi

    RATES_FILE="$(resolve_rates_file 2>/dev/null || true)"
    if [ -z "$RATES_FILE" ]; then
      die_graceful "rates file not found"
    fi

    TRANSCRIPT_BASE="$(resolve_transcript_base 2>/dev/null || true)"
    if [ -z "$TRANSCRIPT_BASE" ]; then
      die_graceful "transcript directory not found"
    fi

    # Read cache multipliers (with safe fallbacks matching Anthropic pricing).
    CACHE_CREATION_5M_MULT="$(jq -r '.cache_multipliers.creation_5m // 1.25' "$RATES_FILE")"
    CACHE_CREATION_1H_MULT="$(jq -r '.cache_multipliers.creation_1h // 2.0'  "$RATES_FILE")"
    CACHE_READ_MULT="$(jq -r '.cache_multipliers.read // 0.1'                 "$RATES_FILE")"

    # Temporary file for deduplication (message IDs seen).
    SEEN_IDS_FILE="$(mktemp)"
    # Accumulator file: one JSON object per line (newline-delimited).
    ACCUM_FILE="$(mktemp)"
    WARNINGS_FILE="$(mktemp)"
    trap 'rm -f "$SEEN_IDS_FILE" "$ACCUM_FILE" "$WARNINGS_FILE"' EXIT

    PROCESSED_SESSIONS=""

    process_jsonl_file() {
      local jsonl_file="$1"
      local rates_file="$2"
      local cm5="$3"
      local cm1h="$4"
      local cr="$5"

      # Extract assistant messages with usage. Use jq streaming to avoid
      # loading the entire (potentially large) file into memory.
      # Each object is filtered to: uuid, message.id, message.model,
      # message.usage, type == "assistant".
      jq -c 'select(.type == "assistant" and (.message.usage != null))
             | {
                 msg_id:  (.message.id // .uuid),
                 model:   (.message.model // "unknown"),
                 in_tok:  (.message.usage.input_tokens // 0),
                 out_tok: (.message.usage.output_tokens // 0),
                 cc_tok:  (.message.usage.cache_creation_input_tokens // 0),
                 cr_tok:  (.message.usage.cache_read_input_tokens // 0),
                 cc5m:    (.message.usage.cache_creation.ephemeral_5m_input_tokens // null),
                 cc1h:    (.message.usage.cache_creation.ephemeral_1h_input_tokens // null)
               }' "$jsonl_file" 2>/dev/null || true
    }

    for SID in $SESSION_IDS; do
      MAIN_JSONL="${TRANSCRIPT_BASE}/${SID}.jsonl"
      if [ ! -f "$MAIN_JSONL" ]; then
        echo "cost-transcript.sh: JSONL not found for session ${SID} at ${MAIN_JSONL}; skipping." >&2
        echo "JSONL not found for session ${SID}" >> "$WARNINGS_FILE"
        continue
      fi

      PROCESSED_SESSIONS="${PROCESSED_SESSIONS} ${SID}"

      # Process main orchestrator JSONL.
      process_jsonl_file "$MAIN_JSONL" "$RATES_FILE" \
        "$CACHE_CREATION_5M_MULT" "$CACHE_CREATION_1H_MULT" "$CACHE_READ_MULT" \
        >> "$ACCUM_FILE"

      # Process sub-agent JSONLs (exclude acompact).
      SUBAGENT_DIR="${TRANSCRIPT_BASE}/${SID}/subagents"
      if [ -d "$SUBAGENT_DIR" ]; then
        for SA_FILE in "${SUBAGENT_DIR}"/agent-*.jsonl; do
          [ -f "$SA_FILE" ] || continue
          case "$(basename "$SA_FILE")" in
            agent-acompact-*) continue ;;
          esac
          process_jsonl_file "$SA_FILE" "$RATES_FILE" \
            "$CACHE_CREATION_5M_MULT" "$CACHE_CREATION_1H_MULT" "$CACHE_READ_MULT" \
            >> "$ACCUM_FILE"
        done
      fi
    done

    if [ ! -s "$ACCUM_FILE" ]; then
      echo "cost-transcript.sh: no assistant messages found in transcripts; skipping." >&2
      exit 0
    fi

    # Deduplicate by msg_id, then sum tokens and compute USD per model.
    # Uses jq to process the newline-delimited JSON accumulator.
    RECONCILED="$(jq -s -r \
      --argjson cm5  "$CACHE_CREATION_5M_MULT" \
      --argjson cm1h "$CACHE_CREATION_1H_MULT" \
      --argjson cr   "$CACHE_READ_MULT" \
      --slurpfile rates "$RATES_FILE" '
      # Deduplicate by msg_id.
      reduce .[] as $row (
        {};
        . as $acc
        | if $acc[$row.msg_id] == null
          then . + {($row.msg_id): $row}
          else .
          end
      )
      | to_entries | map(.value) as $rows

      # Build per-model aggregates.
      | (
          $rows
          | group_by(.model)
          | map(
              . as $group
              | {
                  model:     ($group[0].model),
                  in_tok:    ([$group[].in_tok]  | add // 0),
                  out_tok:   ([$group[].out_tok] | add // 0),
                  cc_tok:    ([$group[].cc_tok]  | add // 0),
                  cr_tok:    ([$group[].cr_tok]  | add // 0),
                  cc5m_tok:  ([($group[].cc5m // 0)]  | add // 0),
                  cc1h_tok:  ([($group[].cc1h // 0)]  | add // 0)
                }
            )
        ) as $by_model_list

      # Resolve rate for a model id (returns [in_rate, out_rate] or lazy_fallback).
      | (
          $rates[0].rates as $rate_map
          | $rates[0].lazy_fallback.input_per_mtok  as $lazy_in
          | $rates[0].lazy_fallback.output_per_mtok as $lazy_out
          | $by_model_list
          | map(
              . as $m
              | ($rate_map[$m.model]) as $r
              | if $r != null
                then ($r.input_per_mtok)  as $ir
                   | ($r.output_per_mtok) as $or
                   | (
                       # If fine-grained cache_creation breakdown is available use it;
                       # otherwise treat all cache_creation as 5m.
                       ( if $m.cc1h_tok > 0 or $m.cc5m_tok > 0
                         then ($m.cc5m_tok / 1000000 * $ir * $cm5)
                              + ($m.cc1h_tok / 1000000 * $ir * $cm1h)
                         else ($m.cc_tok / 1000000 * $ir * $cm5)
                         end
                       ) as $cc_usd
                     | ($m.cr_tok / 1000000 * $ir * $cr)  as $cr_usd
                     | ($m.in_tok  / 1000000 * $ir)        as $in_usd
                     | ($m.out_tok / 1000000 * $or)        as $out_usd
                     | ($in_usd + $out_usd + $cc_usd + $cr_usd) as $total_usd
                     | {
                         model:                $m.model,
                         input_tokens:         $m.in_tok,
                         output_tokens:        $m.out_tok,
                         cache_creation_tokens: $m.cc_tok,
                         cache_read_tokens:    $m.cr_tok,
                         usd: ($total_usd * 1000000 | round / 1000000)
                       }
                   )
                else
                  # Unknown model: use lazy_fallback for input/output; apply cm5 for cache.
                  (
                    ($m.in_tok  / 1000000 * $lazy_in)  as $in_usd
                    | ($m.out_tok / 1000000 * $lazy_out) as $out_usd
                    | ($m.cc_tok / 1000000 * $lazy_in * $cm5) as $cc_usd
                    | ($m.cr_tok / 1000000 * $lazy_in * $cr)  as $cr_usd
                    | ($in_usd + $out_usd + $cc_usd + $cr_usd) as $total_usd
                    | {
                        model:                $m.model,
                        input_tokens:         $m.in_tok,
                        output_tokens:        $m.out_tok,
                        cache_creation_tokens: $m.cc_tok,
                        cache_read_tokens:    $m.cr_tok,
                        usd: ($total_usd * 1000000 | round / 1000000)
                      }
                  )
                end
            )
        ) as $by_model_result

      # Build totals.
      | {
          total_input_tokens:         ([$by_model_result[].input_tokens]         | add // 0),
          total_output_tokens:        ([$by_model_result[].output_tokens]        | add // 0),
          total_cache_creation_tokens: ([$by_model_result[].cache_creation_tokens] | add // 0),
          total_cache_read_tokens:    ([$by_model_result[].cache_read_tokens]    | add // 0),
          total_usd:                  (([$by_model_result[].usd] | add // 0) * 1000000 | round / 1000000),
          by_model:                   ($by_model_result | map({key: .model, value: (del(.model))}) | from_entries)
        }
    ' "$ACCUM_FILE")"

    if [ -z "$RECONCILED" ] || [ "$RECONCILED" = "null" ]; then
      die_graceful "jq reconciliation produced empty result"
    fi

    # Read existing recorded total_usd (for delta computation).
    RECORDED_USD="$(jq -r '.cost.total_usd // 0' "$META" 2>/dev/null || echo 0)"

    # Build warnings array from file.
    WARNINGS_JSON="$(
      if [ -s "$WARNINGS_FILE" ]; then
        jq -Rs '[split("\n") | .[] | select(. != "")]' "$WARNINGS_FILE"
      else
        printf '[]'
      fi
    )"

    # Build processed session_ids array.
    PROC_SESS_JSON="$(
      printf '%s\n' $PROCESSED_SESSIONS \
        | jq -Rs '[split("\n") | .[] | select(. != "")]'
    )"

    TS="$(now_iso)"

    # Write metadata.cost.transcript_reconciled (atomic).
    jq \
      --argjson r    "$RECONCILED" \
      --argjson sess "$PROC_SESS_JSON" \
      --argjson warn "$WARNINGS_JSON" \
      --arg ts       "$TS" \
      --argjson rec_usd "$RECORDED_USD" '
      .cost.transcript_reconciled = (
        $r
        | . + {
            reconciled_at:            $ts,
            session_ids_processed:    $sess,
            warnings:                 $warn,
            delta_vs_recorded_usd:    ((.total_usd - $rec_usd) * 1000000 | round / 1000000)
          }
      )
    ' "$META" > "${META}.tmp" && mv "${META}.tmp" "$META"

    echo "cost-transcript.sh: reconciled ${TICKET_ID} (sessions: $(echo "$PROCESSED_SESSIONS" | wc -w | tr -d ' '), total_usd: $(jq -r '.cost.transcript_reconciled.total_usd' "$META"))." >&2
    ;;

  *)
    usage
    ;;
esac
