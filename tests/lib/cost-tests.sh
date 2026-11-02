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

cost_case() { # fresh fake dirs plus an empty repo dir, cd'ed into
  COST_CASE_N=$((COST_CASE_N + 1))
  COST_ROOT="$TMPDIR_TEST/costcase-$COST_CASE_N"
  mkdir -p "$COST_ROOT/cache" "$COST_ROOT/mi" "$COST_ROOT/projects" "$COST_ROOT/repo"
  export COST_STATUSLINE_CACHE_DIR="$COST_ROOT/cache"
  export COST_MULTI_INSTANCE_DIR="$COST_ROOT/mi"
  export COST_PROJECTS_DIR="$COST_ROOT/projects"
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
tx_line() { # <ts> <message-id> <request-id> <in> <out> <cache-read> <cache-creation>
  jq -nc --arg ts "$1" --arg mid "$2" --arg rid "$3" --argjson i "$4" --argjson o "$5" --argjson cr "$6" --argjson cc "$7" \
    '{type:"assistant",timestamp:$ts,requestId:$rid,message:{id:$mid,usage:{input_tokens:$i,output_tokens:$o,cache_read_input_tokens:$cr,cache_creation_input_tokens:$cc}}}'
}
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
REC="$(cost_run record R-1)"; REC_EXIT=$?
assert_eq "cost record: exit 0" "0" "$REC_EXIT"
is_one_object "$REC" && pass "cost record: prints exactly one JSON object" || fail "cost record: prints exactly one JSON object" "got: $REC"
assert_eq "cost record: three sessions across the three sources give the exact sum" '["known",7.75]' "$(printf '%s' "$REC" | jq -c '[.status, .total_usd]' 2>/dev/null)"
assert_eq "cost record: every session id is listed with its cost" '[["s1",1.5],["s2",4.25],["s3",2]]' \
  "$(printf '%s' "$REC" | jq -c '[.sessions[] | [.id, .cost_usd]]' 2>/dev/null)"
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
REC="$(cost_run record R-2)"
assert_eq "cost record: the closing session is sampled at record time (saved 5, snapshot 12 gives 12)" '["known",12]' "$(printf '%s' "$REC" | jq -c '[.status, .total_usd]' 2>/dev/null)"
printf '%s' "$REC" > "$COST_ROOT/rec.json"
"$METADATA_SH" write R-2 '.cost = $cost[0]' --slurpfile cost "$COST_ROOT/rec.json" > /dev/null 2>&1
assert_eq "cost record: the persisted .cost equals the persisted session cost" "true" \
  "$(ticket_jq R-2 '.cost.total_usd == .cost_sessions[0].usd and .cost.total_usd == 12')"
unset CLAUDE_CODE_SESSION_ID
new_doc R-2b '{"skill_version":"7.13.0","cost_sessions":[{"id":"only","ts":"2026-01-01T00:00:00Z","usd":3}]}'
assert_eq "cost record: with no closing session id the saved values still sum" '["known",3]' \
  "$(cost_run record R-2b | jq -c '[.status, .total_usd]' 2>/dev/null)"

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
unknown_case "closing session without data" "no cost data for sess-A" U-1
new_doc U-2 '{"skill_version":"7.13.0","cost_sessions":[{"id":"gone-1","ts":"t","usd":null},{"id":"sess-A","ts":"t","usd":4}]}'
unknown_case "another session without data" "no cost data for gone-1" U-2
new_doc U-3 '{"skill_version":"7.13.0","cost_sessions":[{"id":"back-1","ts":"t","usd":8,"reset":true}]}'
unknown_case "saved reset flag" "cost counter went backwards for back-1" U-3
cost_snapshot inst sess-A 3
new_doc U-4 '{"skill_version":"7.13.0","cost_sessions":[{"id":"sess-A","ts":"t","usd":8}]}'
unknown_case "reset detected at record time" "cost counter went backwards for sess-A" U-4
COST_STATUSLINE_CACHE_DIR="$COST_ROOT/none" COST_MULTI_INSTANCE_DIR="$COST_ROOT/none" COST_PROJECTS_DIR="$COST_ROOT/none" \
  unknown_case "no source dirs exist" "no cost data for" U-1
printf 'garbage' > "$COST_MULTI_INSTANCE_DIR/bad.json"; printf '{{' > "$COST_STATUSLINE_CACHE_DIR/daily-2026-01-02.json"
rm -f "$COST_MULTI_INSTANCE_DIR/inst.json"
unknown_case "only malformed source files" "no cost data for sess-A" U-1
cost_case
export CLAUDE_CODE_SESSION_ID=sess-A
new_doc U-5 '{"skill_version":"7.13.0","cost_sessions":[{"id":"sess-A","ts":"t","usd":null}]}'
unknown_case "empty cache dir" "no cost data for sess-A" U-5
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
assert_eq "cost tokens: a corrupt transcript does not change the cost" '["known",3]' "$(printf '%s' "$REC" | jq -c '[.status, .total_usd]' 2>/dev/null)"

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
assert_eq "cost.sh: no price table or rate-like constants" "clean" \
  "$([ -f "$COST_SH" ] && { grep -qiE 'per_?million|per_?mtok|price|rate_?table|usd_per|1e6|1000000|1_000_000|opus|sonnet|haiku|0\.0000[0-9]' "$COST_SH" && echo found || echo clean; } || echo missing)"

unset CLAUDE_CODE_SESSION_ID COST_STATUSLINE_CACHE_DIR COST_MULTI_INSTANCE_DIR COST_PROJECTS_DIR MV_LOG
cd "$JIRA_PROJECT_DIR" || exit 1

