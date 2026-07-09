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
- Read budget: 15 source files + lessons. Return changelog_appendix + status.

Commit once the suite is green:
```bash
git add -A && git commit --no-verify -m "doer(<TICKET-ID>): implementation (BDD green)"
```
(code-first mode: `"doer(<TICKET-ID>): regression tests + implementation (direct)"`, covering both the tests and the code in one commit since they were written together.)

**3. Deterministic pre-review checks** (orchestrator, no LLM). Any BLOCKER here skips the reviewer and goes straight to the next iteration's fixer:

- **Tests:** run the repo's test command; any failure (new or pre-existing) is a BLOCKER.
- **Lint / typecheck:** run the repo's commands (detect from package.json / build.gradle / pyproject.toml; ask once and persist as `metadata.lint_command` / `metadata.typecheck_command` if unclear). Failures are BLOCKERs.
- **Scope:** plan file not touched → BLOCKER; file touched outside the plan → INFO for the reviewer.
- **Secrets:** `git diff <base>..HEAD | grep -nEi '(api[_-]?key|secret|token|password|bearer|aws_)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{8,}'` → any match is a BLOCKER (dev rotates credentials; never auto-fix).
- **AC-N leak:** `git diff <base>..HEAD -- . ':(exclude).doer/**' | grep -E '^\+' | grep -E '\bAC-[0-9]+\b'` → BLOCKER; the fixer removes the label and rewrites the comment in plain business language.

**4. Reviewer** (only when pre-checks are clean). Prompt inlines ac, plan, last 2 changelog entries, the diff. Scope, in order:

1. AC match: trace each AC to test + code.
2. Correctness: edge cases, error paths, concurrency, null handling.
3. Test integrity: were tests weakened to pass?
4. Semantic error handling: are handlers specific and meaningful, or silent swallows?
5. One logical unit: does the diff mix unrelated work that should split?
6. Comment quality: stale/misleading comments, restated code, over-long comments → AUTO_FIX to SHORTEN (never to add caveats).

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
2. Run the full suite once more if anything changed since the last green run; then persist `metadata.last_green_sha` (full 40-char `git rev-parse HEAD`) and `metadata.last_green_test_command`. A red suite here re-enters the loop; do not advance.
3. Validate required fields per `lib/state.md`, set `stages.3` complete (`iterations`, `loop_outcome`), narrate *"Stage 3 complete: converged in <i> iteration(s), <N>/<N> tests green. Continuing to Stage 4..."* and auto-proceed: read `04-verify.md` and ONLY that file.

If 3 iterations do not converge, follow the max-iteration escape hatch in `lib/loop.md` (dev decides: one more, accept residuals, or pause).
