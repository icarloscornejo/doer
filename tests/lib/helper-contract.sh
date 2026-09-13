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
git-checks.sh:base-candidates diff-files secrets ac-leak squash-gate trace revert-in-progress phantoms classify-diff temp-rounds doer-history pr-templates
git-ops.sh:squash scrub-history revert-temp restore-phantoms
workspace-guard.sh:acquire release
stage-checks.sh:plan pre-review
metadata.sh:check-required version-check status list
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

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
