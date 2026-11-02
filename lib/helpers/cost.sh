#!/usr/bin/env bash
# wk plugin: cost per ticket helper (/wk:doer and /wk:bugfix).
# Spec: ${CLAUDE_PLUGIN_ROOT}/lib/state.md (cost_sessions, cost).
#
# The ticket cost is the sum of the costs of the sessions that worked it, read
# from counters other tools already persist. This script holds no rates and
# computes no cost from tokens; when a counter is missing or goes backwards the
# record says unknown and why. Data problems never make it exit non-zero.
#
#   sample                     {"id","ts","usd"} for the current session
#   enter <ID> [--file F]      register the current session for the ticket
#   record <ID> [--file F]     print the cost record (one JSON object, exit 0)
#   unknown "<reason>"         print an unknown record (fallback for prose)
#
# Sources (env overrides exist for tests):
#   COST_STATUSLINE_CACHE_DIR  daily-YYYY-MM-DD.json, {session: usd}
#   COST_MULTI_INSTANCE_DIR    <instance>.json snapshots and daily-*.json
#   COST_PROJECTS_DIR          transcripts, projects/*/<session>.jsonl

HERE="$(cd "$(dirname "$0")" && pwd)"
SCOPE_TEXT="whole sessions; may include non-ticket work in them"
STATUSLINE_DIR="${COST_STATUSLINE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline}"
MULTI_DIR="${COST_MULTI_INSTANCE_DIR:-$HOME/Library/Application Support/ai-multi-instance}"
PROJECTS_DIR="${COST_PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"

command -v jq >/dev/null 2>&1 || { echo "cost.sh requires jq" >&2; exit 0; }

# jq-compat:begin cost_lookup
# A daily file value of zero is not trusted (that writer logs zero for sessions
# it has no figure for); a snapshot zero is a real fresh session.
DAILY_HIT='if type == "object" and has($id) then (.[$id] | if type == "number" and . > 0 then . else null end) else empty end'
SNAPSHOT_HIT='if type == "object" and .sessionId == $id then (.sessionCostUsd | if type == "number" and . >= 0 then . else null end) else empty end'
BEST_VALUE='map(select(. != null)) | if length == 0 then null else max end'
SAMPLE_OBJECT='{id: $id, ts: $ts, usd: $usd}'
UNKNOWN_RECORD='{status: "unknown", total_usd: null, reason: $reason, scope: $scope, input_tokens: null, output_tokens: null, cache_read_tokens: null, cache_creation_tokens: null, sessions: [], by_stage: null, by_stage_reason: null, recorded_at: $ts}'
ENTER_STATE='if (.cost_sessions | type) != "array" then "untracked" elif any(.cost_sessions[]?; type == "object" and .id == $id) then "registered" else "missing" end'
SESSION_IDS='try ([.cost_sessions[]? | select(type == "object") | .id | select(type == "string")] | .[]) catch empty'
ONE_OBJECT='length == 1 and (.[0] | type == "object")'
NO_TRANSCRIPT='{sid: $sid, found: false, events: []}'
# jq-compat:end

# jq-compat:begin transcript_events
# One assistant line per API response can be logged several times; the record
# step dedupes by message id, so every usable line is kept here.
TRANSCRIPT_EVENTS='def amount: if type == "number" then . else 0 end;
{sid: $sid, found: true, events: [split("\n")[] | fromjson?
  | select(type == "object" and .type == "assistant" and (.message | type) == "object" and (.message.usage | type) == "object")
  | {mid: .message.id, rid: .requestId, ts: .timestamp,
     i: (.message.usage.input_tokens | amount), o: (.message.usage.output_tokens | amount),
     cr: (.message.usage.cache_read_input_tokens | amount), cc: (.message.usage.cache_creation_input_tokens | amount)}]}'
# jq-compat:end

# jq-compat:begin record
RECORD_PROGRAM='
def total(f): (map(f) | add) // 0;
def epoch_raw:
  if type != "string" then null else
    (capture("^(?<y>[0-9]{4})-(?<mo>[0-9]{2})-(?<d>[0-9]{2})T(?<h>[0-9]{2}):(?<mi>[0-9]{2}):(?<s>[0-9]{2})(?<f>\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})$") // null) as $p
    | if $p == null then null else
        ($p.z | if . == "Z" then 0 else (((if .[0:1] == "-" then -1 else 1 end)) * ((.[1:3] | tonumber) * 3600 + (.[-2:] | tonumber) * 60)) end) as $offset
        | (if $p.f == null then 0 else ("0" + $p.f | tonumber) end) as $fraction
        | ([($p.y | tonumber), ($p.mo | tonumber) - 1, ($p.d | tonumber), ($p.h | tonumber), ($p.mi | tonumber), ($p.s | tonumber), 0, 0] | mktime) - $offset + $fraction
      end
  end;
def epoch: try epoch_raw catch null;
def dedupe:
  to_entries
  | map(.value + {position: .key})
  | unique_by(if .mid == null then ["position", .position] else [.mid, .rid] end);

. as $doc
| ($doc.skill_version // "" | tostring | split(".") | map(tonumber? // 0)) as $version
| ($doc | cost_merge($sample)) as $merged
| ($doc.cost_sessions) as $raw
| ((($raw | type) == "array") and all($raw[]; type == "object" and (.id | type) == "string" and (.usd == null or (.usd | type) == "number"))) as $valid
| (if $valid then $merged.cost_sessions else [] end) as $sessions
| (if ($raw | type) == "null" then
     [if $version < [7, 13, 0] then "ticket predates cost tracking" else "ticket created without cost tracking" end]
   elif ($valid | not) then ["cost_sessions is malformed"]
   elif ($sessions | length) == 0 then ["no sessions registered"]
   else [$sessions[] | if .reset == true then "cost counter went backwards for \(.id)" elif .usd == null then "no cost data for \(.id)" else empty end]
   end) as $reasons
| ($transcripts | map({key: .sid, value: .}) | from_entries) as $by_sid
| ($sessions | map(
    . as $session
    | ($by_sid[$session.id]) as $found
    | (if $found != null and $found.found == true then ($found.events | dedupe) else null end) as $events
    | {id: $session.id, usd: $session.usd, events: $events,
       tokens: (if $events == null then null else {i: ($events | total(.i)), o: ($events | total(.o)), cr: ($events | total(.cr)), cc: ($events | total(.cc))} end)}
  )) as $per
| ($per | map(select(.tokens != null) | .tokens)) as $tokens_list
| ([$per[] | select(.events != null) | .events[]] | map(. + {t: (.ts | epoch)})) as $events_all
| ($now | epoch) as $now_epoch
| ($sessions | map(.ts | epoch) | map(select(. != null)) | min) as $start
| (($doc.stages) as $stages
   | if ($sessions | length) == 0 then {value: null, reason: "no sessions registered"}
     elif ($stages | type) != "object" then {value: null, reason: "ticket has no stages object"}
     elif any($stages | to_entries[]; (.value | type) != "object") then {value: null, reason: "stage values are not objects"}
     elif ($tokens_list | length) == 0 then {value: null, reason: "no transcript found"}
     else
       ($stages | to_entries | map(select(.key | test("^[0-9]+$"))) | sort_by(.key | tonumber)) as $entries
       | ($entries | map({key: .key, has: (.key == "5" or .value.completed_at != null), t: (if .key == "5" then $now_epoch else (.value.completed_at | epoch) end)}) | map(select(.has))) as $present
       | ([$start] + ($present | map(.t))) as $chain
       | if ($chain | map(select(. == null)) | length) > 0 then {value: null, reason: "timestamps are not parseable"}
         elif $chain != ($chain | sort) then {value: null, reason: "timestamps are out of order"}
         else {value: (reduce $present[] as $bound ({lo: $start, out: {}};
                 . as $state
                 | .out[$bound.key] = ($events_all | map(select(.t != null and .t > $state.lo and .t <= $bound.t))
                     | {input_tokens: total(.i), output_tokens: total(.o), cache_read_tokens: total(.cr), cache_creation_tokens: total(.cc)})
                 | .lo = $bound.t) | .out), reason: null}
         end
     end) as $stage_result
| {
    status: (if ($reasons | length) == 0 then "known" else "unknown" end),
    total_usd: (if ($reasons | length) == 0 then ($sessions | map(.usd) | add) else null end),
    reason: (if ($reasons | length) == 0 then null else ($reasons | join("; ")) end),
    scope: $scope,
    input_tokens: (if ($tokens_list | length) == 0 then null else ($tokens_list | total(.i)) end),
    output_tokens: (if ($tokens_list | length) == 0 then null else ($tokens_list | total(.o)) end),
    cache_read_tokens: (if ($tokens_list | length) == 0 then null else ($tokens_list | total(.cr)) end),
    cache_creation_tokens: (if ($tokens_list | length) == 0 then null else ($tokens_list | total(.cc)) end),
    sessions: ($per | map({id: .id, cost_usd: .usd, input_tokens: .tokens.i, output_tokens: .tokens.o})),
    by_stage: $stage_result.value,
    by_stage_reason: $stage_result.reason,
    recorded_at: $now
  }'
# jq-compat:end

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# first_hit <program> <sid> <file>...: value from the first (newest) file that
# holds the id. Unreadable or malformed files are skipped.
first_hit() {
  local program="$1" sid="$2" file out
  shift 2
  for file in "$@"; do
    out="$(jq -c --arg id "$sid" "$program" "$file" 2>/dev/null)" || continue
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
  done
  return 0
}

# dated_files <dir>: daily-*.json newest first. The date in the name orders them.
dated_files() {
  local file
  DATED=()
  for file in "$1"/daily-*.json; do
    [ -f "$file" ] && DATED=("$file" ${DATED[@]+"${DATED[@]}"})
  done
  return 0
}

# fresh_cost <sid>: the largest usable value across the three sources, or null.
# ponytail: reads whole files per source, fine for a week of daily files.
fresh_cost() {
  local sid="$1" file cache_hit multi_hit snapshot_hit
  [ -n "$sid" ] || { echo null; return 0; }
  dated_files "$STATUSLINE_DIR"
  cache_hit="$(first_hit "$DAILY_HIT" "$sid" ${DATED[@]+"${DATED[@]}"})"
  dated_files "$MULTI_DIR"
  multi_hit="$(first_hit "$DAILY_HIT" "$sid" ${DATED[@]+"${DATED[@]}"})"
  local snapshots=() candidates=()
  # filter on the basename: a daily-* component in the directory path must not drop every snapshot
  for file in "$MULTI_DIR"/*.json; do
    [ -f "$file" ] || continue
    case "$(basename "$file")" in daily-*) continue ;; esac
    candidates+=("$file")
  done
  if [ "${#candidates[@]}" -gt 0 ]; then
    while IFS= read -r file; do
      [ -n "$file" ] && snapshots+=("$file")
    done < <(ls -t "${candidates[@]}" 2>/dev/null)
  fi
  snapshot_hit="$(first_hit "$SNAPSHOT_HIT" "$sid" ${snapshots[@]+"${snapshots[@]}"})"
  printf '%s\n' $cache_hit $multi_hit $snapshot_hit | jq -s "$BEST_VALUE" 2>/dev/null || echo null
}

cmd_sample() {
  local sid="${CLAUDE_CODE_SESSION_ID:-}" usd
  usd="$(fresh_cost "$sid")"
  jq -nc --arg id "$sid" --arg ts "$(now_iso)" --argjson usd "${usd:-null}" "$SAMPLE_OBJECT"
}

cmd_unknown() {
  jq -nc --arg reason "${1:-unknown}" --arg scope "$SCOPE_TEXT" --arg ts "$(now_iso)" "$UNKNOWN_RECORD"
}

# parse_ticket_args <ticket> [--file F]: sets TICKET and TARGET.
parse_ticket_args() {
  TICKET="$1"; shift
  local file_name="metadata.json"
  if [ "${1:-}" = "--file" ] && [ -n "${2:-}" ]; then file_name="$2"; fi
  TARGET=".doer/tickets/${TICKET}/${file_name}"
  TARGET_FILE_NAME="$file_name"
}

cmd_enter() {
  local sid="${CLAUDE_CODE_SESSION_ID:-}" state
  [ $# -ge 1 ] && [ -n "$sid" ] || return 0
  parse_ticket_args "$@"
  if [ -f "$TARGET" ]; then
    # Untracked tickets stay untracked; a registered session needs no write.
    state="$(jq -r --arg id "$sid" "$ENTER_STATE" "$TARGET" 2>/dev/null)"
    [ "$state" = "missing" ] && "$HERE/metadata.sh" write "$TICKET" . --file "$TARGET_FILE_NAME" > /dev/null 2>&1
  else
    # The ticket file does not exist yet: leave a scratch for init --track-cost.
    mkdir -p "$(dirname "$TARGET")" && cmd_sample > "$(dirname "$TARGET")/cost-entry.json"
  fi
  return 0
}

record_inner() {
  [ $# -ge 1 ] || { cmd_unknown "no ticket id given"; return 0; }
  parse_ticket_args "$@"
  [ -f "$TARGET" ] || { cmd_unknown "ticket file not found: $TARGET"; return 0; }
  local sid="${CLAUDE_CODE_SESSION_ID:-}" sample="null" merge_def id file
  [ -z "$sid" ] || sample="$(cmd_sample)"
  merge_def="$("$HERE/metadata.sh" cost-merge-def)"
  # Transcript events of every registered session, plus the closing one.
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in */*) continue ;; esac
    local found=()
    for file in "$PROJECTS_DIR"/*/"$id".jsonl "$PROJECTS_DIR"/*/"$id"/subagents/*.jsonl; do
      [ -f "$file" ] && found+=("$file")
    done
    if [ ${#found[@]} -gt 0 ]; then
      cat "${found[@]}" | jq -cRs --arg sid "$id" "$TRANSCRIPT_EVENTS"
    else
      jq -nc --arg sid "$id" "$NO_TRANSCRIPT"
    fi
  done < <({ jq -r "$SESSION_IDS" "$TARGET" 2>/dev/null; echo "$sid"; } | sort -u) > "$WORK/transcripts.json"
  jq -c --argjson sample "$sample" --arg now "$(now_iso)" --arg scope "$SCOPE_TEXT" \
    --slurpfile transcripts "$WORK/transcripts.json" "${merge_def}${RECORD_PROGRAM}" "$TARGET"
}

cmd_record() {
  local output cause
  WORK="$(mktemp -d)" || { cmd_unknown 'cost.sh record failed: mktemp'; return 0; }
  output="$(record_inner "$@" 2>"$WORK/error.txt")"
  if [ "$(printf '%s' "$output" | jq -s "$ONE_OBJECT" 2>/dev/null)" = "true" ]; then
    printf '%s\n' "$output"
  else
    cause="$(head -n 1 "$WORK/error.txt" 2>/dev/null)"
    cmd_unknown "cost.sh record failed: ${cause:-no output}"
  fi
  rm -rf "$WORK"
  return 0
}

case "${1:-}" in
  sample) cmd_sample ;;
  enter) shift; cmd_enter "$@" ;;
  record) shift; cmd_record "$@" ;;
  unknown) shift; cmd_unknown "$@" ;;
  *) echo "Usage: cost.sh sample | enter <ID> [--file F] | record <ID> [--file F] | unknown \"<reason>\"" >&2; exit 2 ;;
esac
exit 0
