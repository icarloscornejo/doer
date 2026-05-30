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
  local projects_dir="${claude_cfg}/projects"

  # Claude Code slugifies the project path by replacing '/' and spaces with '-'.
  local proj_slug
  proj_slug="$(pwd | sed 's|[/ ]|-|g')"
  local base="${projects_dir}/${proj_slug}"
  if [ -d "$base" ]; then
    printf '%s\n' "$base"
    return 0
  fi

  # Fallback: scan projects/ for a directory whose sessions-index.json
  # lists a projectPath matching the current directory. Handles edge cases
  # where the slug algorithm diverges (e.g. unicode, symlinked paths).
  local cwd
  cwd="$(pwd)"
  if [ -d "$projects_dir" ]; then
    local candidate
    candidate="$(
      find "$projects_dir" -maxdepth 2 -name 'sessions-index.json' -print0 2>/dev/null \
        | xargs -0 grep -l "\"projectPath\"" 2>/dev/null \
        | while IFS= read -r idx; do
            if python3 -c "
import json, sys
with open('$idx') as f:
    d = json.load(f)
if d.get('originalPath','') == '$cwd' or any(e.get('projectPath','') == '$cwd' for e in d.get('entries',[])):
    print(sys.argv[1])
" "$(dirname "$idx")" 2>/dev/null; then
              break
            fi
          done
    )"
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
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

    # Parse "<role>\t<stage>" from a sub-agent's sibling meta.json.
    # Convention (written by the doer orchestrator when dispatching an Agent):
    #   description = "doer:s<N>:<role> | <free text>"
    # e.g. "doer:s4:code-writer | implement AC-2 happy path". The role may
    # contain a colon (e.g. "advisor:security"); it is terminated by the first
    # space. Falls back to the harness agentType + "unassigned" stage when the
    # description has no doer prefix (non-doer agents sharing the session), or
    # to "unassigned"/"unassigned" when no meta.json exists.
    parse_agent_role_stage() {
      local meta_file="$1"
      if [ ! -f "$meta_file" ]; then
        printf 'unassigned\tunassigned\n'; return 0
      fi
      local desc atype role stage
      desc="$(jq -r '.description // ""' "$meta_file" 2>/dev/null || echo "")"
      if printf '%s' "$desc" | grep -qE 'doer:s[0-9]+:[a-z][a-z:-]*'; then
        stage="$(printf '%s' "$desc" | sed -E 's/.*doer:s([0-9]+):[a-z][a-z:-]*.*/\1/')"
        role="$(printf '%s' "$desc"  | sed -E 's/.*doer:s[0-9]+:([a-z][a-z:-]*).*/\1/')"
        printf '%s\t%s\n' "$role" "$stage"; return 0
      fi
      atype="$(jq -r '.agentType // "unknown"' "$meta_file" 2>/dev/null || echo "unknown")"
      printf '%s\t%s\n' "$atype" "unassigned"
    }

    process_jsonl_file() {
      local jsonl_file="$1"
      local role="$2"
      local stage="$3"

      # Extract assistant messages with usage. Use jq streaming to avoid
      # loading the entire (potentially large) file into memory. Each row
      # carries the role/stage attribution resolved by the caller, so the
      # downstream aggregation can build by_agent and by_stage breakdowns.
      jq -c --arg role "$role" --arg stage "$stage" \
            'select(.type == "assistant" and (.message.usage != null))
             | {
                 msg_id:  (.message.id // .uuid),
                 model:   (.message.model // "unknown"),
                 role:    $role,
                 stage:   $stage,
                 in_tok:  (.message.usage.input_tokens // 0),
                 out_tok: (.message.usage.output_tokens // 0),
                 cc_tok:  (.message.usage.cache_creation_input_tokens // 0),
                 cr_tok:  (.message.usage.cache_read_input_tokens // 0),
                 cc5m:    (.message.usage.cache_creation.ephemeral_5m_input_tokens // null),
                 cc1h:    (.message.usage.cache_creation.ephemeral_1h_input_tokens // null)
               }' "$jsonl_file" 2>/dev/null || true
    }

    for SID in $SESSION_IDS; do
      # Support two Claude Code storage layouts:
      #   Legacy: <base>/<SID>.jsonl  (single flat file)
      #   Current: <base>/<SID>/subagents/agent-*.jsonl  (directory, no root JSONL)
      MAIN_JSONL="${TRANSCRIPT_BASE}/${SID}.jsonl"
      SESSION_DIR="${TRANSCRIPT_BASE}/${SID}"
      SUBAGENT_DIR="${SESSION_DIR}/subagents"

      FOUND_ANYTHING=0

      # Legacy layout: root JSONL exists. Main-transcript messages are the
      # orchestrator's own turns, attributed to role "orchestrator".
      if [ -f "$MAIN_JSONL" ]; then
        FOUND_ANYTHING=1
        process_jsonl_file "$MAIN_JSONL" "orchestrator" "unassigned" \
          >> "$ACCUM_FILE"
      fi

      # Both layouts: process sub-agent JSONLs under <SID>/subagents/ (exclude
      # acompact). Each sub-agent's role/stage is resolved from its sibling
      # meta.json (agent-<hash>.meta.json) via the doer description convention.
      if [ -d "$SUBAGENT_DIR" ]; then
        for SA_FILE in "${SUBAGENT_DIR}"/agent-*.jsonl; do
          [ -f "$SA_FILE" ] || continue
          case "$(basename "$SA_FILE")" in
            agent-acompact-*) continue ;;
          esac
          FOUND_ANYTHING=1
          SA_META="${SA_FILE%.jsonl}.meta.json"
          ROLE_STAGE="$(parse_agent_role_stage "$SA_META")"
          SA_ROLE="${ROLE_STAGE%%	*}"
          SA_STAGE="${ROLE_STAGE##*	}"
          process_jsonl_file "$SA_FILE" "$SA_ROLE" "$SA_STAGE" \
            >> "$ACCUM_FILE"
        done
      fi

      if [ "$FOUND_ANYTHING" -eq 0 ]; then
        echo "cost-transcript.sh: no JSONL found for session ${SID} (tried ${MAIN_JSONL} and ${SUBAGENT_DIR}/agent-*.jsonl); skipping." >&2
        echo "No JSONL found for session ${SID}" >> "$WARNINGS_FILE"
        continue
      fi

      PROCESSED_SESSIONS="${PROCESSED_SESSIONS} ${SID}"
    done

    if [ ! -s "$ACCUM_FILE" ]; then
      echo "cost-transcript.sh: no assistant messages found in transcripts; skipping." >&2
      exit 0
    fi

    # Deduplicate by msg_id, compute USD PER ROW (resolving each row's model
    # rate), then group the same rows three ways: by_model, by_agent, by_stage.
    # Computing USD per row keeps all three breakdowns consistent against one
    # cost figure. Token/model data comes from each sub-agent's own JSONL and
    # the role/stage attribution from its sibling meta.json.
    RECONCILED="$(jq -s -r \
      --argjson cm5  "$CACHE_CREATION_5M_MULT" \
      --argjson cm1h "$CACHE_CREATION_1H_MULT" \
      --argjson cr   "$CACHE_READ_MULT" \
      --slurpfile rates "$RATES_FILE" '
      def round6: . * 1000000 | round / 1000000;

      # Aggregate a list of usd-annotated rows into the standard breakdown
      # object. keyf selects the grouping key (.model / .role / .stage).
      def agg(keyf):
        group_by(keyf)
        | map({
            key: (.[0] | keyf),
            value: {
              input_tokens:          ([.[].in_tok] | add // 0),
              output_tokens:         ([.[].out_tok] | add // 0),
              cache_creation_tokens: ([.[].cc_tok] | add // 0),
              cache_read_tokens:     ([.[].cr_tok] | add // 0),
              usd:                   ([.[].usd]    | add // 0 | round6)
            }
          })
        | from_entries;

      ($rates[0].rates) as $rate_map
      | ($rates[0].lazy_fallback.input_per_mtok)  as $lazy_in
      | ($rates[0].lazy_fallback.output_per_mtok) as $lazy_out

      # Deduplicate by msg_id (same message can appear across files/resumes).
      | (reduce .[] as $row (
            {};
            if .[$row.msg_id] == null then . + {($row.msg_id): $row} else . end)
         | to_entries | map(.value)) as $rows

      # Annotate each row with its USD cost using its model rate (or fallback).
      | ($rows | map(
          . as $m
          | ($rate_map[$m.model]) as $r
          | (if $r != null then $r.input_per_mtok  else $lazy_in  end) as $ir
          | (if $r != null then $r.output_per_mtok else $lazy_out end) as $outr
          # Fine-grained cache_creation breakdown when present; else treat all as 5m.
          | (if ($m.cc5m // 0) > 0 or ($m.cc1h // 0) > 0
               then (($m.cc5m // 0) / 1000000 * $ir * $cm5)
                    + (($m.cc1h // 0) / 1000000 * $ir * $cm1h)
               else ($m.cc_tok / 1000000 * $ir * $cm5)
             end) as $cc_usd
          | ($m.cr_tok / 1000000 * $ir * $cr) as $cr_usd
          | ($m.in_tok  / 1000000 * $ir)      as $in_usd
          | ($m.out_tok / 1000000 * $outr)    as $out_usd
          | $m + {usd: ($in_usd + $out_usd + $cc_usd + $cr_usd)}
        )) as $rows_usd

      # Totals + the three breakdowns from one consistent set of rows.
      | {
          total_input_tokens:          ([$rows_usd[].in_tok] | add // 0),
          total_output_tokens:         ([$rows_usd[].out_tok] | add // 0),
          total_cache_creation_tokens: ([$rows_usd[].cc_tok] | add // 0),
          total_cache_read_tokens:     ([$rows_usd[].cr_tok] | add // 0),
          total_usd:                   ([$rows_usd[].usd] | add // 0 | round6),
          by_model:                    ($rows_usd | agg(.model)),
          by_agent:                    ($rows_usd | agg(.role)),
          by_stage:                    ($rows_usd | agg(.stage))
        }
    ' "$ACCUM_FILE")" || die_graceful "jq reconciliation failed (exit $?); likely a jq version incompatibility. Run 'jq --version'; this helper needs jq 1.6+"

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
