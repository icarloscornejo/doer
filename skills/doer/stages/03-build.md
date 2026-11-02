# Stage 3. Build (Tests + Code + Review Loop)

**Goal:** implement the plan with tests, converge through the doer/reviewer loop, exit with the full suite green. Uses the loop pattern in `lib/loop.md` (max 3 iterations). Commits real code on the feature branch, one commit per step (tests, implementation, each round of review fixes), not a single commit at the end: per-step commits make it possible to tell exactly which step introduced a regression, and the wrapup squash (`05-wrapup.md` step 5) collapses them into one PR-ready commit anyway.

## Test order (one-line criterion, no ritual)

The change has observable behavior (user-facing flow, bug with repro, conditional logic, analytics with AC) → **tests first**: the test-writer produces failing Given/When/Then-derived tests, then the code-writer makes them pass. The change is trivial/cosmetic (label, copy, constant, config) → **code first**: implement, then add minimal passing regression tests in the same iteration. The orchestrator picks, narrates the choice in one line, and moves on. When in doubt, tests first.

## Iteration 1 (three Agent dispatches, per `lib/loop.md`)

**1. Test-writer** (skip only if tests were imported at Stage 1). Prompt inlines `metadata.ac`, `metadata.plan`, and the chosen test order. Key instructions:

- One or more scenarios per AC; test names reference the scenario (`given_user_has_cart_when_bap_loads_then_promos_shown`); follow repo conventions (read 2-3 existing test files; budget 5 files).
- Tests-first mode: tests MUST currently fail. Code-first mode: tests MUST pass against the implemented change.
- For delete/remove tickets, assert absence via reflection (e.g. ClassNotFoundException); never exercise the code being deleted. For multi-condition guards (feature flags, eligibility), assert the side-effect fires (mock verification), not just state.
- NEVER include `AC-N` labels in test files (names, comments, KDoc); the `covers` field in the JSON output is the only place they belong. No `// RED:`-style meta comments. Em-dashes forbidden. Artifacts in English.
- Return `{"tests_added": [{"name", "file", "covers"}], "changelog_appendix": {...}, "status", "summary"}`.

Commit once the test-writer returns:
```bash
git add -A && git commit --no-verify -m "doer(<TICKET-ID>): BDD scenarios + failing tests"
```
(code-first mode: skip this commit here and fold it into the code-writer commit below, message `"doer(<TICKET-ID>): regression tests (direct)"` becomes part of the combined message.)

**2. Code-writer.** Prompt inlines `metadata.ac`, `metadata.plan`, test file paths, last 2 changelog entries. Key instructions:

- Implement the plan; scenario names are the contract in tests-first mode. Follow codebase conventions; no new dependencies unless the plan names them (flag in changelog if unavoidable).
- Run the full test suite after implementing; everything must pass.
- Comment economy: comments explain WHY, ~2 lines max, no restating code, no ticket numbers, no `AC-N` (Core Principle 10).
- When gating a function behind a flag or condition, grep ALL call sites before marking the step done (event observers are the most-missed). When updating a doc or comment block, scan the whole file for stale references to the changed concept.
- When fixing a failing test or broken behavior, include verbatim: *"Before proposing any fix: read `${CLAUDE_PLUGIN_ROOT}/lib/debugging.md` and follow the protocol. No fix without root cause."*
- If a planned step turns out technically impossible or inapplicable (an interface constraint, a type that "can't" support the planned shape, a pattern that "can't" be followed), do not silently skip it. Grep the real call sites and type/interface definitions that back the claim and cite them verbatim in the changelog (file:line, not a paraphrase). A deviation without cited evidence gets treated as unverified by the reviewer, not as a documented tradeoff.
- Read budget: 15 source files + lessons. Return changelog_appendix + status.

Commit once the suite is green:
```bash
git add -A && git commit --no-verify -m "doer(<TICKET-ID>): implementation (BDD green)"
```
(code-first mode: `"doer(<TICKET-ID>): regression tests + implementation (direct)"`, covering both the tests and the code in one commit since they were written together.)

**3. Deterministic pre-review checks** (orchestrator, no LLM):

```bash
"${CLAUDE_PLUGIN_ROOT}/lib/helpers/stage-checks.sh" pre-review "<TICKET-ID>" "<base>"
```

Runs `metadata.test_command` / `lint_command` / `typecheck_command` (any failure, new or pre-existing, is a BLOCKER; a `missing[]` entry means that command was never persisted, ask once and persist it via a single `metadata.sh write` before re-running), scope (a plan file not touched is a BLOCKER; a file touched outside the plan is INFO for the reviewer), secrets, and AC-N leaks (both BLOCKERs). Any BLOCKER skips the reviewer and goes straight to the next iteration's fixer; secrets are never auto-fixed (the dev rotates credentials), an AC-N leak's fixer removes the label and rewrites the comment in plain business language.

`weakened-tests` covers removed or commented-out assertions, newly disabled tests, assertions wrapped in a new block comment, and deleted tests not planned as `change: delete`. Order for each such BLOCKER:

1. Fixer step: a `weakened-tests` BLOCKER goes to the next fixer first, like any BLOCKER. The fixer restores the assertion or re-enables the test, or returns it STILL_OPEN with a reason that the removal is intentional. Because only the orchestrator may justify, strip the registration command line from every `weakened-tests` BLOCKER inlined into a fixer prompt: sub-agents never see the registration command and never call `metadata.sh write`, and the prompt states that justifications are the orchestrator's alone.
2. Then only STILL_OPEN `weakened-tests` items are escalated to the dev, by the orchestrator (never a sub-agent), in plain chat; the turn ends there. The orchestrator records the justification only on the dev's explicit reason, with the `metadata.sh write` command from the BLOCKER detail (when one reply justifies several findings, one write with the filter `.test_weakening_justifications = ((.test_weakening_justifications // []) + $j)` and `--argjson j '<array of {path,line_text,reason}>'`). The fixer and the dev never act on the same finding at once.
3. A justified item must be able to reach `loop_outcome: converged` with zero open blockers, so move the id of each BLOCKER just justified into `prior_blockers_resolved` (and out of `prior_blockers_still_open`) in that same single `metadata.sh write`: the orchestrator makes ONE write holding both the justification append and this loop-state update, and only then re-runs `pre-review` to confirm. If the confirm run still lists one of them, that is a new transition and a new write.

A planned test deletion is expressed in the plan as `change: delete`, not as a justification.

**4. Reviewer** (only when pre-checks are clean). Prompt inlines ac, plan, last 2 changelog entries, the diff. Scope, in order:

1. AC match: trace each AC to test + code.
2. Deviation verification: for any changelog entry that skips or reinterprets a planned step citing a technical constraint ("this interface can't...", "this type doesn't support..."), do not trust the stated justification. Read the cited call sites and type definitions yourself. If no real construction site in production code actually exercises the blocking condition, the deviation is a BLOCKER, not a documented tradeoff, regardless of how plausible the justification reads.
3. Correctness: edge cases, error paths, concurrency, null handling.
4. Test integrity: were tests weakened to pass?
5. Semantic error handling: are handlers specific and meaningful, or silent swallows?
6. One logical unit: does the diff mix unrelated work that should split?
7. Comment quality: stale/misleading comments, restated code, over-long comments → AUTO_FIX to SHORTEN (never to add caveats).

Findings come back as BLOCKER / AUTO_FIX / SUGGESTION / INFO per `lib/loop.md`. Read budget: 5 files beyond the diff.

## Iterations 2-3

One combined fixer-reviewer Agent per `lib/loop.md` (prior findings inlined, re-scan only touched lines). Convergence = zero BLOCKERs; SUGGESTIONs never block.

Commit after each iteration's fixes, only if the fixer changed anything:
```bash
git add -A && git commit --no-verify -m "doer(<TICKET-ID>): address code review"
```
No changes to commit (the reviewer had nothing left to flag) → skip, no empty commit.

## On convergence

1. If anything is left uncommitted (a stray edit outside the iteration loop), commit it as a straggler:
   ```bash
   git add -A && git commit --no-verify -m "doer(<TICKET-ID>): address code review"
   ```
2. Run the full suite once more if anything changed since the last green run. A red suite here re-enters the loop; do not advance.
3. Require a clean `pre-review` on the final HEAD (after any straggler commit; this also covers the one-more-iteration option and `RETURN_TO_BUILD` re-entry). A BLOCKER re-enters the loop, except: when `loop_outcome` is `accepted_with_residuals` the final-HEAD BLOCKERs are recorded as residuals instead of re-entering the loop, and re-entry after iteration 3 goes to the max-iteration escape hatch, never a 4th automatic iteration, so pre-existing lint failures or untouched planned files cannot deadlock the stage.
4. Build ONE jq filter that in a single pass sets `metadata.last_green_sha` (full 40-char `git rev-parse HEAD`), `metadata.last_green_test_command`, and `stages.3` complete (`completed_at`, `iterations`, `loop_outcome`); call `metadata.sh write "<TICKET-ID>" '<filter>' --require 3:complete` exactly once. `--require` validates the required fields per `lib/state.md` against the transformed document before swapping; on failure, back-fill and write again as a NEW transition. Narrate *"Stage 3 complete: converged in <i> iteration(s), <N>/<N> tests green. Continuing to Stage 4..."* and auto-proceed: read `04-verify.md` and ONLY that file.

If 3 iterations do not converge, follow the max-iteration escape hatch in `lib/loop.md` (dev decides: one more, accept residuals, or pause).
