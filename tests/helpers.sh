#!/usr/bin/env bash
# Smoke tests for wk plugin helper scripts (preferences.sh + jira.sh + metadata.sh).
#
# Run from anywhere:
#   bash tests/helpers.sh
#
# No external frameworks: bash + jq only. preferences.sh runs against a temp
# global file; jira.sh and metadata.sh run against a temp project directory
# (they read/write ./.doer/... relative to cwd). Prints PASS / FAIL per test;
# exits non-zero on any failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFS_SH="${REPO_ROOT}/lib/helpers/preferences.sh"
JIRA_SH="${REPO_ROOT}/lib/helpers/jira.sh"
METADATA_SH="${REPO_ROOT}/lib/helpers/metadata.sh"
ENTRYPOINTS_SH="${REPO_ROOT}/lib/helpers/entrypoints.sh"
VOCAB_GUARD_SH="${REPO_ROOT}/lib/helpers/vocab-guard.sh"
GIT_CHECKS_SH="${REPO_ROOT}/lib/helpers/git-checks.sh"
LESSONS_SH="${REPO_ROOT}/lib/helpers/lessons.sh"
GIT_OPS_SH="${REPO_ROOT}/lib/helpers/git-ops.sh"
WORKSPACE_GUARD_SH="${REPO_ROOT}/lib/helpers/workspace-guard.sh"
STAGE_CHECKS_SH="${REPO_ROOT}/lib/helpers/stage-checks.sh"
HAR_PY="${REPO_ROOT}/lib/helpers/har.py"
AC_GRAPH_PY="${REPO_ROOT}/lib/helpers/ac-graph.py"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+ -- $2}"; }

assert_eq() { # assert_eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
export WK_PREFERENCES_FILE="$TMPDIR_TEST/preferences.json"

# --- syntax ---
bash -n "$PREFS_SH" && pass "preferences.sh parses" || fail "preferences.sh parses"
bash -n "$JIRA_SH" && pass "jira.sh parses" || fail "jira.sh parses"
bash -n "$METADATA_SH" && pass "metadata.sh parses" || fail "metadata.sh parses"
bash -n "$ENTRYPOINTS_SH" && pass "entrypoints.sh parses" || fail "entrypoints.sh parses"
bash -n "$LESSONS_SH" && pass "lessons.sh parses" || fail "lessons.sh parses"

# --- preferences.sh (locale only, global) ---
assert_eq "get-locale defaults to en (no file)" "en" "$("$PREFS_SH" get-locale)"

"$PREFS_SH" init > /dev/null
assert_eq "init creates file" "yes" "$([ -f "$WK_PREFERENCES_FILE" ] && echo yes)"
assert_eq "get-locale still en after init" "en" "$("$PREFS_SH" get-locale)"

"$PREFS_SH" set-locale es > /dev/null
assert_eq "set/get locale roundtrip" "es" "$("$PREFS_SH" get-locale)"

jq -e . "$WK_PREFERENCES_FILE" > /dev/null && pass "preferences file is valid JSON" || fail "preferences file is valid JSON"
assert_eq "preferences file has no jira key (locale-only now)" "null" "$(jq -r '.jira // "null"' "$WK_PREFERENCES_FILE")"

# --- jira.sh (per-project config, lives under cwd's ./.doer/config.json) ---
JIRA_PROJECT_DIR="$TMPDIR_TEST/project"
mkdir -p "$JIRA_PROJECT_DIR"
cd "$JIRA_PROJECT_DIR" || exit 1

CONFIG_JSON="$("$JIRA_SH" config)"
assert_eq "config: no base_url before setup" "null" "$(printf '%s' "$CONFIG_JSON" | jq -r '.base_url')"
assert_eq "config: token_env defaults to JIRA_PAT" "JIRA_PAT" "$(printf '%s' "$CONFIG_JSON" | jq -r '.token_env')"
assert_eq "config: token absent" "false" "$(printf '%s' "$CONFIG_JSON" | jq -r '.token_present')"

"$JIRA_SH" set-url "https://jira.example.com" > /dev/null
assert_eq "config reports base_url after set-url" "https://jira.example.com" "$("$JIRA_SH" config | jq -r '.base_url')"
assert_eq "config.json written under ./.doer" "yes" "$([ -f "./.doer/config.json" ] && echo yes)"

"$JIRA_SH" set-token-env "WK_TEST_JIRA_PAT" > /dev/null
assert_eq "config reports overridden token_env" "WK_TEST_JIRA_PAT" "$("$JIRA_SH" config | jq -r '.token_env')"

export WK_TEST_JIRA_PAT="dummy-token"
assert_eq "config: token present via overridden env" "true" "$("$JIRA_SH" config | jq -r '.token_present')"
unset WK_TEST_JIRA_PAT

ERR_JSON="$("$JIRA_SH" fetch ABC-1 2>/dev/null || true)"
printf '%s' "$ERR_JSON" | jq -e '.error' > /dev/null \
  && pass "fetch without token fails with JSON error" \
  || fail "fetch without token fails with JSON error" "got: $ERR_JSON"

ERR_JSON="$("$JIRA_SH" comment ABC-1 /nonexistent-file 2>/dev/null || true)"
printf '%s' "$ERR_JSON" | jq -e '.error' > /dev/null \
  && pass "comment with missing file fails with JSON error" \
  || fail "comment with missing file fails with JSON error" "got: $ERR_JSON"

export WK_TEST_JIRA_TOKEN_FOR_DETECT="dummy"
assert_eq "detect-token-env: never prints the value, only the name" "yes" \
  "$("$JIRA_SH" detect-token-env | grep -qFx 'WK_TEST_JIRA_TOKEN_FOR_DETECT' && echo yes || echo no)"
assert_eq "detect-token-env: the value never leaks into the output" "no" \
  "$("$JIRA_SH" detect-token-env | grep -q 'dummy' && echo yes || echo no)"
unset WK_TEST_JIRA_TOKEN_FOR_DETECT

printf 'See PDE-2680 and also ABC-123, mentioned twice PDE-2680 here.\n' > extract_keys_fixture.md
assert_eq "extract-keys: unique keys, sorted" '["ABC-123","PDE-2680"]' \
  "$("$JIRA_SH" extract-keys extract_keys_fixture.md | jq -c .)"
assert_eq "extract-keys: --exclude drops the named key" '["ABC-123"]' \
  "$("$JIRA_SH" extract-keys extract_keys_fixture.md --exclude PDE-2680 | jq -c .)"

cat > attach_fetch.json <<'JSON'
{"attachments":[
  {"id":"1","filename":"a.chls","url":"https://jira/att/1","size":1},
  {"id":"2","filename":"a.chls","url":"https://jira/att/2","size":1},
  {"id":"3","filename":"shot.png","url":"https://jira/att/3","size":1},
  {"id":"4","filename":"notes.pdf","url":"https://jira/att/4","size":1}
]}
JSON
printf 'Repro in [^a.chls] and also [^missing.chls] for another run.\n' > attach_ticket.md
ATTACH_JSON="$("$JIRA_SH" attachments attach_fetch.json attach_ticket.md)"
assert_eq "attachments: matches the bugfix.json schema field set" "yes" \
  "$(printf '%s' "$ATTACH_JSON" | jq '[.[0] | keys] == [["converted","done","filename","har","jira_url","kind","path","source"]]' | grep -q true && echo yes || echo no)"
assert_eq "attachments: kind by extension" '["charles","charles","screenshot","other"]' \
  "$(printf '%s' "$ATTACH_JSON" | jq -c '[.[0:4][].kind]')"
assert_eq "attachments: colliding filenames dedupe with a -2 suffix" '["charles/a.chls","charles/a-2.chls"]' \
  "$(printf '%s' "$ATTACH_JSON" | jq -c '[.[0,1].path]')"
assert_eq "attachments: a .chls mentioned but not fetched is source=mentioned, jira_url=null" "true" \
  "$(printf '%s' "$ATTACH_JSON" | jq 'any(.[]; .filename == "missing.chls" and .source == "mentioned" and .jira_url == null)')"
assert_eq "attachments: total entries (2 a.chls dupes + shot.png + notes.pdf + missing.chls mentioned)" "5" \
  "$(printf '%s' "$ATTACH_JSON" | jq 'length')"
assert_eq "attachments: a .chls both fetched and mentioned gets no extra 'mentioned' entry" "0" \
  "$(printf '%s' "$ATTACH_JSON" | jq '[.[] | select(.filename == "a.chls" and .source == "mentioned")] | length')"

# --- cross-scope invariant: jira writes (per-project) never touch locale (global) ---
assert_eq "locale survives jira writes" "es" "$("$PREFS_SH" get-locale)"

# --- metadata.sh (per-ticket state file, lives under ./.doer/tickets/<ID>/) ---
# Still in $JIRA_PROJECT_DIR (cwd-relative, same convention as jira.sh).
TARGET_PATH="./.doer/tickets/T-1/metadata.json"

echo '{"a": 1, "b": 2}' | "$METADATA_SH" init T-1 > /dev/null
assert_eq "init creates the file" "yes" "$([ -f "$TARGET_PATH" ] && echo yes)"
assert_eq "init: content roundtrip" "1 2" "$(jq -r '"\(.a) \(.b)"' "$TARGET_PATH")"

echo '{"a": 9}' | "$METADATA_SH" init T-1 > /dev/null 2>/dev/null
assert_eq "init refuses when file already exists" "1 2" "$(jq -r '"\(.a) \(.b)"' "$TARGET_PATH")"

echo 'not json' | "$METADATA_SH" init T-2 > /dev/null 2>/dev/null
assert_eq "init refuses invalid JSON, no file created" "no" "$([ -f "./.doer/tickets/T-2/metadata.json" ] && echo yes || echo no)"

"$METADATA_SH" write T-1 '.a = 99 | .c = "new"' > /dev/null
assert_eq "write: single call batches multiple fields" "99 2 new" "$(jq -r '"\(.a) \(.b) \(.c)"' "$TARGET_PATH")"

BEFORE_CONTENT="$(cat "$TARGET_PATH")"
"$METADATA_SH" write T-1 '.a | invalidfn' > /dev/null 2>/dev/null
AFTER_CONTENT="$(cat "$TARGET_PATH")"
assert_eq "write: failed jq filter leaves file byte-identical" "$BEFORE_CONTENT" "$AFTER_CONTENT"
assert_eq "write: failed jq filter leaves no tmp leftover" "" "$(find "./.doer/tickets/T-1" -name '*.tmp.*' 2>/dev/null)"

# Regression: macOS's system /bin/bash is 3.2, where expanding an empty
# array under `set -u` throws "unbound variable" (bash >=4 doesn't). The rest
# of this suite runs under $PATH's bash (usually a newer Homebrew build),
# which never exercises that path -- exercise /bin/bash explicitly for the
# commands whose ARGS end up empty (init/read/path take no jq-args).
if [ -x /bin/bash ]; then
  echo '{"regress": true}' | /bin/bash "$METADATA_SH" init T-3 > /dev/null 2>&1
  assert_eq "bash 3.2: init with empty ARGS does not throw unbound variable" "yes" "$([ -f "./.doer/tickets/T-3/metadata.json" ] && echo yes || echo no)"
  /bin/bash "$METADATA_SH" read T-3 > /dev/null 2>&1
  READ_EXIT=$?
  assert_eq "bash 3.2: read with empty ARGS does not throw unbound variable" "0" "$READ_EXIT"
fi

echo '{"x": 1}' | "$METADATA_SH" init T-1 --file bugfix.json > /dev/null
assert_eq "init --file creates the alternate filename" "yes" "$([ -f "./.doer/tickets/T-1/bugfix.json" ] && echo yes)"
"$METADATA_SH" write T-1 '.x = 2' --file bugfix.json > /dev/null
assert_eq "write --file roundtrip on the alternate filename" "2" "$(jq -r '.x' "./.doer/tickets/T-1/bugfix.json")"
assert_eq "default filename untouched by --file writes" "99" "$(jq -r '.a' "$TARGET_PATH")"

FAKE_MV_DIR="$TMPDIR_TEST/fakebin"
mkdir -p "$FAKE_MV_DIR"
cat > "$FAKE_MV_DIR/mv" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_MV_DIR/mv"
BEFORE_CONTENT="$(cat "$TARGET_PATH")"
LOCK_ERR="$(PATH="$FAKE_MV_DIR:$PATH" "$METADATA_SH" write T-1 '.a = 1' 2>&1 >/dev/null)"
LOCK_EXIT=$?
AFTER_CONTENT="$(cat "$TARGET_PATH")"
assert_eq "simulated lock: exit code 2" "2" "$LOCK_EXIT"
assert_eq "simulated lock: original file untouched" "$BEFORE_CONTENT" "$AFTER_CONTENT"
assert_eq "simulated lock: no tmp leftover" "" "$(find "./.doer/tickets/T-1" -name '*.tmp.*' 2>/dev/null)"
printf '%s' "$LOCK_ERR" | grep -qi "EDR\|Console.app" \
  && pass "simulated lock: error message points at EDR/Console.app" \
  || fail "simulated lock: error message points at EDR/Console.app" "got: $LOCK_ERR"

# --- metadata.sh write --require / check-required / version-check / status / list ---
echo '{"stages":{"3":{"status":"pending"}}}' | "$METADATA_SH" init T-4 > /dev/null
BEFORE_T4="$(cat ./.doer/tickets/T-4/metadata.json)"
"$METADATA_SH" write T-4 '.stages["3"].status = "complete"' --require 3:complete > /dev/null 2>&1
assert_eq "write --require: incomplete transition is refused, exit 1" "1" "$?"
assert_eq "write --require: refused transition leaves the file byte-identical" "$BEFORE_T4" "$(cat ./.doer/tickets/T-4/metadata.json)"
assert_eq "write --require: refused transition leaves no tmp leftover" "" "$(find ./.doer/tickets/T-4 -name '*.tmp.*' 2>/dev/null)"

"$METADATA_SH" write T-4 '.stages["3"].status = "complete" | .stages["3"].completed_at = "t" | .stages["3"].iterations = 1 | .stages["3"].loop_outcome = "converged" | .last_green_sha = "sha"' --require 3:complete > /dev/null
assert_eq "write --require: complete transition succeeds and swaps" "0" "$?"
assert_eq "write --require: the transformed fields actually landed" "complete" "$(jq -r '.stages["3"].status' ./.doer/tickets/T-4/metadata.json)"

"$METADATA_SH" write T-4 '.untracked_field = "still works"' > /dev/null
assert_eq "write without --require: unchanged behavior, no validation" "0" "$?"
assert_eq "write without --require: the field landed" "still works" "$(jq -r '.untracked_field' ./.doer/tickets/T-4/metadata.json)"

CHECK_OUT="$(printf '{"stages":{"4":{"status":"skipped","completed_at":"t","skipped_reason":"docs only"}}}' | "$METADATA_SH" check-required 4 skipped -)"
assert_eq "check-required: reports the one missing field" '{"missing":["stages.4.skipped_acknowledged_by"]}' "$CHECK_OUT"
printf '{"stages":{"4":{"status":"skipped","completed_at":"t","skipped_reason":"docs only","skipped_acknowledged_by":"dev"}}}' \
  | "$METADATA_SH" check-required 4 skipped - > /dev/null 2>&1
assert_eq "check-required: complete document exits 0" "0" "$?"
printf '{"stages":{"4":{"status":"skipped","skipped_acknowledged_by":"someone-else"}}}' \
  | "$METADATA_SH" check-required 4 skipped - > /dev/null 2>&1
assert_eq "check-required: wrong skipped_acknowledged_by value is refused" "1" "$?"

echo '{"skill_version":"7.9.0"}' | "$METADATA_SH" init T-5 > /dev/null
assert_eq "version-check: same MAJOR is compatible" "compatible" "$("$METADATA_SH" version-check T-5 7.2.5)"
"$METADATA_SH" version-check T-5 6.9.0 > /dev/null 2>&1
assert_eq "version-check: different MAJOR exits 1" "1" "$?"
assert_eq "version-check: message names both versions" "incompatible 7.9.0 vs 6.9.0" "$("$METADATA_SH" version-check T-5 6.9.0 2>&1 || true)"

echo '{"ticket_id":"T-6","title":"Fix timeout","branch":"T-6-fix","status":"in_progress","current_stage":3,
  "stages":{"1":{"status":"complete"},"2":{"status":"complete"},"3":{"status":"in_progress"},"4":{"status":"pending"},"5":{"status":"pending"}},
  "code_review":[{"iteration":1,"blockers":[{"id":"B-1","text":"x"}]}]}' | "$METADATA_SH" init T-6 > /dev/null
STATUS_OUT="$("$METADATA_SH" status T-6)"
printf '%s' "$STATUS_OUT" | grep -qFx "Current Stage: 3  (build)" \
  && pass "status: renders the current stage and its name" || fail "status: renders the current stage and its name" "got: $STATUS_OUT"
printf '%s' "$STATUS_OUT" | grep -qFx "  [x] 1 ac" \
  && pass "status: a complete stage is marked [x]" || fail "status: a complete stage is marked [x]"
printf '%s' "$STATUS_OUT" | grep -qFx "  [ ] 5 wrapup" \
  && pass "status: a pending stage is marked [ ]" || fail "status: a pending stage is marked [ ]"
printf '%s' "$STATUS_OUT" | grep -qFx "Blockers: 1 open" \
  && pass "status: counts open blockers from the last code_review entry" || fail "status: counts open blockers from the last code_review entry" "got: $STATUS_OUT"

mkdir -p ./.doer/tickets/T-7
echo '{"ticket_id":"T-7","title":"Crash","status":"in_progress","current_stage":4,"stages":{"0":"complete","1":"complete","2":"complete","3":"complete","4":"in_progress","5":"pending","6":"pending"}}' \
  > ./.doer/tickets/T-7/bugfix.json
BUGFIX_STATUS="$("$METADATA_SH" status T-7)"
printf '%s' "$BUGFIX_STATUS" | grep -qFx "Current Stage: 4  (verdict)" \
  && pass "status: auto-detects bugfix.json and uses its stage names" || fail "status: auto-detects bugfix.json and uses its stage names" "got: $BUGFIX_STATUS"

LIST_OUT="$("$METADATA_SH" list)"
printf '%s' "$LIST_OUT" | grep -q '^T-6 ' && printf '%s' "$LIST_OUT" | grep -q 'doer' \
  && pass "list: includes a doer ticket" || fail "list: includes a doer ticket" "got: $LIST_OUT"
printf '%s' "$LIST_OUT" | grep -q '^T-7 ' && printf '%s' "$LIST_OUT" | grep -q 'bugfix' \
  && pass "list: includes a bugfix ticket" || fail "list: includes a bugfix ticket" "got: $LIST_OUT"

# --- metadata.sh: Stage 4 verify evidence (check-required 4 complete, write --require, status) ---
# A complete Stage 4 must carry per-criterion evidence, anomalies, rationale,
# a closed-vocab recommendation, and explicit acceptance of unexercised criteria.
GOOD_STAGE4_DOC='{"ac":{"in_scope":["AC-1","AC-2"]},"stages":{"4":{"status":"complete","completed_at":"t","ac_verdicts":{"AC-1":"PASS","AC-2":"PASS"},"recommendation":"APPROVE","evidence":{"AC-1":"line one","AC-2":"line two"},"anomalies":[],"rationale":"all good"}}}'

# check_stage4 <desc> <expected-exit> <needle-or-empty> <jq-modifier>
# Applies the modifier to the good doc, runs check-required 4 complete, asserts
# the exit code, and (when a needle is given) that the output names that path
# and is not the generic internal jq failure.
check_stage4() {
  local desc="$1" expected_exit="$2" needle="$3" modifier="$4" output exit_code
  output="$(printf '%s' "$GOOD_STAGE4_DOC" | jq -c "$modifier" | "$METADATA_SH" check-required 4 complete - 2>&1)"
  exit_code=$?
  assert_eq "stage4 check: $desc: exit code" "$expected_exit" "$exit_code"
  if [ -n "$needle" ]; then
    if printf '%s' "$output" | grep -qF -- "$needle" && ! printf '%s' "$output" | grep -qF "<internal: jq failed>"; then
      pass "stage4 check: $desc: names $needle"
    else
      fail "stage4 check: $desc: names $needle" "got: $output"
    fi
  fi
}

check_stage4 "the good document passes" 0 "" '.'
check_stage4 "missing evidence" 1 "stages.4.evidence" 'del(.stages["4"].evidence)'
check_stage4 "missing anomalies" 1 "stages.4.anomalies" 'del(.stages["4"].anomalies)'
check_stage4 "missing rationale" 1 "stages.4.rationale" 'del(.stages["4"].rationale)'
check_stage4 "empty anomalies array is present enough" 0 "" '.stages["4"].anomalies = []'
check_stage4 "anomalies as a string is refused" 1 "stages.4.anomalies" '.stages["4"].anomalies = "none"'

# recommendation and verdict vocabulary
check_stage4 "missing recommendation" 1 "stages.4.recommendation" 'del(.stages["4"].recommendation)'
check_stage4 "lowercase recommendation" 1 "stages.4.recommendation" '.stages["4"].recommendation = "approve"'
check_stage4 "unknown recommendation" 1 "stages.4.recommendation" '.stages["4"].recommendation = "SHIP_IT"'
check_stage4 "lowercase verdict value" 1 "stages.4.ac_verdicts.AC-1" '.stages["4"].ac_verdicts["AC-1"] = "pass"'
check_stage4 "in-scope criterion missing from verdicts" 1 "stages.4.ac_verdicts.AC-2" 'del(.stages["4"].ac_verdicts["AC-2"])'
check_stage4 "in-scope item with trailing text is matched by its id" 0 "" '.ac.in_scope = ["AC-1 : x"] | .stages["4"].ac_verdicts = {"AC-1":"PASS"}'
check_stage4 "in-scope item with trailing text still reports a missing id" 1 "stages.4.ac_verdicts.AC-2" '.ac.in_scope = ["AC-1 : x","AC-2 : y"] | .stages["4"].ac_verdicts = {"AC-1":"PASS"}'
check_stage4 "non-string in-scope item is refused by name, not an internal failure" 1 "ac.in_scope" '.ac.in_scope = ["AC-1", 7]'

# PASS and FAIL need evidence; NOT_EXERCISED does not
check_stage4 "PASS without evidence entry" 1 "stages.4.evidence.AC-1" 'del(.stages["4"].evidence["AC-1"])'
check_stage4 "PASS with null evidence" 1 "stages.4.evidence.AC-1" '.stages["4"].evidence["AC-1"] = null'
check_stage4 "PASS with blank evidence" 1 "stages.4.evidence.AC-1" '.stages["4"].evidence["AC-1"] = "   "'
check_stage4 "PASS with empty evidence" 1 "stages.4.evidence.AC-1" '.stages["4"].evidence["AC-1"] = ""'
check_stage4 "FAIL without evidence entry" 1 "stages.4.evidence.AC-1" '.stages["4"].ac_verdicts["AC-1"] = "FAIL" | del(.stages["4"].evidence["AC-1"])'
check_stage4 "FAIL with null evidence" 1 "stages.4.evidence.AC-1" '.stages["4"].ac_verdicts["AC-1"] = "FAIL" | .stages["4"].evidence["AC-1"] = null'
check_stage4 "FAIL with blank evidence" 1 "stages.4.evidence.AC-1" '.stages["4"].ac_verdicts["AC-1"] = "FAIL" | .stages["4"].evidence["AC-1"] = "\n "'
check_stage4 "evidence entry that is not a string is refused" 1 "stages.4.evidence.AC-1" '.stages["4"].evidence["AC-1"] = 5'
NOT_EXERCISED_ACCEPTED='.stages["4"].ac_verdicts["AC-2"] = "NOT_EXERCISED" | del(.stages["4"].evidence["AC-2"]) | .stages["4"].accepted_not_exercised = [{"ac":"AC-2","reason":"no device available"}]'
check_stage4 "unexercised criterion needs no evidence when accepted" 0 "" "$NOT_EXERCISED_ACCEPTED"

# unexercised criteria need an explicit acceptance with a reason
NOT_EXERCISED_BASE='.stages["4"].ac_verdicts["AC-2"] = "NOT_EXERCISED" | del(.stages["4"].evidence["AC-2"])'
check_stage4 "unexercised and unaccepted with APPROVE is refused" 1 "stages.4.accepted_not_exercised.AC-2" "$NOT_EXERCISED_BASE"
check_stage4 "unexercised with empty acceptance list is refused" 1 "stages.4.accepted_not_exercised.AC-2" "$NOT_EXERCISED_BASE | .stages[\"4\"].accepted_not_exercised = []"
check_stage4 "unexercised with blank acceptance reason is refused" 1 "stages.4.accepted_not_exercised.AC-2" "$NOT_EXERCISED_BASE | .stages[\"4\"].accepted_not_exercised = [{\"ac\":\"AC-2\",\"reason\":\"  \"}]"
check_stage4 "unexercised with missing acceptance reason is refused" 1 "stages.4.accepted_not_exercised.AC-2" "$NOT_EXERCISED_BASE | .stages[\"4\"].accepted_not_exercised = [{\"ac\":\"AC-2\"}]"
check_stage4 "acceptance for a different criterion does not cover this one" 1 "stages.4.accepted_not_exercised.AC-2" "$NOT_EXERCISED_BASE | .stages[\"4\"].accepted_not_exercised = [{\"ac\":\"AC-1\",\"reason\":\"fine\"}]"
check_stage4 "null acceptance list counts as absent" 1 "stages.4.accepted_not_exercised.AC-2" "$NOT_EXERCISED_BASE | .stages[\"4\"].accepted_not_exercised = null"

# override: required (object, non-blank reason) when recommendation is not APPROVE
check_stage4 "APPROVE with explicit null override and null acceptance list passes" 0 "" '.stages["4"].override = null | .stages["4"].accepted_not_exercised = null'
check_stage4 "APPROVE with string override is refused" 1 "stages.4.override" '.stages["4"].override = "yes"'
check_stage4 "APPROVE with override lacking a reason is refused" 1 "stages.4.override.reason" '.stages["4"].override = {"reason":"  "}'
check_stage4 "NEED_MORE_DATA without override is refused" 1 "stages.4.override.reason" '.stages["4"].recommendation = "NEED_MORE_DATA"'
check_stage4 "RETURN_TO_BUILD with blank override reason is refused" 1 "stages.4.override.reason" '.stages["4"].recommendation = "RETURN_TO_BUILD" | .stages["4"].override = {"reason":" "}'
check_stage4 "RETURN_TO_BUILD with null override is refused" 1 "stages.4.override.reason" '.stages["4"].recommendation = "RETURN_TO_BUILD" | .stages["4"].override = null'
check_stage4 "NEED_MORE_DATA with string override is refused" 1 "stages.4.override" '.stages["4"].recommendation = "NEED_MORE_DATA" | .stages["4"].override = "yes"'
check_stage4 "NEED_MORE_DATA with an override reason passes" 0 "" '.stages["4"].recommendation = "NEED_MORE_DATA" | .stages["4"].override = {"reason":"dev accepts"}'
check_stage4 "override with an accepted unexercised criterion passes" 0 "" "$NOT_EXERCISED_ACCEPTED | .stages[\"4\"].recommendation = \"NEED_MORE_DATA\" | .stages[\"4\"].override = {\"reason\":\"dev accepts\"}"
check_stage4 "override with an unaccepted unexercised criterion is refused" 1 "stages.4.accepted_not_exercised.AC-2" "$NOT_EXERCISED_BASE | .stages[\"4\"].recommendation = \"NEED_MORE_DATA\" | .stages[\"4\"].override = {\"reason\":\"dev accepts\"}"

# type guards name the bad path instead of an internal jq failure
check_stage4 "evidence as an array is refused" 1 "stages.4.evidence" '.stages["4"].evidence = ["a"]'
check_stage4 "ac_verdicts as an array is refused" 1 "stages.4.ac_verdicts" '.stages["4"].ac_verdicts = ["PASS"]'
check_stage4 "accepted_not_exercised as an object is refused" 1 "stages.4.accepted_not_exercised" '.stages["4"].accepted_not_exercised = {"ac":"AC-2","reason":"x"}'
check_stage4 "accepted_not_exercised with a non-object item is refused" 1 "stages.4.accepted_not_exercised" '.stages["4"].accepted_not_exercised = ["AC-2"]'

# a wrongly typed stages.4 must not break other stages' checks
STAGE5_FIELDS='{"completed_at":"t"}'
for odd_stage4 in '"garbage"' '{"status":"complete","evidence":["a"],"ac_verdicts":["x"],"anomalies":"none","accepted_not_exercised":{"a":1},"override":"yes"}' '{"status":"complete","recommendation":"NEED_MORE_DATA"}'; do
  printf '{"ac":{"in_scope":[7]},"summary":"s","commit_message":"c","pr_description":"p","cost":{"status":"unknown"},"stages":{"4":%s,"5":%s}}' "$odd_stage4" "$STAGE5_FIELDS" \
    | "$METADATA_SH" check-required 5 complete - > /dev/null 2>&1
  assert_eq "stage4 check: odd stages.4 still passes check-required 5 complete ($odd_stage4)" "0" "$?"
done

# write --require 4:complete: refusal leaves the file untouched; a good write lands in one step
STAGE4_FILTER='.stages["4"] = {status:"complete",completed_at:"t",ac_verdicts:$v[0].ac_verdicts,recommendation:$v[0].recommendation,evidence:$v[0].evidence,anomalies:$v[0].anomalies,rationale:$v[0].rationale}'
printf '{"ac":{"in_scope":["AC-1","AC-2"]},"stages":{"4":{"status":"in_progress"}}}' | "$METADATA_SH" init T-8 > /dev/null
STAGE4_BEFORE="$(cat ./.doer/tickets/T-8/metadata.json)"
jq -n '{ac_verdicts:{"AC-1":"PASS","AC-2":"PASS"},recommendation:"APPROVE",evidence:{"AC-1":"only one"},anomalies:[],rationale:"r"}' > "$TMPDIR_TEST/stage4-bad.json"
"$METADATA_SH" write T-8 "$STAGE4_FILTER" --slurpfile v "$TMPDIR_TEST/stage4-bad.json" --require 4:complete > /dev/null 2>&1
assert_eq "stage4 write: evidence missing for a PASS criterion is refused, exit 1" "1" "$?"
assert_eq "stage4 write: refusal leaves the file byte-identical" "$STAGE4_BEFORE" "$(cat ./.doer/tickets/T-8/metadata.json)"

TRICKY_EVIDENCE="it's \"quoted\" \\(env.HOME) \${x} \$(echo no)"
jq -n --arg tricky "$TRICKY_EVIDENCE" '{ac_verdicts:{"AC-1":"PASS","AC-2":"PASS"},recommendation:"APPROVE",evidence:{"AC-1":$tricky,"AC-2":"fine"},anomalies:["odd (redacted)"],rationale:"because"}' > "$TMPDIR_TEST/stage4-good.json"
"$METADATA_SH" write T-8 "$STAGE4_FILTER" --slurpfile v "$TMPDIR_TEST/stage4-good.json" --require 4:complete > /dev/null 2>&1
assert_eq "stage4 write: a complete payload via --slurpfile succeeds" "0" "$?"
assert_eq "stage4 write: evidence with quotes and interpolation text is stored byte for byte" "$TRICKY_EVIDENCE" "$(jq -r '.stages["4"].evidence["AC-1"]' ./.doer/tickets/T-8/metadata.json)"
assert_eq "stage4 write: every Stage 4 field lands in the one write" "true" \
  "$(jq '.stages["4"] | (.status == "complete") and (.evidence | length == 2) and (.anomalies | length == 1) and (.rationale == "because") and (.recommendation == "APPROVE")' ./.doer/tickets/T-8/metadata.json)"

# status: evidence block for a complete doer Stage 4
STATUS_STAGE4_OUT="$("$METADATA_SH" status T-8)"
STATUS_STAGE4_EXIT=$?
assert_eq "stage4 status: complete Stage 4 exits 0" "0" "$STATUS_STAGE4_EXIT"
for expected_fragment in "Verify evidence:" "AC-2" "fine" "odd (redacted)" "because" "PASS"; do
  printf '%s' "$STATUS_STAGE4_OUT" | grep -qF -- "$expected_fragment" \
    && pass "stage4 status: complete Stage 4 prints '$expected_fragment'" \
    || fail "stage4 status: complete Stage 4 prints '$expected_fragment'" "got: $STATUS_STAGE4_OUT"
done

printf '{"ticket_id":"T-12","stages":{"4":{"status":"complete","completed_at":"t","ac_verdicts":{"AC-1":"NOT_EXERCISED"},"recommendation":"APPROVE","evidence":{},"anomalies":[],"rationale":"r","accepted_not_exercised":[{"ac":"AC-1","reason":"no device today"}]}}}' | "$METADATA_SH" init T-12 > /dev/null
printf '%s' "$("$METADATA_SH" status T-12)" | grep -qF "no device today" \
  && pass "stage4 status: prints accepted_not_exercised reasons" || fail "stage4 status: prints accepted_not_exercised reasons"

printf '{"ticket_id":"T-9","stages":{"4":{"status":"complete","completed_at":"t","ac_verdicts":{"AC-1":"PASS"}}}}' | "$METADATA_SH" init T-9 > /dev/null
LEGACY_STATUS_OUT="$("$METADATA_SH" status T-9 2>&1)"
assert_eq "stage4 status: legacy complete Stage 4 exits 0" "0" "$("$METADATA_SH" status T-9 > /dev/null 2>&1; echo $?)"
printf '%s' "$LEGACY_STATUS_OUT" | grep -qF "(none recorded)" \
  && pass "stage4 status: legacy complete Stage 4 prints (none recorded)" || fail "stage4 status: legacy complete Stage 4 prints (none recorded)" "got: $LEGACY_STATUS_OUT"

printf '{"ticket_id":"T-10","stages":{"4":{"status":"complete","completed_at":"t","ac_verdicts":{"AC-1":"PASS"},"evidence":{"AC-1":"e"},"anomalies":{"k":"v"},"rationale":{"x":1}}}}' | "$METADATA_SH" init T-10 > /dev/null
"$METADATA_SH" status T-10 > /dev/null 2>&1
assert_eq "stage4 status: object-valued anomalies and rationale do not break status" "0" "$?"

mkdir -p ./.doer/tickets/T-11
echo '{"ticket_id":"T-11","title":"Crash","status":"in_progress","current_stage":4,"stages":{"0":"complete","4":"complete"}}' > ./.doer/tickets/T-11/bugfix.json
BUGFIX_COMPLETE_OUT="$("$METADATA_SH" status T-11 2>&1)"
assert_eq "stage4 status: bugfix.json with complete string stage exits 0" "0" "$("$METADATA_SH" status T-11 > /dev/null 2>&1; echo $?)"
printf '%s' "$BUGFIX_COMPLETE_OUT" | grep -qF "Ticket: T-11" \
  && pass "stage4 status: bugfix.json still prints the normal summary" || fail "stage4 status: bugfix.json still prints the normal summary" "got: $BUGFIX_COMPLETE_OUT"
printf '%s' "$BUGFIX_COMPLETE_OUT" | grep -qF "Verify evidence:" \
  && fail "stage4 status: bugfix.json prints no evidence block" || pass "stage4 status: bugfix.json prints no evidence block"

printf '{"ticket_id":"T-13","stages":{"4":{"status":"skipped","completed_at":"t","skipped_reason":"docs","skipped_acknowledged_by":"dev"}}}' | "$METADATA_SH" init T-13 > /dev/null
SKIPPED_STATUS_OUT="$("$METADATA_SH" status T-13 2>&1)"
assert_eq "stage4 status: skipped Stage 4 exits 0" "0" "$("$METADATA_SH" status T-13 > /dev/null 2>&1; echo $?)"
printf '%s' "$SKIPPED_STATUS_OUT" | grep -qF "Verify evidence:" \
  && fail "stage4 status: skipped Stage 4 prints no evidence block" || pass "stage4 status: skipped Stage 4 prints no evidence block"

# --- static jq 1.6 compatibility of the jq programs inside metadata.sh ---
# metadata.sh wraps each jq program in marker comments:
#   # jq-compat:begin missing_fields   ...   # jq-compat:end
#   # jq-compat:begin status           ...   # jq-compat:end
# extract_jq_part prints the lines strictly between a begin marker and the next
# end marker. No grep -P: BSD grep must work.
extract_jq_part() { # extract_jq_part <part-name> [file, default metadata.sh]
  awk -v part="$1" '
    $0 ~ ("# jq-compat:begin " part "([[:space:]]|$)") { inside = 1; next }
    inside && /# jq-compat:end/ { inside = 0; next }
    inside { print }
  ' "${2:-$METADATA_SH}"
}

# list_jq_parts <file>: names of every jq-compat part in a script, one per line.
list_jq_parts() {
  awk '{ for (i = 1; i < NF; i++) if ($i == "jq-compat:begin") print $(i + 1) }' "$1"
}

# jq_compat_problems <jq-text>: prints one line per problem; empty output means compatible.
jq_compat_problems() {
  local jq_text="$1" if_count else_count
  [ -n "$(printf '%s' "$jq_text" | tr -d '[:space:]')" ] || { echo "no jq text extracted"; return; }
  if_count="$(printf '%s\n' "$jq_text" | grep -owE 'if' | wc -l | tr -d ' ')"
  else_count="$(printf '%s\n' "$jq_text" | grep -owE 'else' | wc -l | tr -d ' ')"
  [ "$if_count" = "$else_count" ] || echo "if/else mismatch: $if_count if vs $else_count else"
  printf '%s\n' "$jq_text" | grep -qE '[]A-Za-z0-9_")?]\.\[' && echo "dot before index"
  printf '%s\n' "$jq_text" | grep -qwE 'pick|abs|toarray|trim|ltrim|rtrim|have_decnum' && echo "jq 1.7-only builtin"
  printf '%s\n' "$jq_text" | grep -qF '@base32d' && echo "jq 1.7-only builtin @base32d"
  return 0
}

for bad_jq_sample in '.a.[k]' '.stages["4"].["x"]' '$x.[k]' 'if $x then ["p"] end' 'pick(.a)'; do
  assert_eq "jq-compat checker rejects the sample: $bad_jq_sample" "rejected" \
    "$([ -n "$(jq_compat_problems "$bad_jq_sample")" ] && echo rejected || echo accepted)"
done
assert_eq "jq-compat checker accepts ltrimstr" "accepted" \
  "$([ -z "$(jq_compat_problems 'ltrimstr("a") | rtrimstr("b")')" ] && echo accepted || echo rejected)"

for jq_part in missing_fields status; do
  JQ_PART_TEXT="$(extract_jq_part "$jq_part")"
  JQ_PART_PROBLEMS="$(jq_compat_problems "$JQ_PART_TEXT")"
  assert_eq "metadata.sh $jq_part jq text is jq 1.6 compatible" "" "$JQ_PART_PROBLEMS"
  assert_eq "jq-compat checker rejects the $jq_part text with an injected dot-before-index" "rejected" \
    "$([ -n "$(printf '%s' "$JQ_PART_TEXT" | grep -q . && jq_compat_problems "$JQ_PART_TEXT"' | .a.[0]')" ] && echo rejected || echo accepted)"
done

# --- DOER-3 cost per ticket: cost.sh + metadata.sh cost integration ---
# Kept in its own file (sourced, so it shares pass/fail/assert_eq, the jq-compat
# helpers above and the counters) to keep this file navigable.
# shellcheck source=lib/cost-tests.sh
. "${REPO_ROOT}/tests/lib/cost-tests.sh"

# --- lessons.sh prune ---
LESSONS_TEST_DIR="$TMPDIR_TEST/lessons"
mkdir -p "$LESSONS_TEST_DIR"
cat > "$LESSONS_TEST_DIR/old-one.md" <<'EOF'
---
slug: old-one
skill_version: "6.9.0"
---
body
EOF
cat > "$LESSONS_TEST_DIR/no-version.md" <<'EOF'
---
slug: no-version
---
body
EOF
cat > "$LESSONS_TEST_DIR/current.md" <<'EOF'
---
slug: current
skill_version: "7.5.0"
---
body
EOF
PRUNE_OUT="$(WK_LESSONS_DIR="$LESSONS_TEST_DIR" "$LESSONS_SH" prune 7)"
assert_eq "lessons prune: removes the stale-MAJOR lesson" "no" "$([ -f "$LESSONS_TEST_DIR/old-one.md" ] && echo yes || echo no)"
assert_eq "lessons prune: removes the lesson with no skill_version field" "no" "$([ -f "$LESSONS_TEST_DIR/no-version.md" ] && echo yes || echo no)"
assert_eq "lessons prune: keeps the current-MAJOR lesson" "yes" "$([ -f "$LESSONS_TEST_DIR/current.md" ] && echo yes || echo no)"
printf '%s' "$PRUNE_OUT" | grep -q '^PRUNED old-one 6.9.0$' \
  && pass "lessons prune: reports the pruned slug and its old version" || fail "lessons prune: reports the pruned slug and its old version" "got: $PRUNE_OUT"

# --- entrypoints.sh (per-repo store, lives under ./.doer/entry-points.json) ---
ENTRYPOINTS_PROJECT_DIR="$TMPDIR_TEST/entrypoints-project"
mkdir -p "$ENTRYPOINTS_PROJECT_DIR"
cd "$ENTRYPOINTS_PROJECT_DIR" || exit 1

assert_eq "path prints the resolved file path" ".doer/entry-points.json" "$("$ENTRYPOINTS_SH" path)"
assert_eq "list on missing store returns empty array" "[]" "$("$ENTRYPOINTS_SH" list)"
assert_eq "match on missing store returns empty array, no file created" "[]" "$("$ENTRYPOINTS_SH" match banner)"
assert_eq "match against a missing store creates no file" "no" "$([ -f "./.doer/entry-points.json" ] && echo yes || echo no)"

"$ENTRYPOINTS_SH" save --topic "home page offer banner" --paths "app/Foo.kt,app/Bar.kt" \
  --keywords "offer banner,hpmktg" --from "PDE-2917" > /dev/null
assert_eq "save creates the store file" "yes" "$([ -f "./.doer/entry-points.json" ] && echo yes)"
jq -e . "./.doer/entry-points.json" > /dev/null && pass "store file is valid JSON" || fail "store file is valid JSON"
assert_eq "save: paths roundtrip" "app/Bar.kt app/Foo.kt" "$("$ENTRYPOINTS_SH" list | jq -r '.[0].paths | sort | join(" ")')"
assert_eq "save: captured_from roundtrip" "PDE-2917" "$("$ENTRYPOINTS_SH" list | jq -r '.[0].captured_from | join(",")')"

assert_eq "match by keyword substring finds the entry" "home page offer banner" "$("$ENTRYPOINTS_SH" match hpmktg | jq -r '.[0].topic')"
assert_eq "match by unrelated term returns empty" "[]" "$("$ENTRYPOINTS_SH" match "totalmente distinto")"

"$ENTRYPOINTS_SH" save --topic "home page offer banner" --paths "app/Bar.kt,app/Baz.kt" \
  --from "PDE-3000" > /dev/null
assert_eq "save merge: paths are unioned and deduped" "app/Bar.kt app/Baz.kt app/Foo.kt" \
  "$("$ENTRYPOINTS_SH" list | jq -r '.[0].paths | sort | join(" ")')"
assert_eq "save merge: captured_from accumulates" "PDE-2917,PDE-3000" "$("$ENTRYPOINTS_SH" list | jq -r '.[0].captured_from | join(",")')"
assert_eq "save merge: keywords survive an update with no --keywords" "hpmktg,offer banner" \
  "$("$ENTRYPOINTS_SH" list | jq -r '.[0].keywords | sort | join(",")')"

"$ENTRYPOINTS_SH" save --topic "home page offer banner" --paths "app/OnlyOne.kt" --mode replace > /dev/null
assert_eq "save --mode replace: paths become exactly the given set" "app/OnlyOne.kt" \
  "$("$ENTRYPOINTS_SH" list | jq -r '.[0].paths | join(",")')"
assert_eq "save --mode replace: captured_from is untouched (no --from)" "PDE-2917,PDE-3000" \
  "$("$ENTRYPOINTS_SH" list | jq -r '.[0].captured_from | join(",")')"

"$ENTRYPOINTS_SH" save --topic "second topic" --paths "app/Other.kt" > /dev/null
assert_eq "list returns both topics" "2" "$("$ENTRYPOINTS_SH" list | jq 'length')"

"$ENTRYPOINTS_SH" forget --topic "second topic" > /dev/null
assert_eq "forget removes only the named topic" "home page offer banner" "$("$ENTRYPOINTS_SH" list | jq -r '.[0].topic')"
assert_eq "list after forget has exactly one entry" "1" "$("$ENTRYPOINTS_SH" list | jq 'length')"

"$ENTRYPOINTS_SH" forget --topic "home page offer banner" > /dev/null
assert_eq "forget the last entry leaves an empty array" "[]" "$("$ENTRYPOINTS_SH" list)"

cd "$REPO_ROOT" || exit 1

# --- vocab-guard.sh (Core Principle 10, single regex implementation) ---
bash -n "$VOCAB_GUARD_SH" && pass "vocab-guard.sh parses" || fail "vocab-guard.sh parses"

printf 'fix: improve login timeout handling\n' | "$VOCAB_GUARD_SH" > /dev/null 2>&1
assert_eq "vocab-guard: clean text exits 0" "0" "$?"

printf 'fix: remove PROTOLOG_RESPONSE leftover\n' | "$VOCAB_GUARD_SH" > /dev/null 2>&1
assert_eq "vocab-guard: PROTOLOG_RESPONSE (no trailing boundary) is caught" "1" "$?"

printf 'fix: cover AC-3 case\n' | "$VOCAB_GUARD_SH" > /dev/null 2>&1
assert_eq "vocab-guard: AC-N label is caught" "1" "$?"

printf 'fix: mention C-2 in passing\n' | "$VOCAB_GUARD_SH" > /dev/null 2>&1
assert_eq "vocab-guard: C-N label is caught" "1" "$?"

printf 'fix: replay the failing request\n' | "$VOCAB_GUARD_SH" > /dev/null 2>&1
assert_eq "vocab-guard: lowercase 'replay' in prose is NOT caught (word-boundary only)" "0" "$?"

VOCAB_OUT="$(printf 'AC-1 leaked here\n' | "$VOCAB_GUARD_SH" 2>&1)"
case "$VOCAB_OUT" in
  stdin:1:*) pass "vocab-guard: stdin match is labeled stdin:<line>:<text>" ;;
  *) fail "vocab-guard: stdin match is labeled stdin:<line>:<text>" "got: $VOCAB_OUT" ;;
esac

# --- git-checks.sh / git-ops.sh (read-only git inspection + history rewrites) ---
bash -n "$GIT_CHECKS_SH" && pass "git-checks.sh parses" || fail "git-checks.sh parses"
bash -n "$GIT_OPS_SH" && pass "git-ops.sh parses" || fail "git-ops.sh parses"
bash -n "$WORKSPACE_GUARD_SH" && pass "workspace-guard.sh parses" || fail "workspace-guard.sh parses"
bash -n "$STAGE_CHECKS_SH" && pass "stage-checks.sh parses" || fail "stage-checks.sh parses"
python3 -c "import ast; ast.parse(open('${HAR_PY}').read())" && pass "har.py parses" || fail "har.py parses"
python3 -c "import ast; ast.parse(open('${AC_GRAPH_PY}').read())" && pass "ac-graph.py parses" || fail "ac-graph.py parses"

GC_DIR="$TMPDIR_TEST/git-checks-repo"
new_scratch_repo() { # new_scratch_repo <dir> <default-branch>: init + one base commit
  local dir="$1" branch="$2"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q -b "$branch" . && git config user.email t@t.t && git config user.name t )
}
new_scratch_repo "$GC_DIR" main
cd "$GC_DIR" || exit 1

printf 'a\n' > f.txt
printf 'g\n' > g.txt
git add -A && git commit -q --no-verify -m base
git checkout -q -b feature/test

assert_eq "git-checks base-candidates: current branch is excluded" "false" \
  "$("$GIT_CHECKS_SH" base-candidates | jq 'any(.candidates[]; . == "feature/test")')"
assert_eq "git-checks base-candidates: main is a candidate" "true" \
  "$("$GIT_CHECKS_SH" base-candidates | jq 'any(.candidates[]; . == "main")')"

assert_eq "git-checks classify-diff: no changes vs base is non-runtime" "non-runtime" \
  "$("$GIT_CHECKS_SH" classify-diff main)"

printf 'doc change\n' > README.md
git add -A && git commit -q --no-verify -m docs
assert_eq "git-checks classify-diff: docs-only diff is non-runtime" "non-runtime" \
  "$("$GIT_CHECKS_SH" classify-diff main)"

printf 'code\n' > src.kt
git add -A && git commit -q --no-verify -m code
assert_eq "git-checks classify-diff: a source file makes the diff runtime" "runtime" \
  "$("$GIT_CHECKS_SH" classify-diff main)"

DIFF_FILES="$("$GIT_CHECKS_SH" diff-files main | sort)"
EXPECTED_FILES="$(printf 'README.md\nsrc.kt\n')"
assert_eq "git-checks diff-files: union of changed files vs base" "$EXPECTED_FILES" "$DIFF_FILES"

printf 'fun x() { // AC-1 something }\n' > leak.kt
git add -A && git commit -q --no-verify -m "committed leak"
"$GIT_CHECKS_SH" ac-leak main > /dev/null 2>&1
assert_eq "git-checks ac-leak: committed AC-N label in an added line is caught" "1" "$?"
git reset -q --hard HEAD~1

printf 'api_key = "abcdefgh12345"\n' > secret.txt
git add -A && git commit -q --no-verify -m "committed secret"
"$GIT_CHECKS_SH" secrets main > /dev/null 2>&1
assert_eq "git-checks secrets: committed credential-shaped line is caught" "1" "$?"
git reset -q --hard HEAD~1

"$GIT_CHECKS_SH" squash-gate main > /dev/null 2>&1
assert_eq "git-checks squash-gate: clean diff exits 0" "0" "$?"
printf '// REPLAY START T1\nval x = FORCED\n// REPLAY END T1\n' > rep.kt
git add -A && git commit -q --no-verify -m "leftover replay marker"
"$GIT_CHECKS_SH" squash-gate main > /dev/null 2>&1
assert_eq "git-checks squash-gate: REPLAY marker in the diff is caught" "1" "$?"

"$GIT_CHECKS_SH" trace PROTOLOG > /dev/null 2>&1
assert_eq "git-checks trace: no PROTOLOG marker exits 0" "0" "$?"
printf 'println("PROTOLOG - hola")\n' >> rep.kt
git add -A && git commit -q --no-verify -m "add protolog line"
TRACE_OUT="$("$GIT_CHECKS_SH" trace PROTOLOG)"
TRACE_EXIT=$?
assert_eq "git-checks trace: exits 1 when a PROTOLOG line remains" "1" "$TRACE_EXIT"
TRACE_LINES="$(printf '%s\n' "$TRACE_OUT" | grep -c '^rep.kt:')"
assert_eq "git-checks trace: tracked+untracked scan deduplicates to one match, not two" "1" "$TRACE_LINES"

assert_eq "git-checks doer-history: no .doer/ commits since base" "" "$("$GIT_CHECKS_SH" doer-history main)"
assert_eq "git-checks revert-in-progress: clean tree exits 0" "yes" \
  "$("$GIT_CHECKS_SH" revert-in-progress > /dev/null 2>&1 && echo yes || echo no)"
assert_eq "git-checks pr-templates: none present" "" "$("$GIT_CHECKS_SH" pr-templates)"

assert_eq "git-checks temp-rounds: zero before any [TEMP] commit" "0" "$("$GIT_CHECKS_SH" temp-rounds PROTOLOG)"
git commit -q --no-verify --allow-empty -m "[TEMP] PROTOLOG round 1. DO NOT MERGE"
assert_eq "git-checks temp-rounds: counts one after a [TEMP] PROTOLOG commit" "1" "$("$GIT_CHECKS_SH" temp-rounds PROTOLOG)"

# phantoms + restore-phantoms (g.txt is tracked on main, unlike README.md/src.kt
# which only exist on feature/test, so it is a real "dirty but out of scope" file)
git checkout -q -b feature/phantoms main
printf 'a2\n' > f.txt
git add -A && git commit -q --no-verify -m "intended change"
printf 'h2\n' > g.txt
PHANTOMS_JSON="$("$GIT_CHECKS_SH" phantoms main)"
assert_eq "git-checks phantoms: a dirty file outside the intended diff is reported" "true" \
  "$(printf '%s' "$PHANTOMS_JSON" | jq 'any(.[]; .path == "g.txt" and .clean == false)')"
"$GIT_OPS_SH" restore-phantoms main > /dev/null
assert_eq "git-ops restore-phantoms: a leftover-diff phantom is reported, not silently discarded" "g.txt" \
  "$("$GIT_OPS_SH" restore-phantoms main)"
git checkout -q -- g.txt

# --- git-ops.sh squash ---
# Redirect the script's own captured output OUTSIDE the repo under test
# (TMPDIR_TEST, not GC_DIR): writing it inside GC_DIR would create a new
# untracked file there before the command even runs, which squash's own
# dirty-tree check (correctly) treats as a dirty working tree.
git checkout -q -b feature/squash main
printf 'b\n' >> f.txt && git add -A && git commit -q --no-verify -m step1
printf 'c\n' >> f.txt && git add -A && git commit -q --no-verify -m step2
printf 'd\n' >> f.txt && git add -A && git commit -q --no-verify -m step3
BEFORE_HEAD="$(git rev-parse HEAD)"
SQUASH_OUT_FILE="$TMPDIR_TEST/squash_out.txt"
printf 'feat: squashed message' | "$GIT_OPS_SH" squash main SQ-1 doer > "$SQUASH_OUT_FILE"
assert_eq "git-ops squash: collapses to exactly 1 commit" "1" "$(git rev-list --count main..HEAD)"
assert_eq "git-ops squash: backup ref points at the pre-squash HEAD" "$BEFORE_HEAD" \
  "$(git for-each-ref --format='%(objectname)' 'refs/doer-backup/SQ-1-pre-squash-*' | head -1)"
grep -q '^BACKUP refs/doer-backup/SQ-1-pre-squash-' "$SQUASH_OUT_FILE" \
  && pass "git-ops squash: prints the backup ref" || fail "git-ops squash: prints the backup ref"

git checkout -q -b feature/squash-single main
printf 'only\n' > only.txt && git add -A && git commit -q --no-verify -m only
SQUASH_SKIP="$(printf 'msg' | "$GIT_OPS_SH" squash main SQ-2 doer)"
assert_eq "git-ops squash: a single commit is a no-op (SKIP)" "SKIP: 1 commit" "$SQUASH_SKIP"

git checkout -q feature/squash
printf 'dirty\n' >> f.txt
printf 'msg' | "$GIT_OPS_SH" squash main SQ-3 doer > /dev/null 2>&1
assert_eq "git-ops squash: refuses a dirty working tree" "1" "$?"
git checkout -q -- f.txt

# --- git-ops.sh squash: Co-Authored-By stripping + post-commit verification ---
# The platform's attribution guidance nudges the model to append this trailer;
# the dev's golden rule is that it must never survive a squash, in any shape.

git checkout -q -b feature/squash-trailer main
printf 'e\n' >> f.txt && git add -A && git commit -q --no-verify -m stepA
printf 'f\n' >> f.txt && git add -A && git commit -q --no-verify -m stepB
SQUASH_TRAILER_OUT="$TMPDIR_TEST/squash_trailer_out.txt"
printf 'feat: with trailer\n\nCo-Authored-By: Claude X <noreply@anthropic.com>' \
  | "$GIT_OPS_SH" squash main SQ-5 doer > "$SQUASH_TRAILER_OUT"
assert_eq "git-ops squash: still collapses to exactly 1 commit with a trailer in the draft" \
  "1" "$(git rev-list --count main..HEAD)"
git log -1 --format=%B | grep -qi '^co-authored-by' \
  && fail "git-ops squash: trailer stripped from the final message" \
  || pass "git-ops squash: trailer stripped from the final message"
grep -q '^STRIPPED Co-Authored-By trailer$' "$SQUASH_TRAILER_OUT" \
  && pass "git-ops squash: prints STRIPPED when the draft carried a trailer" \
  || fail "git-ops squash: prints STRIPPED when the draft carried a trailer"

git checkout -q -b feature/squash-trailer-ws main
printf 'e\n' >> f.txt && git add -A && git commit -q --no-verify -m stepA
printf 'f\n' >> f.txt && git add -A && git commit -q --no-verify -m stepB
printf 'feat: whitespace before colon\n\nCo-Authored-By : Claude X <noreply@anthropic.com>' \
  | "$GIT_OPS_SH" squash main SQ-6 doer > /dev/null
git log -1 --format=%B | grep -qiE '^co-authored-by[[:space:]]*:' \
  && fail "git-ops squash: strips a trailer with whitespace before the colon" \
  || pass "git-ops squash: strips a trailer with whitespace before the colon"

git checkout -q -b feature/squash-one-trailer main
printf 'one\n' > one.txt && git add -A && git commit -q --no-verify -m "one: subject

Co-Authored-By: Claude X <noreply@anthropic.com>"
ONE_BEFORE_HEAD="$(git rev-parse HEAD)"
SQUASH_ONE_OUT="$TMPDIR_TEST/squash_one_out.txt"
printf 'msg' | "$GIT_OPS_SH" squash main SQ-3 doer > "$SQUASH_ONE_OUT"
assert_eq "git-ops squash: a single commit with a trailer stays a no-op (SKIP)" \
  "SKIP: 1 commit" "$(tail -n1 "$SQUASH_ONE_OUT")"
git log -1 --format=%B | grep -qi '^co-authored-by' \
  && fail "git-ops squash: amends the trailer out of a single pre-existing commit" \
  || pass "git-ops squash: amends the trailer out of a single pre-existing commit"
assert_eq "git-ops squash: backs up before amending a single trailer-carrying commit" "$ONE_BEFORE_HEAD" \
  "$(git for-each-ref --format='%(objectname)' 'refs/doer-backup/SQ-3-pre-squash-*' | head -1)"
grep -q '^STRIPPED Co-Authored-By trailer$' "$SQUASH_ONE_OUT" \
  && pass "git-ops squash: prints STRIPPED for the amended single commit" \
  || fail "git-ops squash: prints STRIPPED for the amended single commit"

git checkout -q -b feature/squash-zero main
printf 'zero\n' > zero.txt && git add -A && git commit -q --no-verify -m "zero: subject

Co-Authored-By: Claude X <noreply@anthropic.com>"
ZERO_HEAD="$(git rev-parse HEAD)"
SQUASH_ZERO_OUT="$(printf 'msg' | "$GIT_OPS_SH" squash feature/squash-zero SQ-4 doer)"
assert_eq "git-ops squash: base == HEAD is a no-op, never touches the base commit" \
  "SKIP: 1 commit" "$SQUASH_ZERO_OUT"
assert_eq "git-ops squash: base == HEAD leaves the commit SHA untouched" "$ZERO_HEAD" "$(git rev-parse HEAD)"
assert_eq "git-ops squash: base == HEAD creates no backup ref" "" \
  "$(git for-each-ref --format='%(refname)' 'refs/doer-backup/SQ-4-pre-squash-*')"

git checkout -q -b feature/squash-empty main
printf 'e\n' >> f.txt && git add -A && git commit -q --no-verify -m stepA
printf 'f\n' >> f.txt && git add -A && git commit -q --no-verify -m stepB
EMPTY_BEFORE_HEAD="$(git rev-parse HEAD)"
printf '   \n\t\nCo-Authored-By: Claude X <noreply@anthropic.com>\n' \
  | "$GIT_OPS_SH" squash main SQ-7 doer > /dev/null 2>&1
assert_eq "git-ops squash: a message that is only the trailer is refused" "1" "$?"
assert_eq "git-ops squash: refusing an empty-after-strip message leaves HEAD untouched" \
  "$EMPTY_BEFORE_HEAD" "$(git rev-parse HEAD)"
assert_eq "git-ops squash: refusing an empty-after-strip message creates no backup ref" "" \
  "$(git for-each-ref --format='%(refname)' 'refs/doer-backup/SQ-7-pre-squash-*')"
assert_eq "git-ops squash: refusing an empty-after-strip message leaves the tree clean" "" \
  "$(git status --porcelain)"

git checkout -q -b feature/squash-hook main
printf 'e\n' >> f.txt && git add -A && git commit -q --no-verify -m stepA
printf 'f\n' >> f.txt && git add -A && git commit -q --no-verify -m stepB
printf 'g\n' >> f.txt && git add -A && git commit -q --no-verify -m stepC
mkdir -p .git/hooks
cat > .git/hooks/prepare-commit-msg <<'HOOK'
#!/bin/sh
echo "Co-Authored-By: Claude X <noreply@anthropic.com>" >> "$1"
HOOK
chmod +x .git/hooks/prepare-commit-msg
SQUASH_HOOK_OUT="$TMPDIR_TEST/squash_hook_out.txt"
printf 'feat: hook re-injects the trailer' | "$GIT_OPS_SH" squash main SQ-8 doer > "$SQUASH_HOOK_OUT" 2>&1
assert_eq "git-ops squash: exits 1 when a repo hook re-injects the trailer after commit" "1" "$?"
grep -q 'survived the commit' "$SQUASH_HOOK_OUT" \
  && pass "git-ops squash: names the survived-the-commit failure" \
  || fail "git-ops squash: names the survived-the-commit failure"
grep -q '^BACKUP refs/doer-backup/SQ-8-pre-squash-' "$SQUASH_HOOK_OUT" \
  && pass "git-ops squash: still announces the backup ref before the hook re-injection is caught" \
  || fail "git-ops squash: still announces the backup ref before the hook re-injection is caught"
rm -f .git/hooks/prepare-commit-msg

# --- git-ops.sh revert-temp ---
git checkout -q -b feature/revert main
printf 'fun a() {\n    val x = 1\n}\n' > Foo.kt
git add -A && git commit -q --no-verify -m base2
printf 'fun a() {\n    val x = 1\n    println("PROTOLOG - r1")\n}\n' > Foo.kt
git add -A && git commit -q --no-verify -m "[TEMP] PROTOLOG round 1. DO NOT MERGE"
printf 'fun a() {\n    val x = 1\n    println("PROTOLOG - r1")\n    println("PROTOLOG - r2")\n}\n' > Foo.kt
git add -A && git commit -q --no-verify -m "[TEMP] PROTOLOG round 2. DO NOT MERGE"
REVERT_OUT="$("$GIT_OPS_SH" revert-temp PROTOLOG)"
assert_eq "git-ops revert-temp: reverts 2 clean [TEMP] commits" "2" "$(printf '%s\n' "$REVERT_OUT" | grep -c '^REVERTED')"
assert_eq "git-ops revert-temp: file is back to its pre-injection state" "fun a() {
    val x = 1
}" "$(cat Foo.kt)"
assert_eq "git-ops revert-temp: NONE when the tag has no [TEMP] commits" "NONE" "$("$GIT_OPS_SH" revert-temp REPLAY)"

git checkout -q -b feature/revert-conflict main
printf 'fun a() {\n    val x = 1\n}\n' > Bar.kt
git add -A && git commit -q --no-verify -m base3
printf 'fun a() {\n    val x = 1\n    println("PROTOLOG - x")\n}\n' > Bar.kt
git add -A && git commit -q --no-verify -m "[TEMP] PROTOLOG round 1. DO NOT MERGE"
printf 'fun a() {\n    val x = 2\n    println("PROTOLOG - x")\n}\n' > Bar.kt
git add -A && git commit -q --no-verify -m "fix: business change on the same line"
REVERT_OUT_FILE="$TMPDIR_TEST/revert_out.txt"
"$GIT_OPS_SH" revert-temp PROTOLOG > "$REVERT_OUT_FILE"
REVERT_EXIT=$?
assert_eq "git-ops revert-temp: exits 1 on a conflict" "1" "$REVERT_EXIT"
grep -q '^CONFLICT .* Bar.kt' "$REVERT_OUT_FILE" \
  && pass "git-ops revert-temp: reports the conflicted sha and its files" \
  || fail "git-ops revert-temp: reports the conflicted sha and its files"
git rev-parse -q --verify REVERT_HEAD > /dev/null 2>&1
assert_eq "git-ops revert-temp: never leaves a revert in progress after a conflict" "1" "$?"

# --- git-ops.sh scrub-history ---
git checkout -q -b feature/scrub main
mkdir -p .doer/tickets/SC-1
printf '{}' > .doer/tickets/SC-1/metadata.json
git add -A && git commit -q --no-verify -m "doer(SC-1): oops committed .doer"
printf 'e\n' >> f.txt && git add -A && git commit -q --no-verify -m "more work"
ROOT_SHA="$(git rev-list --max-parents=0 HEAD)"
"$GIT_OPS_SH" scrub-history "$ROOT_SHA" SC-1 doer > /dev/null 2>&1
assert_eq "git-ops scrub-history: no .doer/ commits remain since the branch root" "" \
  "$("$GIT_CHECKS_SH" doer-history "$ROOT_SHA")"
assert_eq "git-ops scrub-history: a backup ref exists for this ticket" "yes" \
  "$([ -n "$(git for-each-ref --format='%(refname)' 'refs/doer-backup/SC-1-pre-cleanup-*')" ] && echo yes || echo no)"

# --- workspace-guard.sh ---
# Same $PPID-sensitive rule as tests/hooks.sh's run_guard(): call acquire/
# release as a PLAIN STATEMENT, never via $(...) (that forks a subshell and
# breaks the $PPID match against session.sh's own marker). Redirect stdout to
# a file instead, then read the file afterward once the command has already
# run to completion in the foreground.
WG_DIR="$TMPDIR_TEST/workspace-guard-repo"
new_scratch_repo "$WG_DIR" main
cd "$WG_DIR" || exit 1
git commit -q --no-verify --allow-empty -m base

"$WORKSPACE_GUARD_SH" acquire --no-lock > wg_out.txt 2>&1
assert_eq "workspace-guard acquire --no-lock: exits 0" "0" "$?"
assert_eq "workspace-guard acquire --no-lock: adds the exclude rule" "yes" \
  "$(grep -qxF '.doer/' .git/info/exclude && echo yes || echo no)"
assert_eq "workspace-guard acquire --no-lock: no lock or session marker" "no" \
  "$([ -e .doer/tickets ] && echo yes || echo no)"

"$WORKSPACE_GUARD_SH" acquire WG-1 doer > wg_out.txt 2>&1
assert_eq "workspace-guard acquire: exits 0 on a fresh ticket" "0" "$?"
assert_eq "workspace-guard acquire: lock.json records THIS shell's \$\$ (its own \$PPID)" "$$" \
  "$(jq -r '.pid' .doer/tickets/WG-1/lock.json)"
assert_eq "workspace-guard acquire: session marker keyed to the same pid" "yes" \
  "$([ -f ".doer/wk-session-$$.json" ] && echo yes || echo no)"
assert_eq "workspace-guard acquire: session marker records the given skill" "doer" \
  "$(jq -r '.skill' ".doer/wk-session-$$.json")"

"$WORKSPACE_GUARD_SH" acquire WG-1 doer > wg_out.txt 2>&1
assert_eq "workspace-guard acquire: a same-session re-acquire refreshes, never LOCKED" "0" "$?"

mkdir -p .doer/tickets/WG-2
printf '{"pid": 1, "host": "%s", "touched_at": %d}\n' "$(hostname)" "$(date +%s)" > .doer/tickets/WG-2/lock.json
"$WORKSPACE_GUARD_SH" acquire WG-2 doer > wg_out.txt 2>&1
assert_eq "workspace-guard acquire: a dead pid's lock is stolen, not blocked" "0" "$?"
assert_eq "workspace-guard acquire: the stolen lock now records this session" "$$" \
  "$(jq -r '.pid' .doer/tickets/WG-2/lock.json)"

mkdir -p .doer/tickets/WG-3
printf '{"pid": %d, "host": "%s", "touched_at": %d}\n' "$$" "$(hostname)" "$(( $(date +%s) - 2000 ))" > .doer/tickets/WG-3/lock.json
"$WORKSPACE_GUARD_SH" acquire WG-3 doer > wg_out.txt 2>&1
assert_eq "workspace-guard acquire: a stale (>30min) lock is stolen even if same pid" "0" "$?"

mkdir -p .doer/tickets/WG-4
printf '{"pid": 99999, "host": "some-other-machine", "touched_at": %d}\n' "$(date +%s)" > .doer/tickets/WG-4/lock.json
"$WORKSPACE_GUARD_SH" acquire WG-4 doer > wg_out.txt 2>&1
WG4_EXIT=$?
assert_eq "workspace-guard acquire: a fresh lock on an unverifiable host blocks (LOCKED)" "1" "$WG4_EXIT"
grep -q '^LOCKED:' wg_out.txt && pass "workspace-guard acquire: LOCKED message surfaced verbatim" \
  || fail "workspace-guard acquire: LOCKED message surfaced verbatim" "got: $(cat wg_out.txt)"
assert_eq "workspace-guard acquire: a LOCKED attempt never overwrites the lock" "99999" \
  "$(jq -r '.pid' .doer/tickets/WG-4/lock.json)"

mkdir -p .doer/tickets/WG-5
echo '{}' > .doer/tickets/WG-5/oops.json
git add -f .doer/tickets/WG-5/oops.json
git commit -q --no-verify -m "oops committed .doer"
"$WORKSPACE_GUARD_SH" acquire WG-5 doer > wg_out.txt 2>&1
assert_eq "workspace-guard acquire: still succeeds when .doer/ has tracked files" "0" "$?"
grep -q '^TRACKED .doer/tickets/WG-5/oops.json$' wg_out.txt \
  && pass "workspace-guard acquire: reports the tracked path" \
  || fail "workspace-guard acquire: reports the tracked path" "got: $(cat wg_out.txt)"

"$WORKSPACE_GUARD_SH" release WG-1 > wg_out.txt 2>&1
assert_eq "workspace-guard release: exits 0" "0" "$?"
assert_eq "workspace-guard release: removes the lock" "no" \
  "$([ -f .doer/tickets/WG-1/lock.json ] && echo yes || echo no)"
assert_eq "workspace-guard release: removes the session marker" "no" \
  "$([ -f ".doer/wk-session-$$.json" ] && echo yes || echo no)"

# --- workspace-guard.sh inside a linked git worktree (DOER-4) ---
# In a worktree .git is a FILE, so the exclude rule must go through
# `git rev-parse --git-path info/exclude`. All script output goes to
# $TMPDIR_TEST, never into the worktree: an untracked output file there
# would make git-ops squash refuse for the wrong reason. The guard deletes
# its own .guard-test probe, so the tests write a real file under .doer/
# themselves before checking exclusion or squashing.
WT_MAIN="$TMPDIR_TEST/wt-main"
WT_DIR="$TMPDIR_TEST/wt-linked"
WT_OUT="$TMPDIR_TEST/wt_out.txt"
new_scratch_repo "$WT_MAIN" main
( cd "$WT_MAIN" && git commit -q --no-verify --allow-empty -m base && git worktree add -q -b feature/wt "$WT_DIR" )
cd "$WT_DIR" || exit 1
assert_eq "worktree fixture: .git is a file, not a directory" "yes" \
  "$([ -f .git ] && echo yes || echo no)"

"$WORKSPACE_GUARD_SH" acquire --no-lock > "$WT_OUT" 2>&1
assert_eq "worktree: workspace-guard acquire --no-lock exits 0" "0" "$?"
mkdir -p .doer/tickets/WT-1 && echo '{}' > .doer/tickets/WT-1/metadata.json
assert_eq "worktree: acquire --no-lock leaves .doer/ files ignored by git" "" \
  "$(git status --porcelain)"
git check-ignore -q .doer/tickets/WT-1/metadata.json \
  && pass "worktree: check-ignore confirms .doer/ is excluded" \
  || fail "worktree: check-ignore confirms .doer/ is excluded"

"$WORKSPACE_GUARD_SH" acquire WT-1 doer > "$WT_OUT" 2>&1
assert_eq "worktree: workspace-guard acquire <ID> doer exits 0" "0" "$?"
assert_eq "worktree: acquire writes lock.json with this session's pid" "$$" \
  "$(jq -r '.pid' .doer/tickets/WT-1/lock.json 2>/dev/null)"
assert_eq "worktree: acquire writes the session marker" "yes" \
  "$([ -f ".doer/wk-session-$$.json" ] && echo yes || echo no)"

for step in 1 2 3; do
  printf '%s\n' "$step" >> wt.txt && git add wt.txt && git commit -q --no-verify -m "step$step"
done
printf 'feat: squashed in worktree' | "$GIT_OPS_SH" squash main WT-1 doer > "$WT_OUT" 2>&1
assert_eq "worktree: git-ops squash exits 0 with .doer/ present" "0" "$?"
assert_eq "worktree: git-ops squash collapses to 1 commit" "1" "$(git rev-list --count main..HEAD)"

# sibling: a second acquire never duplicates the exclude rule
EXCLUDE_FILE="$(git rev-parse --git-path info/exclude)"
"$WORKSPACE_GUARD_SH" acquire --no-lock > "$WT_OUT" 2>&1
assert_eq "worktree: re-running the guard keeps exactly one .doer/ exclude line" "1" \
  "$(grep -cxF '.doer/' "$EXCLUDE_FILE")"
"$WORKSPACE_GUARD_SH" release WT-1 > "$WT_OUT" 2>&1

# sibling: session.sh start alone (replay/protologs call it without the guard)
rm -f "$EXCLUDE_FILE"
"${REPO_ROOT}/lib/helpers/session.sh" start doer > "$WT_OUT" 2>&1
assert_eq "worktree: session.sh start alone exits 0 and re-creates the exclude rule" "1" \
  "$(grep -cxF '.doer/' "$EXCLUDE_FILE" 2>/dev/null || echo 0)"
"${REPO_ROOT}/lib/helpers/session.sh" stop

# --- stage-checks.sh plan (02-plan.md Step 3, "no LLM") ---
SC_DIR="$TMPDIR_TEST/stage-checks-plan"
mkdir -p "$SC_DIR/.doer/tickets/SCT-1"
cd "$SC_DIR" || exit 1
echo '{"ac":{"in_scope":["AC-1: GIVEN a WHEN b THEN c","AC-2: GIVEN x WHEN y THEN z"]}}' > .doer/tickets/SCT-1/metadata.json
echo "existing" > new_but_exists.txt

PLAN_OUT="$(echo '{
  "files":[{"path":"missing.kt","change":"edit","reason":"x"},{"path":"new_but_exists.txt","change":"new","reason":"y"}],
  "tests":[{"name":"t1","covers":["AC-1"],"what":"x"}],
  "assumptions":[]
}' | "$STAGE_CHECKS_SH" plan SCT-1)"
PLAN_EXIT=$?
assert_eq "stage-checks plan: exits 1 when files/coverage are wrong" "1" "$PLAN_EXIT"
assert_eq "stage-checks plan: reports the missing edit-target file" '["missing.kt"]' \
  "$(printf '%s' "$PLAN_OUT" | jq -c '.files_missing')"
assert_eq "stage-checks plan: reports the new-file-that-already-exists" '["new_but_exists.txt"]' \
  "$(printf '%s' "$PLAN_OUT" | jq -c '.files_unexpected')"
assert_eq "stage-checks plan: reports the uncovered AC" '["AC-2"]' \
  "$(printf '%s' "$PLAN_OUT" | jq -c '.ac_uncovered')"

touch clean.kt
PLAN_OUT="$(echo '{
  "files":[{"path":"clean.kt","change":"edit","reason":"x"},{"path":"brandnew.kt","change":"new","reason":"y"}],
  "tests":[{"name":"t1","covers":["AC-1"],"what":"x"},{"name":"t2","covers":["AC-2"],"what":"y"}],
  "assumptions":[{"id":"A-1","statement":"s","check":null,"risk":"low"},
                 {"id":"A-2","statement":"s2","check":"true","risk":"medium"},
                 {"id":"A-3","statement":"s3","check":"false","risk":"low"}]
}' | "$STAGE_CHECKS_SH" plan SCT-1)"
assert_eq "stage-checks plan: clean plan exits 0 (a low-risk fail does not block)" "0" "$?"
assert_eq "stage-checks plan: a null check is skipped, not run" "skipped" \
  "$(printf '%s' "$PLAN_OUT" | jq -r '.assumptions[] | select(.id == "A-1") | .result')"
assert_eq "stage-checks plan: a null check keeps its risk field intact (the IFS/@tsv trap)" "low" \
  "$(printf '%s' "$PLAN_OUT" | jq -r '.assumptions[] | select(.id == "A-1") | .risk')"
assert_eq "stage-checks plan: a passing check is recorded pass" "pass" \
  "$(printf '%s' "$PLAN_OUT" | jq -r '.assumptions[] | select(.id == "A-2") | .result')"
assert_eq "stage-checks plan: a failing check is recorded fail" "fail" \
  "$(printf '%s' "$PLAN_OUT" | jq -r '.assumptions[] | select(.id == "A-3") | .result')"

echo '{"files":[],"tests":[],"assumptions":[{"id":"A-1","statement":"s","check":"false","risk":"high"}]}' \
  | "$STAGE_CHECKS_SH" plan SCT-1 > /dev/null 2>&1
assert_eq "stage-checks plan: a high-risk failing assumption blocks (exit 1)" "1" "$?"

echo '{"files":[],"tests":[],"assumptions":[{"id":"A-1","statement":"s","check":"sleep 15","risk":"low"}]}' \
  > slow_plan.json
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || command -v perl >/dev/null 2>&1; then
  SECONDS=0
  "$STAGE_CHECKS_SH" plan SCT-1 --plan slow_plan.json > /dev/null 2>&1
  ELAPSED=$SECONDS
  [ "$ELAPSED" -lt 14 ] && pass "stage-checks plan: a slow check is cut off by the 10s timeout" \
    || fail "stage-checks plan: a slow check is cut off by the 10s timeout" "took ${ELAPSED}s"
fi

# --- stage-checks.sh pre-review (03-build.md Step 3, "no LLM") ---
SC_GIT_DIR="$TMPDIR_TEST/stage-checks-review"
new_scratch_repo "$SC_GIT_DIR" main
cd "$SC_GIT_DIR" || exit 1
printf 'a\n' > f.txt
git add -A && git commit -q --no-verify -m base
git checkout -q -b feature/x

mkdir -p .doer/tickets/SCT-2
echo '{"test_command":"true","lint_command":null,"typecheck_command":"true","plan":{"files":[{"path":"f.txt","change":"edit"}]}}' \
  > .doer/tickets/SCT-2/metadata.json
PRE_OUT="$("$STAGE_CHECKS_SH" pre-review SCT-2 main)"
PRE_EXIT=$?
assert_eq "stage-checks pre-review: unmet plan-file scope is a BLOCKER" "1" "$PRE_EXIT"
assert_eq "stage-checks pre-review: reports the missing lint_command" '["lint_command"]' \
  "$(printf '%s' "$PRE_OUT" | jq -c '.missing')"

printf 'a2\n' > f.txt
printf 'x\n' > extra.txt
git add -A && git commit -q --no-verify -m work
PRE_OUT="$("$STAGE_CHECKS_SH" pre-review SCT-2 main)"
assert_eq "stage-checks pre-review: plan file touched, extra file is INFO not a blocker" "0" "$?"
assert_eq "stage-checks pre-review: extra.txt shows up as scope INFO" "true" \
  "$(printf '%s' "$PRE_OUT" | jq '[.info[] | select(.detail | contains("extra.txt"))] | length == 1')"

echo '{"test_command":"false","lint_command":null,"typecheck_command":null,"plan":{"files":[]}}' \
  > .doer/tickets/SCT-2/metadata.json
"$STAGE_CHECKS_SH" pre-review SCT-2 main > /dev/null 2>&1
assert_eq "stage-checks pre-review: a failing test_command is a BLOCKER" "1" "$?"

printf 'api_key = "abcdefgh12345"\n// AC-1 leaked\n' > secret.kt
git add -A && git commit -q --no-verify -m leak
echo '{"test_command":"true","lint_command":"true","typecheck_command":"true","plan":{"files":[]}}' \
  > .doer/tickets/SCT-2/metadata.json
PRE_OUT="$("$STAGE_CHECKS_SH" pre-review SCT-2 main)"
assert_eq "stage-checks pre-review: secrets and AC-leak are both BLOCKERs" "2" \
  "$(printf '%s' "$PRE_OUT" | jq '.blockers | length')"
assert_eq "stage-checks pre-review: a tracked .doer/ file never pollutes scope INFO" "false" \
  "$(printf '%s' "$PRE_OUT" | jq '[.info[] | select(.detail | contains(".doer/"))] | length > 0')"

# --- git-checks.sh weakened-tests, and its composition into stage-checks.sh pre-review ---
# Every case builds its own tiny repo (main = base, feature/x = work) so one
# failing fixture never leaks state into the next. Output of the subcommand is
# TSV: kind<TAB>file<TAB>line<TAB>text.
WT_TAB=$'\t'
WT_ROOT="$TMPDIR_TEST/wt"
WT_COUNT=0
WT_OUT=""
WT_EXIT=0

wt_new() { # fresh repo, cwd moves into it
  WT_COUNT=$((WT_COUNT + 1))
  new_scratch_repo "$WT_ROOT/r$WT_COUNT" main
  cd "$WT_ROOT/r$WT_COUNT" || exit 1
}
wt_base() { git add -A && git commit -q --no-verify -m base && git checkout -q -b feature/x; }
wt_work() { git add -A && git commit -q --no-verify -m work; }
wt_run() { WT_OUT="$("$GIT_CHECKS_SH" weakened-tests main 2>/dev/null)"; WT_EXIT=$?; }

# wt_expect <desc> <kind> <file> [old-or-new line]: finding present and exit 1
wt_expect() {
  local needle="$2${WT_TAB}$3${WT_TAB}"
  [ -z "${4:-}" ] || needle="${needle}$4${WT_TAB}"
  assert_eq "$1" "yes:1" "$(printf '%s\n' "$WT_OUT" | grep -qF -- "$needle" && echo yes):$WT_EXIT"
}
# wt_expect_none <desc>: nothing reported and exit 0
wt_expect_none() { assert_eq "$1" "0:" "$WT_EXIT:$WT_OUT"; }

# wt_write <file> <line>...: write the lines to the file (creating dirs)
wt_write() {
  local target="$1"; shift
  mkdir -p "$(dirname "$target")"
  printf '%s\n' "$@" > "$target"
}

# wt_meta <ID> <plan-files-json> [justifications-json]
wt_meta() {
  mkdir -p ".doer/tickets/$1"
  jq -n --argjson f "$2" --argjson j "${3:-[]}" \
    '{test_command:"true",lint_command:"true",typecheck_command:"true",plan:{files:$f},test_weakening_justifications:$j}' \
    > ".doer/tickets/$1/metadata.json"
}
wt_pre() { PRE_OUT="$("$STAGE_CHECKS_SH" pre-review "$1" "${2:-main}" 2>/dev/null)"; PRE_EXIT=$?; }
wt_wcount() {
  local count
  count="$(printf '%s' "$PRE_OUT" | jq --arg k "$1" '[.[$k][] | select(.kind == "weakened-tests")] | length' 2>/dev/null)"
  echo "${count:-0}"
}

# usage tables document the new subcommand
assert_eq "git-checks usage lists weakened-tests" "yes" \
  "$("$GIT_CHECKS_SH" 2>&1 | grep -qF 'weakened-tests' && echo yes)"
assert_eq "stage-checks usage names the weakened-tests blocker kind" "yes" \
  "$("$STAGE_CHECKS_SH" 2>&1 | grep -qF 'weakened-tests' && echo yes)"

# usage and bad base exit 2
wt_new
wt_write FooTest.kt 'assertEquals(a, b)'
wt_base
"$GIT_CHECKS_SH" weakened-tests no-such-base >/dev/null 2>&1
assert_eq "weakened-tests: unknown base exits 2" "2" "$?"
"$GIT_CHECKS_SH" weakened-tests >/dev/null 2>&1
assert_eq "weakened-tests: missing base argument exits 2" "2" "$?"
wt_run
wt_expect_none "weakened-tests: empty diff reports nothing and exits 0"

# --- removed assertions: table, one row per assertion name (positive = reported with OLD line 2) ---
while IFS='|' read -r WT_FILE WT_LINE; do
  [ -n "$WT_FILE" ] || continue
  wt_new
  wt_write "$WT_FILE" 'keep' "$WT_LINE" 'tail'
  wt_base
  wt_write "$WT_FILE" 'keep' 'tail'
  wt_work; wt_run
  wt_expect "weakened-tests: removed '$WT_LINE' in $WT_FILE is reported at old line 2" removed-assertion "$WT_FILE" 2
done <<'EOF'
FooTest.kt|assertEquals(a, b)
FooTest.kt|assertThat(x).isTrue()
FooTest.kt|assertTrue(result)
FooTest.kt|expectThat(x).isEqualTo(1)
FooTest.kt|verify(mock).call()
FooTest.kt|verify { mock.call() }
FooTest.kt|coVerify { mock.call() }
FooTest.kt|verifyNoMoreInteractions(mock)
FooTest.kt|assertFailsWith<IllegalStateException> {
FooTest.kt|assertThrows<IllegalStateException> {
foo.test.ts|assert.equal(a, b)
foo.test.ts|expect(x).toBe(1)
FooTests.swift|XCTAssertEqual(a, b)
FooTests.swift|#expect(a == b)
FooTests.swift|#require(a)
tests/check.go|assert_eq!(a, b)
test_foo.py|self.assertEqual(a, b)
EOF

# --- removed lines that are NOT assertions (boundary negatives) ---
while IFS='|' read -r WT_FILE WT_LINE; do
  [ -n "$WT_FILE" ] || continue
  wt_new
  wt_write "$WT_FILE" 'keep' "$WT_LINE" 'tail'
  wt_base
  wt_write "$WT_FILE" 'keep' 'tail'
  wt_work; wt_run
  wt_expect_none "weakened-tests: removing '$WT_LINE' in $WT_FILE reports nothing"
done <<'EOF'
FooTest.kt|unexpected(x)
FooTest.kt|myassert(x)
FooTest.kt|unverified(x)
FooTest.kt|myXCTAssertLike(x)
FooTest.kt|val coVerifyAll = true
FooTest.kt|println("hello")
FooTest.kt|// assertEquals(a, b)
FooTest.kt| * verify(mock).call()
test_foo.py|# self.assertEqual(a, b)
test_foo.py|# assert x
src/Foo.kt|assertEquals(a, b)
EOF

# --- commented-out assertions count as removals ---
while IFS='|' read -r WT_FILE WT_OLD WT_NEW; do
  [ -n "$WT_FILE" ] || continue
  wt_new
  wt_write "$WT_FILE" 'keep' "$WT_OLD" 'tail'
  wt_base
  wt_write "$WT_FILE" 'keep' "$WT_NEW" 'tail'
  wt_work; wt_run
  wt_expect "weakened-tests: '$WT_OLD' rewritten as '$WT_NEW' is a removed assertion" removed-assertion "$WT_FILE" 2
done <<'EOF'
FooTest.kt|assertEquals(a, b)|// assertEquals(a, b)
foo.test.ts|expect(x).toBe(1)|// expect(x).toBe(1)
foo.test.ts|expect(x).toBe(1)|/* expect(x).toBe(1) */
test_foo.py|self.assertEqual(a, b)|# self.assertEqual(a, b)
FooTests.swift|#expect(a == b)|// #expect(a == b)
EOF

# equivalent assertion swapped in keeps the net count equal
wt_new
wt_write FooTest.kt 'keep' 'assertEquals(1, x)' 'tail'
wt_base
wt_write FooTest.kt 'keep' 'assertThat(x).isEqualTo(1)' 'tail'
wt_work; wt_run
wt_expect_none "weakened-tests: an equivalent assertion added (net equal) reports nothing"

# single-line removal deep in the file: hunk form "@@ -12 +11,0 @@"
wt_new
{ for n in 1 2 3 4 5 6 7 8 9 10 11; do printf 'line%s\n' "$n"; done
  printf 'assertEquals(1, x)\n'; printf 'line13\nline14\n'; } > FooTest.kt
wt_base
{ for n in 1 2 3 4 5 6 7 8 9 10 11; do printf 'line%s\n' "$n"; done
  printf 'line13\nline14\n'; } > FooTest.kt
wt_work; wt_run
wt_expect "weakened-tests: single-line removal reports the old line 12" removed-assertion FooTest.kt 12

# a removed '--count;' next to a removed expect(, then added '++i;', no trailing newline
wt_new
printf 'keep\nexpect(a).toBe(1);\n--count;' > foo.test.js
wt_base
printf 'keep\n++i;' > foo.test.js
wt_work; wt_run
wt_expect "weakened-tests: '--count;' / '++i;' body lines do not confuse the diff parser" removed-assertion foo.test.js 2

# --- moves cancel as multisets; deficits are counted ---
wt_new
wt_write ATest.kt 'keep' 'assertEquals(1, a)' 'assertEquals(2, b)' 'assertEquals(3, c)'
wt_write BTest.kt 'other'
wt_base
wt_write ATest.kt 'keep'
wt_write BTest.kt 'other' 'assertEquals(1, a)' 'assertEquals(2, b)' 'assertEquals(3, c)'
wt_work; wt_run
wt_expect_none "weakened-tests: moving 3 assertions between test files reports nothing"

wt_new
wt_write FooTest.kt 'keep' 'assertEquals(1, a)' 'assertEquals(2, b)' 'assertEquals(3, c)' 'assertEquals(4, d)' 'assertEquals(5, e)'
wt_base
wt_write FooTest.kt 'keep' 'assertNotNull(a)' 'assertNotNull(b)' 'assertNotNull(c)' 'assertNotNull(d)'
wt_work; wt_run
wt_expect "weakened-tests: replacing 5 assertions with 4 reports the removed ones" removed-assertion FooTest.kt 2
wt_meta WTD-1 '[{"path":"FooTest.kt","change":"edit"}]'
wt_pre WTD-1
assert_eq "pre-review: 5 assertions replaced by 4 blocks without a justification" "1" "$PRE_EXIT"
wt_meta WTD-1 '[{"path":"FooTest.kt","change":"edit"}]' \
  '[{"path":"FooTest.kt","line_text":"assertEquals(1, a)","reason":"one assertion was redundant"}]'
wt_pre WTD-1
assert_eq "pre-review: exactly one justification covers a deficit of one (exit 0, justified INFO)" "0:yes" \
  "$PRE_EXIT:$([ "$(wt_wcount info)" -ge 1 ] && echo yes)"

# --- disabled markers: table (positive = reported as disabled) ---
while IFS='|' read -r WT_FILE WT_LINE; do
  [ -n "$WT_FILE" ] || continue
  wt_new
  wt_write "$WT_FILE" 'keep'
  wt_base
  wt_write "$WT_FILE" 'keep' "$WT_LINE"
  wt_work; wt_run
  wt_expect "weakened-tests: added '$WT_LINE' in $WT_FILE is a disabled finding" disabled "$WT_FILE"
done <<'EOF'
FooTest.kt|@Ignore
FooTest.kt|@Ignore("flaky")
FooTest.kt|@Disabled
FooTest.kt|@Disabled("flaky")
foo.test.ts|xit('a', () => {})
foo.test.ts|xdescribe('a', () => {})
foo.test.ts|xtest('a', () => {})
foo.test.ts|it.skip('a', () => {})
foo.test.ts|test.skip('a', () => {})
foo.test.ts|describe.skip('a', () => {})
foo.test.ts|context.skip('a', () => {})
foo.test.ts|suite.skip('a', () => {})
foo.test.ts|test.describe.skip('a', () => {})
foo.test.ts|it.concurrent.skip('a', () => {})
foo.test.ts|describe.concurrent.skip('a', () => {})
foo.test.ts|it.skip.each([1])('a', () => {})
foo.test.ts|this.skip()
FooTests.swift|try XCTSkip("later")
FooTests.swift|@Test(.disabled("later"))
FooTests.swift|@Suite(.disabled("later")) struct S {}
EOF

# --- disabled false positives (boundary negatives) ---
while IFS='|' read -r WT_FILE WT_LINE; do
  [ -n "$WT_FILE" ] || continue
  wt_new
  wt_write "$WT_FILE" 'keep'
  wt_base
  wt_write "$WT_FILE" 'keep' "$WT_LINE"
  wt_work; wt_run
  wt_expect_none "weakened-tests: added '$WT_LINE' in $WT_FILE stays clean"
done <<'EOF'
FooTest.kt|@IgnoredOnParcel
FooTest.kt|@DisabledIf("cond")
FooTest.kt|MyXCTSkipHelper()
FooTest.kt|val s = list.stream().skip(1)
FooTest.kt|// @Disabled
foo.test.ts|foo.this.skip()
foo.test.ts|skipLink(1)
foo.test.ts|form.submit.skip('a')
foo.test.ts|latest.skip(1)
foo.test.ts|button.disabled(true)
test/setup.ts|process.exit(1)
FooTests.swift|button.disabled(true)
src/Foo.kt|@Ignore
EOF

# disabled marker already present and unchanged, or just re-indented / moved inside the file
wt_new
wt_write FooTest.kt '@Ignore' 'fun a() {}' 'fun b() {}'
wt_base
wt_write FooTest.kt '@Ignore' 'fun a() {}' 'fun b() {}' 'fun c() {}'
wt_work; wt_run
wt_expect_none "weakened-tests: an unchanged @Ignore is not new"
wt_new
wt_write FooTest.kt '@Ignore' 'fun a() {}' 'fun b() {}'
wt_base
wt_write FooTest.kt 'fun a() {}' '    @Ignore' 'fun b() {}'
wt_work; wt_run
wt_expect_none "weakened-tests: a re-indented / moved @Ignore in the same file is not new"

# disabled marker moved between files is clean; a newly added one in the same diff still blocks
wt_new
wt_write A.test.ts 'keep' "it.skip('x', () => {})"
wt_base
wt_write A.test.ts 'keep'
wt_write B.test.ts "it.skip('x', () => {})"
wt_work; wt_run
wt_expect_none "weakened-tests: an it.skip( moved from A.test.ts to B.test.ts reports nothing"
wt_new
wt_write A.test.ts 'keep' "it.skip('x', () => {})"
wt_base
wt_write A.test.ts 'keep'
wt_write B.test.ts "it.skip('x', () => {})" "xit('new', () => {})"
wt_work; wt_run
wt_expect "weakened-tests: a newly added xit( next to a moved it.skip( still blocks" disabled B.test.ts
assert_eq "weakened-tests: only the new marker is reported, not the moved one" "1" \
  "$(printf '%s\n' "$WT_OUT" | grep -c "^disabled${WT_TAB}")"
wt_new
wt_write ATest.kt 'keep' '@Disabled'
wt_write BTest.kt 'other'
wt_base
wt_write ATest.kt 'keep'
wt_write BTest.kt 'other' '@Disabled'
wt_work; wt_run
wt_expect_none "weakened-tests: a @Disabled moved from ATest.kt to BTest.kt reports nothing"

# --- block-commented assertions ---
wt_new
wt_write FooTest.kt 'class FooTest {' '    fun a() {' '        assertEquals(1, x)' '        assertEquals(2, y)' '    }' '}'
wt_base
wt_write FooTest.kt 'class FooTest {' '    fun a() {' '        /*' '        assertEquals(1, x)' '        assertEquals(2, y)' '        */' '    }' '}'
wt_work; wt_run
wt_expect "weakened-tests: wrapping two unchanged assertions in /* */ is block-commented" block-commented FooTest.kt
wt_new
wt_write Other.kt 'keep'
wt_base
wt_write FooTest.kt '/*' ' * Copyright 2026' ' */' 'class FooTest {' '    /**' '     * Explains the test.' '     */' '    fun a() {' '        assertEquals(1, x)' '    }' '}'
wt_work; wt_run
wt_expect_none "weakened-tests: a new test file with a license header and KDoc stays clean"
wt_new
wt_write FooTest.kt 'class FooTest {' '    fun a() {' '        assertEquals(1, x)' '    }' '}'
wt_base
wt_write FooTest.kt 'class FooTest {' '    /**' '     * Explains the test.' '     */' '    fun a() {' '        assertEquals(1, x)' '    }' '}'
wt_work; wt_run
wt_expect_none "weakened-tests: adding KDoc above an existing test stays clean"

# --- deleted tests and renames ---
wt_new
wt_write FooTest.kt 'keep' 'assertEquals(1, a)' 'assertEquals(2, b)' 'assertEquals(3, c)'
wt_write src/Foo.kt 'assertEquals(9, z)'
wt_base
git rm -q FooTest.kt src/Foo.kt
wt_work; wt_run
wt_expect "weakened-tests: a deleted test file is a deleted-test at line 0" deleted-test FooTest.kt 0
assert_eq "weakened-tests: a deleted test file is exactly one finding (no per-assertion noise)" "1" \
  "$(printf '%s\n' "$WT_OUT" | grep -c .)"
wt_meta WTD-2 '[]'
wt_pre WTD-2
assert_eq "pre-review: an unplanned deleted test file is exactly one weakened-tests BLOCKER" "1" "$(wt_wcount blockers)"
assert_eq "pre-review: ... and exits 1" "1" "$PRE_EXIT"
wt_meta WTD-2 '[{"path":"FooTest.kt","change":"delete"}]'
wt_pre WTD-2
assert_eq "pre-review: a deleted test planned as change delete has zero weakened-tests blockers" "0" "$(wt_wcount blockers)"
assert_eq "pre-review: ... and exits 0" "0" "$PRE_EXIT"

wt_new
wt_write FooTest.kt 'keep' 'assertEquals(1, a)' 'assertEquals(2, b)'
wt_base
git mv FooTest.kt BarTest.kt
wt_work; wt_run
wt_expect_none "weakened-tests: a pure rename (R100) reports nothing"

wt_new
wt_write FooTest.kt 'package a' 'class FooTest {' '  fun a() {' '    assertEquals(1, x)' '    println(1)' '  }' '}'
wt_base
git mv FooTest.kt BarTest.kt
wt_write BarTest.kt 'package a' 'class FooTest {' '  fun a() {' '    println(1)' '  }' '}'
wt_work; wt_run
wt_expect "weakened-tests: a rename plus a removed assertion is reported under the new path, old line" removed-assertion BarTest.kt 4

wt_new
wt_write FooTest.kt 'keep' 'assertEquals(1, a)' 'assertEquals(2, b)'
wt_base
mkdir -p src && git mv FooTest.kt src/Foo.kt
wt_work; wt_run
wt_expect "weakened-tests: a test renamed to a non-test path is a deleted-test for the old path" deleted-test FooTest.kt
assert_eq "weakened-tests: ... and only that one finding" "1" "$(printf '%s\n' "$WT_OUT" | grep -c .)"
wt_meta WTD-3 '[{"path":"FooTest.kt","change":"delete"}]'
wt_pre WTD-3
assert_eq "pre-review: test-to-non-test rename listed change delete exits 0 (scope sees both paths)" "0" "$PRE_EXIT"
assert_eq "pre-review: ... with zero weakened-tests blockers" "0" "$(wt_wcount blockers)"
wt_meta WTD-3 '[]'
wt_pre WTD-3
assert_eq "pre-review: the same rename unplanned is one weakened-tests BLOCKER" "1" "$(wt_wcount blockers)"

wt_new
wt_write FooTest.kt 'keep' 'assertEquals(1, a)' 'assertEquals(2, b)'
wt_base
git mv FooTest.kt FooTest.kt.disabled
wt_work; wt_run
wt_expect "weakened-tests: FooTest.kt renamed to FooTest.kt.disabled is a deleted-test" deleted-test FooTest.kt
assert_eq "weakened-tests: ... and exactly one finding" "1" "$(printf '%s\n' "$WT_OUT" | grep -c .)"
wt_meta WTD-4 '[{"path":"FooTest.kt","change":"delete"}]'
wt_pre WTD-4
assert_eq "pre-review: the .disabled rename listed change delete has zero weakened-tests blockers" "0" "$(wt_wcount blockers)"

wt_new
wt_write __tests__/snap.snap 'exports[`a`] = 1;'
wt_write __tests__/data.json '{"a":1}'
wt_write src/Gone.kt 'assertEquals(1, 1)'
wt_base
git rm -q __tests__/snap.snap __tests__/data.json src/Gone.kt
wt_work; wt_run
wt_expect_none "weakened-tests: deleted .snap/.json fixtures and a deleted non-test file report nothing"

# user git config cannot change the result
wt_new
git config diff.renames false
git config diff.noprefix true
wt_write FooTest.kt 'package a' 'class FooTest {' '  fun a() {' '    assertEquals(1, x)' '    println(1)' '  }' '}'
wt_write other.txt 'x'
wt_base
git mv FooTest.kt BarTest.kt
wt_write BarTest.kt 'package a' 'class FooTest {' '  fun a() {' '    println(1)' '  }' '}'
wt_write other.txt 'y'
wt_work; wt_run
wt_expect "weakened-tests: diff.renames=false and diff.noprefix=true do not change the result" removed-assertion BarTest.kt 4

# .doer/** is never analysed
wt_new
wt_write .doer/tickets/X/FooTest.kt 'keep' 'assertEquals(1, a)'
wt_base
wt_write .doer/tickets/X/FooTest.kt 'keep'
wt_work; wt_run
wt_expect_none "weakened-tests: changes under .doer/** are ignored"

# --- pre-review integration ---
wt_removal_fixture() { # FooTest.kt loses assertTrue(result); ticket metadata is written by the caller
  wt_new
  wt_write FooTest.kt 'class FooTest {' '    fun a() {' '        assertTrue(result)' '        assertEquals(1, x)' '    }' '}'
  wt_base
  wt_write FooTest.kt 'class FooTest {' '    fun a() {' '        assertEquals(1, x)' '    }' '}'
  wt_work
}
WT_PLAN_FOO='[{"path":"FooTest.kt","change":"edit"}]'

wt_new
wt_write FooTest.kt 'keep'
wt_base
wt_write FooTest.kt 'keep' '@Disabled'
wt_work
wt_meta WTP-1 "$WT_PLAN_FOO"
wt_pre WTP-1
assert_eq "pre-review: a newly disabled test is a weakened-tests BLOCKER" "1" "$(wt_wcount blockers)"
assert_eq "pre-review: ... and exits 1" "1" "$PRE_EXIT"

wt_removal_fixture
wt_meta WTP-2 "$WT_PLAN_FOO"
wt_pre WTP-2
assert_eq "pre-review: a removed assertion is a weakened-tests BLOCKER" "1" "$(wt_wcount blockers)"
assert_eq "pre-review: ... and exits 1" "1" "$PRE_EXIT"
WT_DETAIL="$(printf '%s' "$PRE_OUT" | jq -r '[.blockers[] | select(.kind == "weakened-tests")][0].detail')"
assert_eq "pre-review: BLOCKER detail format is '<kind> <file>:<line> <text>'" "yes" \
  "$(printf '%s' "$WT_DETAIL" | grep -qF 'removed-assertion FooTest.kt:3 assertTrue(result)' && echo yes)"
assert_eq "pre-review: BLOCKER detail carries the exact metadata.sh write registration command" "yes" \
  "$(printf '%s' "$WT_DETAIL" | grep -qF '"${CLAUDE_PLUGIN_ROOT}/lib/helpers/metadata.sh" write WTP-2 '"'"'.test_weakening_justifications = ((.test_weakening_justifications // []) + [{path: $p, line_text: $t, reason: $r}])'"'"' --arg p '"'"'FooTest.kt'"'"' --arg t '"'"'assertTrue(result)'"'"' --arg r ' && echo yes)"
assert_eq "pre-review: BLOCKER detail also offers the batched --argjson j form" "yes" \
  "$(printf '%s' "$WT_DETAIL" | grep -qF -- '--argjson j' && echo yes)"

wt_meta WTP-2 "$WT_PLAN_FOO" '[{"path":"FooTest.kt","line_text":"assertTrue(result)","reason":"covered by the new integration test"}]'
wt_pre WTP-2
assert_eq "pre-review: a matching justification clears the BLOCKER" "0" "$(wt_wcount blockers)"
assert_eq "pre-review: ... and exits 0" "0" "$PRE_EXIT"
assert_eq "pre-review: ... the finding is INFO carrying (justified: <reason>)" "yes" \
  "$(printf '%s' "$PRE_OUT" | jq -r '[.info[] | select(.kind == "weakened-tests") | .detail][0] // ""' \
     | grep -qF '(justified: covered by the new integration test)' && echo yes)"

wt_meta WTP-2 "$WT_PLAN_FOO" '[{"path":"FooTest.kt","line_text":"assertTrue(result)","reason":"   "}]'
wt_pre WTP-2
assert_eq "pre-review: a blank reason does not downgrade" "1" "$PRE_EXIT"
wt_meta WTP-2 "$WT_PLAN_FOO" '[{"path":"FooTest.kt","line_text":"assertTrue(other)","reason":"a different line"}]'
wt_pre WTP-2
assert_eq "pre-review: a justification for a different line never excuses this one" "1" "$PRE_EXIT"
wt_meta WTP-2 "$WT_PLAN_FOO" '[{"path":"Other.kt","line_text":"assertTrue(result)","reason":"a different file"}]'
wt_pre WTP-2
assert_eq "pre-review: a justification for a different path never excuses this one" "1" "$PRE_EXIT"
wt_meta WTP-2 "$WT_PLAN_FOO" '["foo", 1, null]'
wt_pre WTP-2
assert_eq "pre-review: malformed justification entries still print JSON, block, and exit 1" "1:1" \
  "$PRE_EXIT:$(wt_wcount blockers)"

# two identical removals, one justification: the second stays a BLOCKER
wt_new
wt_write FooTest.kt 'class FooTest {' '    fun a() {' '        assertTrue(result)' '    }' '    fun b() {' '        assertTrue(result)' '    }' '}'
wt_base
wt_write FooTest.kt 'class FooTest {' '    fun a() {' '    }' '    fun b() {' '    }' '}'
wt_work
wt_meta WTP-3 "$WT_PLAN_FOO" '[{"path":"FooTest.kt","line_text":"assertTrue(result)","reason":"first one is redundant"}]'
wt_pre WTP-3
assert_eq "pre-review: one justification does not cover a second identical removal" "1" "$PRE_EXIT"
assert_eq "pre-review: ... at least one weakened-tests BLOCKER remains" "yes" \
  "$([ "$(wt_wcount blockers)" -ge 1 ] && echo yes)"
wt_meta WTP-3 "$WT_PLAN_FOO" '[{"path":"FooTest.kt","line_text":"assertTrue(result)","reason":"first"},{"path":"FooTest.kt","line_text":"assertTrue(result)","reason":"second"}]'
wt_pre WTP-3
assert_eq "pre-review: two entries cover two identical removals (count matching, two INFO)" "0:2" "$PRE_EXIT:$(wt_wcount info)"

# justified removal followed by a second, unjustified removal in the same file
wt_new
wt_write FooTest.kt 'class FooTest {' '    fun a() {' '        assertTrue(result)' '        assertEquals(1, x)' '    }' '}'
wt_base
wt_write FooTest.kt 'class FooTest {' '    fun a() {' '    }' '}'
wt_work
wt_meta WTP-4 "$WT_PLAN_FOO" '[{"path":"FooTest.kt","line_text":"assertTrue(result)","reason":"redundant"}]'
wt_pre WTP-4
assert_eq "pre-review: a second, unjustified removal in the same file still blocks" "1" "$PRE_EXIT"
assert_eq "pre-review: ... as a weakened-tests BLOCKER" "yes" "$([ "$(wt_wcount blockers)" -ge 1 ] && echo yes)"

# block-commented and commented-out through pre-review
wt_new
wt_write foo.test.ts 'keep' 'expect(x).toBe(1)'
wt_base
wt_write foo.test.ts 'keep' '// expect(x).toBe(1)'
wt_work
wt_meta WTP-5 '[{"path":"foo.test.ts","change":"edit"}]'
wt_pre WTP-5
assert_eq "pre-review: a commented-out assertion in foo.test.ts exits 1" "1" "$PRE_EXIT"
assert_eq "pre-review: ... as a weakened-tests BLOCKER" "1" "$(wt_wcount blockers)"

# invalid base stops the stage with exit 2, never clean and never a fixable BLOCKER
wt_removal_fixture
wt_meta WTP-6 "$WT_PLAN_FOO"
wt_pre WTP-6 no-such-base
assert_eq "pre-review: an invalid base exits 2" "2" "$PRE_EXIT"
assert_eq "pre-review: an invalid base prints no clean result" "" "$PRE_OUT"

# .doer/** and empty diff
wt_new
wt_write .doer/tickets/X/FooTest.kt 'keep' 'assertEquals(1, a)'
wt_write f.txt 'a'
wt_base
wt_write .doer/tickets/X/FooTest.kt 'keep'
wt_work
wt_meta WTP-7 '[]'
wt_pre WTP-7
assert_eq "pre-review: .doer/** test changes are ignored (exit 0)" "0" "$PRE_EXIT"
wt_new
wt_write f.txt 'a'
wt_base
wt_meta WTP-8 '[]'
wt_pre WTP-8
assert_eq "pre-review: an empty diff exits 0" "0" "$PRE_EXIT"

# CRLF: trimmed identically when printed and when matched
wt_new
printf 'class FooTest {\r\n    fun a() {\r\n        assertTrue(done)\r\n    }\r\n}\r\n' > FooTest.kt
wt_base
printf 'class FooTest {\r\n    fun a() {\r\n    }\r\n}\r\n' > FooTest.kt
wt_work; wt_run
wt_expect "weakened-tests: a CRLF file reports its removed assertion" removed-assertion FooTest.kt 3
assert_eq "weakened-tests: printed text carries no carriage return" "0" \
  "$(printf '%s' "$WT_OUT" | grep -c $'\r')"
wt_meta WTP-9 "$WT_PLAN_FOO" '[{"path":"FooTest.kt","line_text":"assertTrue(done)","reason":"crlf ok"}]'
wt_pre WTP-9
assert_eq "pre-review: a justification matches the CRLF line once trimmed" "0:1" "$PRE_EXIT:$(wt_wcount info)"

# batching: two findings in two files, one combined write, then pre-review is clean
wt_new
wt_write ATest.kt 'keep' 'assertEquals(1, a)'
wt_write b.test.ts 'keep' 'expect(b).toBe(2)'
wt_base
wt_write ATest.kt 'keep'
wt_write b.test.ts 'keep'
wt_work
wt_meta WTP-10 '[{"path":"ATest.kt","change":"edit"},{"path":"b.test.ts","change":"edit"}]'
wt_pre WTP-10
assert_eq "pre-review: two findings in two files give two BLOCKERs" "2" "$(wt_wcount blockers)"
"$METADATA_SH" write WTP-10 \
  '.test_weakening_justifications = ((.test_weakening_justifications // []) + $j)' \
  --argjson j '[{"path":"ATest.kt","line_text":"assertEquals(1, a)","reason":"dup"},{"path":"b.test.ts","line_text":"expect(b).toBe(2)","reason":"dup"}]' \
  >/dev/null 2>&1
wt_pre WTP-10
assert_eq "pre-review: one combined justification write clears both files (exit 0, two INFO)" "0:2" "$PRE_EXIT:$(wt_wcount info)"

# command safety: run the printed command verbatim, plugin path containing a space
WT_PLUGIN="$TMPDIR_TEST/plug dir/plugin"
mkdir -p "$WT_PLUGIN"
cp -R "$REPO_ROOT/lib" "$WT_PLUGIN/lib"
wt_new
wt_write FooTest.kt 'keep' 'assertEquals("a", b)'
wt_write foo.test.ts 'keep' "expect(x).toBe('y')" "expect(s).toBe('\$(touch PWNED)')"
wt_base
wt_write FooTest.kt 'keep'
wt_write foo.test.ts 'keep'
wt_work
wt_meta WTP-11 '[{"path":"FooTest.kt","change":"edit"},{"path":"foo.test.ts","change":"edit"}]'
wt_pre WTP-11
assert_eq "pre-review: command-safety fixture has three BLOCKERs" "3" "$(wt_wcount blockers)"
for WT_NEEDLE in 'assertEquals("a", b)' "expect(x).toBe('y')" "expect(s).toBe('\$(touch PWNED)')"; do
  WT_DETAIL="$(printf '%s' "$PRE_OUT" | jq -r --arg t "$WT_NEEDLE" \
    '[.blockers[] | select(.kind == "weakened-tests" and (.detail | contains($t)))][0].detail')"
  WT_CMD='"${CLAUDE_PLUGIN_ROOT}'"${WT_DETAIL#*'"${CLAUDE_PLUGIN_ROOT}'}"
  WT_CMD="${WT_CMD//\'<why>\'/\'don\'\\\'\'t\'}"
  CLAUDE_PLUGIN_ROOT="$WT_PLUGIN" bash -c "$WT_CMD" >/dev/null 2>&1
  assert_eq "command safety: the printed command runs verbatim for $WT_NEEDLE" "0" "$?"
done
assert_eq "command safety: three justifications were recorded" "3" \
  "$(jq '.test_weakening_justifications | length' .doer/tickets/WTP-11/metadata.json)"
assert_eq "command safety: the reason with an apostrophe round-trips" "don't" \
  "$(jq -r '.test_weakening_justifications[0].reason' .doer/tickets/WTP-11/metadata.json)"
assert_eq "command safety: a line_text with quotes round-trips" "yes" \
  "$(jq -e '[.test_weakening_justifications[].line_text] | index("expect(x).toBe('"'"'y'"'"')") != null' \
     .doer/tickets/WTP-11/metadata.json >/dev/null 2>&1 && echo yes)"
assert_eq "command safety: \$(touch PWNED) was never executed" "none" \
  "$([ -e PWNED ] || [ -e "$WT_PLUGIN/PWNED" ] && echo found || echo none)"
wt_pre WTP-11
assert_eq "command safety: pre-review then downgrades every finding to INFO (exit 0)" "0" "$PRE_EXIT"
assert_eq "command safety: ... three justified INFO entries" "3" "$(wt_wcount info)"

# --- har.py ---
HAR_DIR="$TMPDIR_TEST/har"
mkdir -p "$HAR_DIR"
cd "$HAR_DIR" || exit 1

python3 - <<'PY'
import json, base64
body1 = json.dumps({"data": {"orders": [1, 2, 3]}, "token": "abcXYZ123token456secretvalue789", "email": "user@example.com"})
body2 = "plain text response, not json"
har = {"log": {"entries": [
    {"request": {"method": "GET", "url": "https://api.example.com/orders?ctx=6x3Srun",
                 "headers": [{"name": "Authorization", "value": "Bearer secret"}]},
     "response": {"status": 200, "headers": [{"name": "Set-Cookie", "value": "sid=abc"}],
                  "content": {"size": len(body1.encode()), "text": body1}}},
    {"request": {"method": "GET", "url": "https://api.example.com/other", "headers": []},
     "response": {"status": 500, "headers": [], "content": {"size": len(body2.encode()), "text": body2}}},
    {"request": {"method": "POST", "url": "https://api.example.com/b64", "headers": []},
     "response": {"status": 200, "headers": [],
                  "content": {"size": 999, "encoding": "base64", "text": base64.b64encode(b'{"x":1}').decode()}}},
]}}
json.dump(har, open("fixture.har", "w"))
PY

LIST_OUT="$(python3 "$HAR_PY" list fixture.har)"
assert_eq "har.py list: one line per entry" "3" "$(printf '%s\n' "$LIST_OUT" | wc -l | tr -d ' ')"
printf '%s\n' "$LIST_OUT" | grep -qF '0: GET 200 104B https://api.example.com/orders?ctx=6x3Srun' \
  && pass "har.py list: method/status/size/url format" || fail "har.py list: method/status/size/url format" "got: $LIST_OUT"

HEAD_OUT="$(python3 "$HAR_PY" head fixture.har 0)"
assert_eq "har.py head: exits 0 on a clean JSON body" "0" "$?"
printf '%s\n' "$HEAD_OUT" | grep -q "^keys: \['data', 'token', 'email'\]$" \
  && pass "har.py head: reports the top-level keys" || fail "har.py head: reports the top-level keys" "got: $HEAD_OUT"

python3 "$HAR_PY" head fixture.har 1 > /dev/null 2>&1
assert_eq "har.py head: a non-JSON body exits 1" "1" "$?"

python3 "$HAR_PY" head fixture.har 2 > /dev/null 2>&1
assert_eq "har.py head: reported content.size mismatching the decoded body exits 1 (truncated)" "1" "$?"

DIGEST_OUT="$(python3 "$HAR_PY" digest fixture.har ctx)"
assert_eq "har.py digest: filters by term across url+body" "GET 200 https://api.example.com/orders?ctx=6x3Srun" "$DIGEST_OUT"

SCAN_OUT="$(python3 "$HAR_PY" scan fixture.har 0)"
assert_eq "har.py scan: flags the Authorization header as a token, without its value" "true" \
  "$(printf '%s' "$SCAN_OUT" | jq 'any(.[]; .where == "header" and .path == "Authorization" and .kind == "token")')"
assert_eq "har.py scan: flags the token body key" "true" \
  "$(printf '%s' "$SCAN_OUT" | jq 'any(.[]; .where == "body" and .path == "$.token" and .kind == "secret-key")')"
assert_eq "har.py scan: flags the email-shaped value" "true" \
  "$(printf '%s' "$SCAN_OUT" | jq 'any(.[]; .where == "body" and .path == "$.email" and .kind == "email")')"
assert_eq "har.py scan: never prints an actual value" "false" \
  "$(printf '%s' "$SCAN_OUT" | grep -q 'secretvalue789' && echo true || echo false)"

# --- har.py splice: a tricky body (quotes, backslash, newline, tab, a
# control char, a literal $, and non-ASCII), verified against the REAL
# target-language interpreter/compiler where one is installed, never
# against another language's parser (the plan's own SKIP rule).
python3 - <<'PY'
import json
msg = 'quote" back\\slash\nnewline\ttab ctrl:' + chr(1) + ' dollar:$ accent:cafe end'
body = json.dumps({"msg": msg}, ensure_ascii=False)
har = {"log": {"entries": [
    {"request": {"method": "GET", "url": "https://x/tricky", "headers": []},
     "response": {"status": 200, "headers": [], "content": {"size": len(body.encode()), "text": body}}}
]}}
json.dump(har, open("tricky.har", "w"), ensure_ascii=False)
PY
EXPECTED_BODY="$(python3 -c "import json; print(json.load(open('tricky.har'))['log']['entries'][0]['response']['content']['text'], end='')")"

printf 'fun main() {\n    val forced = REPLAY_RAW\n    print(forced)\n}\n' > t.kt
SPLICE_OUT="$(python3 "$HAR_PY" splice tricky.har 0 --target t.kt --marker REPLAY_RAW --lang kotlin)"
assert_eq "har.py splice: exits 0 and reports url/bytes/sha256/chunks" "0" "$?"
printf '%s\n' "$SPLICE_OUT" | grep -qE '^https://x/tricky, [0-9]+ bytes, sha256:[0-9a-f]{12}, chunks:1$' \
  && pass "har.py splice: summary line format" || fail "har.py splice: summary line format" "got: $SPLICE_OUT"
if command -v kotlinc >/dev/null 2>&1; then
  kotlinc t.kt -include-runtime -d t.jar > /dev/null 2>&1 \
    && KOTLIN_OUT="$(java -jar t.jar 2>/dev/null)" \
    && assert_eq "har.py splice: kotlin round-trip via kotlinc+java matches the body" "$EXPECTED_BODY" "$KOTLIN_OUT"
else
  echo "SKIP  har.py splice: kotlin round-trip (kotlinc not installed)"
fi

printf 'let forced = REPLAY_RAW\nprint(forced, terminator: "")\n' > t.swift
python3 "$HAR_PY" splice tricky.har 0 --target t.swift --marker REPLAY_RAW --lang swift > /dev/null
if command -v swift >/dev/null 2>&1; then
  SWIFT_OUT="$(swift t.swift 2>/dev/null)"
  assert_eq "har.py splice: swift round-trip via swift matches the body" "$EXPECTED_BODY" "$SWIFT_OUT"
else
  echo "SKIP  har.py splice: swift round-trip (swift not installed)"
fi

printf 'forced = REPLAY_RAW\nimport sys\nsys.stdout.write(forced)\n' > t.py
python3 "$HAR_PY" splice tricky.har 0 --target t.py --marker REPLAY_RAW --lang python > /dev/null
PYTHON_OUT="$(python3 t.py)"
assert_eq "har.py splice: python round-trip via python3 matches the body" "$EXPECTED_BODY" "$PYTHON_OUT"

printf 'const forced = REPLAY_RAW;\nprocess.stdout.write(forced);\n' > t.js
python3 "$HAR_PY" splice tricky.har 0 --target t.js --marker REPLAY_RAW --lang typescript > /dev/null
if command -v node >/dev/null 2>&1; then
  NODE_OUT="$(node t.js 2>/dev/null)"
  assert_eq "har.py splice: typescript round-trip via node matches the body" "$EXPECTED_BODY" "$NODE_OUT"
else
  echo "SKIP  har.py splice: typescript round-trip (node not installed)"
fi

if command -v go >/dev/null 2>&1; then
  printf 'package main\nimport ("fmt"; "os")\nfunc main() { forced := REPLAY_RAW; fmt.Fprint(os.Stdout, forced) }\n' > t.go
  python3 "$HAR_PY" splice tricky.har 0 --target t.go --marker REPLAY_RAW --lang go > /dev/null
  GO_OUT="$(go run t.go 2>/dev/null)"
  assert_eq "har.py splice: go round-trip via go run matches the body" "$EXPECTED_BODY" "$GO_OUT"
else
  echo "SKIP  har.py splice: go round-trip (go not installed)"
fi

# chunked mode (forced via a tiny --max-bytes), still byte-exact
printf 'fun main() {\n    val forced = REPLAY_RAW\n    print(forced)\n}\n' > tc.kt
CHUNK_SUMMARY="$(python3 "$HAR_PY" splice tricky.har 0 --target tc.kt --marker REPLAY_RAW --lang kotlin --max-bytes 20)"
printf '%s\n' "$CHUNK_SUMMARY" | grep -qE 'chunks:[2-9]' \
  && pass "har.py splice: a tiny --max-bytes actually forces multiple chunks" \
  || fail "har.py splice: a tiny --max-bytes actually forces multiple chunks" "got: $CHUNK_SUMMARY"
if command -v kotlinc >/dev/null 2>&1; then
  kotlinc tc.kt -include-runtime -d tc.jar > /dev/null 2>&1 \
    && KOTLIN_CHUNKED_OUT="$(java -jar tc.jar 2>/dev/null)" \
    && assert_eq "har.py splice: chunked kotlin round-trip still matches the body" "$EXPECTED_BODY" "$KOTLIN_CHUNKED_OUT"
else
  echo "SKIP  har.py splice: chunked kotlin round-trip (kotlinc not installed)"
fi

printf 'val x = REPLAY_RAW\n' > redact.kt
python3 "$HAR_PY" splice fixture.har 0 --target redact.kt --marker REPLAY_RAW --lang kotlin --redact '$.token' > /dev/null
grep -q '\[REDACTED\]' redact.kt && pass "har.py splice --redact: replaces the value with a placeholder before emitting" \
  || fail "har.py splice --redact: replaces the value with a placeholder before emitting"
grep -q 'secretvalue789' redact.kt && fail "har.py splice --redact: the real value must never reach the target file" \
  || pass "har.py splice --redact: the real value never reaches the target file"

printf 'val x = 1\n' > noreplaymarker.kt
python3 "$HAR_PY" splice fixture.har 0 --target noreplaymarker.kt --marker REPLAY_RAW --lang kotlin > /dev/null 2>&1
assert_eq "har.py splice: marker not found exits 1, file untouched" "1" "$?"
assert_eq "har.py splice: marker not found leaves the file byte-identical" "val x = 1" "$(cat noreplaymarker.kt)"

printf 'val x = REPLAY_RAW\nval y = REPLAY_RAW\n' > dupmarker.kt
BEFORE_DUP="$(cat dupmarker.kt)"
python3 "$HAR_PY" splice fixture.har 0 --target dupmarker.kt --marker REPLAY_RAW --lang kotlin > /dev/null 2>&1
assert_eq "har.py splice: a duplicated marker exits 1, file untouched" "1" "$?"
assert_eq "har.py splice: duplicated marker leaves the file byte-identical" "$BEFORE_DUP" "$(cat dupmarker.kt)"

printf 'val x = REPLAY_RAW\n' > badlang.kt
python3 "$HAR_PY" splice fixture.har 0 --target badlang.kt --marker REPLAY_RAW --lang rust > /dev/null 2>&1
assert_eq "har.py splice: an unlisted --lang exits 1, file untouched" "1" "$?"

python3 "$HAR_PY" splice fixture.har 0 --target badlang.kt --marker REPLAY_RAW > /dev/null 2>&1
assert_eq "har.py splice: missing --lang is a usage error (exit 2)" "2" "$?"

python3 - <<'PY'
import json
body = 'some """ literal triple quote text'
har = {"log": {"entries": [{"request": {"method": "GET", "url": "https://x/q3", "headers": []},
  "response": {"status": 200, "headers": [], "content": {"size": len(body.encode()), "text": body}}}]}}
json.dump(har, open("quote3.har", "w"))
PY
printf 'val x = REPLAY_RAW\n' > quote3.kt
BEFORE_Q3="$(cat quote3.kt)"
python3 "$HAR_PY" splice quote3.har 0 --target quote3.kt --marker REPLAY_RAW --lang kotlin > /dev/null 2>&1
assert_eq "har.py splice: a literal triple-quote under --max-bytes refuses the Kotlin raw-string path (exit 1)" "1" "$?"
assert_eq "har.py splice: that refusal leaves the file untouched" "$BEFORE_Q3" "$(cat quote3.kt)"
printf 'x = REPLAY_RAW\n' > quote3.py
python3 "$HAR_PY" splice quote3.har 0 --target quote3.py --marker REPLAY_RAW --lang python > /dev/null 2>&1
assert_eq "har.py splice: the same triple-quote body is fine for a non-Kotlin target" "0" "$?"

python3 - <<'PY'
import json, base64
raw = b'\xff\xfe\x00invalid utf8'
har = {"log": {"entries": [{"request": {"method": "GET", "url": "https://x/bad", "headers": []},
  "response": {"status": 200, "headers": [], "content": {"size": len(raw), "encoding": "base64", "text": base64.b64encode(raw).decode()}}}]}}
json.dump(har, open("badutf8.har", "w"))
PY
printf 'val x = REPLAY_RAW\n' > badutf8.kt
BEFORE_BAD="$(cat badutf8.kt)"
python3 "$HAR_PY" splice badutf8.har 0 --target badutf8.kt --marker REPLAY_RAW --lang kotlin > /dev/null 2>&1
assert_eq "har.py splice: a non-UTF-8 body exits 1, file untouched" "1" "$?"
assert_eq "har.py splice: non-UTF-8 refusal leaves the file byte-identical" "$BEFORE_BAD" "$(cat badutf8.kt)"

cd "$REPO_ROOT" || exit 1

# --- ac-graph.py (01-ac.md Step 5.5: integrity pass, merge, split, render-table) ---
AC_DIR="$TMPDIR_TEST/ac-graph"
mkdir -p "$AC_DIR"
cd "$AC_DIR" || exit 1

new_ac_fixture() { # writes a fresh, valid 3-candidate draft.json in cwd
  python3 - <<'PY'
import json
draft = {
  "in_scope": ["AC-1: GIVEN a WHEN b THEN c", "AC-2: GIVEN x WHEN y THEN z", "AC-3: GIVEN p WHEN q THEN r"],
  "candidates": [
    {"candidate_id": "C-1", "status": "active", "ac": "AC-1", "text": "GIVEN a WHEN b THEN c"},
    {"candidate_id": "C-2", "status": "active", "ac": "AC-2", "text": "GIVEN x WHEN y THEN z"},
    {"candidate_id": "C-3", "status": "active", "ac": "AC-3", "text": "GIVEN p WHEN q THEN r"},
  ],
  "out_of_scope": [{"id": "OOS-1", "text": "not in scope"}],
  "open_questions_resolved": [],
  "merged": [],
  "source_map": [
    {"obligation_id": "O-1", "origins": [{"section": "Acceptance Criteria", "bullet": "bullet 1"}], "added_by": None,
     "disposition": {"type": "ac", "ref": "C-1"}, "fidelity": {"verdict": "match", "note": "ok"}},
    {"obligation_id": "O-2", "origins": [{"section": "Acceptance Criteria", "bullet": "bullet 2"}], "added_by": None,
     "disposition": {"type": "ac", "ref": "C-2"}, "fidelity": {"verdict": "match", "note": "ok"}},
    {"obligation_id": "O-3", "origins": [{"section": "Acceptance Criteria", "bullet": "bullet 3"}], "added_by": None,
     "disposition": {"type": "ac", "ref": "C-3"}, "fidelity": {"verdict": "partial", "note": "drops x"}},
    {"obligation_id": "O-4", "origins": [{"section": "Scope", "bullet": "bullet 4"}], "added_by": None,
     "disposition": {"type": "out_of_scope", "ref": "OOS-1"}, "fidelity": None},
  ],
  "discarded_intake_items": [], "applicable_lessons": [],
  "self_review": {"ran": True, "rounds": 1, "findings": [], "dev_accepted": [], "dev_rejected": []},
}
json.dump(draft, open("draft.json", "w"), indent=2)
PY
}

new_ac_fixture
python3 "$AC_GRAPH_PY" validate draft.json > /dev/null 2>&1
assert_eq "ac-graph validate: a well-formed draft passes" "0" "$?"

python3 -c "
import json
d = json.load(open('draft.json'))
del d['source_map'][0]['disposition']
json.dump(d, open('nodisp.json', 'w'))
"
NODISP_OUT="$(python3 "$AC_GRAPH_PY" validate nodisp.json)"
NODISP_EXIT=$?
assert_eq "ac-graph validate: a missing disposition fails, named by obligation_id" "1" "$NODISP_EXIT"
printf '%s' "$NODISP_OUT" | jq -e '.violations[] | select(startswith("O-1"))' > /dev/null 2>&1
assert_eq "ac-graph validate: the violation names the offending O-N" "0" "$?"

new_ac_fixture
echo '{"candidate_id": "C-3", "merge_into_candidate_id": "C-1", "survivor_text": "GIVEN a OR p WHEN b OR q THEN c OR r", "explain": "combined"}' > f1.json
MERGE_OUT="$(python3 "$AC_GRAPH_PY" merge draft.json --finding f1.json)"
assert_eq "ac-graph merge: exits 0" "0" "$?"
printf '%s\n' "$MERGE_OUT" | grep -qF 'merged C-3 -> C-1 (AC-1)' \
  && pass "ac-graph merge: summary names dropped, survivor, and new AC" || fail "ac-graph merge: summary line" "got: $MERGE_OUT"
assert_eq "ac-graph merge: renumbers to exactly AC-1, AC-2" '["AC-1","AC-2"]' \
  "$(jq -c '[.candidates[] | select(.status == "active") | .ac]' draft.json)"
assert_eq "ac-graph merge: the merged[] row carries undo data" "true" \
  "$(jq '.merged[0] | has("survivor_prev_text") and has("redirected_edges") and has("survivor_post_hash")' draft.json)"
assert_eq "ac-graph merge: merged_into_ac is the survivor's new AC-N" "AC-1" "$(jq -r '.merged[0].merged_into_ac' draft.json)"
assert_eq "ac-graph merge: fidelity resets on every row resolving to the survivor (O-1 direct, O-3 via the merge)" '["O-1","O-3"]' \
  "$(jq -c '[.source_map[] | select(.fidelity.verdict == "unreviewed") | .obligation_id] | sort' draft.json)"
python3 "$AC_GRAPH_PY" validate draft.json > /dev/null 2>&1
assert_eq "ac-graph merge: the result still validates" "0" "$?"

# Flatten-edges: C-3 -> C-2, then C-2 -> C-1; C-3's entry must retarget to C-1.
new_ac_fixture
echo '{"candidate_id": "C-3", "merge_into_candidate_id": "C-2", "survivor_text": "GIVEN x OR p WHEN y OR q THEN z OR r", "explain": "m1"}' > f1.json
python3 "$AC_GRAPH_PY" merge draft.json --finding f1.json > /dev/null
echo '{"candidate_id": "C-2", "merge_into_candidate_id": "C-1", "survivor_text": "EVERYTHING COMBINED", "explain": "m2"}' > f2.json
python3 "$AC_GRAPH_PY" merge draft.json --finding f2.json > /dev/null
assert_eq "ac-graph merge: flatten-edges redirects C-3's entry onto the new survivor C-1" "C-1" \
  "$(jq -r '.merged[] | select(.candidate_id == "C-3") | .merge_into_candidate_id' draft.json)"
assert_eq "ac-graph merge: the C-2 -> C-1 entry records C-3 in redirected_edges" '["C-3"]' \
  "$(jq -c '.merged[] | select(.candidate_id == "C-2") | .redirected_edges' draft.json)"
python3 "$AC_GRAPH_PY" validate draft.json > /dev/null 2>&1
assert_eq "ac-graph merge: a two-hop merge chain still validates (flattened, not chained)" "0" "$?"

python3 "$AC_GRAPH_PY" split draft.json C-2 > /dev/null
assert_eq "ac-graph split: C-2 reactivates" "active" "$(jq -r '.candidates[] | select(.candidate_id == "C-2") | .status' draft.json)"
assert_eq "ac-graph split: C-3's flattened edge un-flattens back onto C-2, not left dangling on C-1" "C-2" \
  "$(jq -r '.merged[] | select(.candidate_id == "C-3") | .merge_into_candidate_id' draft.json)"
assert_eq "ac-graph split: C-3 itself is still merged (only C-2 was split)" "merged" \
  "$(jq -r '.candidates[] | select(.candidate_id == "C-3") | .status' draft.json)"
python3 "$AC_GRAPH_PY" validate draft.json > /dev/null 2>&1
assert_eq "ac-graph split: the result still validates" "0" "$?"

# Hash protection (the round-3 Codex fix): split refuses out of order, then
# succeeds once the later merge is undone first; an unrelated dev edit is
# caught the same way a later merge is.
new_ac_fixture
echo '{"candidate_id": "C-3", "merge_into_candidate_id": "C-1", "survivor_text": "SURV V1", "explain": "m1"}' > f1.json
python3 "$AC_GRAPH_PY" merge draft.json --finding f1.json > /dev/null
BEFORE_BAD_SPLIT="$(cat draft.json)"
echo '{"candidate_id": "C-2", "merge_into_candidate_id": "C-1", "survivor_text": "SURV V2", "explain": "m2"}' > f2.json
python3 "$AC_GRAPH_PY" merge draft.json --finding f2.json > /dev/null
BEFORE_REFUSED="$(cat draft.json)"
python3 "$AC_GRAPH_PY" split draft.json C-3 > /dev/null 2>&1
assert_eq "ac-graph split: refuses an out-of-order split (survivor changed by a later merge)" "1" "$?"
assert_eq "ac-graph split: a refused split leaves the draft byte-identical" "$BEFORE_REFUSED" "$(cat draft.json)"
python3 "$AC_GRAPH_PY" split draft.json C-2 > /dev/null
python3 "$AC_GRAPH_PY" split draft.json C-3 > /dev/null 2>&1
assert_eq "ac-graph split: undoing the later merge first, then the older one, both succeed" "0" "$?"

new_ac_fixture
echo '{"candidate_id": "C-2", "merge_into_candidate_id": "C-1", "survivor_text": "SURV", "explain": "m"}' > f1.json
python3 "$AC_GRAPH_PY" merge draft.json --finding f1.json > /dev/null
python3 -c "
import json
d = json.load(open('draft.json'))
for c in d['candidates']:
    if c['candidate_id'] == 'C-1':
        c['text'] = 'SURV, but a dev edit added more'
json.dump(d, open('draft.json', 'w'))
"
python3 "$AC_GRAPH_PY" split draft.json C-2 > /dev/null 2>&1
assert_eq "ac-graph split: a dev edit to the survivor (not another merge) is caught the same way" "1" "$?"

python3 -c "
import json
d = json.load(open('draft.json'))
d['merged'].append({'candidate_id': 'C-3', 'merge_into_candidate_id': 'C-1', 'merged_into_ac': 'AC-1', 'dropped': 'legacy', 'reason': 'pre-7.10.0'})
for c in d['candidates']:
    if c['candidate_id'] == 'C-3':
        c['status'] = 'merged'; c['ac'] = None
json.dump(d, open('legacy_merge.json', 'w'))
"
BEFORE_LEGACY="$(cat legacy_merge.json)"
python3 "$AC_GRAPH_PY" split legacy_merge.json C-3 > /dev/null 2>&1
assert_eq "ac-graph split: a pre-7.10.0 merge with no undo data is refused" "1" "$?"
assert_eq "ac-graph split: that refusal leaves the draft byte-identical" "$BEFORE_LEGACY" "$(cat legacy_merge.json)"

new_ac_fixture
RENDER_OUT="$(python3 "$AC_GRAPH_PY" render-table draft.json)"
assert_eq "ac-graph render-table: one row per origins entry across all 4 obligations" "4" \
  "$(printf '%s\n' "$RENDER_OUT" | grep -c '^| "')"
printf '%s\n' "$RENDER_OUT" | grep -qF '| "bullet 3" | Acceptance Criteria | AC-3 | partial |' \
  && pass "ac-graph render-table: a partial-fidelity row renders correctly" \
  || fail "ac-graph render-table: a partial-fidelity row renders correctly" "got: $RENDER_OUT"
assert_eq "ac-graph render-table: exactly one row needs attention (the partial one)" "ATTENTION 1 O-3" \
  "$(printf '%s\n' "$RENDER_OUT" | tail -1)"

python3 -c "
import json
d = json.load(open('draft.json'))
d['source_map'].append({'obligation_id': 'O-99', 'disposition': {'type': 'ac', 'ref': 'C-1'}, 'fidelity': {'verdict': 'match', 'note': 'x'}})
json.dump(d, open('legacy_row.json', 'w'))
"
LEGACY_RENDER="$(python3 "$AC_GRAPH_PY" render-table legacy_row.json)"
printf '%s\n' "$LEGACY_RENDER" | grep -qF '| "(persisted text, not a ticket quote)" | unknown | AC-1 | unreviewed |' \
  && pass "ac-graph render-table: a legacy row with no origins renders as unknown/unreviewed" \
  || fail "ac-graph render-table: a legacy row with no origins renders as unknown/unreviewed" "got: $LEGACY_RENDER"

# --- DOER-5: squash-gate reads only added lines; every base-taking check fails closed ---
# Each case builds its own tiny repo (main = base, feature/x = work), so the only
# marker in a diff is the one the case is about.
FC_ROOT="$TMPDIR_TEST/fc"
FC_COUNT=0
FC_OUT=""
FC_EXIT=0
fc_new() { # fresh repo, cwd moves into it
  FC_COUNT=$((FC_COUNT + 1))
  new_scratch_repo "$FC_ROOT/r$FC_COUNT" main
  cd "$FC_ROOT/r$FC_COUNT" || exit 1
}
fc_base() { git add -A && git commit -q --no-verify -m base && git checkout -q -b feature/x; }
fc_work() { git add -A && git commit -q --no-verify -m work; }
fc_run() { FC_OUT="$("$@" 2>/dev/null)"; FC_EXIT=$?; }

# fc_fail <git-subcommand> <command...>: runs the command with a git shim first
# on PATH that exits 128 for that one subcommand (skipping git's global options
# such as -c and -C) and execs the real git otherwise. The shim lives only in a
# subshell, so PATH never leaks into later tests.
FC_REAL_GIT="$(command -v git)"
FC_SHIM_DIR="$TMPDIR_TEST/fc-shim"
mkdir -p "$FC_SHIM_DIR"
cat > "$FC_SHIM_DIR/git" <<'SHIM'
#!/usr/bin/env bash
args=("$@")
idx=0
while [ "$idx" -lt "$#" ]; do
  case "${args[$idx]}" in
    -c|-C) idx=$((idx + 2)) ;;
    --no-pager|--no-optional-locks|--git-dir=*|--work-tree=*) idx=$((idx + 1)) ;;
    *) break ;;
  esac
done
[ "${args[$idx]:-}" = "$FC_FAIL_SUB" ] && exit 128
exec "$FC_REAL_GIT" "$@"
SHIM
chmod +x "$FC_SHIM_DIR/git"
fc_fail() {
  local failing_subcommand="$1"
  shift
  ( PATH="$FC_SHIM_DIR:$PATH"; FC_FAIL_SUB="$failing_subcommand"; FC_REAL_GIT="$FC_REAL_GIT"
    export PATH FC_FAIL_SUB FC_REAL_GIT
    "$@" ) >/dev/null 2>&1
  FC_EXIT=$?
}

# squash-gate: a marker that is only context, hunk header or removed is not a trace
fc_new
printf 'PROTOLOG - old\n    mid\n    target\n    tail\n' > ctx.txt
fc_base
printf 'PROTOLOG - old\n    mid\n    changed\n    tail\n' > ctx.txt
fc_work
fc_run "$GIT_CHECKS_SH" squash-gate main
assert_eq "squash-gate: a marker only in a context line exits 0" "0" "$FC_EXIT"

fc_new
fc_header_file() { # fc_header_file <last-line>: marker line, ten filler lines, then <last-line>
  printf 'PROTOLOG - legacy\n'
  for fc_line in 1 2 3 4 5 6 7 8 9 10; do printf '    filler %s\n' "$fc_line"; done
  printf '    %s\n' "$1"
}
fc_header_file target > hdr.txt
fc_base
fc_header_file changed > hdr.txt
fc_work
assert_eq "squash-gate fixture: the hunk header really carries the marker" "yes" \
  "$(git diff main..HEAD | grep -q '^@@.*PROTOLOG - legacy' && echo yes)"
fc_run "$GIT_CHECKS_SH" squash-gate main
assert_eq "squash-gate: a marker only in a hunk header exits 0" "0" "$FC_EXIT"

fc_new
printf '    a\nPROTOLOG - gone\n    b\n' > rm.txt
fc_base
printf '    a\n    b\n' > rm.txt
fc_work
fc_run "$GIT_CHECKS_SH" squash-gate main
assert_eq "squash-gate: a marker line removed on the branch exits 0" "0" "$FC_EXIT"

# squash-gate: real added markers are still caught and printed with their file
fc_new
printf 'a\n' > keep.txt
fc_base
printf 'println("PROTOLOG - x")\n' > rep.kt
fc_work
fc_run "$GIT_CHECKS_SH" squash-gate main
assert_eq "squash-gate: an added PROTOLOG line exits 1" "1" "$FC_EXIT"
assert_eq "squash-gate: ... and prints the added line" "yes" \
  "$(printf '%s\n' "$FC_OUT" | grep -qF 'PROTOLOG - x' && echo yes)"
assert_eq "squash-gate: ... prefixed with the file it was added to" "yes" \
  "$(printf '%s\n' "$FC_OUT" | grep -q '^rep.kt: ' && echo yes)"

for fc_marker in 'PROTOLOG_RESPONSE - body' 'REPLAY-ORIG: x' 'REPLAY END T1'; do
  fc_new
  printf 'a\n' > keep.txt
  fc_base
  printf 'val x = "%s"\n' "$fc_marker" > rep.kt
  fc_work
  fc_run "$GIT_CHECKS_SH" squash-gate main
  assert_eq "squash-gate: an added '$fc_marker' line exits 1" "1" "$FC_EXIT"
done

fc_new
printf 'PROTOLOG - old\n    mid\n    target\n    tail\n' > ctx.txt
fc_base
printf 'PROTOLOG - old\n    mid\n    // REPLAY START T1\n    tail\n' > ctx.txt
fc_work
fc_run "$GIT_CHECKS_SH" squash-gate main
assert_eq "squash-gate: a context marker does not mask a real added marker" "1" "$FC_EXIT"

fc_new
printf 'a\n' > keep.txt
fc_base
printf '+ PROTOLOG - x\n' > plus.txt
fc_work
fc_run "$GIT_CHECKS_SH" squash-gate main
assert_eq "squash-gate: an added line that itself starts with + is not mistaken for a header" "1" "$FC_EXIT"

# squash-gate and ac-leak must not depend on the user's diff configuration
fc_new
printf 'a\n' > keep.txt
fc_base
printf 'println("PROTOLOG - x") // AC-1\n' > rep.kt
fc_work
FC_COLOR_CONFIG="'color.diff'='always'"
FC_OUT="$(GIT_CONFIG_PARAMETERS="$FC_COLOR_CONFIG" "$GIT_CHECKS_SH" squash-gate main 2>/dev/null)"; FC_EXIT=$?
assert_eq "squash-gate: color.diff=always does not hide an added marker" "1" "$FC_EXIT"
FC_OUT="$(GIT_CONFIG_PARAMETERS="$FC_COLOR_CONFIG" "$GIT_CHECKS_SH" ac-leak main 2>/dev/null)"; FC_EXIT=$?
assert_eq "ac-leak: color.diff=always does not hide an added AC label" "1" "$FC_EXIT"
FC_OUT="$(GIT_CONFIG_PARAMETERS="'diff.external'='true'" "$GIT_CHECKS_SH" squash-gate main 2>/dev/null)"; FC_EXIT=$?
assert_eq "squash-gate: an external diff driver does not hide an added marker" "1" "$FC_EXIT"

# every base-taking check: an unusable base, or a git error, exits 2 and never 0
fc_new
printf 'a\n' > f.txt
printf 'g\n' > g.txt
fc_base
printf 'a2\n' > f.txt
fc_work
for fc_cmd in diff-files secrets ac-leak squash-gate phantoms classify-diff doer-history weakened-tests; do
  fc_run "$GIT_CHECKS_SH" "$fc_cmd" no-such-base
  assert_eq "git-checks $fc_cmd: an unusable base exits 2" "2" "$FC_EXIT"
done
for fc_cmd in diff-files secrets ac-leak squash-gate phantoms classify-diff weakened-tests; do
  fc_fail diff "$GIT_CHECKS_SH" "$fc_cmd" main
  assert_eq "git-checks $fc_cmd: a git diff error exits 2" "2" "$FC_EXIT"
done
fc_fail log "$GIT_CHECKS_SH" doer-history main
assert_eq "git-checks doer-history: a git log error exits 2" "2" "$FC_EXIT"
fc_fail log "$GIT_CHECKS_SH" temp-rounds PROTOLOG
assert_eq "git-checks temp-rounds: a git log error exits 2" "2" "$FC_EXIT"
fc_fail grep "$GIT_CHECKS_SH" trace PROTOLOG
assert_eq "git-checks trace: a git grep error exits 2" "2" "$FC_EXIT"
fc_fail status "$GIT_CHECKS_SH" revert-in-progress
assert_eq "git-checks revert-in-progress: a git status error exits 2" "2" "$FC_EXIT"
fc_fail diff git -c a.b=c diff
assert_eq "fc_fail shim: git -c a.b=c diff is intercepted" "128" "$FC_EXIT"
fc_fail diff git rev-parse HEAD
assert_eq "fc_fail shim: other git subcommands pass through" "0" "$FC_EXIT"

# pre-review: an unusable base or a git error stops the stage with exit 2
wt_meta FC-1 '[]'
fc_run "$STAGE_CHECKS_SH" pre-review FC-1 no-such-base
assert_eq "pre-review: an unusable base exits 2" "2" "$FC_EXIT"
fc_fail diff "$STAGE_CHECKS_SH" pre-review FC-1 main
assert_eq "pre-review: a git diff error exits 2" "2" "$FC_EXIT"

# doer-history: the range is a revision, not a path
fc_new
mkdir -p .doer/tickets/X
printf '{}\n' > .doer/tickets/X/metadata.json
printf 'a\n' > f.txt
git add -f -A && git commit -q --no-verify -m "old doer commit"
printf 'a2\n' > f.txt
fc_base
printf 'b\n' > g.txt
fc_work
fc_run "$GIT_CHECKS_SH" doer-history main
assert_eq "doer-history: a .doer commit before the base is not listed" "" "$FC_OUT"
printf '{"in":"range"}\n' > .doer/tickets/X/metadata.json
git add -f -A && git commit -q --no-verify -m "doer(X): in range"
fc_run "$GIT_CHECKS_SH" doer-history main
assert_eq "doer-history: a .doer commit inside the range is listed" "1" "$(printf '%s\n' "$FC_OUT" | sed '/^$/d' | wc -l | tr -d ' ')"
fc_run "$GIT_OPS_SH" scrub-history main X doer
assert_eq "scrub-history: verification ignores .doer commits before the base" "0" "$FC_EXIT"
fc_run "$GIT_CHECKS_SH" doer-history main
assert_eq "scrub-history: nothing is left in the range afterwards" "" "$FC_OUT"

cd "$REPO_ROOT" || exit 1

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
