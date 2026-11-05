# =====================================================================
# DOER-3: cost per ticket (lib/helpers/cost.sh + metadata.sh integration)
# =====================================================================
# Fixtures are fake directories reached through COST_STATUSLINE_CACHE_DIR,
# COST_MULTI_INSTANCE_DIR and COST_PROJECTS_DIR. Every case sets or unsets
# CLAUDE_CODE_SESSION_ID explicitly. Nothing here aborts the suite: a missing
# cost.sh just makes the assertions fail.
COST_SH="${REPO_ROOT}/lib/helpers/cost.sh"
COST_CASE_N=0
COST_SCOPE_TEXT="whole sessions; may include non-ticket work in them"

# DOER-6: the fixture rate table (round numbers, USD per million tokens) reached
# through COST_RATES_FILE. cold_after_seconds is 120 on purpose: a hard-coded 300
# in the helper would fail the compaction cases.
COST_RATES_JSON='{"taken_on":"2026-11-03","source":"https://example.test/pricing","unit":"USD per million tokens","per_tokens":1000000,"compaction":{"cold_after_seconds":120},"models":{"m-a":{"input":10,"output":20,"cache_read":1,"cache_write_5m":12.5,"cache_write_1h":20},"m-b":{"input":1,"output":2,"cache_read":0.1,"cache_write_5m":1.25,"cache_write_1h":2},"m-long":{"input":1,"output":2,"cache_read":0.1,"cache_write_5m":1.25,"cache_write_1h":2,"long_prompt":{"over_tokens":100,"input":5,"output":10,"cache_read":0.5,"cache_write_5m":6.25,"cache_write_1h":10}},"m-fast":{"input":4,"output":20,"cache_read":0.2,"cache_write_5m":5,"cache_write_1h":8,"fast_multiplier":2}}}'

cost_case() { # fresh fake dirs plus an empty repo dir, cd'ed into
  COST_CASE_N=$((COST_CASE_N + 1))
  COST_ROOT="$TMPDIR_TEST/costcase-$COST_CASE_N"
  mkdir -p "$COST_ROOT/cache" "$COST_ROOT/mi" "$COST_ROOT/projects" "$COST_ROOT/repo"
  export COST_STATUSLINE_CACHE_DIR="$COST_ROOT/cache"
  export COST_MULTI_INSTANCE_DIR="$COST_ROOT/mi"
  export COST_PROJECTS_DIR="$COST_ROOT/projects"
  printf '%s\n' "$COST_RATES_JSON" > "$COST_ROOT/rates.json"
  export COST_RATES_FILE="$COST_ROOT/rates.json"
  cd "$COST_ROOT/repo" || exit 1
}
cost_run() { "$COST_SH" "$@" 2>/dev/null; }
cost_snapshot() { # <instance> <sid> <usd-json>
  printf '{"sessionId":"%s","sessionCostUsd":%s}\n' "$2" "$3" > "$COST_MULTI_INSTANCE_DIR/$1.json"
}
cost_daily() { # <dir> <yyyy-mm-dd> <json>
  printf '%s\n' "$3" > "$1/daily-$2.json"
}
sample_usd() { # <sid>
  CLAUDE_CODE_SESSION_ID="$1" cost_run sample | jq -c '.usd' 2>/dev/null
}
new_doc() { # <ticket> <json> [init-args...]
  local ticket="$1" json="$2"; shift 2
  printf '%s' "$json" | "$METADATA_SH" init "$ticket" "$@" > /dev/null 2>&1
}
cs_state() { # <ticket> [file]: cost_sessions without ts, keys sorted
  jq -cS '[.cost_sessions[]? | del(.ts)]' ".doer/tickets/$1/${2:-metadata.json}" 2>/dev/null
}
ticket_jq() { # <ticket> <jq-expr> [file]
  jq -c "$2" ".doer/tickets/$1/${3:-metadata.json}" 2>/dev/null
}
tx_line() { # <ts> <message-id> <request-id> <in> <out> <cache-read> <cache-creation> [model, default m-a]
  jq -nc --arg ts "$1" --arg mid "$2" --arg rid "$3" --argjson i "$4" --argjson o "$5" --argjson cr "$6" --argjson cc "$7" --arg model "${8:-m-a}" \
    '{type:"assistant",timestamp:$ts,requestId:$rid,message:{id:$mid,model:$model,usage:{input_tokens:$i,output_tokens:$o,cache_read_input_tokens:$cr,cache_creation_input_tokens:$cc}}}'
}
tx_split() { # <ts> <message-id> <request-id> <in> <out> <cache-read> <cache-5m> <cache-1h> [model, default m-a]
  jq -nc --arg ts "$1" --arg mid "$2" --arg rid "$3" --argjson i "$4" --argjson o "$5" --argjson cr "$6" --argjson c5 "$7" --argjson c1 "$8" --arg model "${9:-m-a}" \
    '{type:"assistant",timestamp:$ts,requestId:$rid,message:{id:$mid,model:$model,usage:{input_tokens:$i,output_tokens:$o,cache_read_input_tokens:$cr,cache_creation_input_tokens:($c5 + $c1),cache_creation:{ephemeral_5m_input_tokens:$c5,ephemeral_1h_input_tokens:$c1}}}}'
}
tx_boundary() { # <ts> <uuid> <pre-tokens> <post-tokens>: a compaction boundary line
  jq -nc --arg ts "$1" --arg u "$2" --argjson pre "$3" --argjson post "$4" \
    '{type:"system",subtype:"compact_boundary",uuid:$u,timestamp:$ts,isSidechain:false,compactMetadata:{trigger:"manual",preTokens:$pre,postTokens:$post}}'
}
tx_synthetic() { # <ts>: a zero-usage assistant line, as written for API errors
  jq -nc --arg ts "$1" '{type:"assistant",timestamp:$ts,message:{id:null,model:"<synthetic>",usage:{input_tokens:0,output_tokens:0,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}'
}
# usd_close <actual-json> <expected>: true when the two differ by less than 1e-9
# (float sums are compared with a tolerance so summation order cannot matter).
usd_close() {
  jq -n --argjson a "${1:-null}" --argjson e "$2" '$a != null and (($a - $e) | fabs) < 0.000000001' 2>/dev/null
}
rec_field() { printf '%s' "$REC" | jq -c "$1" 2>/dev/null; }
tx_put() { # <path relative to the projects dir>, lines on stdin
  mkdir -p "$(dirname "$COST_PROJECTS_DIR/$1")"
  cat >> "$COST_PROJECTS_DIR/$1"
}
is_one_object() { # <text>: exactly one JSON value and it is an object
  [ "$(printf '%s' "$1" | jq -s 'length == 1 and (.[0] | type == "object")' 2>/dev/null)" = "true" ]
}
touch_at() { touch -t "$1" "$2"; }

bash -n "$COST_SH" 2>/dev/null && pass "cost.sh exists and parses" || fail "cost.sh exists and parses"

# --- lookup (sample): newest file per source, positives, snapshot 0, null, dotfiles, malformed ---
cost_case
cost_daily "$COST_STATUSLINE_CACHE_DIR" 2026-01-02 '{"s1":3.5}'
assert_eq "cost lookup: a status line cache value is used" "3.5" "$(sample_usd s1)"
assert_eq "cost lookup: an id nobody holds is no data" "null" "$(sample_usd nobody)"
SAMPLE_JSON="$(CLAUDE_CODE_SESSION_ID=s1 cost_run sample)"
assert_eq "cost sample: prints id, a UTC ISO8601 ts and usd" "true" \
  "$(printf '%s' "$SAMPLE_JSON" | jq '.id == "s1" and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and .usd == 3.5' 2>/dev/null)"
CLAUDE_CODE_SESSION_ID="" cost_run sample > "$COST_ROOT/empty-sample.json"
assert_eq "cost sample: an empty session id env gives usd null, still one object" "true" \
  "$(jq -s 'length == 1 and .[0].usd == null' "$COST_ROOT/empty-sample.json" 2>/dev/null)"
(unset CLAUDE_CODE_SESSION_ID; "$COST_SH" sample > "$COST_ROOT/unset-sample.json" 2>/dev/null; echo "$?" > "$COST_ROOT/unset-exit")
assert_eq "cost sample: an unset session id env exits 0" "0" "$(cat "$COST_ROOT/unset-exit")"
assert_eq "cost sample: an unset session id env gives usd null" "true" \
  "$(jq -s 'length == 1 and .[0].usd == null' "$COST_ROOT/unset-sample.json" 2>/dev/null)"

cost_case
cost_daily "$COST_STATUSLINE_CACHE_DIR" 2026-01-02 '{"s1":0}'
assert_eq "cost lookup: a daily file 0 alone is not trusted (no data)" "null" "$(sample_usd s1)"
cost_snapshot inst s1 6
assert_eq "cost lookup: daily 0 plus a positive snapshot picks the positive" "6" "$(sample_usd s1)"

cost_case
cost_snapshot inst s1 0
assert_eq "cost lookup: a snapshot 0 alone is 0 (fresh session)" "0" "$(sample_usd s1)"
cost_snapshot inst s1 null
assert_eq "cost lookup: a snapshot null is no data" "null" "$(sample_usd s1)"

cost_case
cost_daily "$COST_STATUSLINE_CACHE_DIR" 2026-01-02 '{"s1":2}'
cost_snapshot inst s1 7
cost_daily "$COST_MULTI_INSTANCE_DIR" 2026-01-02 '{"s1":4}'
assert_eq "cost lookup: the fresh cost is the max across the three sources" "7" "$(sample_usd s1)"
rm -f "$COST_MULTI_INSTANCE_DIR/inst.json" "$COST_STATUSLINE_CACHE_DIR/daily-2026-01-02.json"
assert_eq "cost lookup: the multi-instance daily file alone is a source" "4" "$(sample_usd s1)"

cost_case
cost_daily "$COST_STATUSLINE_CACHE_DIR" 2026-01-01 '{"s1":9}'
cost_daily "$COST_STATUSLINE_CACHE_DIR" 2026-01-02 '{"s1":1}'
touch_at 202601010000 "$COST_STATUSLINE_CACHE_DIR/daily-2026-01-01.json"
touch_at 202601020000 "$COST_STATUSLINE_CACHE_DIR/daily-2026-01-02.json"
cost_snapshot inst s1 1
assert_eq "cost lookup: only the newest daily file per source counts (stale 9, fresh 1)" "1" "$(sample_usd s1)"
cost_case
cost_snapshot inst-a s1 9
cost_snapshot inst-b s1 4
touch_at 202601010000 "$COST_MULTI_INSTANCE_DIR/inst-a.json"
touch_at 202601020000 "$COST_MULTI_INSTANCE_DIR/inst-b.json"
assert_eq "cost lookup: only the newest snapshot holding the id counts" "4" "$(sample_usd s1)"
cost_case
mkdir -p "$COST_ROOT/daily-x/mi"
COST_MULTI_INSTANCE_DIR="$COST_ROOT/daily-x/mi"
cost_snapshot inst s1 7
assert_eq "cost lookup: a daily-x directory component does not hide snapshots" "7" "$(sample_usd s1)"
cost_case
cost_daily "$COST_MULTI_INSTANCE_DIR" 2026-01-01 '{"s1":9}'
cost_daily "$COST_MULTI_INSTANCE_DIR" 2026-01-02 '{"s1":2}'
touch_at 202601010000 "$COST_MULTI_INSTANCE_DIR/daily-2026-01-01.json"
touch_at 202601020000 "$COST_MULTI_INSTANCE_DIR/daily-2026-01-02.json"
assert_eq "cost lookup: only the newest multi-instance daily file counts" "2" "$(sample_usd s1)"

cost_case
printf '{"sessionId":"s1","sessionCostUsd":50}\n' > "$COST_MULTI_INSTANCE_DIR/.hidden.json"
printf '{"s1":60}\n' > "$COST_STATUSLINE_CACHE_DIR/.daily-2026-01-03.json"
assert_eq "cost lookup: dotfiles are ignored" "null" "$(sample_usd s1)"
cost_case
cost_daily "$COST_STATUSLINE_CACHE_DIR" 2026-01-02 '{"s1":3}'
printf '{{{ not json' > "$COST_STATUSLINE_CACHE_DIR/daily-2026-01-09.json"
printf 'garbage' > "$COST_MULTI_INSTANCE_DIR/bad.json"
touch_at 202601010000 "$COST_STATUSLINE_CACHE_DIR/daily-2026-01-02.json"
touch_at 202601090000 "$COST_STATUSLINE_CACHE_DIR/daily-2026-01-09.json"
assert_eq "cost lookup: malformed files are ignored, a valid older file still counts" "3" "$(sample_usd s1)"
CLAUDE_CODE_SESSION_ID=s1 COST_STATUSLINE_CACHE_DIR="$COST_ROOT/none" COST_MULTI_INSTANCE_DIR="$COST_ROOT/none" cost_run sample > /dev/null
assert_eq "cost sample: nonexistent source dirs exit 0" "0" "$?"

# --- sampling inside metadata.sh write ---
cost_case
export CLAUDE_CODE_SESSION_ID=sess-A
cost_snapshot inst sess-A 5
new_doc W-1 '{"a":1,"cost_sessions":[]}'
"$METADATA_SH" write W-1 '.a = 2' > /dev/null 2>&1
assert_eq "cost write: exit 0 when sampling" "0" "$?"
assert_eq "cost write: an unseen session id is added with its cost" '[{"id":"sess-A","usd":5}]' "$(cs_state W-1)"
assert_eq "cost write: the added entry carries a ts string and the caller's change landed" '["string",2]' \
  "$(ticket_jq W-1 '[(.cost_sessions[0].ts | type), .a]')"
cost_snapshot inst sess-A 8
"$METADATA_SH" write W-1 '.a = 3' > /dev/null 2>&1
assert_eq "cost write: a higher cost advances the saved value" '[{"id":"sess-A","usd":8}]' "$(cs_state W-1)"
cost_snapshot inst sess-A null
"$METADATA_SH" write W-1 '.a = 4' > /dev/null 2>&1
assert_eq "cost write: a null sample never erases the saved value" '[{"id":"sess-A","usd":8}]' "$(cs_state W-1)"
cost_snapshot inst sess-A 3
"$METADATA_SH" write W-1 '.a = 5' > /dev/null 2>&1
assert_eq "cost write: a lower cost sets reset and keeps the saved value" '[{"id":"sess-A","reset":true,"usd":8}]' "$(cs_state W-1)"
new_doc W-2 '{"cost_sessions":[{"id":"sess-A","ts":"t","usd":3}]}'
"$METADATA_SH" write W-2 '.a = 1' > /dev/null 2>&1
assert_eq "cost write: an equal cost is not a reset" '[{"id":"sess-A","usd":3}]' "$(cs_state W-2)"

cost_case
cost_daily "$COST_STATUSLINE_CACHE_DIR" 2026-01-01 '{"sess-A":9}'
cost_daily "$COST_STATUSLINE_CACHE_DIR" 2026-01-02 '{"sess-A":1}'
touch_at 202601010000 "$COST_STATUSLINE_CACHE_DIR/daily-2026-01-01.json"
touch_at 202601020000 "$COST_STATUSLINE_CACHE_DIR/daily-2026-01-02.json"
cost_snapshot inst sess-A 1
new_doc W-3 '{"cost_sessions":[{"id":"sess-A","ts":"t","usd":9}]}'
"$METADATA_SH" write W-3 '.a = 1' > /dev/null 2>&1
assert_eq "cost write: a stale 9 saved then a fresh 1 is a reset that keeps 9" '[{"id":"sess-A","reset":true,"usd":9}]' "$(cs_state W-3)"

new_doc W-4 '{"a":1}'
jq '.a = 2' .doer/tickets/W-4/metadata.json > "$COST_ROOT/w4-expected.json"
"$METADATA_SH" write W-4 '.a = 2' > /dev/null 2>&1
assert_eq "cost write: a document without cost_sessions is byte-identical to a plain jq transform" "" \
  "$(cmp "$COST_ROOT/w4-expected.json" .doer/tickets/W-4/metadata.json 2>&1)"

# failing / garbage / missing cost.sh, via a copy of metadata.sh with a stub sibling
make_stub_meta() { # <name> <cost.sh body, or NONE> -> prints the metadata.sh copy path
  local dir="$TMPDIR_TEST/stub-$1/lib/helpers"
  mkdir -p "$dir"
  cp "$METADATA_SH" "$dir/metadata.sh"
  if [ "$2" != "NONE" ]; then
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$dir/cost.sh"
    chmod +x "$dir/cost.sh"
  fi
  printf '%s' "$dir/metadata.sh"
}
STUB_N=0
for stub_body in 'exit 1' 'echo garbage; exit 0' 'echo "{\"id\":5,\"ts\":\"t\",\"usd\":\"x\"}"; exit 0' 'echo "{\"id\":\"\",\"ts\":\"t\",\"usd\":1}"; exit 0' 'exit 0' NONE; do
  STUB_N=$((STUB_N + 1))
  STUB_META="$(make_stub_meta "$STUB_N" "$stub_body")"
  new_doc "S-$STUB_N" '{"a":1,"cost_sessions":[{"id":"x","ts":"t","usd":1}]}'
  "$STUB_META" write "S-$STUB_N" '.a = 2' > /dev/null 2>&1
  assert_eq "cost write: stub '$stub_body' exits 0" "0" "$?"
  assert_eq "cost write: stub '$stub_body' leaves the caller's result intact" '[2,[{"id":"x","ts":"t","usd":1}]]' \
    "$(ticket_jq "S-$STUB_N" '[.a, .cost_sessions]')"
done

new_doc W-5 '{"a":1,"cost_sessions":[null,{"id":"x","usd":"a"}]}'
"$METADATA_SH" write W-5 '.a = 2' > /dev/null 2>&1
assert_eq "cost write: malformed cost_sessions entries never fail the write" "0" "$?"
assert_eq "cost write: malformed cost_sessions leave the caller's result untouched" '[2,[null,{"id":"x","usd":"a"}]]' \
  "$(ticket_jq W-5 '[.a, .cost_sessions]')"

STAGE5_CLOSE_DOC='{"summary":"s","commit_message":"c","pr_description":"p","cost":{"status":"unknown"},"stages":{"5":{"status":"in_progress"}},"cost_sessions":[null,{"id":"x","usd":"a"}]}'
new_doc W-6 "$STAGE5_CLOSE_DOC"
"$METADATA_SH" write W-6 '.stages["5"].status = "complete" | .stages["5"].completed_at = "t"' --require 5:complete > /dev/null 2>&1
assert_eq "cost write: a Stage 5 close with --require and malformed cost_sessions still succeeds" "0" "$?"
STUB_META="$(make_stub_meta close 'exit 1')"
new_doc W-7 "$STAGE5_CLOSE_DOC"
"$STUB_META" write W-7 '.stages["5"].status = "complete" | .stages["5"].completed_at = "t"' --require 5:complete > /dev/null 2>&1
assert_eq "cost write: a Stage 5 close with --require and a failing cost.sh still succeeds" "0" "$?"

new_doc W-8 '{"a":1,"cost_sessions":[]}'
cost_snapshot inst sess-A 5
"$METADATA_SH" write W-8 '.a = 2 # trailing note' > /dev/null 2>&1
assert_eq "cost write: a caller filter ending in a # comment succeeds" "0" "$?"
assert_eq "cost write: a caller filter ending in a # comment still gets the sample and its change" '[2,[{"id":"sess-A","usd":5}]]' \
  "$([ -f .doer/tickets/W-8/metadata.json ] && jq -c --argjson cs "$(cs_state W-8)" '[.a, $cs]' .doer/tickets/W-8/metadata.json)"

MV_BIN="$TMPDIR_TEST/mvbin"; mkdir -p "$MV_BIN"
printf '#!/usr/bin/env bash\necho mv >> "$MV_LOG"\nexec /bin/mv "$@"\n' > "$MV_BIN/mv"
chmod +x "$MV_BIN/mv"
export MV_LOG="$COST_ROOT/mv.log"
: > "$MV_LOG"
new_doc W-9 '{"a":1,"cost_sessions":[]}'
PATH="$MV_BIN:$PATH" "$METADATA_SH" write W-9 '.a = 2' > /dev/null 2>&1
assert_eq "cost write: one write with sampling is exactly one file replacement" "1" "$(wc -l < "$MV_LOG" | tr -d ' ')"

# --- entry and init --track-cost ---
cost_case
export CLAUDE_CODE_SESSION_ID=sess-A
cost_snapshot inst sess-A 5
printf '{"ticket_id":"I-1"}' | "$METADATA_SH" init I-1 --track-cost > /dev/null 2>&1
assert_eq "cost init --track-cost: exit 0 and stores the current session with its cost" '[{"id":"sess-A","usd":5}]' "$(cs_state I-1)"
printf '{"ticket_id":"I-0"}' | "$METADATA_SH" init I-0 > /dev/null 2>&1
assert_eq "cost init: a plain init has no cost_sessions" "null" "$(ticket_jq I-0 '.cost_sessions')"
assert_eq "cost init: a plain init output is the input document unchanged" '{"ticket_id":"I-0"}' "$(ticket_jq I-0 '.')"
printf '{"ticket_id":"I-1b"}' | "$METADATA_SH" init I-1b --file bugfix.json --track-cost > /dev/null 2>&1
assert_eq "cost init --track-cost: works together with --file bugfix.json" '[{"id":"sess-A","usd":5}]' "$(cs_state I-1b bugfix.json)"

mkdir -p .doer/tickets/I-2
printf '{"id":"sess-A","ts":"2020-01-01T00:00:00Z","usd":2}\n' > .doer/tickets/I-2/cost-entry.json
printf '{"ticket_id":"I-2"}' | "$METADATA_SH" init I-2 --track-cost > /dev/null 2>&1
assert_eq "cost init --track-cost: a same-id cost-entry.json is used (its earlier ts wins), one entry" '[1,"2020-01-01T00:00:00Z"]' \
  "$(ticket_jq I-2 '[(.cost_sessions | length), .cost_sessions[0].ts]')"
assert_eq "cost init --track-cost: the same-id scratch is deleted" "no" "$([ -e .doer/tickets/I-2/cost-entry.json ] && echo yes || echo no)"
mkdir -p .doer/tickets/I-3
printf '{"id":"other-session","ts":"2020-01-01T00:00:00Z","usd":99}\n' > .doer/tickets/I-3/cost-entry.json
printf '{"ticket_id":"I-3"}' | "$METADATA_SH" init I-3 --track-cost > /dev/null 2>&1
assert_eq "cost init --track-cost: a foreign-id cost-entry.json is ignored" '[{"id":"sess-A","usd":5}]' "$(cs_state I-3)"
assert_eq "cost init --track-cost: the foreign scratch is deleted too" "no" "$([ -e .doer/tickets/I-3/cost-entry.json ] && echo yes || echo no)"

new_doc E-1 '{"cost_sessions":[{"id":"other","ts":"t","usd":1}]}'
export MV_LOG="$COST_ROOT/mv-enter.log"; : > "$MV_LOG"
PATH="$MV_BIN:$PATH" cost_run enter E-1 > /dev/null
assert_eq "cost enter: exit 0 for an existing ticket" "0" "$?"
assert_eq "cost enter: an unregistered session is registered" '["other","sess-A"]' "$(ticket_jq E-1 '[.cost_sessions[].id]')"
assert_eq "cost enter: registering takes exactly one file replacement" "1" "$(wc -l < "$MV_LOG" | tr -d ' ')"
BEFORE_ENTER="$(cat .doer/tickets/E-1/metadata.json)"
: > "$MV_LOG"
PATH="$MV_BIN:$PATH" cost_run enter E-1 > /dev/null
assert_eq "cost enter: an already registered session causes no write at all" "0" "$(wc -l < "$MV_LOG" | tr -d ' ')"
assert_eq "cost enter: an already registered session leaves the file byte-identical" "$BEFORE_ENTER" "$(cat .doer/tickets/E-1/metadata.json)"
new_doc E-2 '{"cost_sessions":[]}' --file bugfix.json
cost_run enter E-2 --file bugfix.json > /dev/null
assert_eq "cost enter: --file bugfix.json registers into that file" '["sess-A"]' "$(ticket_jq E-2 '[.cost_sessions[].id]' bugfix.json)"
cost_run enter NEW-1 > /dev/null
assert_eq "cost enter: a ticket not created yet gets a cost-entry.json scratch with the session" "sess-A" \
  "$(jq -r '.id' .doer/tickets/NEW-1/cost-entry.json 2>/dev/null)"
mkdir -p .doer/tickets/NEW-2
printf '{"id":"older","ts":"2020-01-01T00:00:00Z","usd":1}\n' > .doer/tickets/NEW-2/cost-entry.json
cost_run enter NEW-2 > /dev/null
assert_eq "cost enter: an older scratch is overwritten" "sess-A" "$(jq -r '.id' .doer/tickets/NEW-2/cost-entry.json 2>/dev/null)"

# --- record: summing across sources, closing session, unknown variants ---
cost_case
cost_daily "$COST_STATUSLINE_CACHE_DIR" 2026-01-02 '{"s1":1.5}'
cost_snapshot inst-b s2 4.25
cost_daily "$COST_MULTI_INSTANCE_DIR" 2026-01-02 '{"s3":2}'
new_doc R-1 '{"skill_version":"7.13.0","cost_sessions":[]}'
export CLAUDE_CODE_SESSION_ID=s1; "$METADATA_SH" write R-1 '.n = 1' > /dev/null 2>&1
export CLAUDE_CODE_SESSION_ID=s2; "$METADATA_SH" write R-1 '.n = 2' > /dev/null 2>&1
export CLAUDE_CODE_SESSION_ID=s3
# DOER-6: the total comes from the transcripts (m-b: input 1, output 2, cache read 0.1 per million);
# the counters above only feed the optional reported_usd cross-check.
tx_line 2026-01-02T00:00:00Z a1 r1 1000000 0 0 0 m-b | tx_put proj/s1.jsonl
tx_line 2026-01-02T00:00:00Z a2 r2 0 1000000 0 0 m-b | tx_put proj/s2.jsonl
tx_line 2026-01-02T00:00:00Z a3 r3 0 0 1000000 0 m-b | tx_put proj/s3.jsonl
REC="$(cost_run record R-1)"; REC_EXIT=$?
assert_eq "cost record: exit 0" "0" "$REC_EXIT"
is_one_object "$REC" && pass "cost record: prints exactly one JSON object" || fail "cost record: prints exactly one JSON object" "got: $REC"
assert_eq "cost record: three sessions priced from their transcripts give the exact sum" '["known",true]' \
  "$(printf '%s' "$REC" | jq -c '[.status, ((.total_usd - 3.1) | fabs) < 0.000000001]' 2>/dev/null)"
assert_eq "cost record: every session id is listed with its computed cost (micro-dollars)" '[["s1",1000000],["s2",2000000],["s3",100000]]' \
  "$(printf '%s' "$REC" | jq -c '[.sessions[] | [.id, (.cost_usd * 1000000 | round)]]' 2>/dev/null)"
assert_eq "cost record: the counters of the three sources are only the cross-check (reported_usd 7.75)" "7.75" "$(rec_field '.reported_usd')"
assert_eq "cost record: scope states whole sessions" "$COST_SCOPE_TEXT" "$(printf '%s' "$REC" | jq -r '.scope' 2>/dev/null)"
assert_eq "cost record: recorded_at is a UTC ISO8601 string" "true" \
  "$(printf '%s' "$REC" | jq '.recorded_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' 2>/dev/null)"
printf '%s' "$REC" > "$COST_ROOT/rec.json"
"$METADATA_SH" write R-1 '.cost = $cost[0]' --slurpfile cost "$COST_ROOT/rec.json" > /dev/null 2>&1
assert_eq "cost record: the closing write stores the record byte for byte" "$(jq -cS . "$COST_ROOT/rec.json")" "$(ticket_jq R-1 '.cost' | jq -cS . 2>/dev/null)"
assert_eq "cost record: the persisted sessions equal what the closing write folded in" '[["s1",1.5],["s2",4.25],["s3",2]]' \
  "$(ticket_jq R-1 '[.cost_sessions[] | [.id, .usd]]')"

cost_case
export CLAUDE_CODE_SESSION_ID=sess-A
cost_snapshot inst sess-A 12
new_doc R-2 '{"skill_version":"7.13.0","cost_sessions":[{"id":"sess-A","ts":"2026-01-01T00:00:00Z","usd":5}]}'
tx_line 2026-01-02T00:00:00Z a1 r1 4000000 0 0 0 m-b | tx_put proj/sess-A.jsonl
REC="$(cost_run record R-2)"
assert_eq "cost record: the closing session transcript is priced (4 million input tokens at 1 per million is 4)" '["known",true]' \
  "$(printf '%s' "$REC" | jq -c '[.status, ((.total_usd - 4) | fabs) < 0.000000001]' 2>/dev/null)"
assert_eq "cost record: the closing counter sample (snapshot 12) is only the cross-check" "12" "$(rec_field '.reported_usd')"
unset CLAUDE_CODE_SESSION_ID
new_doc R-2b '{"skill_version":"7.13.0","cost_sessions":[{"id":"only","ts":"2026-01-01T00:00:00Z","usd":3}]}'
tx_line 2026-01-02T00:00:00Z a1 r1 3000000 0 0 0 m-b | tx_put proj/only.jsonl
assert_eq "cost record: with no closing session id the saved sessions still sum from their transcripts" '["known",true]' \
  "$(cost_run record R-2b | jq -c '[.status, ((.total_usd - 3) | fabs) < 0.000000001]' 2>/dev/null)"

# unknown variants: every one is one valid object, exit 0, null total, a reason
unknown_case() { # <desc> <reason-fragment-or-empty> <ticket> [record-args...]
  local desc="$1" fragment="$2" ticket="$3"; shift 3
  REC="$(cost_run record "$ticket" "$@")"; REC_EXIT=$?
  assert_eq "cost record unknown ($desc): exit 0" "0" "$REC_EXIT"
  is_one_object "$REC" && pass "cost record unknown ($desc): one valid JSON object" || fail "cost record unknown ($desc): one valid JSON object" "got: $REC"
  assert_eq "cost record unknown ($desc): status unknown with a null total" '["unknown",null]' "$(printf '%s' "$REC" | jq -c '[.status, .total_usd]' 2>/dev/null)"
  assert_eq "cost record unknown ($desc): scope text present" "$COST_SCOPE_TEXT" "$(printf '%s' "$REC" | jq -r '.scope' 2>/dev/null)"
  if [ -n "$fragment" ]; then
    assert_eq "cost record unknown ($desc): reason mentions '$fragment'" "true" \
      "$(printf '%s' "$REC" | jq --arg f "$fragment" '(.reason | type == "string") and (.reason | contains($f))' 2>/dev/null)"
  fi
}
cost_case
export CLAUDE_CODE_SESSION_ID=sess-A
new_doc U-1 '{"skill_version":"7.13.0","cost_sessions":[{"id":"sess-A","ts":"t","usd":null}]}'
unknown_case "closing session without a transcript" "no transcript found for sess-A" U-1
new_doc U-2 '{"skill_version":"7.13.0","cost_sessions":[{"id":"gone-1","ts":"t","usd":null},{"id":"sess-A","ts":"t","usd":4}]}'
unknown_case "another session without a transcript" "no transcript found for gone-1" U-2
COST_STATUSLINE_CACHE_DIR="$COST_ROOT/none" COST_MULTI_INSTANCE_DIR="$COST_ROOT/none" COST_PROJECTS_DIR="$COST_ROOT/none" \
  unknown_case "no source dirs exist" "no transcript found for" U-1
printf 'garbage' > "$COST_MULTI_INSTANCE_DIR/bad.json"; printf '{{' > "$COST_STATUSLINE_CACHE_DIR/daily-2026-01-02.json"
unknown_case "only malformed counter files" "no transcript found for sess-A" U-1
cost_case
export CLAUDE_CODE_SESSION_ID=sess-A
new_doc U-5 '{"skill_version":"7.13.0","cost_sessions":[{"id":"sess-A","ts":"t","usd":null}]}'
unknown_case "empty projects dir" "no transcript found for sess-A" U-5
new_doc U-6 '{"skill_version":"7.9.0"}'
unknown_case "older ticket without cost_sessions" "predates cost tracking" U-6
new_doc U-7 '{"skill_version":"7.13.0"}'
unknown_case "newer ticket without cost_sessions" "created without cost tracking" U-7
new_doc U-8 '{"skill_version":"7.10.0"}'
unknown_case "7.10.0 is older than 7.13.0 numerically" "predates cost tracking" U-8
new_doc U-9 '{"skill_version":"7.100.0"}'
unknown_case "7.100.0 is newer than 7.13.0 numerically" "created without cost tracking" U-9
new_doc U-10 '{"skill_version":"7.13.0","cost_sessions":"not-an-array"}'
unknown_case "wrong-typed cost_sessions" "" U-10
new_doc U-11 '{"skill_version":"7.13.0","cost_sessions":[null,{"id":"x","usd":"a"}],"stages":"nope"}'
unknown_case "malformed cost_sessions and non-object stages" "" U-11
REC="$(cost_run record NO-SUCH-TICKET)"; REC_EXIT=$?
assert_eq "cost record: a ticket that does not exist exits 0" "0" "$REC_EXIT"
is_one_object "$REC" && pass "cost record: a missing ticket still prints one valid object" || fail "cost record: a missing ticket still prints one valid object" "got: $REC"
assert_eq "cost record: a missing ticket is unknown" "unknown" "$(printf '%s' "$REC" | jq -r '.status' 2>/dev/null)"

# unknown "<reason>"
TRICKY_REASON="it's \"quoted\" \\(env.HOME) \${x} \$(echo no)"
UNK="$(cost_run unknown "$TRICKY_REASON")"; UNK_EXIT=$?
assert_eq "cost unknown: exit 0" "0" "$UNK_EXIT"
is_one_object "$UNK" && pass "cost unknown: prints one valid JSON object" || fail "cost unknown: prints one valid JSON object" "got: $UNK"
assert_eq "cost unknown: status, null total and the reason verbatim" "$(jq -nc --arg r "$TRICKY_REASON" '["unknown",null,$r]')" \
  "$(printf '%s' "$UNK" | jq -c '[.status, .total_usd, .reason]' 2>/dev/null)"
assert_eq "cost unknown: scope text present" "$COST_SCOPE_TEXT" "$(printf '%s' "$UNK" | jq -r '.scope' 2>/dev/null)"
assert_eq "cost unknown: recorded_at is a string" "string" "$(printf '%s' "$UNK" | jq -r '.recorded_at | type' 2>/dev/null)"

# --- record: tokens ---
cost_case
unset CLAUDE_CODE_SESSION_ID
new_doc K-1 '{"skill_version":"7.13.0","cost_sessions":[{"id":"tk-1","ts":"2026-01-01T00:00:00Z","usd":3},{"id":"tk-2","ts":"2026-01-01T00:00:00Z","usd":1}]}'
{
  tx_line 2026-01-01T00:10:00Z m1 r1 10 20 30 40
  tx_line 2026-01-01T00:10:01Z m1 r1 10 20 30 40
  tx_line 2026-01-01T00:10:02Z m1 r1 10 20 30 40
  tx_line 2026-01-01T00:11:00Z m2 r2 1 2 3 4
  printf '{"type":"user","timestamp":"2026-01-01T00:12:00Z","message":{"content":"hi"}}\n'
} | tx_put proj/tk-1.jsonl
tx_line 2026-01-01T00:13:00Z m3 r3 100 200 300 400 | tx_put proj/tk-1/subagents/agent-a.jsonl
REC="$(cost_run record K-1)"
assert_eq "cost tokens: session input and output tokens (dedupe by message.id, subagents included)" '[111,222]' \
  "$(printf '%s' "$REC" | jq -c '.sessions[] | select(.id == "tk-1") | [.input_tokens, .output_tokens]' 2>/dev/null)"
assert_eq "cost tokens: a session with no transcript has null tokens" '[null,null]' \
  "$(printf '%s' "$REC" | jq -c '.sessions[] | select(.id == "tk-2") | [.input_tokens, .output_tokens]' 2>/dev/null)"
cost_case
unset CLAUDE_CODE_SESSION_ID
new_doc K-2 '{"skill_version":"7.13.0","cost_sessions":[{"id":"tk-1","ts":"2026-01-01T00:00:00Z","usd":3}]}'
{
  tx_line 2026-01-01T00:10:00Z m1 r1 10 20 30 40
  tx_line 2026-01-01T00:10:01Z m1 r1 10 20 30 40
  tx_line 2026-01-01T00:11:00Z m2 r2 1 2 3 4
} | tx_put proj/tk-1.jsonl
tx_line 2026-01-01T00:13:00Z m3 r3 100 200 300 400 | tx_put proj/tk-1/subagents/agent-a.jsonl
REC="$(cost_run record K-2)"
assert_eq "cost tokens: record totals are the four deduplicated sums" '[111,222,333,444]' \
  "$(printf '%s' "$REC" | jq -c '[.input_tokens, .output_tokens, .cache_read_tokens, .cache_creation_tokens]' 2>/dev/null)"
printf 'this line is not json\n' >> "$COST_PROJECTS_DIR/proj/tk-1.jsonl"
REC="$(cost_run record K-2)"; REC_EXIT=$?
assert_eq "cost tokens: a corrupt transcript line keeps exit 0" "0" "$REC_EXIT"
is_one_object "$REC" && pass "cost tokens: a corrupt transcript still gives one valid object" || fail "cost tokens: a corrupt transcript still gives one valid object" "got: $REC"
# m-a: input 10, output 20, cache read 1, cache write 12.5 per million, on the deduplicated 111/222/333/444 tokens
assert_eq "cost tokens: a corrupt transcript does not change the priced cost" '["known",true]' \
  "$(printf '%s' "$REC" | jq -c '[.status, ((.total_usd - 0.011433) | fabs) < 0.000000001]' 2>/dev/null)"

# --- record: by_stage ---
cost_case
unset CLAUDE_CODE_SESSION_ID
STAGES_DOC='{"skill_version":"7.13.0","cost_sessions":[{"id":"bs-1","ts":"2026-01-01T00:00:00Z","usd":2}],"stages":{"1":{"status":"complete","completed_at":"2026-01-01T01:00:00Z"},"2":{"status":"complete","completed_at":"2026-01-01T02:00:00Z"},"3":{"status":"complete","completed_at":"2026-01-01T03:00:00Z"},"4":{"status":"complete","completed_at":"2026-01-01T04:00:00Z"},"5":{"status":"in_progress"}}}'
new_doc B-1 "$STAGES_DOC"
{
  tx_line 2026-01-01T00:30:00Z a 1 1 0 0 0
  tx_line 2026-01-01T01:00:00Z b 1 2 0 0 0
  tx_line 2026-01-01T01:30:00Z c 1 4 0 0 0
  tx_line 2026-01-01T03:30:00Z d 1 8 0 0 0
  tx_line 2026-01-01T05:00:00Z e 1 16 0 0 0
  tx_line 2026-01-01T07:00:00+05:30 f 1 32 0 0 0
  tx_line 2026-01-01T03:45:00.999Z g 1 64 0 0 0
} | tx_put proj/bs-1.jsonl
REC="$(cost_run record B-1)"; REC_EXIT=$?
assert_eq "cost by_stage: exit 0" "0" "$REC_EXIT"
assert_eq "cost by_stage: tokens land in (previous completed_at, own completed_at], offsets and fractions normalised, stage 5 closed by recorded_at" \
  '{"1":3,"2":36,"3":0,"4":72,"5":16}' \
  "$(printf '%s' "$REC" | jq -cS '.by_stage | with_entries(.value = (.value.input_tokens // 0))' 2>/dev/null)"
assert_eq "cost by_stage: no by_stage_reason when the stages are usable" "null" "$(printf '%s' "$REC" | jq -c '.by_stage_reason' 2>/dev/null)"

new_doc B-2 '{"skill_version":"7.13.0","cost_sessions":[{"id":"bs-1","ts":"2026-01-01T00:00:00Z","usd":2}],"stages":{"1":{"status":"complete","completed_at":"2026-01-01T01:00:00Z"},"2":{"status":"complete","completed_at":"2026-01-01T02:00:00Z"},"3":{"status":"imported"},"4":{"status":"complete","completed_at":"2026-01-01T04:00:00Z"},"5":{"status":"in_progress"}}}'
REC="$(cost_run record B-2)"
assert_eq "cost by_stage: an imported stage without completed_at merges forward into the next stage" '[0,72]' \
  "$(printf '%s' "$REC" | jq -c '[(.by_stage["3"].input_tokens // 0), .by_stage["4"].input_tokens]' 2>/dev/null)"

new_doc B-3 '{"skill_version":"7.13.0","cost_sessions":[{"id":"bs-1","ts":"2026-01-01T00:00:00Z","usd":2}],"stages":{"1":{"status":"complete","completed_at":"2026-01-01T06:30:00+05:30"},"5":{"status":"in_progress"}}}'
REC="$(cost_run record B-3)"
assert_eq "cost by_stage: a completed_at with a numeric offset is normalised (06:30+05:30 is 01:00Z)" '[3,"known"]' \
  "$(printf '%s' "$REC" | jq -c '[.by_stage["1"].input_tokens, .status]' 2>/dev/null)"

printf '%s' '{"ticket_id":"BF-1","skill_version":"7.13.0","cost_sessions":[{"id":"bs-1","ts":"2026-01-01T00:00:00Z","usd":2}],"stages":{"0":"complete","1":"complete","2":"complete","3":"complete","4":"in_progress"}}' \
  | "$METADATA_SH" init BF-1 --file bugfix.json > /dev/null 2>&1
REC="$(cost_run record BF-1 --file bugfix.json)"; REC_EXIT=$?
assert_eq "cost by_stage: a bugfix file with string stages exits 0" "0" "$REC_EXIT"
assert_eq "cost by_stage: a bugfix file has null by_stage, a reason, and still a known cost" '[null,"string","known"]' \
  "$(printf '%s' "$REC" | jq -c '[.by_stage, (.by_stage_reason | type), .status]' 2>/dev/null)"

new_doc B-4 '{"skill_version":"7.13.0","cost_sessions":[{"id":"bs-1","ts":"2026-01-01T00:00:00Z","usd":2}],"stages":{"1":{"status":"complete","completed_at":"garbage"},"5":{"status":"in_progress"}}}'
REC="$(cost_run record B-4)"; REC_EXIT=$?
assert_eq "cost by_stage: unparseable timestamps exit 0" "0" "$REC_EXIT"
assert_eq "cost by_stage: unparseable timestamps give null by_stage with a reason" '[null,"string"]' \
  "$(printf '%s' "$REC" | jq -c '[.by_stage, (.by_stage_reason | type)]' 2>/dev/null)"
new_doc B-5 '{"skill_version":"7.13.0","cost_sessions":[{"id":"bs-1","ts":"2026-01-01T00:00:00Z","usd":2}],"stages":{"1":{"completed_at":"2026-01-01T03:00:00Z"},"2":{"completed_at":"2026-01-01T02:00:00Z"}}}'
REC="$(cost_run record B-5)"
assert_eq "cost by_stage: out-of-order timestamps give null by_stage with a reason" '[null,"string"]' \
  "$(printf '%s' "$REC" | jq -c '[.by_stage, (.by_stage_reason | type)]' 2>/dev/null)"

# --- record: by_stage usd ---
# Every null by_stage path keeps its reason and carries an explicit null unassigned_usd (has(), because a missing key also reads null).
assert_eq "cost by_stage usd: a bugfix file keeps by_stage null and gets an explicit null unassigned_usd" '[null,true,null]' \
  "$(cost_run record BF-1 --file bugfix.json | jq -c '[.by_stage, has("unassigned_usd"), .unassigned_usd]' 2>/dev/null)"
assert_eq "cost by_stage usd: unparseable timestamps keep their reason and get an explicit null unassigned_usd" '[null,"timestamps are not parseable",true,null]' \
  "$(cost_run record B-4 | jq -c '[.by_stage, .by_stage_reason, has("unassigned_usd"), .unassigned_usd]' 2>/dev/null)"
assert_eq "cost by_stage usd: out-of-order timestamps keep their reason and get an explicit null unassigned_usd" '[null,"timestamps are out of order",true,null]' \
  "$(cost_run record B-5 | jq -c '[.by_stage, .by_stage_reason, has("unassigned_usd"), .unassigned_usd]' 2>/dev/null)"
new_doc B-6 '{"skill_version":"7.13.0","cost_sessions":[{"id":"bs-1","ts":"2026-01-01T00:00:00Z","usd":2}]}'
assert_eq "cost by_stage usd: a ticket without a stages object keeps its reason and gets an explicit null unassigned_usd" '[null,"ticket has no stages object",true,null]' \
  "$(cost_run record B-6 | jq -c '[.by_stage, .by_stage_reason, has("unassigned_usd"), .unassigned_usd]' 2>/dev/null)"
cost_case
unset CLAUDE_CODE_SESSION_ID
new_doc B-7 "$STAGES_DOC"
assert_eq "cost by_stage usd: sessions without any transcript keep their reason and get an explicit null unassigned_usd" '[null,"no transcript found",true,null]' \
  "$(cost_run record B-7 | jq -c '[.by_stage, .by_stage_reason, has("unassigned_usd"), .unassigned_usd]' 2>/dev/null)"
assert_eq "cost by_stage usd: the unknown record carries an explicit null unassigned_usd" '[null,true,null]' \
  "$(cost_run unknown "why" | jq -c '[.by_stage, has("unassigned_usd"), .unassigned_usd]' 2>/dev/null)"

# Two sessions, two models, stages 1 and 2 (stage 5 open). Per-event pricing: two m-long events of 60 prompt tokens
# each stay on the base tier even though together they pass the 100-token long_prompt threshold; the 200-token one
# is on the long tier. Outside every window: an event at exactly the earliest session start and one with an
# unparseable timestamp (1.0 each). A compaction 10 minutes after the last stage 2 request is cold (100000 x 1.25
# + 1000 x 2 per million = 0.127, on that request's model); one before any request has no price and only flags its stage.
cost_case
unset CLAUDE_CODE_SESSION_ID
new_doc U-1 '{"skill_version":"7.13.0","cost_sessions":[{"id":"us-1","ts":"2026-01-01T00:00:00Z","usd":2},{"id":"us-2","ts":"2026-01-01T00:00:00Z","usd":1}],"stages":{"1":{"status":"complete","completed_at":"2026-01-01T01:00:00Z"},"2":{"status":"complete","completed_at":"2026-01-01T02:00:00Z"},"5":{"status":"in_progress"}}}'
{
  tx_boundary 2026-01-01T00:10:00Z cb-null 100000 1000
  tx_line 2026-01-01T00:00:00Z at-start 1 100000 0 0 0 m-a
  tx_line "not-a-time" at-garbage 1 0 500000 0 0 m-b
  tx_line 2026-01-01T00:30:00Z s1-a 1 100000 0 0 0 m-a
  tx_line 2026-01-01T00:40:00Z s1-l1 1 60 0 0 0 m-long
  tx_line 2026-01-01T00:50:00Z s1-l2 1 60 0 0 0 m-long
  tx_line 2026-01-01T01:20:00Z s2-b 1 0 500000 0 0 m-b
  tx_boundary 2026-01-01T01:30:00Z cb-cold 100000 1000
} | tx_put proj/us-1.jsonl
tx_line 2026-01-01T01:40:00Z s2-l 1 200 0 0 0 m-long | tx_put proj/us-2.jsonl
REC="$(cost_run record U-1)"
assert_eq "cost by_stage usd: each stage sums its own events at the same per-event rates as the total" "true" \
  "$(usd_close "$(rec_field '.by_stage["1"].usd')" 1.00012)"
assert_eq "cost by_stage usd: a long-prompt event is priced on its own tier, in the session that holds it" "true" \
  "$(usd_close "$(rec_field '.by_stage["2"].usd')" 1.001)"
assert_eq "cost by_stage usd: an open stage 5 with no events costs zero" "true" \
  "$(usd_close "$(rec_field '.by_stage["5"].usd')" 0)"
assert_eq "cost by_stage usd: events outside every window are reported, not dropped" "true" \
  "$(usd_close "$(rec_field '.unassigned_usd')" 2)"
assert_eq "cost by_stage usd: a compaction is attributed to the stage holding its timestamp, apart from usd" '[true,true,true]' \
  "$(rec_field '[(.by_stage["2"].compaction_usd - 0.127 | fabs < 0.000000001), (.by_stage["1"].compaction_usd == 0), (.by_stage["2"].usd < 1.002)]')"
assert_eq "cost by_stage usd: a compaction without a price flags its own stage only" '[["no previous request (compaction)"],[]]' \
  "$(rec_field '[.by_stage["1"].unpriced_models, .by_stage["2"].unpriced_models]')"
assert_eq "cost by_stage usd: stages plus compactions plus unassigned equal total_usd to the cent" "true" \
  "$(rec_field '((([.by_stage[] | .usd, .compaction_usd] | add) + .unassigned_usd - .total_usd) | fabs) < 0.005')"
assert_eq "cost by_stage usd: the equation also holds to float precision" "true" \
  "$(rec_field '((([.by_stage[] | .usd, .compaction_usd] | add) + .unassigned_usd - .total_usd) | fabs) < 0.000000001')"
assert_eq "cost by_stage usd: the total itself is unchanged by the split" "true" "$(usd_close "$(rec_field '.total_usd')" 4.12812)"

# No stage 5: an event after the last completed stage is unassigned, and so is a compaction there.
cost_case
unset CLAUDE_CODE_SESSION_ID
new_doc U-2 '{"skill_version":"7.13.0","cost_sessions":[{"id":"us-1","ts":"2026-01-01T00:00:00Z","usd":2}],"stages":{"1":{"status":"complete","completed_at":"2026-01-01T01:00:00Z"},"2":{"status":"complete","completed_at":"2026-01-01T02:00:00Z"}}}'
{
  tx_line 2026-01-01T00:30:00Z a 1 100000 0 0 0 m-a
  tx_line 2026-01-01T03:00:00Z late 1 100000 0 0 0 m-a
  tx_boundary 2026-01-01T03:30:00Z cb-late 100000 1000
} | tx_put proj/us-1.jsonl
REC="$(cost_run record U-2)"
assert_eq "cost by_stage usd: without a stage 5 there is no key for it" "false" "$(rec_field '.by_stage | has("5")')"
assert_eq "cost by_stage usd: an event and a compaction after the last bound land in unassigned_usd (1.0 + 1.27)" "true" \
  "$(usd_close "$(rec_field '.unassigned_usd')" 2.27)"
assert_eq "cost by_stage usd: the equation holds when the tail is unassigned" "true" \
  "$(rec_field '((([.by_stage[] | .usd, .compaction_usd] | add) + .unassigned_usd - .total_usd) | fabs) < 0.000000001')"

# Equal bounds: the first stage owns the events at the bound, the second window is empty.
cost_case
unset CLAUDE_CODE_SESSION_ID
new_doc U-3 '{"skill_version":"7.13.0","cost_sessions":[{"id":"us-1","ts":"2026-01-01T00:00:00Z","usd":2}],"stages":{"1":{"status":"complete","completed_at":"2026-01-01T01:00:00Z"},"2":{"status":"complete","completed_at":"2026-01-01T01:00:00Z"},"5":{"status":"in_progress"}}}'
tx_line 2026-01-01T00:30:00Z a 1 100000 0 0 0 m-a | tx_put proj/us-1.jsonl
REC="$(cost_run record U-3)"
assert_eq "cost by_stage usd: equal bounds give the whole cost to the first stage and an empty window to the second" '[true,true]' \
  "$(rec_field '[(.by_stage["1"].usd - 1 | fabs < 0.000000001), (.by_stage["2"].usd == 0)]')"

# A model missing from the rate table: its tokens count in its stage, usd covers the priced events only.
cost_case
unset CLAUDE_CODE_SESSION_ID
new_doc U-4 '{"skill_version":"7.13.0","cost_sessions":[{"id":"us-1","ts":"2026-01-01T00:00:00Z","usd":2}],"stages":{"1":{"status":"complete","completed_at":"2026-01-01T01:00:00Z"},"2":{"status":"complete","completed_at":"2026-01-01T02:00:00Z"}}}'
{
  tx_line 2026-01-01T00:30:00Z a 1 100000 0 0 0 m-a
  tx_line 2026-01-01T01:20:00Z b 1 0 500000 0 0 m-b
  tx_line 2026-01-01T01:30:00Z x 1 1000 2000 0 0 m-x
} | tx_put proj/us-1.jsonl
REC="$(cost_run record U-4)"
assert_eq "cost by_stage usd: an unpriced model keeps its tokens in the stage" '[1000,502000]' \
  "$(rec_field '[.by_stage["2"].input_tokens, .by_stage["2"].output_tokens]')"
assert_eq "cost by_stage usd: an unpriced model leaves the stage usd to the priced events and lists the model" '[true,["m-x"],[]]' \
  "$(rec_field '[(.by_stage["2"].usd - 1 | fabs < 0.000000001), .by_stage["2"].unpriced_models, .by_stage["1"].unpriced_models]')"
assert_eq "cost by_stage usd: top-level status and unpriced_models stay as before" '["partial",["m-x"]]' \
  "$(rec_field '[.status, .unpriced_models]')"

# total_usd null while by_stage is an object (a registered session without a transcript, or no readable rate table):
# the new usd fields are null too, tokens stay.
cost_case
unset CLAUDE_CODE_SESSION_ID
new_doc U-5 '{"skill_version":"7.13.0","cost_sessions":[{"id":"us-1","ts":"2026-01-01T00:00:00Z","usd":2},{"id":"us-gone","ts":"2026-01-01T00:00:00Z","usd":1}],"stages":{"1":{"status":"complete","completed_at":"2026-01-01T01:00:00Z"},"5":{"status":"in_progress"}}}'
tx_line 2026-01-01T00:30:00Z a 1 100000 0 0 0 m-a | tx_put proj/us-1.jsonl
REC="$(cost_run record U-5)"
assert_eq "cost by_stage usd: a session without a transcript leaves tokens but no usd, compaction_usd or unassigned_usd" '[null,100000,null,null,null,true]' \
  "$(rec_field '[.total_usd, .by_stage["1"].input_tokens, .by_stage["1"].usd, .by_stage["1"].compaction_usd, .unassigned_usd, (.by_stage["1"] | has("usd") and has("compaction_usd"))]')"
new_doc U-6 '{"skill_version":"7.13.0","cost_sessions":[{"id":"us-1","ts":"2026-01-01T00:00:00Z","usd":2}],"stages":{"1":{"status":"complete","completed_at":"2026-01-01T01:00:00Z"},"5":{"status":"in_progress"}}}'
REC="$(COST_RATES_FILE="$COST_ROOT/missing-rates.json" cost_run record U-6)"
assert_eq "cost by_stage usd: an unreadable rate table leaves tokens but no usd, compaction_usd or unassigned_usd" '["unknown",100000,null,null,null,true]' \
  "$(rec_field '[.status, .by_stage["1"].input_tokens, .by_stage["1"].usd, .by_stage["1"].compaction_usd, .unassigned_usd, (.by_stage["1"] | has("usd") and has("compaction_usd"))]')"

# =====================================================================
# DOER-6: the cost is priced from the transcripts with a shipped rate table
# =====================================================================
# Fixture table (COST_RATES_JSON): m-a 10/20/1/12.5/20, m-b 1/2/0.1/1.25/2 per million
# (input/output/cache read/cache write 5m/cache write 1h); m-long has a long_prompt tier
# above 100 prompt tokens; m-fast has fast_multiplier 2; cold_after_seconds is 120.
price_doc() { # <ticket> <session-id>...: a tracked ticket with these registered sessions
  local ticket="$1" sessions="[]" session_id; shift
  for session_id in "$@"; do
    sessions="$(printf '%s' "$sessions" | jq -c --arg id "$session_id" '. + [{id: $id, ts: "2026-01-01T00:00:00Z", usd: null}]')"
  done
  new_doc "$ticket" "$(jq -nc --argjson s "$sessions" '{skill_version: "7.13.3", cost_sessions: $s}')"
}

# AC-1: two sessions, two models, no counter source of any kind
cost_case
unset CLAUDE_CODE_SESSION_ID
price_doc P-1 p1-a p1-b
tx_split 2026-01-01T10:00:00Z a1 r1 100 50 200 40 10 m-a | tx_put proj/p1-a.jsonl
tx_split 2026-01-01T10:00:00Z b1 r1 1000 500 2000 400 100 m-b | tx_put proj/p1-b.jsonl
REC="$(COST_STATUSLINE_CACHE_DIR="$COST_ROOT/none" COST_MULTI_INSTANCE_DIR="$COST_ROOT/none" cost_run record P-1)"
assert_eq "cost price: two models from transcripts alone give a known record" "known" "$(rec_field '.status' | tr -d '"')"
assert_eq "cost price: total_usd sums input, output, cache read, 5m and 1h writes per model (2900 + 2900 micro-dollars)" "true" \
  "$(usd_close "$(rec_field '.total_usd')" 0.0058)"
assert_eq "cost price: by_model prices each model separately" "true" "$(usd_close "$(rec_field '.by_model["m-b"].usd')" 0.0029)"
assert_eq "cost price: by_model carries the model's four token sums" '[100,50,200,50]' \
  "$(rec_field '.by_model["m-a"] | [.input_tokens, .output_tokens, .cache_read_tokens, .cache_creation_tokens]')"
assert_eq "cost price: the record names when the rates were taken and where" '["2026-11-03","https://example.test/pricing"]' \
  "$(rec_field '[.rates.taken_on, .rates.source]')"
assert_eq "cost price: nothing is unpriced" "[]" "$(rec_field '.unpriced_models')"
assert_eq "cost price: no counters at all means reported_usd is null" "null" "$(rec_field '.reported_usd')"

# AC-2: models the table does not hold
cost_case
unset CLAUDE_CODE_SESSION_ID
price_doc P-2 p2
{
  tx_line 2026-01-01T10:00:00Z a1 r1 1000000 0 0 0 m-b
  tx_line 2026-01-01T10:00:01Z a2 r2 500 500 0 0 m-zzz
} | tx_put proj/p2.jsonl
REC="$(cost_run record P-2)"
assert_eq "cost price: an unlisted model makes the record partial, not unknown" "partial" "$(rec_field '.status' | tr -d '"')"
assert_eq "cost price: partial total_usd covers the priced model only" "true" "$(usd_close "$(rec_field '.total_usd')" 1)"
assert_eq "cost price: unpriced_models names the model" '["m-zzz"]' "$(rec_field '.unpriced_models')"
assert_eq "cost price: the unpriced model's tokens are still counted" '[1000500,500]' "$(rec_field '[.input_tokens, .output_tokens]')"
assert_eq "cost price: the reason says which model was not priced" "true" "$(rec_field '.reason | type == "string" and contains("m-zzz")')"
assert_eq "cost price: by_model usd of the unpriced model is null" "null" "$(rec_field '.by_model["m-zzz"].usd')"

price_doc P-2b p2b
tx_line 2026-01-01T10:00:00Z a1 r1 1000000 0 0 0 m-b-20260101 | tx_put proj/p2b.jsonl
REC="$(cost_run record P-2b)"
assert_eq "cost price: a listed id with a -YYYYMMDD suffix is priced" '["known",true]' "$(rec_field '[.status, ((.total_usd - 1) | fabs) < 0.000000001]')"
price_doc P-2c p2c
{
  tx_line 2026-01-01T10:00:00Z a1 r1 1000 0 0 0 m-b-2
  tx_line 2026-01-01T10:00:01Z a2 r2 1000 0 0 0 m-b-2-extra
  tx_line 2026-01-01T10:00:02Z a3 r3 1000 0 0 0 m-b-202601011
} | tx_put proj/p2c.jsonl
REC="$(cost_run record P-2c)"
assert_eq "cost price: look-alike ids are never matched to a neighbour (partial, total 0)" '["partial",["m-b-2","m-b-2-extra","m-b-202601011"],0]' \
  "$(rec_field '[.status, (.unpriced_models | sort), .total_usd]')"
price_doc P-2d p2d
tx_line 2026-01-01T10:00:00Z a1 r1 10 10 0 0 m-zzz | tx_put proj/p2d.jsonl
REC="$(cost_run record P-2d)"
assert_eq "cost price: only unpriced models gives partial with total 0" '["partial",0]' "$(rec_field '[.status, .total_usd]')"

price_doc P-2e p2e
tx_line 2026-01-01T10:00:00Z a1 r1 1000000 0 0 0 m-fast | jq -c '.message.usage.speed = "fast"' | tx_put proj/p2e.jsonl
REC="$(cost_run record P-2e)"
assert_eq "cost price: a fast-mode event on a model with fast_multiplier is priced at twice the rates" '["known",true]' \
  "$(rec_field '[.status, ((.total_usd - 8) | fabs) < 0.000000001]')"
price_doc P-2f p2f
tx_line 2026-01-01T10:00:00Z a1 r1 1000000 0 0 0 m-b | jq -c '.message.usage.speed = "fast"' | tx_put proj/p2f.jsonl
REC="$(cost_run record P-2f)"
assert_eq "cost price: a fast-mode event on a model without fast_multiplier is counted but flagged not priced" '["partial",["m-b (fast mode)"],1000000]' \
  "$(rec_field '[.status, .unpriced_models, .input_tokens]')"
price_doc P-2g p2g
tx_line 2026-01-01T10:00:00Z a1 r1 1000000 0 0 0 m-b | jq -c '.message.usage.server_tool_use.web_search_requests = 2' | tx_put proj/p2g.jsonl
REC="$(cost_run record P-2g)"
assert_eq "cost price: a web-search event keeps its token cost and flags only the search fee" '["partial",["m-b (web search fee)"],true]' \
  "$(rec_field '[.status, .unpriced_models, ((.total_usd - 1) | fabs) < 0.000000001]')"
price_doc P-2h p2h
tx_line 2026-01-01T10:00:00Z a1 r1 100 0 0 0 m-long | tx_put proj/p2h.jsonl
REC="$(cost_run record P-2h)"
assert_eq "cost price: a prompt exactly at the long_prompt threshold is priced at the base tier" "true" "$(usd_close "$(rec_field '.total_usd')" 0.0001)"
price_doc P-2i p2i
tx_line 2026-01-01T10:00:00Z a1 r1 101 0 0 0 m-long | tx_put proj/p2i.jsonl
REC="$(cost_run record P-2i)"
assert_eq "cost price: a prompt over the threshold is priced at the long tier" "true" "$(usd_close "$(rec_field '.total_usd')" 0.000505)"
price_doc P-2j p2j
tx_line 2026-01-01T10:00:00Z a1 r1 60 0 50 0 m-long | tx_put proj/p2j.jsonl
REC="$(cost_run record P-2j)"
assert_eq "cost price: the prompt length counts cache reads too (60 + 50 > 100 is the long tier)" "true" \
  "$(usd_close "$(rec_field '.total_usd')" 0.000325)"

# AC-3: a message logged more than once counts once
cost_case
unset CLAUDE_CODE_SESSION_ID
price_doc P-3 p3
{
  tx_line 2026-01-01T10:00:00Z m1 r1 0 10 0 0 m-b
  tx_line 2026-01-01T10:00:01Z m1 r1 0 50 0 0 m-b
  tx_line 2026-01-01T10:00:02Z m1 r1 0 50 0 0 m-b
  tx_line 2026-01-01T10:00:03Z m1 r-retry 0 50 0 0 m-b
} | tx_put proj/p3.jsonl
REC="$(cost_run record P-3)"
assert_eq "cost dedupe: streaming and retried lines of one message id count once at the final usage" '[50,true]' \
  "$(rec_field '[.output_tokens, ((.total_usd - 0.0001) | fabs) < 0.000000001]')"
{
  tx_line 2026-01-01T10:00:04Z x 1 0 7 0 0 m-b | jq -c 'del(.message.id)'
  tx_line 2026-01-01T10:00:05Z x 2 0 7 0 0 m-b | jq -c 'del(.message.id)'
} | tx_put proj/p3.jsonl
REC="$(cost_run record P-3)"
assert_eq "cost dedupe: lines without a message id each count" "64" "$(rec_field '.output_tokens')"

# AC-3 across sessions: a resumed or forked session copies earlier lines
cost_case
unset CLAUDE_CODE_SESSION_ID
price_doc P-3b zz-orig aa-copy
{
  tx_line 2026-01-01T10:00:00Z x1 r1 1000000 0 0 0 m-b
  tx_line 2026-01-01T10:00:10Z y1 r2 1000000 0 0 0 m-b
  tx_boundary 2026-01-01T10:05:00Z u1 1000000 10000
} | tx_put proj/zz-orig.jsonl
{
  tx_boundary 2026-01-01T10:05:00Z u1 1000000 10000
  tx_line 2026-01-01T10:00:00Z x1 r1 1000000 0 0 0 m-b
  tx_line 2026-01-01T10:06:00Z z1 r3 1000000 0 0 0 m-b
} | tx_put proj/aa-copy.jsonl
REC="$(cost_run record P-3b)"
assert_eq "cost dedupe: a message copied into a second session counts once; the shared boundary is priced once (1 + 1 + 1 + 1.27)" '["known",1,true]' \
  "$(rec_field '[.status, .compactions.count, ((.total_usd - 4.27) | fabs) < 0.000000001]')"
assert_eq "cost dedupe: the copied message is attributed to the session registered first, not the alphabetical first" '[["zz-orig",2000000],["aa-copy",1000000]]' \
  "$(rec_field '[.sessions[] | [.id, .input_tokens]]')"
assert_eq "cost dedupe: token totals count the copied message once" "3000000" "$(rec_field '.input_tokens')"

# a session with no transcript, or an unreadable rate table: unknown, still one object, exit 0
cost_case
unset CLAUDE_CODE_SESSION_ID
price_doc P-4 p4-ok p4-gone
tx_line 2026-01-01T10:00:00Z a1 r1 1000000 0 0 0 m-b | tx_put proj/p4-ok.jsonl
unknown_case "one registered session has no transcript" "no transcript found for p4-gone" P-4
price_doc P-4b p4b
tx_line 2026-01-01T10:00:00Z a1 r1 1000000 0 0 0 m-b | tx_put proj/p4b.jsonl
COST_RATES_FILE="$COST_ROOT/missing-rates.json" unknown_case "the rate table file is missing" "rate table" P-4b
printf '{{' > "$COST_ROOT/bad-rates.json"
COST_RATES_FILE="$COST_ROOT/bad-rates.json" unknown_case "the rate table is not JSON" "rate table" P-4b
printf '{"taken_on":"2026-11-03"}' > "$COST_ROOT/empty-rates.json"
COST_RATES_FILE="$COST_ROOT/empty-rates.json" unknown_case "the rate table has no models" "rate table" P-4b

# counters are only a cross-check
cost_case
unset CLAUDE_CODE_SESSION_ID
new_doc P-5 '{"skill_version":"7.13.3","cost_sessions":[{"id":"c1","ts":"2026-01-01T00:00:00Z","usd":100}]}'
tx_line 2026-01-01T10:00:00Z a1 r1 3000000 0 0 0 m-b | tx_put proj/c1.jsonl
REC="$(cost_run record P-5)"
assert_eq "cost cross-check: a counter of 100 never replaces the priced transcript (3)" '["known",true,100]' \
  "$(rec_field '[.status, ((.total_usd - 3) | fabs) < 0.000000001, .reported_usd]')"
new_doc P-5b '{"skill_version":"7.13.3","cost_sessions":[{"id":"c2","ts":"2026-01-01T00:00:00Z","usd":8,"reset":true}]}'
tx_line 2026-01-01T10:00:00Z a1 r1 3000000 0 0 0 m-b | tx_put proj/c2.jsonl
REC="$(cost_run record P-5b)"
assert_eq "cost cross-check: a counter that went backwards no longer makes the record unknown, reported_usd is null" '["known",true,null]' \
  "$(rec_field '[.status, ((.total_usd - 3) | fabs) < 0.000000001, .reported_usd]')"

# compaction: priced from the boundary metadata (cold: cache write 5m, warm: cache read, output = postTokens)
cost_case
unset CLAUDE_CODE_SESSION_ID
price_doc P-6a p6a
{
  tx_line 2026-01-01T10:00:00Z a1 r1 1 0 0 0 m-a
  tx_boundary 2026-01-01T10:02:01Z u1 1000000 10000
} | tx_put proj/p6a.jsonl
REC="$(cost_run record P-6a)"
assert_eq "cost compaction: 121 s after the previous request is cold (1000000 x 12.5 + 10000 x 20 per million = 12.7)" '["known",1,true,true]' \
  "$(rec_field '[.status, .compactions.count, ((.compactions.estimated_usd - 12.7) | fabs) < 0.000000001, ((.total_usd - 12.70001) | fabs) < 0.000000001]')"
price_doc P-6b p6b
{
  tx_line 2026-01-01T10:00:00Z a1 r1 1 0 0 0 m-a
  tx_boundary 2026-01-01T10:02:00Z u1 1000000 10000
} | tx_put proj/p6b.jsonl
REC="$(cost_run record P-6b)"
assert_eq "cost compaction: 120 s after the previous request is warm (cache read: 1.0 + 0.2 = 1.2)" "true" \
  "$(usd_close "$(rec_field '.compactions.estimated_usd')" 1.2)"
price_doc P-6c p6c
{
  tx_line 2026-01-01T10:00:00Z a1 r1 1 0 0 0 m-a
  tx_synthetic 2026-01-01T10:03:20Z
  tx_boundary 2026-01-01T10:04:10Z u1 1000000 10000
} | tx_put proj/p6c.jsonl
REC="$(cost_run record P-6c)"
assert_eq "cost compaction: a zero-usage synthetic line is never the previous request (cold from the real line, known)" '["known",true]' \
  "$(rec_field '[.status, ((.compactions.estimated_usd - 12.7) | fabs) < 0.000000001]')"
price_doc P-6d p6d
tx_boundary 2026-01-01T10:02:00Z u1 1000000 10000 | tx_put proj/p6d.jsonl
REC="$(cost_run record P-6d)"
assert_eq "cost compaction: a boundary with no previous request is flagged and the record is partial" "partial" "$(rec_field '.status' | tr -d '"')"
assert_eq "cost compaction: ... naming the compaction in unpriced_models" "true" "$(rec_field '.unpriced_models | any(.[]; contains("compaction"))')"
price_doc P-6e p6e
{
  tx_line 2026-01-01T10:00:00Z a1 r1 1 0 0 0 m-zzz
  tx_boundary 2026-01-01T10:02:01Z u1 1000000 10000
} | tx_put proj/p6e.jsonl
REC="$(cost_run record P-6e)"
assert_eq "cost compaction: a boundary after an unpriced model is flagged as that model's compaction" '["partial",true]' \
  "$(rec_field '[.status, (.unpriced_models | index("m-zzz (compaction)") != null)]')"
price_doc P-6f p6f
{
  tx_line 2026-01-01T10:00:00Z a1 r1 1 0 0 0 m-a
  tx_boundary 2026-01-01T10:02:01Z u1 1000000 10000
  tx_line 2026-01-01T11:00:00Z a2 r2 1 0 0 0 m-a
  tx_boundary 2026-01-01T11:02:01Z u2 1000000 10000
} | tx_put proj/p6f.jsonl
REC="$(cost_run record P-6f)"
assert_eq "cost compaction: two boundaries add up" '[2,true]' "$(rec_field '[.compactions.count, ((.compactions.estimated_usd - 25.4) | fabs) < 0.000000001]')"

# compaction in a subagent file pairs with that file's own thread, never with the main thread
cost_case
unset CLAUDE_CODE_SESSION_ID
price_doc P-6g p6g
tx_line 2026-01-01T10:00:00Z a1 r1 1 0 0 0 m-a | tx_put proj/p6g.jsonl
{
  tx_line 2026-01-01T10:00:00Z s1 r2 1 0 0 0 m-b | jq -c '.isSidechain = true'
  tx_boundary 2026-01-01T10:02:01Z u1 1000000 10000 | jq -c '.isSidechain = true'
} | tx_put proj/p6g/subagents/agent-a.jsonl
REC="$(cost_run record P-6g)"
assert_eq "cost compaction: a boundary inside a subagent file is priced with that file's own model (m-b: 1.25 + 0.02)" "true" \
  "$(usd_close "$(rec_field '.compactions.estimated_usd')" 1.27)"
price_doc P-6h p6h
tx_boundary 2026-01-01T10:02:01Z u1 1000000 10000 | tx_put proj/p6h.jsonl
tx_line 2026-01-01T10:00:00Z s1 r2 1 0 0 0 m-b | jq -c '.isSidechain = true' | tx_put proj/p6h/subagents/agent-a.jsonl
REC="$(cost_run record P-6h)"
assert_eq "cost compaction: a main-file boundary is never paired with a subagent line (partial)" "partial" "$(rec_field '.status' | tr -d '"')"

# --- close (--require 5:complete) and display (status / list) ---
CLOSE_DOC='{"summary":"s","commit_message":"c","pr_description":"p","stages":{"5":{"completed_at":"t"}}}'
for cost_value in '{"status":"unknown","reason":"r"}' '{"status":"known","total_usd":1}'; do
  printf '%s' "$CLOSE_DOC" | jq -c --argjson c "$cost_value" '.cost = $c' | "$METADATA_SH" check-required 5 complete - > /dev/null 2>&1
  assert_eq "cost close: check-required 5 complete accepts cost $cost_value" "0" "$?"
done
for bad_cost in '' ',"cost":null' ',"cost":{}' ',"cost":"unknown"' ',"cost":{"total_usd":1}'; do
  printf '%s' "${CLOSE_DOC%\}}${bad_cost}}" | "$METADATA_SH" check-required 5 complete - > "$TMPDIR_TEST/close-out.txt" 2>&1
  CLOSE_EXIT=$?
  assert_eq "cost close: check-required 5 complete refuses cost variant [${bad_cost:-missing}]" "1" "$CLOSE_EXIT"
  grep -qF 'cost' "$TMPDIR_TEST/close-out.txt" \
    && pass "cost close: the refusal for [${bad_cost:-missing}] names cost" || fail "cost close: the refusal for [${bad_cost:-missing}] names cost" "got: $(cat "$TMPDIR_TEST/close-out.txt")"
done
cost_case
unset CLAUDE_CODE_SESSION_ID
new_doc C-1 '{"summary":"s","commit_message":"c","pr_description":"p","stages":{"5":{"status":"in_progress"}}}'
BEFORE_C1="$(cat .doer/tickets/C-1/metadata.json)"
"$METADATA_SH" write C-1 '.stages["5"].completed_at = "t"' --require 5:complete > /dev/null 2>&1
assert_eq "cost close: write --require 5:complete without a cost is refused, exit 1" "1" "$?"
assert_eq "cost close: the refused write leaves the file byte-identical" "$BEFORE_C1" "$(cat .doer/tickets/C-1/metadata.json)"
cost_run unknown "$TRICKY_REASON" > "$COST_ROOT/unk.json"
"$METADATA_SH" write C-1 '.stages["5"].completed_at = "t" | .cost = $cost[0]' --slurpfile cost "$COST_ROOT/unk.json" --require 5:complete > /dev/null 2>&1
assert_eq "cost close: write --require 5:complete accepts an unknown cost record" "0" "$?"
assert_eq "cost close: --slurpfile stores the record byte for byte" "$(jq -cS . "$COST_ROOT/unk.json")" "$(ticket_jq C-1 '.cost' | jq -cS . 2>/dev/null)"

new_doc D-1 '{"title":"T","status":"complete","current_stage":5,"stages":{"5":{"status":"complete"}},"cost":{"status":"known","total_usd":17.619,"scope":"whole sessions; may include non-ticket work in them","sessions":[{"id":"a"},{"id":"b"},{"id":"c"}]}}'
STATUS_OUT="$("$METADATA_SH" status D-1 2>&1)"
printf '%s\n' "$STATUS_OUT" | grep -qFx 'Cost: $17.62 across 3 sessions (whole sessions)' \
  && pass "cost status: a known cost prints the dollar total, session count and scope" \
  || fail "cost status: a known cost prints the dollar total, session count and scope" "got: $STATUS_OUT"
new_doc D-2 '{"title":"T","status":"complete","current_stage":5,"stages":{"5":{"status":"complete"}},"cost":{"status":"unknown","total_usd":null,"reason":"no cost data for s1; cost counter went backwards for s2"}}'
STATUS_OUT="$("$METADATA_SH" status D-2 2>&1)"
printf '%s\n' "$STATUS_OUT" | grep -qFx 'Cost: unknown (no cost data for s1)' \
  && pass "cost status: an unknown cost prints the first reason clause" \
  || fail "cost status: an unknown cost prints the first reason clause" "got: $STATUS_OUT"
new_doc D-2b '{"title":"T","status":"complete","current_stage":5,"stages":{"5":{"status":"complete"}},"cost":{"status":"partial","total_usd":2.5,"reason":"models not priced: m-x, m-y","unpriced_models":["m-x","m-y (fast mode)"],"sessions":[{"id":"a"},{"id":"b"}]}}'
STATUS_OUT="$("$METADATA_SH" status D-2b 2>&1)"
printf '%s\n' "$STATUS_OUT" | grep -qFx 'Cost: $2.50 across 2 sessions (whole sessions; not priced: m-x, m-y (fast mode))' \
  && pass "cost status: a partial cost prints the total and the models that were not priced" \
  || fail "cost status: a partial cost prints the total and the models that were not priced" "got: $STATUS_OUT"
"$METADATA_SH" list 2>&1 | grep '^D-2b ' | grep -qF '$2.50' \
  && pass "cost list: a partial cost shows its total" || fail "cost list: a partial cost shows its total"
new_doc D-3 '{"title":"T","status":"complete","current_stage":5,"stages":{"5":{"status":"complete"}}}'
STATUS_OUT="$("$METADATA_SH" status D-3 2>&1)"; STATUS_EXIT=$?
assert_eq "cost status: a ticket without cost exits 0" "0" "$STATUS_EXIT"
printf '%s\n' "$STATUS_OUT" | grep -q '^Cost:' && fail "cost status: a ticket without cost prints no Cost line" || pass "cost status: a ticket without cost prints no Cost line"
mkdir -p .doer/tickets/D-4
printf '%s' '{"title":"T","status":"complete","current_stage":5,"stages":{"5":{"status":"complete"}},"cost":{"status":"known","total_usd":1,"sessions":[{"id":"a"}]}}' > .doer/tickets/D-4/metadata.json
printf '%s' '{"title":"T","status":"in_progress","current_stage":4,"stages":{"0":"complete"},"cost":{"status":"unknown","reason":"x"}}' > .doer/tickets/D-4/bugfix.json
assert_eq "cost status: a key with both files prints one Cost line per file" "2" "$("$METADATA_SH" status D-4 2>&1 | grep -c '^Cost:')"
printf '%s' '{"title":"T","status":"in_progress","current_stage":6,"stages":{"0":"complete","6":"in_progress"},"cost":{"status":"known","total_usd":2.5,"sessions":[{"id":"a"},{"id":"b"}]}}' > "$COST_ROOT/bf.json"
mkdir -p .doer/tickets/D-5; cp "$COST_ROOT/bf.json" .doer/tickets/D-5/bugfix.json
"$METADATA_SH" status D-5 2>&1 | grep -qFx 'Cost: $2.50 across 2 sessions (whole sessions)' \
  && pass "cost status: a bugfix.json cost renders too" || fail "cost status: a bugfix.json cost renders too"
printf '%s' '{"title":"T","status":"in_progress","current_stage":3,"stages":{"0":"complete"},"cost":"weird"}' > "$COST_ROOT/odd.json"
mkdir -p .doer/tickets/D-6; cp "$COST_ROOT/odd.json" .doer/tickets/D-6/metadata.json
"$METADATA_SH" status D-6 > /dev/null 2>&1
assert_eq "cost status: a non-object cost value does not break status" "0" "$?"

LIST_OUT="$("$METADATA_SH" list 2>&1)"; LIST_EXIT=$?
assert_eq "cost list: exit 0 with cost tickets present" "0" "$LIST_EXIT"
printf '%s\n' "$LIST_OUT" | grep '^D-1 ' | grep -qF '$17.62' \
  && pass "cost list: a known cost is appended to the ticket line" || fail "cost list: a known cost is appended to the ticket line" "got: $LIST_OUT"
printf '%s\n' "$LIST_OUT" | grep '^D-2 ' | grep -qi 'unknown' \
  && pass "cost list: an unknown cost is appended to the ticket line" || fail "cost list: an unknown cost is appended to the ticket line" "got: $LIST_OUT"
printf '%s\n' "$LIST_OUT" | grep '^D-5 ' | grep -qF '$2.50' \
  && pass "cost list: a bugfix ticket shows its cost" || fail "cost list: a bugfix ticket shows its cost" "got: $LIST_OUT"
printf '%s\n' "$LIST_OUT" | grep '^D-3 ' | grep -qi 'cost\|\$' \
  && fail "cost list: a ticket without cost keeps its line unchanged" || pass "cost list: a ticket without cost keeps its line unchanged"

# --- static checks: jq 1.6 compatibility of metadata.sh and cost.sh, no price table ---
for part_file in "$METADATA_SH" "$COST_SH"; do
  part_label="$(basename "$part_file")"
  [ -f "$part_file" ] || { fail "$part_label exists for the jq-compat scan"; continue; }
  assert_eq "$part_label: jq-compat begin and end markers are balanced" \
    "$(grep -c 'jq-compat:begin' "$part_file")" "$(grep -c 'jq-compat:end' "$part_file")"
  for part_name in $(list_jq_parts "$part_file"); do
    PART_TEXT="$(extract_jq_part "$part_name" "$part_file")"
    assert_eq "$part_label $part_name jq text is jq 1.6 compatible" "" "$(jq_compat_problems "$PART_TEXT")"
    assert_eq "$part_label $part_name: the checker rejects an injected dot-before-index" "rejected" \
      "$([ -n "$(printf '%s' "$PART_TEXT" | grep -q . && jq_compat_problems "$PART_TEXT"' | .a.[0]')" ] && echo rejected || echo accepted)"
  done
done
for required_part in list init write; do
  assert_eq "metadata.sh carries a jq-compat part named $required_part" "yes" \
    "$(list_jq_parts "$METADATA_SH" | grep -qx "$required_part" && echo yes || echo no)"
done
assert_eq "cost.sh carries at least one jq-compat part" "yes" \
  "$([ -f "$COST_SH" ] && [ "$(list_jq_parts "$COST_SH" | wc -l | tr -d ' ')" -ge 1 ] && echo yes || echo no)"
# every `jq` program in cost.sh sits inside a marked part: a bare jq filter outside markers is unscanned
assert_eq "cost.sh: no jq program is left outside a jq-compat part" "0" \
  "$([ -f "$COST_SH" ] && awk '/# jq-compat:begin/{inside=1; next} /# jq-compat:end/{inside=0; next} !inside && /(^|[^A-Za-z_-])jq[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(--[a-z-]+[[:space:]]+[^[:space:]]+[[:space:]]+)*\047/ {n++} END{print n+0}' "$COST_SH" || echo missing)"
# DOER-6: the rates live in lib/cost-rates.json only. The helpers hold no model name, divisor, rate
# literal or compaction parameter (the words "price" and "priced" are fine now: unpriced_models).
COST_RATES_REAL="${REPO_ROOT}/lib/cost-rates.json"
for rate_free_file in "$COST_SH" "${REPO_ROOT}/lib/helpers/metadata.sh"; do
  assert_eq "$(basename "$rate_free_file"): no model name, divisor or rate-like constant" "clean" \
    "$([ -f "$rate_free_file" ] && { grep -qiE 'opus|sonnet|haiku|fable|mythos|per_?million|per_?mtok|usd_per|1e6|1000000|1_000_000|0\.0000[0-9]' "$rate_free_file" && echo found || echo clean; } || echo missing)"
done
assert_eq "cost.sh: no compaction threshold literal" "clean" \
  "$([ -f "$COST_SH" ] && { grep -qE '(^|[^0-9.])(300|120)([^0-9.]|$)' "$COST_SH" && echo found || echo clean; } || echo missing)"
assert_eq "cost-rates.json is valid JSON with the date, source, divisor and compaction parameter" "true" \
  "$(jq '(.taken_on | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and (.source | test("^https://")) and (.per_tokens | type == "number") and (.compaction.cold_after_seconds | type == "number") and (.models | type == "object" and length > 0)' "$COST_RATES_REAL" 2>/dev/null || echo false)"
assert_eq "cost-rates.json: every model has the five numeric rates" "true" \
  "$(jq '[.models[] | [.input, .output, .cache_read, .cache_write_5m, .cache_write_1h] | all(type == "number")] | all' "$COST_RATES_REAL" 2>/dev/null || echo false)"
assert_eq "cost-rates.json: only claude-haiku-5-5 has a long_prompt tier" '["claude-haiku-5-5"]' \
  "$(jq -c '[.models | to_entries[] | select(.value.long_prompt != null) | .key]' "$COST_RATES_REAL" 2>/dev/null)"
assert_eq "cost-rates.json: fast_multiplier 2 on Opus 5.5, 5 and 4.8 only" '["claude-opus-4-8","claude-opus-5","claude-opus-5-5"]' \
  "$(jq -c '[.models | to_entries[] | select(.value.fast_multiplier == 2) | .key] | sort' "$COST_RATES_REAL" 2>/dev/null)"

# every model id of the shipped table prices (real file, COST_RATES_FILE unset, from a temp dir,
# CLAUDE_PLUGIN_ROOT unset): input|output|cache read|write 5m|write 1h, USD per million tokens
cost_case
unset CLAUDE_CODE_SESSION_ID
cost_run_real() { (cd "$COST_ROOT/repo" && env -u COST_RATES_FILE -u CLAUDE_PLUGIN_ROOT "$COST_SH" "$@" 2>/dev/null); }
while IFS='|' read -r model_id rate_in rate_out rate_read rate_w5 rate_w1; do
  [ -n "$model_id" ] || continue
  price_doc "T-$model_id" "t-$model_id"
  tx_split 2026-01-01T10:00:00Z a1 r1 10000 10000 10000 10000 10000 "$model_id" | tx_put "proj/t-$model_id.jsonl"
  REC="$(cost_run_real record "T-$model_id")"
  expected_usd="$(jq -n --arg r "$rate_in+$rate_out+$rate_read+$rate_w5+$rate_w1" '$r | split("+") | map(tonumber) | add * 0.01')"
  assert_eq "cost table: $model_id prices 10000 tokens of each kind at the documented rates" '["known",[],true]' \
    "$(printf '%s' "$REC" | jq -c --argjson e "$expected_usd" '[.status, .unpriced_models, ((.total_usd - $e) | fabs) < 0.000000001]' 2>/dev/null)"
done <<'RATES'
claude-fable-5-1|10|50|0.25|12.5|20
claude-fable-5|10|50|1|12.5|20
claude-mythos-5-1|10|50|0.25|12.5|20
claude-mythos-5|10|50|1|12.5|20
claude-opus-5-5|4|20|0.2|5|8
claude-opus-5|5|25|0.5|6.25|10
claude-opus-4-8|5|25|0.5|6.25|10
claude-opus-4-7|5|25|0.5|6.25|10
claude-opus-4-6|5|25|0.5|6.25|10
claude-opus-4-5|5|25|0.5|6.25|10
claude-opus-4-1|15|75|1.5|18.75|30
claude-opus-4|15|75|1.5|18.75|30
claude-sonnet-5-5|2|10|0.1|2.5|4
claude-sonnet-5|2|10|0.2|2.5|4
claude-sonnet-4-6|3|15|0.3|3.75|6
claude-sonnet-4-5|3|15|0.3|3.75|6
claude-sonnet-4|3|15|0.3|3.75|6
claude-haiku-5-5|0.1|0.5|0.01|0.125|0.2
claude-haiku-4-5|1|5|0.1|1.25|2
claude-3-5-haiku|0.8|4|0.08|1|1.6
RATES
# a dated snapshot id, the long-prompt edge of Haiku 5.5, fast mode and a search fee on the real table
price_doc T-dated t-dated
tx_line 2026-01-01T10:00:00Z a1 r1 1000000 0 0 0 claude-opus-5-5-20261101 | tx_put proj/t-dated.jsonl
REC="$(cost_run_real record T-dated)"
assert_eq "cost table: a dated snapshot id of a listed model is priced (4 per million input)" '["known",true]' \
  "$(printf '%s' "$REC" | jq -c '[.status, ((.total_usd - 4) | fabs) < 0.000000001]' 2>/dev/null)"
price_doc T-edge1 t-edge1
tx_line 2026-01-01T10:00:00Z a1 r1 100000 0 0 0 claude-haiku-5-5 | tx_put proj/t-edge1.jsonl
REC="$(cost_run_real record T-edge1)"
assert_eq "cost table: a Haiku 5.5 prompt of 100000 tokens is priced at the base tier (0.01)" "true" "$(usd_close "$(printf '%s' "$REC" | jq -c '.total_usd' 2>/dev/null)" 0.01)"
price_doc T-edge2 t-edge2
tx_line 2026-01-01T10:00:00Z a1 r1 100001 0 0 0 claude-haiku-5-5 | tx_put proj/t-edge2.jsonl
REC="$(cost_run_real record T-edge2)"
assert_eq "cost table: a Haiku 5.5 prompt of 100001 tokens is priced at the long tier (0.0500005)" "true" "$(usd_close "$(printf '%s' "$REC" | jq -c '.total_usd' 2>/dev/null)" 0.0500005)"
price_doc T-fast t-fast
tx_line 2026-01-01T10:00:00Z a1 r1 1000000 0 0 0 claude-opus-5-5 | jq -c '.message.usage.speed = "fast"' | tx_put proj/t-fast.jsonl
REC="$(cost_run_real record T-fast)"
assert_eq "cost table: Opus 5.5 fast mode is priced at twice the input rate (8 per million)" '["known",true]' \
  "$(printf '%s' "$REC" | jq -c '[.status, ((.total_usd - 8) | fabs) < 0.000000001]' 2>/dev/null)"
price_doc T-search t-search
tx_line 2026-01-01T10:00:00Z a1 r1 1000000 0 0 0 claude-sonnet-5-5 | jq -c '.message.usage.server_tool_use.web_search_requests = 1' | tx_put proj/t-search.jsonl
REC="$(cost_run_real record T-search)"
assert_eq "cost table: a web-search event keeps its token cost (2) and flags the search fee" '["partial",["claude-sonnet-5-5 (web search fee)"],true]' \
  "$(printf '%s' "$REC" | jq -c '[.status, .unpriced_models, ((.total_usd - 2) | fabs) < 0.000000001]' 2>/dev/null)"
assert_eq "cost table: the default table path works from another directory with COST_RATES_FILE and CLAUDE_PLUGIN_ROOT unset" \
  "$(jq -r '.taken_on' "$COST_RATES_REAL" 2>/dev/null)" "$(printf '%s' "$REC" | jq -r '.rates.taken_on' 2>/dev/null)"

unset CLAUDE_CODE_SESSION_ID COST_STATUSLINE_CACHE_DIR COST_MULTI_INSTANCE_DIR COST_PROJECTS_DIR COST_RATES_FILE MV_LOG
cd "$JIRA_PROJECT_DIR" || exit 1

