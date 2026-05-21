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
EXTRACT_SH="${REPO_ROOT}/skills/load/lib/extract-acs.sh"

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

test_lock
test_inbox
test_cost
test_extract_acs

echo
echo "Results: ${PASS} passed, ${FAIL} failed."
[ "$FAIL" -eq 0 ]
