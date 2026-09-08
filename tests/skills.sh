#!/usr/bin/env bash
# Meta-tests for tests/lib/skill-contract.sh: the FIRST test coverage for any
# skills/*/stages/*.md contract in this repo (mirrors the lesson tests/hooks.sh
# already learned in 7.7.0: "a contract nobody tests is a contract nobody
# notices going dead").
#
# Run from anywhere:
#   bash tests/skills.sh
#
# The checker is invoked directly against (1) the real repo, which must
# pass, and (2) a deliberately mutated temp copy per scenario, which must
# fail. Each mutated copy lives under its own mktemp -d, so nothing here
# touches the real working tree, and the checker (never tests/skills.sh) is
# what actually runs against it, so there is no recursion risk.
#
# No external frameworks: bash + python3 (for exact, unambiguous text
# substitution in the mutation fixtures; sed backreferences on strings full
# of backticks/parens/periods are an unnecessary way to get this wrong).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER="${REPO_ROOT}/tests/lib/skill-contract.sh"
AC_REL="skills/doer/stages/01-ac.md"
STATE_REL="lib/state.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; }

# replace_once <file> <old> <new>: exact substring replace, exactly one
# occurrence expected. Fails loudly (nonzero exit), not silently, if <old>
# is not found exactly once, since a silent no-op mutation would make its
# fixture meaningless.
replace_once() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
n = text.count(old)
if n != 1:
    sys.stderr.write(f"replace_once: expected exactly 1 occurrence of {old!r} in {path}, found {n}\n")
    sys.exit(1)
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
}

# fixture_dir: a fresh temp copy of just the two files the checker reads,
# laid out at the same relative paths so the checker's own path-joining
# still works against ROOT=$tmp.
fixture_dir() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/skills/doer/stages" "$tmp/lib"
  cp "$REPO_ROOT/$AC_REL" "$tmp/$AC_REL"
  cp "$REPO_ROOT/$STATE_REL" "$tmp/$STATE_REL"
  printf '%s' "$tmp"
}

# mutate_and_expect_fail <desc> <mutator-fn-name>: build a fixture, apply
# the named mutator function (it receives the fixture root as $1 and does
# its own replace_once calls), then assert the checker rejects the result.
# A mutator that fails to apply (replace_once found 0 or >1 occurrences) is
# itself a test failure, not a skip: it means the fixture text has drifted
# from the real file and is no longer testing what it claims to.
mutate_and_expect_fail() {
  local desc="$1" mutator="$2" tmp
  tmp="$(fixture_dir)"
  if ! "$mutator" "$tmp"; then
    fail "$desc (mutator failed to apply; fixture text has drifted from the real file)"
    rm -rf "$tmp"
    return
  fi
  if bash "$CHECKER" "$tmp" >/dev/null 2>&1; then
    fail "$desc (checker should have rejected this mutation but passed it)"
  else
    pass "$desc"
  fi
  rm -rf "$tmp"
}

mut_drop_distinctness_rule() {
  replace_once "$1/$AC_REL" \
    'Normalize every candidate to a six-position assertion tuple: `(actor, precondition, trigger, observable effect, channel/recipient, expected disposition)`.' \
    'Group candidates however seems reasonable.'
}

mut_step55_no_longer_binds_to_step5() {
  replace_once "$1/$AC_REL" \
    'the literal distinctness rule, partition table, and completeness rule from Step 5, identical wording, so generation and review can never diverge on what counts as one AC.' \
    'whatever criteria the reviewer prefers.'
}

mut_id_domain_swap() {
  replace_once "$1/$AC_REL" \
    '"merge_into_candidate_id": "C-1"' \
    '"merge_into_candidate_id": "AC-1"'
}

mut_round2_redundant_narrate_only() {
  replace_once "$1/$AC_REL" \
    'auto-applied and narrated, exactly like Round 1.' \
    'narrate-only, same as overscoped.'
}

mut_round2_growth_auto_apply() {
  replace_once "$1/$AC_REL" \
    "escalate to the dev with the reviewer's \`suggested_fix\`; the dev is the terminal authority here, not a third reviewer round." \
    "apply the reviewer's \`suggested_fix\` automatically, same as Round 1."
}

mut_overscoped_unconditional() {
  replace_once "$1/$AC_REL" \
    'apply automatically ONLY if the source ticket excludes that item explicitly; otherwise hold it as a narrated proposal requiring dev approval at presentation.' \
    'apply automatically in every case, no exceptions.'
}

mut_drop_survivor_text() {
  replace_once "$1/$AC_REL" \
    '"survivor_text": "<full replacement text for the surviving candidate, covering every row of both candidates>", ' \
    ''
}

mut_drop_candidates_from_state() {
  replace_once "$1/$STATE_REL" '"candidates": [], ' ''
}

mut_pause_leaves_pending() {
  replace_once "$1/$AC_REL" \
    'set `stages.1.status = "in_progress"`, never `pending`' \
    'leave `stages.1.status` as `pending`'
}

mut_reintroduce_numeric_range() {
  replace_once "$1/$AC_REL" \
    '**ACs**: one Given/When/Then per candidate' \
    '**ACs** (3-7): one Given/When/Then per candidate'
}

mut_table_shown_unconditionally() {
  replace_once "$1/$AC_REL" \
    'only when `intake.raw_acs != "derive"` (the ticket brought its own ACs), shown right after Self-review notes' \
    'always, shown right after Self-review notes'
}

mut_drop_fidelity_from_source_map() {
  replace_once "$1/$AC_REL" \
    '"fidelity": {"verdict": "match | partial | diverges", "note": "<=1 sentence"} | null}`' \
    '}`'
}

mut_drop_fidelity_reset_on_merge() {
  replace_once "$1/$AC_REL" \
    "resets that row's \`fidelity\` to \`{\"verdict\": \"unreviewed\", \"note\": \"<what changed>\"}\`; renumbering \`AC-N\` alone (with no text change) does not reset it." \
    "leaves that row's \`fidelity\` untouched."
}

mut_attention_rows_no_question() {
  replace_once "$1/$AC_REL" \
    "When any row needs attention (and only then, and only under the \`raw_acs != \"derive\"\` gate above), follow the table with \`AskUserQuestion\`: \`Re-run self-review on the current draft (Recommended)\` / \`I'll edit by hand\` / \`Approve as is\`." \
    "Attention rows are narrated only; the dev proceeds with the normal approval options below."
}

mut_edit_cap_auto_advances() {
  replace_once "$1/$AC_REL" \
    'Stage 1 never auto-advances past the cap while a row needs attention.' \
    'Stage 1 proceeds regardless.'
}

mut_drop_bold_label_rule() {
  replace_once "$1/$AC_REL" \
    'the `AC-N` label is always bold, even on a trivial cosmetic bullet (`- **AC-1:** <plain cosmetic criterion>`).' \
    'the `AC-N` label is plain text.'
}

mut_collapse_clauses_one_line() {
  replace_once "$1/$AC_REL" \
    'each clause is its own markdown sub-bullet (plain ASCII hyphen-space) under the label,' \
    'all clauses stay on one line, joined by commas,'
}

# Reintroduces a U+00A0 indent into the example block, the exact regression
# 7.8.2 fixed (the model kept emitting a literal &nbsp; entity instead of the
# raw byte, so 7.8.2 replaced the invisible-character indent with plain
# ASCII sub-bullets). Uses python directly instead of replace_once because
# the replacement needs a literal U+00A0 character, awkward to pass through
# bash args.
mut_replace_nbsp_with_ascii_space() {
  python3 - "$1/$AC_REL" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
if text.count("- GIVEN") != 1:
    sys.stderr.write("mut_replace_nbsp_with_ascii_space: '- GIVEN' not found exactly once\n")
    sys.exit(1)
text = text.replace("- GIVEN", " - GIVEN", 1)
open(path, "w", encoding="utf-8").write(text)
PY
}

# --- 1. Baseline: the real repo must pass the checker as-is. ---
BASELINE_OUT="$(mktemp)"
if bash "$CHECKER" "$REPO_ROOT" >"$BASELINE_OUT" 2>&1; then
  pass "checker passes against the real repo"
else
  fail "checker passes against the real repo"
  echo "--- checker output ---"
  cat "$BASELINE_OUT"
  echo "----------------------"
fi
rm -f "$BASELINE_OUT"

# --- 2. Mutation fixtures, one per finding from the crosscheck rounds. ---
mutate_and_expect_fail "mutation: distinctness rule removed from Step 5" mut_drop_distinctness_rule
mutate_and_expect_fail "mutation: Step 5.5 no longer binds to Step 5's rule (drift risk)" mut_step55_no_longer_binds_to_step5
mutate_and_expect_fail "mutation: merge_into_candidate_id domain swapped C- -> AC-" mut_id_domain_swap
mutate_and_expect_fail "mutation: Round 2 redundant no longer auto-applies" mut_round2_redundant_narrate_only
mutate_and_expect_fail "mutation: Round 2 growth findings auto-apply (forbidden; must escalate)" mut_round2_growth_auto_apply
mutate_and_expect_fail "mutation: overscoped auto-apply made unconditional" mut_overscoped_unconditional
mutate_and_expect_fail "mutation: survivor_text dropped from the finding schema" mut_drop_survivor_text
mutate_and_expect_fail "mutation: candidates catalog dropped from lib/state.md" mut_drop_candidates_from_state
mutate_and_expect_fail "mutation: pause leaves the stage pending instead of in_progress" mut_pause_leaves_pending
mutate_and_expect_fail "mutation: 3-7 numeric AC range reintroduced" mut_reintroduce_numeric_range
mutate_and_expect_fail "mutation: bold AC label requirement dropped" mut_drop_bold_label_rule
mutate_and_expect_fail "mutation: GIVEN/WHEN/THEN collapsed to one line" mut_collapse_clauses_one_line
mutate_and_expect_fail "mutation: three-U+00A0 indent replaced with plain ASCII spaces" mut_replace_nbsp_with_ascii_space
mutate_and_expect_fail "mutation: correspondence table shown unconditionally (raw_acs gate dropped)" mut_table_shown_unconditionally
mutate_and_expect_fail "mutation: fidelity dropped from source_map row schema" mut_drop_fidelity_from_source_map
mutate_and_expect_fail "mutation: fidelity no longer resets on a later text change" mut_drop_fidelity_reset_on_merge
mutate_and_expect_fail "mutation: attention rows no longer trigger the how-to-proceed question" mut_attention_rows_no_question
mutate_and_expect_fail "mutation: edit cap auto-advances with attention pending" mut_edit_cap_auto_advances

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
