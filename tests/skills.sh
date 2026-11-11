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

# DOER-13: bounded suite output. Prose contract between the stage files and bounded.sh.
bp_has() { # bp_has <desc> <text> <fixed-string>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then pass "bounded prose: $1"; else fail "bounded prose: $1"; fi
}
bp_lacks_re() { # bp_lacks_re <desc> <text> <extended-regex>
  if printf '%s\n' "$2" | grep -qE -- "$3"; then fail "bounded prose: $1"; else pass "bounded prose: $1"; fi
}
BP_PLAN_FILE="$REPO_ROOT/skills/doer/stages/02-plan.md"
BP_AC_FILE="$REPO_ROOT/skills/doer/stages/01-ac.md"
BP_BUILD_FILE="$REPO_ROOT/skills/doer/stages/03-build.md"
BP_WRAPUP_FILE="$REPO_ROOT/skills/doer/stages/05-wrapup.md"
BP_BUGFIX_FILE="$REPO_ROOT/skills/bugfix/SKILL.md"
BP_PLAN_SECTION="$(md_section "$BP_PLAN_FILE" '## Mechanical steps through scripts')"
BP_AC_STEP4="$(md_section "$BP_AC_FILE" '## Step 4.')"
BP_BUILD_CONV="$(md_section "$BP_BUILD_FILE" '## On convergence')"
BP_BUGFIX_SUITE="$(grep '^4\. Run the full relevant suite' "$BP_BUGFIX_FILE")"
BP_BUGFIX_WRITE="$(grep '^1\. Write every test' "$BP_BUGFIX_FILE")"

bp_has "02-plan.md has the Mechanical steps section" "$BP_PLAN_SECTION" '## Mechanical steps through scripts'
bp_has "02-plan section states the 8,000 character threshold" "$BP_PLAN_SECTION" '8,000 characters'
bp_has "02-plan section states the 3 or more chained calls rule" "$BP_PLAN_SECTION" '3 or more'
bp_has "02-plan section holds the inventory table header" "$BP_PLAN_SECTION" '| Step | Raw output | (a) | (b) | Decision |'
bp_has "02-plan section states the 55 line cap" "$BP_PLAN_SECTION" '55 lines'
bp_has "02-plan section states the 16,000 character FAIL section" "$BP_PLAN_SECTION" '16,000'
bp_has "02-plan section states the 27,000 character total" "$BP_PLAN_SECTION" '27,000'
bp_has "02-plan section names the fails file" "$BP_PLAN_SECTION" '.doer/bounded-fails.txt'
bp_has "02-plan section is honest about the redaction limit" "$BP_PLAN_SECTION" 'not guaranteed'
bp_has "02-plan section names the redaction marker" "$BP_PLAN_SECTION" '[REDACTED]'
bp_lacks_re "02-plan section carries no ticket id" "$BP_PLAN_SECTION" 'DOER-'
bp_lacks_re "02-plan section carries no requirement label" "$BP_PLAN_SECTION" '\bAC-[0-9]+\b'
for bp_file in "$BP_PLAN_FILE" "$BP_AC_FILE" "$BP_BUGFIX_FILE"; do
  bp_lacks_re "$(basename "$(dirname "$bp_file")")/$(basename "$bp_file") never names the pre-review script call literally" "$(cat "$bp_file")" 'stage-checks\.sh"? pre-review'
done

for bp_pair in "03-build On convergence:$BP_BUILD_CONV" "01-ac Step 4:$BP_AC_STEP4" "bugfix full suite step:$BP_BUGFIX_SUITE"; do
  bp_name="${bp_pair%%:*}"
  bp_text="${bp_pair#*:}"
  bp_has "$bp_name calls bounded.sh run" "$bp_text" 'bounded.sh run'
  bp_has "$bp_name uses the 540 second timeout" "$bp_text" '--timeout 540'
  bp_has "$bp_name uses the sh -c single-quoted form" "$bp_text" "sh -c '"
  bp_has "$bp_name states the failed status" "$bp_text" '`failed`'
  bp_has "$bp_name states the timeout status" "$bp_text" '`timeout`'
  bp_has "$bp_name states the error status" "$bp_text" '`error`'
  bp_lacks_re "$bp_name carries no requirement label" "$bp_text" '\bAC-[0-9]+\b'
done

bp_lacks_re "bugfix run-the-tests-first step does not call bounded.sh" "$BP_BUGFIX_WRITE" 'bounded\.sh'
bp_lacks_re "05-wrapup.md does not mention bounded.sh" "$(cat "$BP_WRAPUP_FILE")" 'bounded\.sh'
bp_has "03-build keeps the raw test command for last_green_test_command" "$(cat "$BP_BUILD_FILE")" \
  '`last_green_test_command` is the raw `metadata.test_command`, never the `bounded.sh` wrapper'
BP_ASK_LINE="$(printf '%s\n' "$BP_AC_STEP4" | grep -niE -m1 'ask once' | cut -d: -f1)"
BP_CALL_LINE="$(printf '%s\n' "$BP_AC_STEP4" | grep -nF -m1 'bounded.sh run' | cut -d: -f1)"
if [ -n "$BP_ASK_LINE" ] && [ -n "$BP_CALL_LINE" ] && [ "$BP_ASK_LINE" -le "$BP_CALL_LINE" ]; then
  pass "bounded prose: 01-ac Step 4 applies the ask-once persist rule before the call"
else
  fail "bounded prose: 01-ac Step 4 applies the ask-once persist rule before the call"
fi

# DOER-10: only the two PR-description writers run on Haiku (read budget 0, no code written or judged);
# the clause keeps a prompt that could pass the long-prompt threshold on the session model.
HAIKU_MODEL='Agent with `model: "haiku"` on every dispatch of this writer, rewrite rounds included'
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

# --- 1e. Per-ticket --no-pr parameter: prose contracts. Fixed strings on
# purpose; they ARE the contract between the skills, lib/state.md and metadata.sh.
np_has() { # np_has <desc> <text> <fixed-string>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then pass "no-pr prose: $1"; else fail "no-pr prose: $1"; fi
}
np_lacks() { # np_lacks <desc> <text> <fixed-string>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then fail "no-pr prose: $1"; else pass "no-pr prose: $1"; fi
}
# np_closing_line <desc> <text>: the one no-PR closing line (merge <branch> into <base>)
# must offer a push on approval and never mention a PR. Absent line fails.
np_closing_line() {
  local line
  line="$(printf '%s\n' "$2" | grep -F 'merge `<branch>` into `<base>`')"
  if [ -n "$line" ] && printf '%s' "$line" | grep -qF 'push' && printf '%s' "$line" | grep -qF 'when you approve' \
     && ! printf '%s' "$line" | grep -qF 'PR'; then pass "no-pr prose: $1"; else fail "no-pr prose: $1"; fi
}

DOER_SKILL_MD="$REPO_ROOT/skills/doer/SKILL.md"
WRAPUP_MD="$REPO_ROOT/skills/doer/stages/05-wrapup.md"
DOER_FRONT="$(awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f' "$DOER_SKILL_MD")"
DOER_DISPATCH="$(md_section "$DOER_SKILL_MD" '## Entry-point dispatch')"
np_has "doer frontmatter is version 7.19.0" "$DOER_FRONT" 'version: 7.19.0'
np_has "doer description mentions --no-pr" "$DOER_FRONT" '--no-pr'
np_has "doer dispatch shows <ID> [--no-pr]" "$DOER_DISPATCH" '<ID> [--no-pr]'
np_has "doer dispatch mentions --no-pr" "$DOER_DISPATCH" '--no-pr'
np_has "doer dispatch says a resume --no-pr is ignored" "$DOER_DISPATCH" 'ignored'
np_has "01-ac Step 3 records no_pr" "$AC_STEP3" 'no_pr'

STATE_TEXT="$(cat "$REPO_ROOT/$STATE_REL")"
np_has "state.md documents no_pr" "$STATE_TEXT" 'no_pr'
if grep -F 'no_pr' "$REPO_ROOT/$STATE_REL" | grep -qF 'absent'; then pass "no-pr prose: state.md says absent no_pr means the PR flow"; else fail "no-pr prose: state.md says absent no_pr means the PR flow"; fi

WRAPUP_INTRO="$(sed -n 3p "$WRAPUP_MD")"
WRAPUP_STEP5="$(md_section "$WRAPUP_MD" '## 5.')"
WRAPUP_STEP6="$(md_section "$WRAPUP_MD" '## 6.')"
WRAPUP_TEXT="$(cat "$WRAPUP_MD")"
WRAPUP_NOPR_PARA="$(printf '%s\n' "$WRAPUP_STEP6" | grep -F '**No-PR.**')"
np_has "wrapup intro says step 6 is skipped in no-PR mode" "$WRAPUP_INTRO" 'In no-PR mode step 6 is skipped with a recorded one-line message instead of a reply.'
np_has "wrapup step 5 defines PR-ready for no-PR mode" "$WRAPUP_STEP5" 'In no-PR mode (`metadata.no_pr` is true) read "PR-ready" as: one commit on top of the base branch.'
np_has "wrapup step 5 keeps the three candidates" "$WRAPUP_STEP5" 'Draft THREE candidates'
np_has "wrapup step 5 keeps the squash gate offer" "$WRAPUP_STEP5" 'Squash gate, then offer to squash now'
np_has "wrapup step 5 keeps the squash command" "$WRAPUP_STEP5" 'git-ops.sh" squash <base> <TICKET-ID> doer'
np_has "wrapup step 5 keeps the squash sentence" "$WRAPUP_STEP5" 'The dev squashes the per-stage commits into one PR-ready commit.'
np_has "wrapup step 6 has a No-PR paragraph" "$WRAPUP_NOPR_PARA" '**No-PR.**'
np_has "wrapup step 6 No-PR paragraph keys on metadata.no_pr" "$WRAPUP_NOPR_PARA" 'metadata.no_pr'
np_has "wrapup step 6 No-PR paragraph prints the skip message" "$WRAPUP_NOPR_PARA" 'PR description skipped: this ticket has no PR'
np_has "wrapup step 6 No-PR paragraph records via metadata.sh write" "$WRAPUP_NOPR_PARA" 'metadata.sh write'
np_has "wrapup step 6 No-PR paragraph stores \"skipped\"" "$WRAPUP_NOPR_PARA" '"skipped"'
np_has "wrapup step 6 keeps pr-templates" "$WRAPUP_STEP6" 'git-checks.sh" pr-templates'
np_has "wrapup step 6 keeps the writer Agent dispatch" "$WRAPUP_STEP6" 'Dispatch a PR-description writer Agent'
np_has "wrapup step 6 keeps the approval question" "$WRAPUP_STEP6" 'keep it as is, or want changes?'
np_has "wrapup step 8 precondition accepts \"skipped\"" "$(md_section "$WRAPUP_MD" '## 8.')" 'Precondition: step 6 has the dev'"'"'s explicit approval of the PR description (or `"skipped"`)'
np_has "wrapup keeps the default closing line" "$WRAPUP_TEXT" 'Run your pre-commit checks, use the commit message and PR description above, then push and open the PR manually (or keep everything as is).'
np_closing_line "wrapup has a no-PR closing line without PR wording" "$WRAPUP_TEXT"

BUGFIX_FRONT="$(awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f' "$BUGFIX_MD")"
BUGFIX_TEXT="$(cat "$BUGFIX_MD")"
np_has "bugfix frontmatter is version 7.19.0" "$BUGFIX_FRONT" 'version: 7.19.0'
np_has "bugfix description mentions --no-pr" "$BUGFIX_FRONT" '--no-pr'
np_has "bugfix Stage 0 mentions --no-pr" "$BUGFIX_STAGE0" '--no-pr'
np_has "bugfix Stage 0 records no_pr" "$BUGFIX_STAGE0" 'no_pr'
np_has "bugfix Stage 0 says a resume --no-pr is ignored" "$BUGFIX_STAGE0" 'ignored'
np_has "bugfix schema carries \"no_pr\": false" "$BUGFIX_TEXT" '"no_pr": false'
np_has "bugfix Stage 6 has a No-PR clause" "$BUGFIX_STAGE6" '**No-PR.**'
np_has "bugfix Stage 6 prints the skip message" "$BUGFIX_STAGE6" 'PR description skipped: this ticket has no PR'
np_has "bugfix Stage 6 stores \"skipped\"" "$BUGFIX_STAGE6" '"skipped"'
np_has "bugfix Stage 6 keeps pr-templates" "$BUGFIX_STAGE6" 'pr-templates'
np_has "bugfix Stage 6 keeps the approval question" "$BUGFIX_STAGE6" 'keep it as is, or want changes?'
np_has "bugfix Stage 6 keeps the squash gate offer" "$BUGFIX_STAGE6" 'Squash gate, then offer to squash now'
np_has "bugfix Stage 6 step 10 precondition accepts \"skipped\"" "$BUGFIX_STAGE6" 'Precondition: step 9 has the dev'"'"'s explicit approval (or `"skipped"`)'
np_closing_line "bugfix Stage 6 has a no-PR closing line without PR wording" "$BUGFIX_STAGE6"
np_lacks "bugfix never says open the PR" "$BUGFIX_TEXT" 'open the PR'

PLUGIN_JSON_VERSION="$(jq -r '.version' "$REPO_ROOT/.claude-plugin/plugin.json")"
if [ "$PLUGIN_JSON_VERSION" = "7.19.0" ]; then pass "no-pr prose: plugin.json version is 7.19.0"; else fail "no-pr prose: plugin.json version is 7.19.0"; fi
np_has "README mentions --no-pr" "$(cat "$REPO_ROOT/README.md")" '--no-pr'
np_has "README states Plugin version 7.19.0" "$(cat "$REPO_ROOT/README.md")" 'Plugin version 7.19.0'
CHANGELOG_718="$(awk '/^## 7\.18\.0/{g=1;next} g&&/^## /{exit} g' "$REPO_ROOT/CHANGELOG.md")"
np_has "CHANGELOG has a 7.18.0 heading" "$(cat "$REPO_ROOT/CHANGELOG.md")" '## 7.18.0'
np_has "CHANGELOG 7.18.0 entry mentions --no-pr" "$CHANGELOG_718" '--no-pr'
np_has "CHANGELOG keeps the 7.17.1 heading" "$(cat "$REPO_ROOT/CHANGELOG.md")" '## 7.17.1'

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
