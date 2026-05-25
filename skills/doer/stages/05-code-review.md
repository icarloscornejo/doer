# Stage 5. Code Review (Hybrid: Deterministic + Reviewer LLM)

**Goal:** PR-readiness check. Catch the mechanical "should never reach a PR" issues with deterministic greps, then invoke the reviewer LLM only for the semantic judgements that require it.

**This stage uses the loop pattern in `${CLAUDE_PLUGIN_ROOT}/lib/loop.md`. Read it now.** Standard delta-aware loop applies. Iter 2+ uses the combined fixer-reviewer per the Loop Pattern.

## Advisor personas (opt-in)

Run BEFORE the deterministic Pre-reviewer Checks A/B/C, but ONLY in iteration 1 of Stage 5. Personas do not re-run in iter 2/3; their blockers carry into later iterations through the standard `prior_blockers_resolved` / `prior_blockers_still_open` flow exactly like reviewer-sourced blockers.

**Step 1. Read the flag.** Run `${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh get-flag stage5_advisor_personas` (the helper reads `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json` and emits a comma-separated list of persona ids, e.g. `security,performance`). If the output is empty, skip this entire block and proceed directly to the Pre-reviewer Checks below.

**Step 2. Validate persona ids.** For each id in the list, verify `${CLAUDE_PLUGIN_ROOT}/lib/advisor-personas/<id>.json` exists. Drop missing ids with one narrated warning per missing id (`"Persona '<id>' not found in lib/advisor-personas/. Skipping."`). If the list is empty after validation, skip this block.

**Step 3. Dispatch.** MUST invoke `/wk:advise --target ticket:<TICKET-ID> --personas <comma-list>` via the Agent tool (or the equivalent Agent dispatch using the persona JSON files inline; see `skills/advise/SKILL.md` for the prompt template). The orchestrator MUST NOT perform advisor reviews inline. The skill writes one file per persona at `.doer/tickets/<TICKET-ID>/advisor-findings/<persona-id>.json`. Wait for all persona Agents to return before proceeding.

**Step 4. Ingest findings.** For each `.doer/tickets/<TICKET-ID>/advisor-findings/<persona-id>.json` written this iteration, parse the `findings[]` array and route each entry by `severity`:

- `"blocker"` -> append to `metadata.code_review[iteration=1].blockers[]` as `{"id": "B-<n>", "text": "<title>: <explain> Fix: <fix> (where: <where>)", "source": "advisor:<persona-id>"}`. Use the next available `B-<n>` id (continue numbering across reviewer + advisor blockers in the same iteration).
- `"high"`, `"medium"`, `"low"` -> append to `metadata.code_review[iteration=1].suggestions[]` as `{"text": "[<SEVERITY>] <title>: <explain> Fix: <fix> (where: <where>)", "source": "advisor:<persona-id>"}`.
- `"info"` -> append to `metadata.code_review[iteration=1].info[]` as `{"text": "<title>: <explain> (where: <where>)", "source": "advisor:<persona-id>"}`.

Set `metadata.code_review[iteration=1].advisor_personas_ran` to the list of persona ids that successfully ran (excluding the dropped-missing ones).

**Step 5. Inline findings into the reviewer LLM prompt.** When invoking the reviewer LLM in the next sub-step, append a section to its prompt:

```
== Advisor findings (already ingested into metadata.code_review) ==
<JSON dump of the findings appended this turn, grouped by persona>
```

The reviewer is instructed to acknowledge advisor blockers but NOT to re-judge them; its scope remains the three judgement axes documented below.

**Step 6. Convergence interaction.** If advisor personas produced any blockers AND the deterministic Pre-reviewer Checks A/B/C also produce blockers, all blockers from this iteration are persisted together. The combined fixer-reviewer in iter 2 receives the prior `metadata.code_review` entry inline and treats every prior blocker (regardless of `source`) under the standard `RESOLVED` / `STILL_OPEN` rule.

**Iteration 2 and 3 behavior.** Personas are NOT re-invoked. The combined fixer-reviewer of iter 2/3 inherits all prior blockers (advisor and reviewer alike) through the existing loop machinery. Any `source: "advisor:<persona-id>"` annotation is preserved when a blocker is recorded as `STILL_OPEN`.

**Failure modes.**
- `/wk:advise` returns a non-JSON or empty array for a persona: log a warning, treat that persona as having zero findings, and continue. Do NOT fail Stage 5.
- A persona file is malformed JSON: drop with a warning, continue.
- All requested personas fail: narrate a single warning (`"All advisor personas returned no usable findings. Continuing with deterministic checks only."`) and proceed.

## Pre-reviewer deterministic checks

Run all three. Each catches a class of PR-readiness issues without an LLM call.

**Check A. Secrets in the diff.**
Use `gitleaks` if available; otherwise a regex sweep:
```bash
git diff <base>..HEAD | grep -nEi '(api[_-]?key|secret|token|password|bearer|aws_)[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{8,}'
```
Any match → BLOCKER. Do not auto-fix; the dev must rotate credentials and amend.

**Check B. Smoke / end-to-end test exists.**
Inspect `metadata.plan.tests` + the actual tests added in Stage 3 (paths in `metadata.changelog` Stage 3 entries). Look for at least one test that exercises the full flow described in the ACs (not just unit isolation). If none → SUGGESTION (not BLOCKER, since some tickets legitimately have only unit-level tests):
```
- S-1 (smoke): no end-to-end test detected. Consider adding one if the
  ticket touches a user-facing flow.
```

**Check C. Swallow-all error handlers in the diff.**
```bash
git diff <base>..HEAD | grep -nE '(except\s*:|except\s+Exception\s*:|catch\s*\(\s*\w*\s*\)\s*\{?\s*\}?)' | grep -v test
```
Any match → SUGGESTION (the dev may have intentional reasons; do not auto-fix):
```
- S-2 (error handling): bare `except:` at <file>:<line>. Consider catching
  a specific exception or logging.
```

## Reviewer LLM (only if pre-checks did not produce BLOCKERs)

If Check A (secrets) produced any BLOCKERs, end the iteration and hand them to the iter-N+1 fixer (the dev cannot proceed with secrets in the diff). Skip the reviewer LLM for that iteration.

Otherwise, MUST invoke the PR-readiness reviewer as a sub-agent via the Agent tool with a TIGHT scope. The orchestrator MUST NOT perform the PR-readiness review inline. Stage 4's reviewer already validated correctness; do not duplicate that work here:

```
You are the PR-readiness reviewer for ticket <TICKET-ID>.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump>

== metadata.plan ==
<JSON dump>

== Last 2 metadata.changelog entries ==
<JSON dump>

== Diff ==
<output of `git diff <base>..HEAD`>

The deterministic checks already ran (secrets, smoke test, swallow-all
handlers). Stage 4's reviewer already validated correctness and AC behavior.

Your scope is narrow. Judge ONLY:

1. ONE logical unit: does the diff describe a single coherent change,
   or does it mix unrelated work that should split into separate PRs?
   If mixed, classify as BLOCKER with a "recommended split" suggestion.

2. Semantic error handling: where the dev DID handle errors (not bare
   except), are the handlers appropriate? Specific exception types?
   Meaningful recovery or fallback? Logging? Or silently swallowing in
   a way that will hide bugs in production?

3. Stale or misleading comments in the diff: TODO that should have
   been done, comments that contradict what the code now does, dead
   code commented out.

Output findings as BLOCKER / AUTO_FIX / SUGGESTION / INFO. See
${CLAUDE_PLUGIN_ROOT}/lib/loop.md for classification rules.

Read budget: 3 files max beyond what's in the diff.
```

## Debugging discipline (when fixing failures)

When the iter 2+ combined fixer-reviewer (or any AUTO_FIX fixer) is responding to a BLOCKER that indicates incorrect behavior (not style, formatting, or pure mechanical cleanup), the prompt MUST include this instruction verbatim:

> Before proposing any fix: read `${CLAUDE_PLUGIN_ROOT}/lib/debugging.md` and follow the protocol. No fix without root cause. Narrate each phase.

## Loop convergence

Standard delta-aware loop applies (see `${CLAUDE_PLUGIN_ROOT}/lib/loop.md`). Iter 2+ uses the combined fixer-reviewer per the Loop Pattern.

Commit at convergence:
```bash
git add -A
git commit --no-verify -m "doer(<TICKET-ID>): address code review"
```

If the dev had nothing to fix (all pre-checks clean and reviewer found zero BLOCKERs), no commit is needed (no diff vs HEAD).

If a commit happened, run the test suite once more and update the green-test marker so Stage 6 can skip:
```json
metadata.last_green_sha = <git rev-parse HEAD>   # MUST be the full 40-char SHA. NEVER abbreviated. The skip-safe check in Stage 6 compares this string-equal to `git rev-parse HEAD` of the new HEAD; an abbreviated SHA breaks the comparison.
metadata.last_green_test_command = <the test command that ran>
```
If the post-commit test run fails, that is a regression: surface as a BLOCKER and re-enter the iter loop. Do not advance.

Run the Stage Finalization Checklist (`${CLAUDE_PLUGIN_ROOT}/lib/stage-checklist.md`) before transitioning. Auto-proceed: Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/06-quality-gate.md` and ONLY that file.
