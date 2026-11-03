#!/usr/bin/env bash
# Contract checker for the deterministic helpers introduced across 7.10.0:
# (a) every subcommand of every helper is actually invoked from at least one
#     skills/ or lib/ markdown file (a helper subcommand nobody calls is
#     dead code nobody would notice going stale); (b) no skills/ markdown
#     file still contains the raw mechanical patterns those helpers replaced
#     (a leftover un-migrated grep/sed/heredoc means the refactor missed a
#     call site, silently leaving two implementations of the same rule to
#     drift apart, exactly what this whole effort was for).
#
# Usage: helper-contract.sh <repo-root>
#
# Takes an explicit root (like skill-contract.sh) so tests/skills.sh can
# point this at a mutated temp copy without recursing into itself or
# inspecting the real working tree.
#
# No external frameworks: bash + grep. Prints PASS/FAIL per check; exits
# non-zero on any failure.

set -u

ROOT="${1:?usage: helper-contract.sh <repo-root>}"
DOCS="$ROOT/skills $ROOT/lib"
# A subcommand's caller can be prose in a .md file, OR another helper
# composing it internally (stage-checks.sh pre-review calls git-checks.sh
# secrets/ac-leak itself, for instance): both count as "not dead".
IMPLS="$ROOT/lib/helpers $ROOT/hooks"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

# grep_callers <pattern>: greps every .md under skills/+lib/, plus every
# helper/hook script (excluding the pattern's own file, checked by name so
# a script mentioning its own subcommand in its --help text does not count
# as a caller), for a fixed string.
grep_callers() {
  local pattern="$1" skip="${2:-}"
  find $DOCS -name '*.md' -type f -print0 2>/dev/null | xargs -0 grep -lF -- "$pattern" 2>/dev/null
  find $IMPLS \( -name '*.sh' -o -name '*.py' \) -type f -print0 2>/dev/null \
    | xargs -0 grep -lF -- "$pattern" 2>/dev/null | { [ -n "$skip" ] && grep -vF "/$skip" || cat; }
}

# --- (a) every helper subcommand is invoked from at least one .md file ---
# One row per "<helper-basename> <subcommand>" pair. Hand-maintained, not
# auto-parsed from each script's usage()/docstring: this is a fixed, known
# set of scripts, and a hardcoded table is far more robust than a parser
# for two slightly different doc-comment styles (bash usage() vs Python
# module docstrings).
SUBCOMMANDS="
vocab-guard.sh:
git-checks.sh:base-candidates diff-files secrets ac-leak squash-gate trace revert-in-progress phantoms classify-diff temp-rounds doer-history pr-templates weakened-tests
git-ops.sh:squash scrub-history revert-temp restore-phantoms
workspace-guard.sh:acquire release
session.sh:ensure-exclude
stage-checks.sh:plan pre-review
metadata.sh:check-required version-check status list
cost.sh:enter record unknown sample
jira.sh:detect-token-env extract-keys attachments
lessons.sh:prune
har.py:convert list head digest scan splice
ac-graph.py:validate merge split render-table
protolog-restore.py:check strip
"

while IFS= read -r line; do
  [ -n "$line" ] || continue
  script="${line%%:*}"
  subs="${line#*:}"
  base="${script%.*}"
  if [ -z "$subs" ]; then
    if [ -n "$(grep_callers "$base" "$script")" ]; then
      pass "$script is invoked from at least one .md or helper"
    else
      fail "$script is invoked from at least one .md or helper (looks dead)"
    fi
    continue
  fi
  for sub in $subs; do
    FOUND=0
    for f in $(grep_callers "$base" "$script" 2>/dev/null); do
      grep -qF "$sub" "$f" 2>/dev/null && { FOUND=1; break; }
    done
    if [ "$FOUND" -eq 1 ]; then
      pass "$script $sub is invoked from at least one .md or helper"
    else
      fail "$script $sub is invoked from at least one .md or helper (looks dead)"
    fi
  done
done <<EOF
$SUBCOMMANDS
EOF

# --- (b) no leftover raw mechanical pattern in skills/*.md ---
check_gone() { # check_gone <desc> <pattern>
  local hits
  hits="$(find "$ROOT/skills" -name '*.md' -type f -print0 2>/dev/null | xargs -0 grep -lF -- "$2" 2>/dev/null)"
  if [ -z "$hits" ]; then
    pass "no leftover pattern: $1"
  else
    fail "no leftover pattern: $1" "found in: $hits"
  fi
}

# Patterns are the actual COMMAND shape (with its real flags/args prefix),
# not a bare keyword: several of these words legitimately appear in prose
# describing what the helper now does internally ("runs `filter-branch`
# scoped to...", "neither `makehar` nor Charles.app found"), which is the
# refactor's own documentation, not a leftover raw invocation.
check_gone "raw AC-N label regex fragment (vocab-guard.sh is the only implementation)" 'AC-[0-9]+'
check_gone "inline python3 heredoc (- <<)" 'python3 - <<'
check_gone "raw git revert --no-edit invocation (git-ops.sh revert-temp is the only implementation)" 'git revert --no-edit <sha>'
check_gone "raw git filter-branch invocation (git-ops.sh scrub-history is the only implementation)" 'git filter-branch -f --index-filter'
check_gone "raw git reset --soft invocation (git-ops.sh squash is the only implementation)" 'git reset --soft <base> &&'
check_gone "raw git update-ref refs/ invocation (git-ops.sh is the only implementation)" 'git update-ref refs/'
check_gone 'raw git grep -l "PROTOLOG - " invocation (git-checks.sh trace is the only implementation)' 'git grep -l "PROTOLOG - "'
check_gone "raw mkdir -p .git/info invocation (workspace-guard.sh is the only implementation)" 'mkdir -p .git/info'
check_gone 'raw makehar invocation (har.py convert is the only implementation)' 'makehar "<in.chls>"'

# --- (c) no helper script hardcodes the raw .git/info path ---
# In a linked worktree .git is a file, so any hardcoded .git/info/... breaks
# there (DOER-4). The exclude path comes from `git rev-parse --git-path`,
# implemented once in session.sh ensure-exclude.
RAW_GIT_INFO_HITS="$(find "$ROOT/lib/helpers" -type f \( -name '*.sh' -o -name '*.py' \) -print0 2>/dev/null | xargs -0 grep -lF -- '.git/info' 2>/dev/null)"
if [ -z "$RAW_GIT_INFO_HITS" ]; then
  pass "no helper script hardcodes the raw .git/info path (worktree-safe)"
else
  fail "no helper script hardcodes the raw .git/info path (worktree-safe)" "found in: $RAW_GIT_INFO_HITS"
fi

# --- (d) the squash gate is its own command, in prose and in code ---
# A gate that exits 1 must stop the flow (DOER-5): chaining it with the squash
# in one Bash command lets the squash run after the gate failed. A trailing
# backslash joins a code line with the next one before any rule is applied.
join_continuations() { # join_continuations <file>
  awk '{ line = $0; while (line ~ /\\$/ && (getline next_line) > 0) { sub(/\\$/, "", line); line = line " " next_line } print line }' "$1"
}

# gate_fence_report <file>: "<blocks holding squash-gate> <of those not exactly one line> <blocks holding the gate command>"
gate_fence_report() {
  join_continuations "$1" | awk '
    /^[[:space:]]*```/ {
      if (in_fence) {
        if (has_gate) { blocks++; if (non_blank != 1) multi_line++ }
        if (has_command) command_blocks++
        in_fence = 0
      } else { in_fence = 1; has_gate = 0; has_command = 0; non_blank = 0 }
      next
    }
    in_fence {
      if ($0 ~ /[^[:space:]]/) non_blank++
      if (index($0, "squash-gate")) has_gate = 1
      if (index($0, "git-checks.sh\" squash-gate")) has_command = 1
    }
    END { printf "%d %d %d\n", blocks + 0, multi_line + 0, command_blocks + 0 }'
}

GATE_FILES="$(find "$ROOT/skills" "$ROOT/lib" -name '*.md' -type f -print0 2>/dev/null | xargs -0 grep -lF -- 'squash-gate' 2>/dev/null)"
for gate_file in $GATE_FILES; do
  gate_rel="${gate_file#"$ROOT"/}"
  if join_continuations "$gate_file" | grep -F -- 'squash-gate' | grep -qE '&&|\|\||;|\||git-ops\.sh"? squash'; then
    fail "squash-gate contract: $gate_rel: a line with squash-gate also holds a chain operator or the squash"
  else
    pass "squash-gate contract: $gate_rel: no line chains the gate with another command"
  fi
  read -r gate_blocks gate_multi_line gate_command_blocks <<EOF
$(gate_fence_report "$gate_file")
EOF
  if [ "$gate_multi_line" -eq 0 ]; then
    pass "squash-gate contract: $gate_rel: every fenced block with the gate holds only that one line"
  else
    fail "squash-gate contract: $gate_rel: a fenced block with the gate holds more than one line"
  fi
done

for gate_stage in skills/doer/stages/05-wrapup.md skills/bugfix/SKILL.md; do
  gate_file="$ROOT/$gate_stage"
  read -r gate_blocks gate_multi_line gate_command_blocks <<EOF
$(gate_fence_report "$gate_file")
EOF
  if [ "$gate_command_blocks" -eq 1 ]; then
    pass "squash-gate contract: $gate_stage: exactly one fenced block runs the gate"
  else
    fail "squash-gate contract: $gate_stage: expected exactly one fenced block running the gate, found $gate_command_blocks"
  fi
  for gate_phrase in 'as its own Bash command' 'Do not squash and do not offer the squash'; do
    if grep -qF -- "$gate_phrase" "$gate_file"; then
      pass "squash-gate contract: $gate_stage: says '$gate_phrase'"
    else
      fail "squash-gate contract: $gate_stage: missing the sentence '$gate_phrase'"
    fi
  done
done

# --- (e) a check that can exit 2 is never piped or chained, and every caller says what exit 2 means ---
EXIT2_PHRASE='Exit 2 means the base is unusable or git failed'
EXIT2_FILES="$(find "$ROOT/skills" "$ROOT/lib" -name '*.md' -type f -print0 2>/dev/null \
  | xargs -0 grep -lE 'git-checks\.sh"? (doer-history|trace|revert-in-progress|temp-rounds|classify-diff|diff-files)|stage-checks\.sh"? pre-review' 2>/dev/null)"
for exit2_file in $EXIT2_FILES; do
  exit2_rel="${exit2_file#"$ROOT"/}"
  if grep -qF -- "$EXIT2_PHRASE" "$exit2_file"; then
    pass "exit-2 contract: $exit2_rel: says what exit 2 means"
  else
    fail "exit-2 contract: $exit2_rel: calls a check that can exit 2 but never says '$EXIT2_PHRASE'"
  fi
  if join_continuations "$exit2_file" | grep -E '(git-checks\.sh|stage-checks\.sh)"? [a-z-]+' | grep -qE ' (\|\||&&|;|\|) '; then
    fail "exit-2 contract: $exit2_rel: a check is piped or chained, which hides its exit code"
  else
    pass "exit-2 contract: $exit2_rel: no check is piped or chained"
  fi
done

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
