#!/usr/bin/env bash
# Smoke tests for wk plugin helper scripts (preferences.sh + jira.sh).
#
# Run from anywhere:
#   bash tests/helpers.sh
#
# No external frameworks: bash + jq only. preferences.sh runs against a temp
# global file; jira.sh runs against a temp project directory (it reads/writes
# ./.doer/config.json relative to cwd). Prints PASS / FAIL per test; exits
# non-zero on any failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFS_SH="${REPO_ROOT}/lib/helpers/preferences.sh"
JIRA_SH="${REPO_ROOT}/lib/helpers/jira.sh"

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

cd "$REPO_ROOT" || exit 1

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
