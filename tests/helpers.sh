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

cd "$REPO_ROOT" || exit 1

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
