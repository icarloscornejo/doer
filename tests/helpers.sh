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

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
