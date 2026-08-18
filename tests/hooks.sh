#!/usr/bin/env bash
# Smoke tests for wk plugin PreToolUse guards (hooks/*.sh, hooks/replay-restore.py).
#
# Run from anywhere:
#   bash tests/hooks.sh
#
# No external frameworks: bash + jq + python3. Every scenario runs in a fresh
# scratch git repo under a temp dir. This is the FIRST test file for any hook
# in this repo; it exists specifically to close the gap that let
# protolog-temp-commit-integrity-guard.sh ship fail-open (7.7.0): a hook with
# no test is a hook nobody notices going dead.
#
# IMPORTANT test-harness note, learned the hard way while writing this file:
# never call run_guard() via `SZ=$(run_guard ...)` command substitution.
# That forks a subshell around the WHOLE function call, and the guard's own
# `bash "$guard"` then runs as a child of that subshell, not of this script,
# which breaks the $PPID match against the session marker (named after this
# script's own $$) and makes every guard look silently inert regardless of
# what it actually decided. Call run_guard() as a plain statement, then read
# the output file's size separately via guard_out_size() (safe to wrap in
# $(...), since by then the guard has already run to completion in the
# foreground and nothing further is $PPID-sensitive).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROTOLOG_INTEGRITY="${REPO_ROOT}/hooks/protolog-temp-commit-integrity-guard.sh"
PROTOLOG_REVERT="${REPO_ROOT}/hooks/protolog-revert-conflict-guard.sh"
REPLAY_INTEGRITY="${REPO_ROOT}/hooks/replay-temp-commit-integrity-guard.sh"
REPLAY_REVERT="${REPO_ROOT}/hooks/replay-revert-conflict-guard.sh"
REPLAY_RESTORE="${REPO_ROOT}/hooks/replay-restore.py"
GIT_COMMIT_GUARD="${REPO_ROOT}/hooks/git-commit-no-verify-guard.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+ -- $2}"; }

assert_eq() { # assert_eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

run_guard() { # run_guard <guard> <command-string> <outfile>. Plain statement only, see header.
  local guard="$1" cmd="$2" out="$3"
  printf '%s' "{\"tool_input\":{\"command\":\"${cmd}\"}}" | bash "$guard" > "$out"
}
guard_out_size() { # guard_out_size <outfile>: 0 = allow (silent), >0 = deny (JSON on stdout).
  wc -c < "$1" | tr -d ' '
}

new_scratch_repo() { # new_scratch_repo <dir>: init + one base commit
  local dir="$1"
  mkdir -p "$dir"
  ( cd "$dir" \
    && git init -q . \
    && git config user.email t@t.t \
    && git config user.name t )
}

write_marker() { # write_marker <dir> <skill>: marker keyed to the CURRENT shell's $$,
  # which must equal the $PPID the guard sees, since the guard runs as this
  # script's direct child (see the header note on why never $()).
  local dir="$1" skill="$2"
  mkdir -p "$dir/.doer"
  printf '{"pid":%d,"host":"%s","skill":"%s","touched_at":%d}\n' \
    "$$" "$(hostname)" "$skill" "$(date +%s)" > "$dir/.doer/wk-session-$$.json"
}

# --- syntax ---
bash -n "$PROTOLOG_INTEGRITY" && pass "protolog-temp-commit-integrity-guard.sh parses" || fail "protolog-temp-commit-integrity-guard.sh parses"
bash -n "$PROTOLOG_REVERT" && pass "protolog-revert-conflict-guard.sh parses" || fail "protolog-revert-conflict-guard.sh parses"
bash -n "$REPLAY_INTEGRITY" && pass "replay-temp-commit-integrity-guard.sh parses" || fail "replay-temp-commit-integrity-guard.sh parses"
bash -n "$REPLAY_REVERT" && pass "replay-revert-conflict-guard.sh parses" || fail "replay-revert-conflict-guard.sh parses"
bash -n "$GIT_COMMIT_GUARD" && pass "git-commit-no-verify-guard.sh parses" || fail "git-commit-no-verify-guard.sh parses"
python3 -c "import ast; ast.parse(open('${REPLAY_RESTORE}').read())" \
  && pass "replay-restore.py parses" || fail "replay-restore.py parses"
jq . "${REPO_ROOT}/hooks/hooks.json" > /dev/null && pass "hooks.json is valid JSON" || fail "hooks.json is valid JSON"

# =====================================================================
# protolog-temp-commit-integrity-guard.sh: the fail-open regression
# =====================================================================
DIR="$TMPDIR_TEST/protolog-prod-shape"
new_scratch_repo "$DIR"
cd "$DIR" || exit 1
printf 'fun a() {\n    val x = 1\n}\n' > Foo.kt
git add -A && git commit -q --no-verify -m base
write_marker "$DIR" protologs
printf 'fun a() {\n    val x = 1\n    val leaked = refactorProhibido()\n    println("PROTOLOG - hola")\n}\n' > Foo.kt

run_guard "$PROTOLOG_INTEGRITY" \
  'git add -A && git commit --no-verify -m \"[TEMP] PROTOLOG round 1. DO NOT MERGE\"' \
  "$DIR/out.txt"
SZ=$(guard_out_size "$DIR/out.txt")
if [ "$SZ" -gt 0 ]; then
  pass "protolog integrity guard denies a forbidden refactor under the REAL production command shape (git add -A && git commit, nothing pre-staged)"
else
  fail "protolog integrity guard denies a forbidden refactor under the REAL production command shape" \
    "guard allowed it (this is the exact 7.7.0 regression: --cached alone sees an empty index before git add -A runs)"
fi

git checkout -q -- Foo.kt
printf 'fun a() {\n    val x = 1\n    println("PROTOLOG - solo log")\n}\n' > Foo.kt
run_guard "$PROTOLOG_INTEGRITY" \
  'git add -A && git commit --no-verify -m \"[TEMP] PROTOLOG round 2. DO NOT MERGE\"' \
  "$DIR/out2.txt"
SZ=$(guard_out_size "$DIR/out2.txt")
assert_eq "protolog integrity guard allows a clean PROTOLOG-only addition" "0" "$SZ"

run_guard "$PROTOLOG_INTEGRITY" \
  'git add -A && git commit --no-verify -m \"unrelated real commit\"' \
  "$DIR/out3.txt"
SZ=$(guard_out_size "$DIR/out3.txt")
assert_eq "protolog integrity guard is inert on a non-[TEMP]-PROTOLOG commit" "0" "$SZ"

cd "$REPO_ROOT" || exit 1

# =====================================================================
# replay-restore.py: byte-exact restore-equality invariant
# =====================================================================
DIR="$TMPDIR_TEST/restore"
mkdir -p "$DIR"
cd "$DIR" || exit 1

printf 'fun a() {\n    val x = 1\n}\n' > parent.kt
printf 'fun a() {\n    // REPLAY START T1\n    // REPLAY-ORIG:    val x = 1\n    val x = FORCED\n// REPLAY END T1\n}\n' > post_ok.kt
python3 "$REPLAY_RESTORE" check post_ok.kt parent.kt > /dev/null 2>&1
assert_eq "replay-restore.py check: well-formed block matches parent" "0" "$?"

printf 'fun a() {\n    val leaked = true\n    // REPLAY START T1\n    // REPLAY-ORIG:    val x = 1\n    val x = FORCED\n// REPLAY END T1\n}\n' > post_bad.kt
python3 "$REPLAY_RESTORE" check post_bad.kt parent.kt > /dev/null 2>&1
assert_eq "replay-restore.py check: line added outside a block is denied (exit 1)" "1" "$?"

printf 'fun a() {\n    // REPLAY START T1\n    // REPLAY-ORIG:    val x = 1\n    val x = FORCED\n}\n' > post_unbal.kt
python3 "$REPLAY_RESTORE" check post_unbal.kt parent.kt > /dev/null 2>&1
assert_eq "replay-restore.py check: missing REPLAY END is a structural violation (exit 2)" "2" "$?"

printf 'fun a() {\n    // REPLAY START T1\n    // REPLAY START T2\n    // REPLAY END T2\n// REPLAY END T1\n}\n' > post_nested.kt
python3 "$REPLAY_RESTORE" check post_nested.kt parent.kt > /dev/null 2>&1
assert_eq "replay-restore.py check: nested REPLAY START is a structural violation (exit 2)" "2" "$?"

printf 'fun a() {\r\n    val x = 1\r\n}\r\n' > parent_crlf.kt
printf 'fun a() {\r\n    // REPLAY START T1\r\n    // REPLAY-ORIG:    val x = 1\r\n    val x = FORCED\r\n// REPLAY END T1\r\n}\r\n' > post_crlf.kt
python3 "$REPLAY_RESTORE" check post_crlf.kt parent_crlf.kt > /dev/null 2>&1
assert_eq "replay-restore.py check: CRLF line endings preserved through the round trip" "0" "$?"

printf 'fun a() {\n    val x = 1\n}' > parent_nonl.kt
printf 'fun a() {\n    // REPLAY START T1\n    // REPLAY-ORIG:    val x = 1\n    val x = FORCED\n// REPLAY END T1\n}' > post_nonl.kt
python3 "$REPLAY_RESTORE" check post_nonl.kt parent_nonl.kt > /dev/null 2>&1
assert_eq "replay-restore.py check: missing final newline preserved through the round trip" "0" "$?"

# round 2: parent already carries a round-1 block; both sides get stripped,
# so a same-site payload swap still matches.
printf 'fun a() {\n    // REPLAY START T1\n    // REPLAY-ORIG:    val x = 1\n    val x = FORCED_A\n// REPLAY END T1\n}\n' > parent_r2.kt
printf 'fun a() {\n    // REPLAY START T1\n    // REPLAY-ORIG:    val x = 1\n    val x = FORCED_B\n// REPLAY END T1\n}\n' > post_r2.kt
python3 "$REPLAY_RESTORE" check post_r2.kt parent_r2.kt > /dev/null 2>&1
assert_eq "replay-restore.py check: round 2 same-site payload swap still matches (both sides stripped)" "0" "$?"

STRIP_OUT="$(python3 "$REPLAY_RESTORE" strip post_ok.kt)"
EXPECTED="$(cat parent.kt)"
assert_eq "replay-restore.py strip: reconstructs the exact original file" "$EXPECTED" "$STRIP_OUT"

cd "$REPO_ROOT" || exit 1

# =====================================================================
# replay-temp-commit-integrity-guard.sh
# =====================================================================
DIR="$TMPDIR_TEST/replay-guard"
new_scratch_repo "$DIR"
cd "$DIR" || exit 1
printf 'fun a() {\n    val orders = api.getOrders(id)\n}\n' > Foo.kt
git add -A && git commit -q --no-verify -m base
write_marker "$DIR" replay

cat > Foo.kt <<'EOF'
fun a() {
    // REPLAY START T1
    // REPLAY-ORIG:    val orders = api.getOrders(id)
    val orders = FORCED
    println("PROTOLOG_RESPONSE - entry")
    println("PROTOLOG_RESPONSE - applied")
    // REPLAY END T1
}
EOF
run_guard "$REPLAY_INTEGRITY" \
  'git add -A && git commit --no-verify -m \"[TEMP] REPLAY PDE-1: force orders. DO NOT MERGE\"' \
  "$DIR/out_a.txt"
SZ=$(guard_out_size "$DIR/out_a.txt")
assert_eq "replay integrity guard allows a well-formed additive block with REPLAY-ORIG" "0" "$SZ"

git checkout -q -- Foo.kt
cat > Foo.kt <<'EOF'
fun a() {
    val leaked = true
    // REPLAY START T1
    // REPLAY-ORIG:    val orders = api.getOrders(id)
    val orders = FORCED
    // REPLAY END T1
}
EOF
run_guard "$REPLAY_INTEGRITY" \
  'git add -A && git commit --no-verify -m \"[TEMP] REPLAY PDE-1: force orders. DO NOT MERGE\"' \
  "$DIR/out_b.txt"
SZ=$(guard_out_size "$DIR/out_b.txt")
[ "$SZ" -gt 0 ] && pass "replay integrity guard denies a line added outside a block" \
  || fail "replay integrity guard denies a line added outside a block"

git checkout -q -- Foo.kt
cat > Foo.kt <<'EOF'
fun a() {
    // REPLAY START T1
    // REPLAY-ORIG:    val orders = api.getOrders(id)
    val orders = FORCED
    // REPLAY END T1
}
EOF
run_guard "$REPLAY_INTEGRITY" \
  'git add -A && git commit --no-verify -m \"[TEMP] REPLAY PDE-1: force orders\"' \
  "$DIR/out_c.txt"
SZ=$(guard_out_size "$DIR/out_c.txt")
[ "$SZ" -gt 0 ] && pass "replay integrity guard denies a commit message missing DO NOT MERGE" \
  || fail "replay integrity guard denies a commit message missing DO NOT MERGE"

git checkout -q -- Foo.kt
printf 'payload data' > NuevoAsset.kt
run_guard "$REPLAY_INTEGRITY" \
  'git add -A && git commit --no-verify -m \"[TEMP] REPLAY PDE-1: force orders. DO NOT MERGE\"' \
  "$DIR/out_d.txt"
SZ=$(guard_out_size "$DIR/out_d.txt")
[ "$SZ" -gt 0 ] && pass "replay integrity guard denies a brand new source file in a [TEMP] REPLAY commit" \
  || fail "replay integrity guard denies a brand new source file in a [TEMP] REPLAY commit"
rm -f NuevoAsset.kt

run_guard "$REPLAY_INTEGRITY" \
  'git add -A && git commit --no-verify -m \"unrelated real fix\"' \
  "$DIR/out_e.txt"
SZ=$(guard_out_size "$DIR/out_e.txt")
assert_eq "replay integrity guard is inert on a non-[TEMP]-REPLAY commit" "0" "$SZ"

# round 2: same-site payload swap, purely a matter of restore-equality holding.
git checkout -q -- Foo.kt
cat > Foo.kt <<'EOF'
fun a() {
    // REPLAY START T1
    // REPLAY-ORIG:    val orders = api.getOrders(id)
    val orders = FORCED_A
    // REPLAY END T1
}
EOF
git add -A && git commit -q --no-verify -m "[TEMP] REPLAY PDE-1: round 1. DO NOT MERGE"
cat > Foo.kt <<'EOF'
fun a() {
    // REPLAY START T1
    // REPLAY-ORIG:    val orders = api.getOrders(id)
    val orders = FORCED_B
    // REPLAY END T1
}
EOF
run_guard "$REPLAY_INTEGRITY" \
  'git add -A && git commit --no-verify -m \"[TEMP] REPLAY PDE-1: round 2. DO NOT MERGE\"' \
  "$DIR/out_f.txt"
SZ=$(guard_out_size "$DIR/out_f.txt")
assert_eq "replay integrity guard allows round 2 (same-site payload swap, parent already has a block)" "0" "$SZ"

# purely additive second block, no REPLAY-ORIG needed.
cat > Foo.kt <<'EOF'
fun a() {
    // REPLAY START T1
    // REPLAY-ORIG:    val orders = api.getOrders(id)
    val orders = FORCED_B
    // REPLAY END T1
    // REPLAY START T2
    println("PROTOLOG_RESPONSE - extra diagnostic")
    // REPLAY END T2
}
EOF
run_guard "$REPLAY_INTEGRITY" \
  'git add -A && git commit --no-verify -m \"[TEMP] REPLAY PDE-1: round 3. DO NOT MERGE\"' \
  "$DIR/out_g.txt"
SZ=$(guard_out_size "$DIR/out_g.txt")
assert_eq "replay integrity guard allows a purely additive block with no REPLAY-ORIG line" "0" "$SZ"

cd "$REPO_ROOT" || exit 1

# =====================================================================
# Session-marker gate: every guard must be silent with no live marker
# =====================================================================
DIR="$TMPDIR_TEST/no-marker"
new_scratch_repo "$DIR"
cd "$DIR" || exit 1
printf 'fun a() {\n    val leaked = true\n}\n' > Foo.kt
git add -A && git commit -q --no-verify -m base
# deliberately NOT calling write_marker: no .doer/wk-session-*.json exists.

run_guard "$PROTOLOG_INTEGRITY" \
  'git add -A && git commit --no-verify -m \"[TEMP] PROTOLOG round 1. DO NOT MERGE\"' \
  "$DIR/out_nomark1.txt"
SZ=$(guard_out_size "$DIR/out_nomark1.txt")
assert_eq "protolog-temp-commit-integrity-guard.sh is silent with no live session marker" "0" "$SZ"

run_guard "$REPLAY_INTEGRITY" \
  'git add -A && git commit --no-verify -m \"[TEMP] REPLAY X: y. DO NOT MERGE\"' \
  "$DIR/out_nomark2.txt"
SZ=$(guard_out_size "$DIR/out_nomark2.txt")
assert_eq "replay-temp-commit-integrity-guard.sh is silent with no live session marker" "0" "$SZ"

run_guard "$GIT_COMMIT_GUARD" \
  'git commit -m \"no marker, bare commit\"' \
  "$DIR/out_nomark3.txt"
SZ=$(guard_out_size "$DIR/out_nomark3.txt")
assert_eq "git-commit-no-verify-guard.sh is silent with no live session marker" "0" "$SZ"

cd "$REPO_ROOT" || exit 1

# =====================================================================
# No cross-firing between the protolog and replay revert guards
# =====================================================================
DIR="$TMPDIR_TEST/no-cross-fire"
new_scratch_repo "$DIR"
cd "$DIR" || exit 1
printf 'a\n' > f.txt
git add -A && git commit -q --no-verify -m base
printf 'b\n' > f.txt
git add -A && git commit -q --no-verify -m "[TEMP] REPLAY X: y. DO NOT MERGE"
REPLAY_SHA="$(git rev-parse HEAD)"
write_marker "$DIR" replay

# Fake an in-progress revert of the [TEMP] REPLAY commit by writing
# REVERT_HEAD directly (a real conflicted revert does the same thing; this
# is just deterministic to set up). Both guards only ever read this file and
# `git log -1 --format=%s REVERT_HEAD`, so this exercises the exact same
# code path a real conflict would.
GIT_DIR="$(git rev-parse --git-dir)"
printf '%s\n' "$REPLAY_SHA" > "$GIT_DIR/REVERT_HEAD"

run_guard "$REPLAY_REVERT" 'git revert --continue' "$DIR/out_replay_fires.txt"
SZ=$(guard_out_size "$DIR/out_replay_fires.txt")
[ "$SZ" -gt 0 ] && pass "replay revert guard denies --continue while REVERT_HEAD is a [TEMP] REPLAY commit" \
  || fail "replay revert guard denies --continue while REVERT_HEAD is a [TEMP] REPLAY commit"

run_guard "$PROTOLOG_REVERT" 'git revert --continue' "$DIR/out_cross.txt"
SZ=$(guard_out_size "$DIR/out_cross.txt")
assert_eq "protolog revert guard does not fire on a [TEMP] REPLAY REVERT_HEAD (no cross-firing)" "0" "$SZ"

rm -f "$GIT_DIR/REVERT_HEAD"
cd "$REPO_ROOT" || exit 1

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
