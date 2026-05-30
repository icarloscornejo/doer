#!/usr/bin/env bash
# Smoke tests for wk plugin helper scripts.
#
# Run from anywhere:
#   bash tests/helpers.sh
#
# No external frameworks: bash + jq only. Each test runs in a fresh temp
# directory. Prints PASS / FAIL per test; exits non-zero on any failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK_SH="${REPO_ROOT}/lib/helpers/lock.sh"
INBOX_SH="${REPO_ROOT}/lib/helpers/inbox.sh"
COST_SH="${REPO_ROOT}/lib/helpers/cost.sh"
COST_TRANSCRIPT_SH="${REPO_ROOT}/lib/helpers/cost-transcript.sh"
PREFS_SH="${REPO_ROOT}/lib/helpers/preferences.sh"
EXTRACT_SH="${REPO_ROOT}/skills/load/lib/extract-acs.sh"
FIXTURES="${REPO_ROOT}/tests/fixtures/transcripts"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+ -- $2}"; }

assert() { # assert <desc> <cond-cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc" "command failed: $*"; fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to run these tests" >&2
  exit 2
fi

mk_meta() {
  mkdir -p ".doer/tickets/$1"
  cat > ".doer/tickets/$1/metadata.json" <<JSON
{"ticket_id":"$1","title":"t","branch":"b","status":"in_progress","current_stage":1,"skill_version":"6.0.0"}
JSON
}

new_workdir() {
  local d
  d="$(mktemp -d)"
  cd "$d"
}

# ---------------------------------------------------------------------------
# lock.sh
# ---------------------------------------------------------------------------
test_lock() {
  echo "## lock.sh"

  new_workdir
  bash "$LOCK_SH" acquire TEST-1 >/dev/null 2>&1
  if [ -f .doer/tickets/TEST-1/lock.json ]; then pass "lock acquire creates lock.json"
  else fail "lock acquire creates lock.json"; fi

  T1=$(jq -r .last_touched_at .doer/tickets/TEST-1/lock.json)
  sleep 1
  bash "$LOCK_SH" touch TEST-1
  T2=$(jq -r .last_touched_at .doer/tickets/TEST-1/lock.json)
  if [ "$T1" != "$T2" ]; then pass "lock touch refreshes last_touched_at"
  else fail "lock touch refreshes last_touched_at" "T1=$T1 T2=$T2"; fi

  bash "$LOCK_SH" release TEST-1
  if [ ! -f .doer/tickets/TEST-1/lock.json ]; then pass "lock release removes lock.json"
  else fail "lock release removes lock.json"; fi

  new_workdir
  WK_LOCK_TTL_SECONDS=1 bash "$LOCK_SH" acquire TEST-2 >/dev/null
  sleep 2
  if WK_LOCK_TTL_SECONDS=1 bash "$LOCK_SH" acquire TEST-2 >/dev/null 2>&1; then
    pass "lock acquire reclaims stale lock"
  else
    fail "lock acquire reclaims stale lock"
  fi

  new_workdir
  bash "$LOCK_SH" acquire TEST-3 >/dev/null
  if bash "$LOCK_SH" acquire TEST-3 >/dev/null 2>&1; then
    fail "lock acquire fails on fresh held lock"
  else
    pass "lock acquire fails on fresh held lock"
  fi
}

# ---------------------------------------------------------------------------
# inbox.sh
# ---------------------------------------------------------------------------
test_inbox() {
  echo "## inbox.sh"

  new_workdir
  mk_meta TEST-1

  ID=$(bash "$INBOX_SH" post TEST-1 --from 2 --to 4 --kind advisory --text "hello")
  COUNT=$(jq '.inbox | length' .doer/tickets/TEST-1/metadata.json)
  if [ "$COUNT" = "1" ] && [ -n "$ID" ]; then pass "inbox post creates message"
  else fail "inbox post creates message" "count=$COUNT id=$ID"; fi

  bash "$INBOX_SH" post TEST-1 --from 5 --to '*' --kind fyi --text "broadcast" >/dev/null
  bash "$INBOX_SH" post TEST-1 --from 5 --to 7 --kind fyi --text "private" >/dev/null
  LIST=$(bash "$INBOX_SH" list TEST-1 --to 4)
  COUNT=$(echo "$LIST" | jq 'length')
  if [ "$COUNT" = "2" ]; then pass "inbox list --to includes broadcast"
  else fail "inbox list --to includes broadcast" "got $COUNT"; fi

  bash "$INBOX_SH" ack TEST-1 "$ID" --by 4
  ACKED=$(jq -r --arg id "$ID" '.inbox[] | select(.id==$id) | .acked_at' .doer/tickets/TEST-1/metadata.json)
  if [ "$ACKED" != "null" ] && [ -n "$ACKED" ]; then pass "inbox ack sets acked_at"
  else fail "inbox ack sets acked_at" "acked_at=$ACKED"; fi

  bash "$INBOX_SH" clear TEST-1 --acked
  REMAINING=$(jq '.inbox | length' .doer/tickets/TEST-1/metadata.json)
  if [ "$REMAINING" = "2" ]; then pass "inbox clear --acked removes only acked"
  else fail "inbox clear --acked removes only acked" "remaining=$REMAINING"; fi
}

# ---------------------------------------------------------------------------
# cost.sh
# ---------------------------------------------------------------------------
test_cost() {
  echo "## cost.sh"

  new_workdir
  mk_meta TEST-1

  cat > rates.json <<'JSON'
{
  "currency": "USD",
  "fetched_at": "2026-05-20T00:00:00Z",
  "ttl_days": 7,
  "rates": {
    "test-known": {"input_per_mtok": 10.0, "output_per_mtok": 50.0}
  },
  "lazy_fallback": {"input_per_mtok": 3.0, "output_per_mtok": 15.0}
}
JSON
  export WK_COST_RATES_FILE="$PWD/rates.json"

  WK_COST_RATES_FILE="$WK_COST_RATES_FILE" bash "$COST_SH" record TEST-1 \
    --model test-known --input 1000000 --output 1000000 --stage 4 >/dev/null
  USD=$(jq '.cost.total_usd' .doer/tickets/TEST-1/metadata.json)
  if [ "$USD" = "60" ]; then pass "cost record known model computes USD"
  else fail "cost record known model computes USD" "got $USD expected 60"; fi

  WK_COST_RATES_FILE="$WK_COST_RATES_FILE" bash "$COST_SH" record TEST-1 \
    --model test-unknown --input 1000000 --output 1000000 --stage 4 2>warn.log >/dev/null
  UNKNOWN=$(jq '.cost.unknown_models | length' .doer/tickets/TEST-1/metadata.json)
  if [ "$UNKNOWN" = "1" ] && grep -q "unknown model" warn.log; then
    pass "cost record unknown model uses lazy_fallback and warns"
  else
    fail "cost record unknown model uses lazy_fallback and warns" "unknown=$UNKNOWN warn=$(cat warn.log)"
  fi

  TOTAL=$(WK_COST_RATES_FILE="$WK_COST_RATES_FILE" bash "$COST_SH" total TEST-1)
  if echo "$TOTAL" | jq -e '.total_usd > 0' >/dev/null; then
    pass "cost total returns aggregated object"
  else
    fail "cost total returns aggregated object" "$TOTAL"
  fi

  new_workdir
  mk_meta TEST-2
  WK_COST_DISABLED=1 WK_COST_RATES_FILE="$WK_COST_RATES_FILE" bash "$COST_SH" record TEST-2 \
    --model test-known --input 1000000 --output 1000000 >/dev/null
  COST_FIELD=$(jq '.cost // "absent"' .doer/tickets/TEST-2/metadata.json)
  if [ "$COST_FIELD" = '"absent"' ]; then pass "cost record honours WK_COST_DISABLED"
  else fail "cost record honours WK_COST_DISABLED" "cost=$COST_FIELD"; fi

  unset WK_COST_RATES_FILE
}

# ---------------------------------------------------------------------------
# extract-acs.sh
# ---------------------------------------------------------------------------
test_extract_acs() {
  echo "## extract-acs.sh"

  new_workdir

  cat > heading.md <<'MD'
# Title

## Acceptance Criteria

- AC-1 thing
- AC-2 other

## Notes
extra
MD
  OUT=$(bash "$EXTRACT_SH" heading.md)
  if echo "$OUT" | grep -q "AC-1 thing" && ! echo "$OUT" | grep -q "extra"; then
    pass "extract-acs detects markdown heading"
  else
    fail "extract-acs detects markdown heading" "out=$OUT"
  fi

  cat > bold.md <<'MD'
Some preamble.

**Acceptance Criteria**
- AC-1 alpha
- AC-2 beta

**Other Section**
ignored
MD
  OUT=$(bash "$EXTRACT_SH" bold.md)
  if echo "$OUT" | grep -q "AC-1 alpha" && ! echo "$OUT" | grep -q "ignored"; then
    pass "extract-acs detects bold label"
  else
    fail "extract-acs detects bold label" "out=$OUT"
  fi

  cat > plain.md <<'MD'
Description goes here.

AC:
- AC-1 plain
- AC-2 also
MD
  OUT=$(bash "$EXTRACT_SH" plain.md)
  if echo "$OUT" | grep -q "AC-1 plain"; then
    pass "extract-acs detects plain label"
  else
    fail "extract-acs detects plain label" "out=$OUT"
  fi

  cat > none.md <<'MD'
Just a description.

No criteria here.
MD
  OUT=$(bash "$EXTRACT_SH" none.md)
  if [ -z "$OUT" ]; then pass "extract-acs returns empty when no AC section"
  else fail "extract-acs returns empty when no AC section" "out=$OUT"; fi
}

# ---------------------------------------------------------------------------
# cost-transcript.sh
# ---------------------------------------------------------------------------
test_cost_transcript() {
  echo "## cost-transcript.sh"

  # --- rates file with cache_multipliers ---
  new_workdir
  cat > rates.json <<'JSON'
{
  "currency": "USD",
  "fetched_at": "2026-05-22T00:00:00Z",
  "ttl_days": 7,
  "cache_multipliers": {
    "creation_5m": 1.25,
    "creation_1h": 2.0,
    "read": 0.1
  },
  "rates": {
    "claude-sonnet-4-6": {"input_per_mtok": 3.0, "output_per_mtok": 15.0}
  },
  "lazy_fallback": {"input_per_mtok": 3.0, "output_per_mtok": 15.0}
}
JSON
  export WK_COST_RATES_FILE="$PWD/rates.json"

  mk_meta TEST-TR-1

  # Write session_ids into metadata.
  jq '.session_ids = ["abc123"] | .session_ids_source = "env:CLAUDE_CODE_SESSION_ID"' \
    .doer/tickets/TEST-TR-1/metadata.json > .doer/tickets/TEST-TR-1/metadata.json.tmp \
    && mv .doer/tickets/TEST-TR-1/metadata.json.tmp .doer/tickets/TEST-TR-1/metadata.json

  # Set up fake transcript directory structure.
  mkdir -p "transcripts/abc123"
  cp "${FIXTURES}/session-abc123.jsonl" "transcripts/abc123.jsonl"

  # Run reconcile using override.
  WK_TRANSCRIPT_DIR="$PWD/transcripts" \
  WK_COST_RATES_FILE="$WK_COST_RATES_FILE" \
    bash "$COST_TRANSCRIPT_SH" reconcile TEST-TR-1 2>/dev/null

  # Verify transcript_reconciled was written.
  HAS=$(jq '.cost.transcript_reconciled | type' .doer/tickets/TEST-TR-1/metadata.json)
  if [ "$HAS" = '"object"' ]; then
    pass "cost-transcript reconcile writes transcript_reconciled"
  else
    fail "cost-transcript reconcile writes transcript_reconciled" "got $HAS"
  fi

  # Verify deduplication: msg-001 appears twice in fixture; only one should be counted.
  IN_TOK=$(jq '.cost.transcript_reconciled.total_input_tokens' .doer/tickets/TEST-TR-1/metadata.json)
  # msg-001: 100 input, msg-002: 80 input. Total = 180 (not 280 if dup was counted).
  if [ "$IN_TOK" = "180" ]; then
    pass "cost-transcript deduplicates by message id"
  else
    fail "cost-transcript deduplicates by message id" "got ${IN_TOK}, expected 180"
  fi

  # Verify total_usd > 0.
  USD=$(jq '.cost.transcript_reconciled.total_usd' .doer/tickets/TEST-TR-1/metadata.json)
  if jq -n --argjson u "$USD" '$u > 0' >/dev/null 2>&1; then
    pass "cost-transcript reconcile computes total_usd > 0"
  else
    fail "cost-transcript reconcile computes total_usd > 0" "got $USD"
  fi

  # Verify session_ids_processed is populated.
  SESS_COUNT=$(jq '.cost.transcript_reconciled.session_ids_processed | length' \
    .doer/tickets/TEST-TR-1/metadata.json)
  if [ "$SESS_COUNT" = "1" ]; then
    pass "cost-transcript records session_ids_processed"
  else
    fail "cost-transcript records session_ids_processed" "count=$SESS_COUNT"
  fi

  # --- best-effort: missing session JSONL does not abort ---
  new_workdir
  cat > rates.json <<'JSON'
{
  "currency": "USD",
  "fetched_at": "2026-05-22T00:00:00Z",
  "ttl_days": 7,
  "cache_multipliers": {"creation_5m": 1.25, "creation_1h": 2.0, "read": 0.1},
  "rates": {},
  "lazy_fallback": {"input_per_mtok": 3.0, "output_per_mtok": 15.0}
}
JSON
  mk_meta TEST-TR-2
  jq '.session_ids = ["missing-session"]' \
    .doer/tickets/TEST-TR-2/metadata.json > .doer/tickets/TEST-TR-2/metadata.json.tmp \
    && mv .doer/tickets/TEST-TR-2/metadata.json.tmp .doer/tickets/TEST-TR-2/metadata.json

  mkdir -p "transcripts"
  # No JSONL for missing-session.
  if WK_TRANSCRIPT_DIR="$PWD/transcripts" WK_COST_RATES_FILE="$PWD/rates.json" \
     bash "$COST_TRANSCRIPT_SH" reconcile TEST-TR-2 >/dev/null 2>&1; then
    pass "cost-transcript exits 0 when session JSONL is missing"
  else
    fail "cost-transcript exits 0 when session JSONL is missing"
  fi

  # --- best-effort: no session_ids in metadata ---
  new_workdir
  mk_meta TEST-TR-3
  if WK_TRANSCRIPT_DIR="$PWD/transcripts" WK_COST_RATES_FILE="$PWD/rates.json" \
     bash "$COST_TRANSCRIPT_SH" reconcile TEST-TR-3 >/dev/null 2>&1; then
    pass "cost-transcript exits 0 when session_ids is empty"
  else
    fail "cost-transcript exits 0 when session_ids is empty"
  fi

  # --- WK_COST_DISABLED=1 is a no-op ---
  new_workdir
  mk_meta TEST-TR-4
  jq '.session_ids = ["abc123"]' \
    .doer/tickets/TEST-TR-4/metadata.json > .doer/tickets/TEST-TR-4/metadata.json.tmp \
    && mv .doer/tickets/TEST-TR-4/metadata.json.tmp .doer/tickets/TEST-TR-4/metadata.json
  WK_COST_DISABLED=1 WK_TRANSCRIPT_DIR="$PWD/transcripts" WK_COST_RATES_FILE="$PWD/rates.json" \
    bash "$COST_TRANSCRIPT_SH" reconcile TEST-TR-4 >/dev/null 2>&1
  HAS=$(jq '.cost.transcript_reconciled // "absent"' .doer/tickets/TEST-TR-4/metadata.json)
  if [ "$HAS" = '"absent"' ]; then
    pass "cost-transcript honours WK_COST_DISABLED"
  else
    fail "cost-transcript honours WK_COST_DISABLED" "got $HAS"
  fi

  # --- subagents layout: by_agent / by_stage from sibling meta.json ---
  new_workdir
  cat > rates.json <<'JSON'
{
  "currency": "USD",
  "fetched_at": "2026-05-22T00:00:00Z",
  "ttl_days": 7,
  "cache_multipliers": {"creation_5m": 1.25, "creation_1h": 2.0, "read": 0.1},
  "rates": {"claude-sonnet-4-6": {"input_per_mtok": 3.0, "output_per_mtok": 15.0}},
  "lazy_fallback": {"input_per_mtok": 3.0, "output_per_mtok": 15.0}
}
JSON
  export WK_COST_RATES_FILE="$PWD/rates.json"

  mk_meta TEST-TR-5
  jq '.session_ids = ["session-doer"]' \
    .doer/tickets/TEST-TR-5/metadata.json > .doer/tickets/TEST-TR-5/metadata.json.tmp \
    && mv .doer/tickets/TEST-TR-5/metadata.json.tmp .doer/tickets/TEST-TR-5/metadata.json

  # Point the transcript base at the fixtures dir (it holds session-doer/subagents/).
  WK_TRANSCRIPT_DIR="$FIXTURES" WK_COST_RATES_FILE="$WK_COST_RATES_FILE" \
    bash "$COST_TRANSCRIPT_SH" reconcile TEST-TR-5 2>/dev/null
  TR5=$(jq '.cost.transcript_reconciled' .doer/tickets/TEST-TR-5/metadata.json)

  # by_agent: code-writer (s4) and advisor:security (s5, role with a colon)
  # parsed from meta.json description prefix; the no-prefix agent falls back
  # to its agentType (Explore).
  if echo "$TR5" | jq -e '.by_agent."code-writer".usd == 0.033
                          and .by_agent."advisor:security".usd == 0.0165
                          and (.by_agent.Explore != null)' >/dev/null; then
    pass "cost-transcript by_agent attributes roles from meta.json prefix"
  else
    fail "cost-transcript by_agent attributes roles from meta.json prefix" "$(echo "$TR5" | jq -c '.by_agent')"
  fi

  # by_stage: stage 4 and 5 from the doer prefix; no-prefix agent -> unassigned.
  if echo "$TR5" | jq -e '.by_stage."4".usd == 0.033
                          and .by_stage."5".usd == 0.0165
                          and (.by_stage.unassigned != null)' >/dev/null; then
    pass "cost-transcript by_stage attributes stages from meta.json prefix"
  else
    fail "cost-transcript by_stage attributes stages from meta.json prefix" "$(echo "$TR5" | jq -c '.by_stage')"
  fi

  # acompact agent is excluded: its 99999/99999 tokens must NOT appear anywhere.
  if echo "$TR5" | jq -e '.total_input_tokens == 1700 and .total_output_tokens == 3100' >/dev/null; then
    pass "cost-transcript excludes agent-acompact-* from totals"
  else
    fail "cost-transcript excludes agent-acompact-* from totals" "in=$(echo "$TR5" | jq '.total_input_tokens') out=$(echo "$TR5" | jq '.total_output_tokens')"
  fi

  unset WK_COST_RATES_FILE
}

test_cost_status_orchestrator_only() {
  echo "## cost.sh status (orchestrator-only)"

  new_workdir
  cat > rates.json <<'JSON'
{
  "currency": "USD",
  "fetched_at": "2026-05-20T00:00:00Z",
  "ttl_days": 7,
  "rates": {"claude-opus-4-7": {"input_per_mtok": 15.0, "output_per_mtok": 75.0}},
  "lazy_fallback": {"input_per_mtok": 3.0, "output_per_mtok": 15.0}
}
JSON
  export WK_COST_RATES_FILE="$PWD/rates.json"

  mkdir -p .doer/tickets/TEST-OO/
  cat > .doer/tickets/TEST-OO/metadata.json <<'JSON'
{
  "ticket_id": "TEST-OO",
  "cost": {
    "currency": "USD",
    "rates_fetched_at": "2026-05-20T00:00:00Z",
    "total_input_tokens": 0,
    "total_output_tokens": 0,
    "total_usd": 0,
    "by_model": {},
    "by_stage": {},
    "by_agent": {},
    "unknown_models": [],
    "transcript_reconciled": {
      "reconciled_at": "2026-05-26T00:00:00Z",
      "session_ids_processed": ["s1"],
      "total_input_tokens": 12345,
      "total_output_tokens": 6789,
      "total_cache_creation_tokens": 1000,
      "total_cache_read_tokens": 500,
      "total_usd": 0.5,
      "by_model": {
        "claude-opus-4-7": {"input_tokens": 12345, "output_tokens": 6789, "cache_creation_tokens": 1000, "cache_read_tokens": 500, "usd": 0.5}
      },
      "by_agent": {
        "code-writer": {"input_tokens": 10000, "output_tokens": 5000, "cache_creation_tokens": 800, "cache_read_tokens": 400, "usd": 0.4},
        "orchestrator": {"input_tokens": 2345, "output_tokens": 1789, "cache_creation_tokens": 200, "cache_read_tokens": 100, "usd": 0.1}
      },
      "by_stage": {
        "4": {"input_tokens": 10000, "output_tokens": 5000, "cache_creation_tokens": 800, "cache_read_tokens": 400, "usd": 0.4},
        "unassigned": {"input_tokens": 2345, "output_tokens": 1789, "cache_creation_tokens": 200, "cache_read_tokens": 100, "usd": 0.1}
      },
      "delta_vs_recorded_usd": 0.5,
      "warnings": []
    }
  }
}
JSON

  OUT=$(bash "$COST_SH" status TEST-OO)
  if echo "$OUT" | grep -q "Cost Summary (from transcript)" \
     && echo "$OUT" | grep -q "By Stage (transcript)" \
     && echo "$OUT" | grep -q "By Agent (transcript)" \
     && echo "$OUT" | grep -q "code-writer" \
     && echo "$OUT" | grep -q "claude-opus-4-7"; then
    pass "cost status renders transcript breakdown when total_usd is 0"
  else
    fail "cost status renders transcript breakdown when total_usd is 0" "out=$OUT"
  fi

  if echo "$OUT" | grep -q "No cost recorded for this ticket yet"; then
    fail "cost status does not print 'No cost recorded' when transcript exists"
  else
    pass "cost status does not print 'No cost recorded' when transcript exists"
  fi

  # Sanity: the regular path still renders when total_usd > 0.
  jq '.cost.total_usd = 1.23 | .cost.total_input_tokens = 50000 | .cost.total_output_tokens = 10000 | .cost.by_stage = {"4": {"calls": 1, "input_tokens": 50000, "output_tokens": 10000, "usd": 1.23}}' \
    .doer/tickets/TEST-OO/metadata.json > .doer/tickets/TEST-OO/metadata.json.tmp \
    && mv .doer/tickets/TEST-OO/metadata.json.tmp .doer/tickets/TEST-OO/metadata.json
  OUT=$(bash "$COST_SH" status TEST-OO)
  if echo "$OUT" | grep -q "=== Cost Summary ===" \
     && echo "$OUT" | grep -q "Transcript Reconciliation" \
     && ! echo "$OUT" | grep -q "orchestrator-only"; then
    pass "cost status renders normal breakdown when total_usd > 0"
  else
    fail "cost status renders normal breakdown when total_usd > 0" "out=$OUT"
  fi

  unset WK_COST_RATES_FILE
}

test_preferences() {
  echo "## preferences.sh"

  new_workdir
  PREFS_DIR="$(pwd)/wk-prefs"
  export WK_PREFERENCES_FILE="$PREFS_DIR/preferences.json"

  RESOLVED="$(bash "$PREFS_SH" path)"
  if [ "$RESOLVED" = "$WK_PREFERENCES_FILE" ]; then
    pass "preferences honours WK_PREFERENCES_FILE override"
  else
    fail "preferences honours WK_PREFERENCES_FILE override" "got $RESOLVED"
  fi

  LOC="$(bash "$PREFS_SH" get-locale)"
  if [ "$LOC" = "en" ]; then
    pass "preferences get-locale defaults to en when file missing"
  else
    fail "preferences get-locale defaults to en when file missing" "got $LOC"
  fi

  bash "$PREFS_SH" set-locale es >/dev/null
  LOC="$(bash "$PREFS_SH" get-locale)"
  if [ "$LOC" = "es" ] && [ -f "$WK_PREFERENCES_FILE" ]; then
    pass "preferences set-locale persists locale"
  else
    fail "preferences set-locale persists locale" "got $LOC, file=$WK_PREFERENCES_FILE"
  fi

  bash "$PREFS_SH" set-flag stage4_per_task_gate true >/dev/null
  bash "$PREFS_SH" set-flag stage5_advisor_personas '["security","performance"]' >/dev/null
  GATE="$(bash "$PREFS_SH" get-flag stage4_per_task_gate)"
  PERSONAS="$(bash "$PREFS_SH" get-flag stage5_advisor_personas)"
  if [ "$GATE" = "true" ] && [ "$PERSONAS" = "security,performance" ]; then
    pass "preferences set-flag handles bool and array"
  else
    fail "preferences set-flag handles bool and array" "gate=$GATE personas=$PERSONAS"
  fi

  if jq -e '.locale == "es" and .stage4_per_task_gate == true and (.stage5_advisor_personas | length) == 2' \
       "$WK_PREFERENCES_FILE" >/dev/null 2>&1; then
    pass "preferences JSON shape valid"
  else
    fail "preferences JSON shape valid"
  fi

  ES="$(bash "$PREFS_SH" detect-locale "ok dale hazlo porfavor con esto")"
  EN="$(bash "$PREFS_SH" detect-locale "please run the test now and report")"
  if [ "$ES" = "es" ] && [ "$EN" = "en" ]; then
    pass "preferences detect-locale heuristic"
  else
    fail "preferences detect-locale heuristic" "es=$ES en=$EN"
  fi

  rm -f "$WK_PREFERENCES_FILE"
  bash "$PREFS_SH" init >/dev/null
  bash "$PREFS_SH" init >/dev/null
  if jq -e '.locale == null and .stage1_ac_self_review == true and .stage4_per_task_gate == false and (.stage5_advisor_personas | length) == 0' \
       "$WK_PREFERENCES_FILE" >/dev/null 2>&1; then
    pass "preferences init is idempotent"
  else
    fail "preferences init is idempotent"
  fi

  AC_FLAG="$(bash "$PREFS_SH" get-flag stage1_ac_self_review)"
  if [ "$AC_FLAG" = "true" ]; then
    pass "preferences default stage1_ac_self_review is true"
  else
    fail "preferences default stage1_ac_self_review is true" "got $AC_FLAG"
  fi

  unset WK_PREFERENCES_FILE
}

test_lock
test_inbox
test_cost
test_cost_transcript
test_cost_status_orchestrator_only
test_preferences
test_extract_acs

echo
echo "Results: ${PASS} passed, ${FAIL} failed."
[ "$FAIL" -eq 0 ]
