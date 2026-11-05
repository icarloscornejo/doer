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
HELPER_CHECKER="${REPO_ROOT}/tests/lib/helper-contract.sh"
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

# --- 1b. tests/lib/helper-contract.sh: no dead helper subcommand, no
# leftover raw mechanical pattern anywhere in the real repo. Run directly
# against the real tree (not a copied fixture): unlike skill-contract.sh,
# it reads the whole skills/+lib/+hooks/ tree, not two named files, so a
# two-file fixture_dir() copy would not exercise it meaningfully; its own
# logic (a fixed table of known subcommands, fixed leftover-pattern
# strings) is simple enough not to need mutation coverage of its own.
HELPER_OUT="$(mktemp)"
if bash "$HELPER_CHECKER" "$REPO_ROOT" >"$HELPER_OUT" 2>&1; then
  pass "helper-contract.sh passes against the real repo"
else
  fail "helper-contract.sh passes against the real repo"
  echo "--- checker output ---"
  cat "$HELPER_OUT"
  echo "----------------------"
fi
rm -f "$HELPER_OUT"

# --- 1c. Stage 3 weakened-tests contract: plain greps on the final text of
# 03-build.md (who may justify a removed test line, and when pre-review must
# be clean). Key phrases are fixed strings on purpose; they ARE the contract.
BUILD_MD="$REPO_ROOT/skills/doer/stages/03-build.md"
build_has() { # build_has <desc> <fixed-string>
  if grep -qF -- "$2" "$BUILD_MD"; then pass "03-build: $1"; else fail "03-build: $1"; fi
}
build_has "names the weakened-tests blocker kind" 'weakened-tests'
build_has "weakened-tests BLOCKERs go to the next fixer first" \
  'a `weakened-tests` BLOCKER goes to the next fixer first'
build_has "only STILL_OPEN weakened-tests items are escalated, by the orchestrator" \
  'only STILL_OPEN `weakened-tests` items are escalated to the dev, by the orchestrator'
build_has "the dev justifies only with an explicit reason, then pre-review re-runs" \
  'records the justification only on the dev'"'"'s explicit reason'
build_has "fixer prompts strip the registration command line" \
  'strip the registration command line from every `weakened-tests` BLOCKER inlined into a fixer prompt'
build_has "sub-agents never call metadata.sh write for justifications" \
  'sub-agents never see the registration command and never call `metadata.sh write`'
build_has "justifications are the orchestrator's alone" \
  "justifications are the orchestrator's alone"
build_has "loop state updated in the same single write" \
  'in that same single `metadata.sh write`'
build_has "justified id moves to prior_blockers_resolved" 'prior_blockers_resolved'
build_has "convergence requires a clean pre-review on the final HEAD" \
  'a clean `pre-review` on the final HEAD'
build_has "accepted_with_residuals exemption is stated" 'accepted_with_residuals'
build_has "residual BLOCKERs are recorded instead of re-entering the loop" \
  'recorded as residuals instead of re-entering the loop'
build_has "re-entry after iteration 3 goes to the escape hatch" \
  'never a 4th automatic iteration'
CONV_SECTION="$(awk '/^## On convergence/{grab=1} grab{print}' "$BUILD_MD")"
conv_line() { printf '%s\n' "$CONV_SECTION" | grep -nF -- "$1" | head -1 | cut -d: -f1; }
STRAGGLER_LINE="$(conv_line 'straggler')"
PRE_LINE="$(conv_line 'a clean `pre-review` on the final HEAD')"
COMPLETE_LINE="$(conv_line '--require 3:complete')"
if [ -n "$STRAGGLER_LINE" ] && [ -n "$PRE_LINE" ] && [ -n "$COMPLETE_LINE" ] \
   && [ "$STRAGGLER_LINE" -lt "$PRE_LINE" ] && [ "$PRE_LINE" -lt "$COMPLETE_LINE" ]; then
  pass "03-build: On convergence orders straggler step, then clean pre-review, then the 3:complete write"
else
  fail "03-build: On convergence orders straggler step, then clean pre-review, then the 3:complete write"
fi
if grep -qF 'test_weakening_justifications' "$REPO_ROOT/lib/state.md"; then
  pass "state.md documents metadata.test_weakening_justifications"
else
  fail "state.md documents metadata.test_weakening_justifications"
fi

# --- 1d. DOER-3 cost per ticket: contract greps on the prose call sites. Fixed
# strings on purpose; they ARE the contract between the skills and cost.sh.
# md_section <file> <heading-prefix>: from the heading line up to (excluding)
# the next heading of the same or a shallower level.
md_section() {
  awk -v prefix="$2" '
    function level(line,   n) { n = 0; while (substr(line, n + 1, 1) == "#") n++; return n }
    index($0, prefix) == 1 && !grab { grab = 1; lvl = level($0); print; next }
    grab && /^#+ / && level($0) <= lvl { grab = 0 }
    grab { print }
  ' "$1"
}
cost_has() { # cost_has <desc> <text> <fixed-string>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then pass "cost prose: $1"; else fail "cost prose: $1"; fi
}
COST_ENTER='lib/helpers/cost.sh" enter'
COST_RECORD='lib/helpers/cost.sh" record'
COST_UNKNOWN='lib/helpers/cost.sh" unknown'
COST_SLURP='--slurpfile cost'
COST_SET='.cost = $cost[0]'

AC_STEP1="$(md_section "$REPO_ROOT/skills/doer/stages/01-ac.md" '## Step 1.')"
AC_STEP3="$(md_section "$REPO_ROOT/skills/doer/stages/01-ac.md" '## Step 3.')"
cost_has "01-ac.md Step 1 registers the session with cost.sh enter" "$AC_STEP1" "$COST_ENTER"
cost_has "01-ac.md Step 3 init passes --track-cost" "$AC_STEP3" 'init "<TICKET-ID>" --track-cost'
cost_has "_resume.md registers the session with cost.sh enter" "$(cat "$REPO_ROOT/skills/doer/stages/_resume.md")" "$COST_ENTER"

WRAPUP_STEP8="$(md_section "$REPO_ROOT/skills/doer/stages/05-wrapup.md" '## 8.')"
cost_has "05-wrapup.md Step 8 runs cost.sh record" "$WRAPUP_STEP8" "$COST_RECORD"
cost_has "05-wrapup.md Step 8 falls back to cost.sh unknown" "$WRAPUP_STEP8" "$COST_UNKNOWN"
cost_has "05-wrapup.md Step 8 passes the record with --slurpfile cost" "$WRAPUP_STEP8" "$COST_SLURP"
cost_has "05-wrapup.md Step 8 stores it as .cost = \$cost[0]" "$WRAPUP_STEP8" "$COST_SET"
cost_has "05-wrapup.md Step 8 says a close is never blocked by cost" "$WRAPUP_STEP8" 'never blocked by cost'

BUGFIX_MD="$REPO_ROOT/skills/bugfix/SKILL.md"
BUGFIX_STAGE0="$(md_section "$BUGFIX_MD" '## Stage 0')"
BUGFIX_SPIKE="$(md_section "$BUGFIX_MD" '### `not_app_bug`')"
BUGFIX_STAGE6="$(md_section "$BUGFIX_MD" '## Stage 6')"
cost_has "bugfix Stage 0 init passes --track-cost" "$BUGFIX_STAGE0" '--file bugfix.json --track-cost'
cost_has "bugfix Stage 0 resume registers the session with cost.sh enter" "$BUGFIX_STAGE0" "$COST_ENTER"
cost_has "bugfix Stage 0 creates the scratch with cost.sh enter before init" "$BUGFIX_STAGE0" 'cost-entry.json'
cost_has "bugfix spike close records cost with cost.sh record" "$BUGFIX_SPIKE" "$COST_RECORD"
cost_has "bugfix spike close stores .cost = \$cost[0]" "$BUGFIX_SPIKE" "$COST_SET"
cost_has "bugfix spike close falls back to cost.sh unknown" "$BUGFIX_SPIKE" "$COST_UNKNOWN"
cost_has "bugfix Stage 6 close records cost with cost.sh record" "$BUGFIX_STAGE6" "$COST_RECORD"
cost_has "bugfix Stage 6 close stores .cost = \$cost[0]" "$BUGFIX_STAGE6" "$COST_SET"
cost_has "bugfix Stage 6 close falls back to cost.sh unknown" "$BUGFIX_STAGE6" "$COST_UNKNOWN"

# DOER-10: only the two PR-description writers run on Haiku (read budget 0, no code written or judged);
# the clause keeps a prompt that could pass the long-prompt threshold on the session model.
HAIKU_MODEL='model: "haiku"'
HAIKU_CLAUSE='omit `model`'
HAIKU_LIMIT='100 KB'
WRAPUP_STEP6="$(md_section "$REPO_ROOT/skills/doer/stages/05-wrapup.md" '## 6.')"
for haiku_section in "WRAPUP_STEP6:05-wrapup.md Step 6 PR writer" "BUGFIX_STAGE6:bugfix Stage 6 PR writer"; do
  haiku_var="${haiku_section%%:*}"
  haiku_text="${!haiku_var}"
  haiku_desc="${haiku_section#*:}"
  for haiku_needle in "$HAIKU_MODEL" "$HAIKU_CLAUSE" "$HAIKU_LIMIT"; do
    if printf '%s\n' "$haiku_text" | grep -qF -- "$haiku_needle"; then pass "model prose: $haiku_desc names $haiku_needle"; else fail "model prose: $haiku_desc names $haiku_needle"; fi
  done
done
HAIKU_FILES="$(cd "$REPO_ROOT" && grep -rlF 'model: "' skills lib 2>/dev/null | sort | tr '\n' ' ')"
if [ "$HAIKU_FILES" = "skills/bugfix/SKILL.md skills/doer/stages/05-wrapup.md " ]; then
  pass "model prose: only the two PR writers name an Agent model (no other dispatch, no 04-verify.md)"
else
  fail "model prose: only the two PR writers name an Agent model (found: $HAIKU_FILES)"
fi

ANALYZE_CONFIRM="$(md_section "$REPO_ROOT/skills/bugfix/analyze.md" '## 4. Confirm')"
cost_has "analyze.md Confirm write records cost with cost.sh record" "$ANALYZE_CONFIRM" "$COST_RECORD"
cost_has "analyze.md Confirm write stores .cost = \$cost[0]" "$ANALYZE_CONFIRM" "$COST_SET"
cost_has "analyze.md Confirm write falls back to cost.sh unknown" "$ANALYZE_CONFIRM" "$COST_UNKNOWN"
cost_has "analyze.md Confirm write passes --slurpfile cost" "$ANALYZE_CONFIRM" "$COST_SLURP"

if grep -qF 'cost_sessions' "$REPO_ROOT/lib/state.md"; then
  pass "state.md documents cost_sessions"
else
  fail "state.md documents cost_sessions"
fi

# --- 1e. DOER-5: helper-contract.sh rejects a squash gate chained with the squash,
# and a check whose exit 2 is not explained. Each mutation runs on a copy of
# skills/, lib/ and hooks/ and must fail with the specific contract line; the
# unmutated copy must pass, so a failure cannot come from an unrelated check.
contract_dir() {
  local tmp
  tmp="$(mktemp -d)"
  cp -R "$REPO_ROOT/skills" "$REPO_ROOT/lib" "$REPO_ROOT/hooks" "$tmp/"
  printf '%s' "$tmp"
}

# contract_mutation_fails <desc> <expected FAIL fragment> <file> <old> <new>
contract_mutation_fails() {
  local desc="$1" expected="$2" rel="$3" old="$4" new="$5" tmp out
  tmp="$(contract_dir)"
  if ! replace_once "$tmp/$rel" "$old" "$new"; then
    fail "$desc (mutation did not apply; the text it targets is missing or ambiguous)"
    rm -rf "$tmp"
    return
  fi
  out="$(bash "$HELPER_CHECKER" "$tmp" 2>&1)"
  if [ $? -ne 0 ] && printf '%s\n' "$out" | grep -qF -- "FAIL  $expected"; then
    pass "$desc"
  else
    fail "$desc" "expected the line 'FAIL  $expected'"
  fi
  rm -rf "$tmp"
}

CONTRACT_COPY="$(contract_dir)"
if bash "$HELPER_CHECKER" "$CONTRACT_COPY" >/dev/null 2>&1; then
  pass "helper-contract.sh passes on an unmutated copy of the tree"
else
  fail "helper-contract.sh passes on an unmutated copy of the tree"
fi
rm -rf "$CONTRACT_COPY"

GATE_CHAIN=' && "${CLAUDE_PLUGIN_ROOT}/lib/helpers/git-ops.sh" squash <base> T-1 doer'
contract_mutation_fails "contract: the gate chained with the squash in the 05-wrapup fence is rejected" \
  'squash-gate contract: skills/doer/stages/05-wrapup.md' \
  skills/doer/stages/05-wrapup.md 'squash-gate <base>' "squash-gate <base>$GATE_CHAIN"
contract_mutation_fails "contract: the gate chained with the squash in the indented bugfix fence is rejected" \
  'squash-gate contract: skills/bugfix/SKILL.md' \
  skills/bugfix/SKILL.md 'squash-gate <base>' "squash-gate <base>$GATE_CHAIN"
contract_mutation_fails "contract: the gate chained in inline code in prose is rejected" \
  'squash-gate contract: skills/doer/stages/05-wrapup.md' \
  skills/doer/stages/05-wrapup.md 'Exit 1 or 2: STOP.' 'Exit 1 or 2: STOP. (Shortcut: `git-checks.sh" squash-gate <base> && git-ops.sh squash`.)'
contract_mutation_fails "contract: the gate chained on an indented code line is rejected" \
  'squash-gate contract: skills/doer/stages/05-wrapup.md' \
  skills/doer/stages/05-wrapup.md 'Exit 1 or 2: STOP.' '    git-checks.sh" squash-gate <base> && git-ops.sh squash
Exit 1 or 2: STOP.'
contract_mutation_fails "contract: a gate split by a line continuation is rejected" \
  'squash-gate contract: skills/bugfix/SKILL.md' \
  skills/bugfix/SKILL.md 'squash-gate <base>' 'squash-gate <base> \
   && git-ops.sh" squash <base> T-1 bugfix'
contract_mutation_fails "contract: dropping 'as its own Bash command' from the bugfix skill is rejected" \
  "squash-gate contract: skills/bugfix/SKILL.md: missing the sentence 'as its own Bash command'" \
  skills/bugfix/SKILL.md 'as its own Bash command' 'alone'
contract_mutation_fails "contract: dropping the exit 2 sentence from _commands.md is rejected" \
  'exit-2 contract: skills/doer/stages/_commands.md' \
  skills/doer/stages/_commands.md 'Exit 2 means the base is unusable or git failed' 'Exit codes are documented elsewhere'
contract_mutation_fails "contract: piping doer-history in 05-wrapup is rejected" \
  'exit-2 contract: skills/doer/stages/05-wrapup.md' \
  skills/doer/stages/05-wrapup.md 'git-checks.sh" doer-history <base>' 'git-checks.sh" doer-history <base> | wc -l'

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
