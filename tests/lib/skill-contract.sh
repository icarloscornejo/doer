#!/usr/bin/env bash
# Contract checker for skills/doer/stages/01-ac.md + lib/state.md (the Stage 1
# AC-discipline contract: distinctness rule, completeness rule, self-review
# taxonomy, terminal rules, ID domains).
#
# Usage: skill-contract.sh <repo-root>
#
# Takes an explicit root instead of deriving one from its own location
# (unlike tests/helpers.sh and tests/hooks.sh, which derive REPO_ROOT from
# $0), because tests/skills.sh needs to point this at a mutated temp copy of
# the repo without either (a) still inspecting the real working tree, or (b)
# recursively invoking tests/skills.sh itself. This file has no meta-tests
# inside it and cannot recurse.
#
# No external frameworks: bash + awk + grep. Prints PASS/FAIL per check;
# exits non-zero on any failure.

set -u

ROOT="${1:?usage: skill-contract.sh <repo-root>}"
AC_MD="$ROOT/skills/doer/stages/01-ac.md"
STATE_MD="$ROOT/lib/state.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

for f in "$AC_MD" "$STATE_MD"; do
  [ -f "$f" ] || { fail "file exists: $f"; echo; echo "Results: $PASS passed, $FAIL failed"; exit 1; }
done

# Extract a section from a heading line (inclusive) up to but excluding the
# next "## "-level heading (or EOF). $2 is an awk-safe literal regex for the
# heading line.
section() { # section <file> <heading-regex>
  awk -v pat="$2" '
    $0 ~ pat { grab=1 }
    grab && /^## / && $0 !~ pat { exit }
    grab { print }
  ' "$1"
}

STEP5="$(section "$AC_MD" '^## Step 5\. AC confirm')"
STEP55="$(section "$AC_MD" '^## Step 5\.5\. AC self-review')"

if [ -n "$STEP5" ]; then pass "Step 5 section found"; else fail "Step 5 section found"; fi
if [ -n "$STEP55" ]; then pass "Step 5.5 section found"; else fail "Step 5.5 section found"; fi

check_step5() { # check_step5 <desc> <fixed-string>
  if printf '%s\n' "$STEP5" | grep -qF "$2"; then pass "Step 5: $1"; else fail "Step 5: $1"; fi
}
check_step55() { # check_step55 <desc> <fixed-string>
  if printf '%s\n' "$STEP55" | grep -qF "$2"; then pass "Step 5.5: $1"; else fail "Step 5.5: $1"; fi
}

# --- Step 5: distinctness + completeness rules must be defined here ---
check_step5 "distinctness rule (six-position assertion tuple)" \
  'Normalize every candidate to a six-position assertion tuple'
check_step5 "distinctness fallback: keep separate when in doubt" \
  'When in doubt, keep them separate'
check_step5 "completeness rule (every obligation maps to exactly one disposition)" \
  'maps to EXACTLY ONE disposition'
check_step5 "partition table present" \
  'Copy in ES / PT / EN'

# --- Step 5.5: must bind to Step 5's rule, not define its own ---
check_step55 "reviewer prompt reuses Step 5's rule identically (no drift)" \
  'the literal distinctness rule, partition table, and completeness rule from Step 5, identical wording'

# --- The old numeric range must be fully gone from the file ---
if grep -qF '(3-7)' "$AC_MD"; then
  fail "no 3-7 numeric AC range remains"
else
  pass "no 3-7 numeric AC range remains"
fi

# --- Step 5.5: terminal rules, current (post-round-4-audit) shape ---
check_step55 "Round 2 'redundant' auto-applies (same as Round 1)" \
  'auto-applied and narrated, exactly like Round 1'
check_step55 "Round 2 'overscoped' stays narrate-only" \
  'narrate-only, same authority rule as Round 1'
check_step55 "Round 2 growth findings escalate to the dev, never a third round" \
  "escalate to the dev with the reviewer's \`suggested_fix\`; the dev is the terminal authority here, not a third reviewer round"
check_step55 "Round 1 'overscoped' auto-apply is conditional on explicit exclusion" \
  'apply automatically ONLY if the source ticket excludes that item explicitly'
check_step55 "'survivor_text' is part of the finding schema" \
  '"survivor_text"'
check_step55 "'split C-N' edit command is documented" \
  'split C-N'
check_step55 "pause sets stages.1.status to in_progress, never pending" \
  'set `stages.1.status = "in_progress"`, never `pending`'
check_step55 "merge chains are forbidden (inbound edges flatten instead)" \
  'merge chains are never allowed'

# --- JSON shape / ID domains, cross-checked between 01-ac.md and lib/state.md ---
AC_BLOCK="$(awk '/^"ac": \{/{grab=1} grab{print} grab&&/^\}/{exit}' "$AC_MD")"
if [ -n "$AC_BLOCK" ]; then pass "ac JSON block found in 01-ac.md"; else fail "ac JSON block found in 01-ac.md"; fi

for field in in_scope candidates out_of_scope open_questions_resolved merged source_map discarded_intake_items applicable_lessons self_review; do
  if printf '%s\n' "$AC_BLOCK" | grep -qF "\"$field\""; then
    pass "01-ac.md ac block has '$field'"
  else
    fail "01-ac.md ac block has '$field'"
  fi
  if grep -qF "\"$field\"" "$STATE_MD"; then
    pass "lib/state.md ac schema has '$field'"
  else
    fail "lib/state.md ac schema has '$field'"
  fi
done

# merge_into_candidate_id must live in the C- domain, never the AC- domain.
if printf '%s\n' "$AC_BLOCK" | grep -qF '"merge_into_candidate_id": "C-1"'; then
  pass "merge_into_candidate_id example uses the C- domain"
else
  fail "merge_into_candidate_id example uses the C- domain"
fi
if printf '%s\n' "$AC_BLOCK" | grep -qE '"merge_into_candidate_id": "AC-[0-9]+"'; then
  fail "merge_into_candidate_id example does not leak into the AC- domain"
else
  pass "merge_into_candidate_id example does not leak into the AC- domain"
fi
# in_scope stays in the AC- domain (it is the one ID family that crosses the
# Stage 1 boundary; everything else here is internal).
if printf '%s\n' "$AC_BLOCK" | grep -qE '"in_scope": \["AC-[0-9]+:'; then
  pass "in_scope example uses the AC- domain"
else
  fail "in_scope example uses the AC- domain"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
