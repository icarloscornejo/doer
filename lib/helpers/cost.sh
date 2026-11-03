#!/usr/bin/env bash
# wk plugin: cost per ticket helper (/wk:doer and /wk:bugfix).
# Spec: ${CLAUDE_PLUGIN_ROOT}/lib/state.md (cost_sessions, cost).
#
# The ticket cost is measured from the session transcripts the ticket worked in:
# tokens per model (deduplicated by message id across every registered session)
# priced with the table shipped in lib/cost-rates.json. This script holds no
# rates, no model names and no compaction parameter. The status line and
# multi-instance counters, when present, are only a cross-check (reported_usd),
# never the source. Data problems never make it exit non-zero.
#
#   sample                     {"id","ts","usd"} for the current session (counter cross-check)
#   enter <ID> [--file F]      register the current session for the ticket
#   record <ID> [--file F]     print the cost record (one JSON object, exit 0)
#   unknown "<reason>"         print an unknown record (fallback for prose)
#
# Sources (env overrides exist for tests):
#   COST_RATES_FILE            the rate table, default lib/cost-rates.json next to this helper
#   COST_PROJECTS_DIR          transcripts, projects/*/<session>.jsonl (+ <session>/subagents/*.jsonl)
#   COST_STATUSLINE_CACHE_DIR  daily-YYYY-MM-DD.json, {session: usd}   (cross-check only)
#   COST_MULTI_INSTANCE_DIR    <instance>.json snapshots and daily-*.json   (cross-check only)

HERE="$(cd "$(dirname "$0")" && pwd)"
SCOPE_TEXT="whole sessions; may include non-ticket work in them"
STATUSLINE_DIR="${COST_STATUSLINE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline}"
MULTI_DIR="${COST_MULTI_INSTANCE_DIR:-$HOME/Library/Application Support/ai-multi-instance}"
PROJECTS_DIR="${COST_PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"
RATES_FILE="${COST_RATES_FILE:-$HERE/../cost-rates.json}"

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
NO_TRANSCRIPT='{sid: $sid, found: false, files: []}'
TRANSCRIPT_SESSION='{sid: $sid, found: true, files: .}'
# jq-compat:end

# jq-compat:begin transcript_events
# One transcript file in, one object out: its assistant usage events (a message can
# be logged several times; the record step dedupes by message id across the ticket)
# and its compaction boundaries. A compaction records the last real assistant line
# of the SAME file and thread before it (same isSidechain value, a real model,
# non-zero usage), never a synthetic error line and never another file's line.
TRANSCRIPT_EVENTS='def amount: if type == "number" then . else 0 end;
[split("\n")[] | fromjson? | select(type == "object")
  | {type, subtype, uuid, timestamp, requestId, isSidechain, compactMetadata,
     message: (.message | if type == "object" then {id, model, usage} else null end)}] as $lines
| ($lines | to_entries) as $all
| {events: [$all[] | select(.value.type == "assistant" and (.value.message | type) == "object" and (.value.message.usage | type) == "object")
      | .value as $line | $line.message.usage as $usage
      | ($usage.cache_creation | if type == "object" then (.ephemeral_1h_input_tokens | amount) else 0 end) as $write_1h
      | ($usage.cache_creation_input_tokens | amount) as $write_total
      | {mid: $line.message.id, rid: $line.requestId, ts: $line.timestamp, model: $line.message.model,
         fast: ($usage.speed == "fast"),
         search: (($usage.server_tool_use | if type == "object" then (.web_search_requests | amount) else 0 end) > 0),
         i: ($usage.input_tokens | amount), o: ($usage.output_tokens | amount), cr: ($usage.cache_read_input_tokens | amount),
         c5: ($usage.cache_creation | if type == "object" and (.ephemeral_5m_input_tokens | type) == "number" then .ephemeral_5m_input_tokens else ([$write_total - $write_1h, 0] | max) end),
         c1: $write_1h}],
   compactions: [$all[] | select(.value.type == "system" and .value.subtype == "compact_boundary" and (.value.compactMetadata | type) == "object")
      | .key as $at | .value as $boundary
      | ([$all[] | select(.key < $at and .value.type == "assistant" and (.value.message | type) == "object" and (.value.message.usage | type) == "object"
            and ((.value.isSidechain == true) == ($boundary.isSidechain == true))
            and (.value.message.model | type == "string" and . != "<synthetic>")
            and ((.value.message.usage | [.input_tokens, .output_tokens, .cache_read_input_tokens, .cache_creation_input_tokens] | map(amount) | add) > 0))] | last) as $previous
      | {ckey: ($boundary.uuid // ("ts:" + ($boundary.timestamp | tostring) + "|" + ($boundary.compactMetadata | tojson))),
         ts: $boundary.timestamp, pre: ($boundary.compactMetadata.preTokens | amount), post: ($boundary.compactMetadata.postTokens | amount),
         model: $previous.value.message.model, prev_ts: $previous.value.timestamp}]}'
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
# A model matches its table key exactly, or the key followed by -YYYYMMDD; never by prefix.
def rate_for($table; $model):
  if ($model | type) != "string" then null else
    ([$table.models | to_entries[] | .key as $listed
      | select($listed == $model or ($model | startswith($listed + "-") and (ltrimstr($listed + "-") | test("^[0-9]{8}$"))))
      | .value] | .[0])
  end;
# Price one event; usd null means "tokens counted, not priced", with the reason in flags.
def event_cost($table):
  if (.i + .o + .cr + .c5 + .c1) == 0 then {usd: 0, flags: []} else
    rate_for($table; .model) as $base
    | if $base == null then {usd: null, flags: [(.model | if type == "string" then . else "unknown model" end)]}
      elif .fast and (($base.fast_multiplier | type) != "number") then {usd: null, flags: ["\(.model) (fast mode)"]}
      else
        (.i + .cr + .c5 + .c1) as $prompt
        | (if ($base.long_prompt | type) == "object" and $prompt > $base.long_prompt.over_tokens then $base.long_prompt else $base end) as $r
        | (if .fast then $base.fast_multiplier else 1 end) as $multiplier
        | {usd: ((.i * $r.input + .o * $r.output + .cr * $r.cache_read + .c5 * $r.cache_write_5m + .c1 * $r.cache_write_1h) * $multiplier / $table.per_tokens),
           flags: (if .search then ["\(.model) (web search fee)"] else [] end)}
      end
  end;
# A compaction request has its own system prompt, so its input is a fresh cache write
# unless the previous request of the thread was seconds ago (then a cache read); its
# output is taken as postTokens (the real output is not recorded anywhere).
def compaction_cost($table):
  if .model == null or .prev_ts == null then {usd: null, flag: "no previous request (compaction)"} else
    rate_for($table; .model) as $base
    | if $base == null then {usd: null, flag: "\(.model) (compaction)"} else
        ((.ts | epoch) as $at | (.prev_ts | epoch) as $before | if $at == null or $before == null then null else $at - $before end) as $gap
        | if $gap == null then {usd: null, flag: "\(.model) (compaction time)"} else
            (if ($base.long_prompt | type) == "object" and .pre > $base.long_prompt.over_tokens then $base.long_prompt else $base end) as $r
            | (if $gap > $table.compaction.cold_after_seconds then $r.cache_write_5m else $r.cache_read end) as $input_rate
            | {usd: ((.pre * $input_rate + .post * $r.output) / $table.per_tokens), flag: null}
          end
      end
  end;

. as $doc
| ($doc.skill_version // "" | tostring | split(".") | map(tonumber? // 0)) as $version
| ($doc | cost_merge($sample)) as $merged
| ($doc.cost_sessions) as $raw
| ((($raw | type) == "array") and all($raw[]; type == "object" and (.id | type) == "string" and (.usd == null or (.usd | type) == "number"))) as $valid
| (if $valid then $merged.cost_sessions else [] end) as $sessions
| (($rates | type) == "object" and (try (($rates.models | type) == "object" and ($rates.models | length) > 0 and ($rates.per_tokens | type) == "number" and $rates.per_tokens > 0 and ($rates.compaction.cold_after_seconds | type) == "number") catch false)) as $table_ok
| ($transcripts | map({key: .sid, value: .}) | from_entries) as $by_sid
| ($sessions | map(select((($by_sid[.id] // {found: false}).found) == true))) as $with_transcript
| (if ($raw | type) == "null" then
     [if $version < [7, 13, 0] then "ticket predates cost tracking" else "ticket created without cost tracking" end]
   elif ($valid | not) then ["cost_sessions is malformed"]
   elif ($sessions | length) == 0 then ["no sessions registered"]
   else
     [$sessions[] | select((($by_sid[.id] // {found: false}).found) != true) | "no transcript found for \(.id)"]
     + (if $table_ok then [] else ["rate table unreadable or malformed"] end)
   end) as $reasons
# Registration order (the closing session last), then file order, is the pool order; the
# same message in several files or sessions counts once, at its largest output, attributed
# to the earliest occurrence.
| ([$sessions[] | . as $session | ($by_sid[$session.id] // {found: false, files: []}) | select(.found == true) | .files[]
    | {events: (.events | map(. + {sid: $session.id})), compactions: (.compactions | map(. + {sid: $session.id}))}]) as $files
| ([$files[].events[]] | to_entries | map(.value + {pool_pos: .key})
    | group_by(if .mid == null then ["position", .pool_pos] else ["message", .mid] end)
    | map(sort_by([-(.o), .pool_pos]) | .[0])
    | sort_by(.pool_pos)) as $events
| ($events | map(. + (if $table_ok then event_cost($rates) else {usd: null, flags: []} end))) as $priced
| ([$files[].compactions[]] | to_entries | map(.value + {pool_pos: .key})
    | group_by(.ckey)
    | map(sort_by([(if .model == null then 1 else 0 end), .pool_pos]) | .[0])
    | sort_by(.pool_pos)) as $boundaries
| ($boundaries | map(. + (if $table_ok then compaction_cost($rates) else {usd: null, flag: null} end))) as $compactions
| ((($priced | map(.flags[])) + ($compactions | map(.flag // empty))) | unique) as $unpriced
| ([$compactions[] | .usd | select(. != null)] | add // 0) as $compaction_usd
| ($priced | map(select(.i + .o + .cr + .c5 + .c1 > 0))) as $real
| ($events | map(. + {t: (.ts | epoch)})) as $events_all
| ($now | epoch) as $now_epoch
| ($sessions | map(.ts | epoch) | map(select(. != null)) | min) as $start
| (($doc.stages) as $stages
   | if ($sessions | length) == 0 then {value: null, reason: "no sessions registered"}
     elif ($stages | type) != "object" then {value: null, reason: "ticket has no stages object"}
     elif any($stages | to_entries[]; (.value | type) != "object") then {value: null, reason: "stage values are not objects"}
     elif ($with_transcript | length) == 0 then {value: null, reason: "no transcript found"}
     else
       ($stages | to_entries | map(select(.key | test("^[0-9]+$"))) | sort_by(.key | tonumber)) as $entries
       | ($entries | map({key: .key, has: (.key == "5" or .value.completed_at != null), t: (if .key == "5" then $now_epoch else (.value.completed_at | epoch) end)}) | map(select(.has))) as $present
       | ([$start] + ($present | map(.t))) as $chain
       | if ($chain | map(select(. == null)) | length) > 0 then {value: null, reason: "timestamps are not parseable"}
         elif $chain != ($chain | sort) then {value: null, reason: "timestamps are out of order"}
         else {value: (reduce $present[] as $bound ({lo: $start, out: {}};
                 . as $state
                 | .out[$bound.key] = ($events_all | map(select(.t != null and .t > $state.lo and .t <= $bound.t))
                     | {input_tokens: total(.i), output_tokens: total(.o), cache_read_tokens: total(.cr), cache_creation_tokens: (total(.c5) + total(.c1))})
                 | .lo = $bound.t) | .out), reason: null}
         end
     end) as $stage_result
| {
    status: (if ($reasons | length) > 0 then "unknown" elif ($unpriced | length) > 0 then "partial" else "known" end),
    total_usd: (if ($reasons | length) > 0 then null else (([$priced[] | .usd | select(. != null)] | add // 0) + $compaction_usd) end),
    reason: (if ($reasons | length) > 0 then ($reasons | join("; ")) elif ($unpriced | length) > 0 then "not priced: \($unpriced | join(", "))" else null end),
    scope: $scope,
    input_tokens: (if ($with_transcript | length) == 0 then null else ($events | total(.i)) end),
    output_tokens: (if ($with_transcript | length) == 0 then null else ($events | total(.o)) end),
    cache_read_tokens: (if ($with_transcript | length) == 0 then null else ($events | total(.cr)) end),
    cache_creation_tokens: (if ($with_transcript | length) == 0 then null else ($events | total(.c5) + total(.c1)) end),
    sessions: ($sessions | map(. as $session
      | (($by_sid[$session.id] // {found: false}).found == true) as $found
      | ($priced | map(select(.sid == $session.id))) as $mine
      | {id: $session.id,
         cost_usd: (if $found and $table_ok then (([$mine[] | .usd | select(. != null)] | add // 0) + ([$compactions[] | select(.sid == $session.id) | .usd | select(. != null)] | add // 0)) else null end),
         input_tokens: (if $found then ($mine | total(.i)) else null end),
         output_tokens: (if $found then ($mine | total(.o)) else null end)})),
    by_stage: $stage_result.value,
    by_stage_reason: $stage_result.reason,
    by_model: ($real | group_by(.model // "unknown model")
      | map({key: (.[0].model // "unknown model"),
             value: {input_tokens: total(.i), output_tokens: total(.o), cache_read_tokens: total(.cr), cache_creation_tokens: (total(.c5) + total(.c1)),
                     usd: ([.[] | .usd | select(. != null)] | if length == 0 then null else add end)}})
      | from_entries),
    unpriced_models: $unpriced,
    compactions: {count: ($compactions | length), estimated_usd: $compaction_usd},
    rates: (if $table_ok then {taken_on: $rates.taken_on, source: $rates.source} else null end),
    reported_usd: (if $valid and ($sessions | length) > 0 and all($sessions[]; .reset != true and (.usd | type) == "number") then ($sessions | map(.usd) | add) else null end),
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

# fresh_cost <sid>: the largest usable counter value across the three sources, or null.
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
  local sid="${CLAUDE_CODE_SESSION_ID:-}" sample="null" merge_def id file rates_json found
  [ -z "$sid" ] || sample="$(cmd_sample)"
  merge_def="$("$HERE/metadata.sh" cost-merge-def)"
  # An unreadable rate table is passed as null: the program then answers unknown with that reason.
  rates_json="$(jq -c . "$RATES_FILE" 2>/dev/null)" || rates_json=""
  [ -n "$rates_json" ] || rates_json="null"
  # Transcripts of every registered session in registration order (the closing session last),
  # each file parsed on its own so a compaction never pairs with another file's lines.
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in */*) continue ;; esac
    : > "$WORK/files.jsonl"
    found=0
    for file in "$PROJECTS_DIR"/*/"$id".jsonl "$PROJECTS_DIR"/*/"$id"/subagents/*.jsonl; do
      [ -f "$file" ] || continue
      found=1
      jq -cRs "$TRANSCRIPT_EVENTS" "$file" >> "$WORK/files.jsonl" 2>/dev/null || true
    done
    if [ "$found" -eq 1 ]; then
      jq -cs --arg sid "$id" "$TRANSCRIPT_SESSION" "$WORK/files.jsonl"
    else
      jq -nc --arg sid "$id" "$NO_TRANSCRIPT"
    fi
  done < <({ jq -r "$SESSION_IDS" "$TARGET" 2>/dev/null; echo "$sid"; } | awk 'NF && !seen[$0]++') > "$WORK/transcripts.json"
  jq -c --argjson sample "$sample" --arg now "$(now_iso)" --arg scope "$SCOPE_TEXT" \
    --argjson rates "$rates_json" \
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
