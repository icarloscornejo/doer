# Stage 4. Code (Doer/Reviewer Loop)

**Goal:** implement the change per `metadata.plan`. The exact contract depends on `metadata.testing_strategy.mode`:

- `bdd`: implement code so the BDD scenario tests from Stage 3 pass; scenario names are the implementation contract.
- `direct`: implement the change directly. Tests do not exist yet; Stage 3 writes regression tests AFTER this stage commits.

**This stage uses the loop pattern in `${CLAUDE_PLUGIN_ROOT}/lib/loop.md`. Read it now.** Loop with **max 3 iterations**.

**Mode check.** At entry, read `metadata.testing_strategy.mode`. The value is inlined into the writer prompt and influences pre-reviewer Check A (see "Pre-reviewer deterministic checks"). After commit, the orchestrator decides where to advance based on `testing_strategy.mode` (see "Direct return" at the end).

**Gate check.** At entry, also resolve `stage4_per_task_gate` and `stage4_parallel_subagents` via `${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh get-flag <flag-name>` (each returns `true`, `false`, or empty/`false` when unset, default `false`). The two flags are mutually exclusive: if both are `true`, the gate wins, parallelism is silently disabled, and the orchestrator narrates *"Both stage4_per_task_gate and stage4_parallel_subagents are true. Per-task gate takes precedence; parallelism disabled for this Stage 4."* before continuing. The decision tree:

1. If `stage4_per_task_gate: true`: run the "Per-task gate (opt-in)" sub-loop below.
2. Else if `stage4_parallel_subagents: true`: run the "Parallel subagents (opt-in)" sub-loop below.
3. Else: skip directly to the writer prompt for the full plan, the deterministic checks, and the reviewer (legacy flow).

In all three branches, the deterministic Check A/B/C and the reviewer LLM run ONCE at the end against the cumulative Stage 4 diff.

## Per-task gate (opt-in)

Active ONLY when `preferences.sh get-flag stage4_per_task_gate` returns `true`. The orchestrator implements one entry of `metadata.plan.steps[]` at a time and pauses for a human gate after each. The deterministic checks and the reviewer LLM still run ONCE at the end against the full Stage 4 diff (the gate is PRE-reviewer, not POST).

**Initialize at entry:**

1. Capture `metadata.stages.4.pre_stage4_sha = <git rev-parse HEAD>` (full 40-char SHA). This is the rollback anchor for `view-full-diff` and the diff base for the eventual reviewer call.
2. Initialize `metadata.stages.4.per_task_gate = {"enabled": true, "decisions": []}`.

**Per-step loop.** For each entry in `metadata.plan.steps[]` (in `order`):

1. Capture `pre_step_sha = <git rev-parse HEAD>` (local variable, not persisted).
2. Invoke the **single-step writer** (variant of the writer prompt below; payload is restricted to the current step plus AC and lessons; read budget shrinks to 5 source files since the surface area is smaller).
3. `git add -A`.
4. **Empty-diff branch.** If `git diff --cached` is empty, do NOT present the gate. Append `{step_order: <order>, decision: "auto_accepted_empty", at: "<ISO8601>"}` to `metadata.stages.4.per_task_gate.decisions`, narrate *"Step N produced zero changes. Auto-accepted. Continuing."*, advance to the next step.
5. **Gate.** Otherwise, narrate the staged diff (`git diff --cached`) and call `AskUserQuestion` with the four-option gate (see "Gate options" below). Apply the chosen branch.
6. Repeat until all steps are processed OR a `reject` aborts the stage.

**Gate options.** Present exactly these four decision options in `AskUserQuestion` (the tool also auto-appends a free-text "Other"; do NOT add a fifth option). Orchestrator narration is in the operating locale; the option semantics are fixed:

| Option | Action |
|---|---|
| `accept` | Leave the staged diff in place. Append `{step_order, decision: "accepted", at}`. Continue. |
| `edit` | Sub-prompt: `manual` or `via-writer`. See "Edit semantics" below. |
| `reject` | `git reset --hard <pre_step_sha>`. Append `{step_order, decision: "rejected", at}`. Set `metadata.stages.4.status = "blocked"`, set `metadata.stages.4.blocked_reason = "rejected at step <order>"`. Narrate *"Stage 4 aborted at step N (rejected). Run /doer continue <ID> after adjusting metadata.plan."*. End turn. |
| `skip` | `git reset --hard <pre_step_sha>`. Append `{step_order, decision: "skipped", at}`. Continue to the next step. The plan step is recorded as not implemented; the eventual reviewer will see it as a missing-file BLOCKER from Check C if the step required a file that was now never touched, which the dev can address by accepting residuals at convergence or re-running. |

**View full diff (not a decision).** This is NOT one of the four options. If the dev replies through the auto-appended free-text option asking to see the full diff, print `git diff <pre_stage4_sha>..HEAD` (cumulative Stage 4 diff) and re-present the SAME gate. It does not count as a decision and is never recorded in `decisions[]`.

**Edit semantics.** When the dev picks `edit`, ask one follow-up `AskUserQuestion`:

- `manual`: narrate *"Edit by hand and reply when done."*. End turn. On the next user message that is not a halt signal, run `git add -A`, append `{step_order, decision: "edited_manual", at}`, continue to the next step. (The auto-resume rule from `lib/narration.md` already covers re-entry semantics.)
- `via-writer`: ask the dev for instructions in a free-text field, then re-invoke the single-step writer with those instructions inlined as `== Dev edit instructions ==`. Re-present the SAME gate (no new `pre_step_sha`; this is still the same step). Append `{step_order, decision: "edited_via_writer", at, edit_instructions: "<verbatim>"}` only when the dev finally accepts (so a step that goes via-writer twice ends up with one `edited_via_writer` decision plus one `accepted`).

**After the per-step loop:**

If the loop exited via a `reject`, Stage 4 is blocked and the turn already ended; nothing else to do. Otherwise (all steps processed via `accepted`, `edited_manual`, `edited_via_writer`, `auto_accepted_empty`, or `skipped`), narrate a one-line summary of the decisions (e.g. *"Per-task gate: 4 accepted, 1 edited (manual), 1 skipped."*) and fall through to the deterministic Check A/B/C and the reviewer LLM exactly as in the legacy flow. The diff base for both is `metadata.stages.4.pre_stage4_sha`.

**Single-step writer prompt skeleton.** Identical to the full writer prompt below, except:
- `== Current step ==` block is added with the JSON of the one `metadata.plan.steps[i]` entry.
- The instruction is restricted: *"Implement ONLY the current step. Do not implement other entries of metadata.plan.steps. Do not refactor unrelated code. If the step says to edit a file you have not touched yet, edit ONLY the lines required by this step."*
- For `via-writer` re-invocations, also include `== Dev edit instructions ==` with the dev's verbatim text and the instruction *"Apply the dev edit instructions. Do not revert prior decisions for other steps; the diff so far is already accepted."*
- Read budget: 5 source files.

## Parallel subagents (opt-in)

Active ONLY when `preferences.sh get-flag stage4_parallel_subagents` returns `true` AND `stage4_per_task_gate` returns `false` (or is unset). The orchestrator dispatches independent steps in parallel within each `parallel_group`. The deterministic checks and the reviewer LLM still run ONCE at the end against the cumulative Stage 4 diff (parallelism is PRE-reviewer, not POST).

**Initialize at entry:**

1. Capture `metadata.stages.4.pre_stage4_sha = <git rev-parse HEAD>` (full 40-char SHA). Diff base for the eventual reviewer.
2. Initialize `metadata.stages.4.parallel_subagents = {"enabled": true, "groups": []}`.

**Build the dispatch order.** Walk `metadata.plan.steps[]` in `order` and group entries:

- Steps sharing the same non-null `parallel_group` join that group.
- Steps with `parallel_group` absent or `null` form a singleton group with id `"serial-<order>"`.
- Group dispatch order is determined by the FIRST step (lowest `order`) in each group. Once a group dispatches, the next group does not start until the previous group fully resolves.

**Conflict detection (pre-dispatch, per group).** For every group with more than one step, compute the union of declared file paths across the group's steps:
- Take each step's `where` (parsing the `<file>:<line-range>` form; the file part is everything before the first `:`).
- Add files referenced in `metadata.plan.files[]` that the step's `verb` would touch (best-effort match by path; when the planner's `where` already names a file, this is redundant but cheap).
- If two steps in the group declare the same file, narrate *"Group <id> has file overlap (<path>); serializing within the group."* and dispatch the group's steps SEQUENTIALLY in `order` (each step's writer ⇒ `git add -A` ⇒ next; no gate, no rollback). Record `dispatched: "serialized_due_to_overlap"`.
- If files are disjoint, dispatch in parallel (below). Record `dispatched: "parallel"`.
- Singleton groups (one step) record `dispatched: "serial_singleton"` and run as a single Agent call.

**Parallel dispatch.** For a parallel group of N>=2 steps:

1. Record `started_at = <ISO8601>` on the group entry.
2. Issue N Agent invocations in a single tool block. Each Agent uses the single-step writer prompt (same as documented in the per-task gate section), with its own step inlined as `== Current step ==`. Each Agent writes directly to the working tree; the orchestrator does NOT pre-stash, isolate, or sandbox. Read budget: 5 source files per Agent.
3. Wait for all N to return. The orchestrator does NOT cancel siblings if one errors.
4. **Error handling.** For any Agent that returned a non-success result:
   - Append the failed step's `order` to `metadata.stages.4.parallel_subagents.groups[g].errored_step_orders`.
   - Persist the `changelog_appendix` of every Agent that DID succeed in the group as separate entries in `metadata.changelog`. Do NOT roll back successful work.
   - Narrate the error *"Step <order> failed in group <id>: <agent error>. Other steps in the group completed. Stage 4 paused."*.
   - End turn. The dev resumes via `/doer continue <ID>` after deciding (re-plan, retry, or accept partial).
5. **All succeeded.** Run a single `git add -A`, persist each `changelog_appendix` as a separate `metadata.changelog` entry tagged with the step's `order`, narrate *"Group <id>: <N> steps completed in parallel."*, set `completed_at = <ISO8601>` on the group entry, advance to the next group.

**After all groups complete:** narrate a one-line summary (e.g. *"Parallel dispatch: 3 groups, 7 steps, 2 groups parallel and 1 serialized due to overlap."*) and fall through to the deterministic Check A/B/C and the reviewer LLM exactly as in the legacy flow. The diff base for both is `metadata.stages.4.pre_stage4_sha`.

**Why the "write directly to working tree" model.** Each parallel group is constructed so that its steps touch disjoint files (verified pre-dispatch). When that holds, concurrent writes do not race, and a single `git add -A` after the group resolves all of them. Worktree isolation would add complexity (per-step worktrees, merge passes, conflict resolution) without protecting against anything that the disjoint-files invariant does not already cover.

## Debugging discipline (when fixing failures)

When the writer or fixer sub-agent is responding to a failing test, runtime error, or reviewer BLOCKER that signals broken behavior, the prompt MUST include this instruction verbatim:

> Before proposing any fix: read `${CLAUDE_PLUGIN_ROOT}/lib/debugging.md` and follow the protocol. No fix without root cause. Narrate each phase.

This applies to iter 2+ combined fixer-reviewer dispatches and to AUTO_FIX fixers when the trigger is broken behavior (not pure mechanical cleanup).

## Code writer prompt (skeleton)

The orchestrator MUST invoke the code writer as a sub-agent via the Agent tool for every iteration (iter 1 full-plan writer, per-task-gate single-step writer, parallel subagents per group). The orchestrator MUST NOT write implementation code inline.

```
You are the code writer for ticket <TICKET-ID>.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump of metadata.ac>

== metadata.plan ==
<JSON dump of metadata.plan>

== Tests added in Stage 3 ==
<list of test file paths from metadata.changelog Stage 3 entries; the agent
reads them as part of its source budget. EMPTY if testing_strategy.mode is
"direct" (Stage 3 has not run yet).>

== Last changelog entries ==
<JSON dump of metadata.changelog[-2:]>

== Testing strategy ==
<JSON dump of metadata.testing_strategy>

If strategy.mode is "bdd": implement the code such that the BDD scenario tests
pass. Trace each scenario to the AC it covers. The scenario names in the test
files are your implementation contract.
If strategy.mode is "direct": implement the change directly. Tests do not exist
yet (they will be written in Stage 3 after this stage). Do not over-engineer.

Implement the plan. Follow existing codebase conventions. Do not add new
dependencies unless metadata.plan specifies them (if you must, return a
changelog item flagging it).

After implementation:
- For "bdd": run the full test suite. All tests (new and pre-existing) MUST pass.
- For "direct": no new tests exist yet. Run the pre-existing test suite to confirm no regression. If the repo has no test command or running it is too expensive, note that in the changelog and skip.

Output JSON:
{
  "changelog_appendix": {
    "stage": 4, "iteration": <N>, "kind": "initial",
    "items": [
      {"type": "step", "text": "<plan step + how it was executed + file path>"},
      ...
    ]
  }
}

Read budget: 15 source files (iter 1) or 3 source files beyond the diff (iter 2+).

Em-dashes are forbidden. Use commas, periods, or parentheses instead.
All artifacts you write (code comments, JSON values, commit messages) MUST be in English.
NEVER include AC-N identifiers (e.g. AC-1, AC-3) anywhere in source or test files -- not in inline comments, not in KDoc, not in test names. These are internal doer orchestration labels with no meaning to future codebase readers. Given/When/Then KDoc on test functions is encouraged but must be written in plain business language only, with no AC-N references.
```

## Cost attribution (Agent `description` convention)

Cost is recovered from the session transcript at Stage 9 (`cost-transcript.sh reconcile`), not from the Agent return. To make the per-stage / per-agent breakdown attributable, set the `description` of EVERY Agent dispatched in Stage 4 (iter 1 full-plan writer, single-step writer, parallel-group writers, iter 1 reviewer, AUTO_FIX fixer, iter 2+ combined fixer-reviewer) to the canonical prefix when dispatching it:

```
doer:s4:<role> | <free text describing the call>
```

Where `<role>` is one of `code-writer` (writers, single-step or parallel), `code-reviewer` (iter 1 reviewer), `auto-fix-fixer` (AUTO_FIX pass), `code-fixer-reviewer` (iter 2+ combined). Increment `metadata.stages.4.agent_invocations` after each return. The reconciler parses `doer:s<N>:<role>` from each sub-agent's `meta.json` to build `cost.by_stage` / `cost.by_agent`; without the prefix the call lands under `unassigned`. See `${CLAUDE_PLUGIN_ROOT}/lib/cost.md`.

## Pre-reviewer deterministic checks

Run these BEFORE invoking the code-reviewer. Each catches a class of obvious failures without burning an LLM call.

**Check A. Tests pass.** Behavior depends on `metadata.testing_strategy.mode`:

- **`bdd`**: run the repo's test command. ALL tests (the new failing ones added in Stage 3 plus all pre-existing tests) MUST now pass. Any failure is a BLOCKER:
  ```bash
  <repo's test command>
  ```
  ```
  - B-1 (test fail): tests/login_test.kt::testLoginSuccess expected "ok", got "null"
  - B-2 (regression): tests/auth_test.kt::testTokenRefresh now fails (was passing pre-Stage 4)
  ```
- **`direct`**: no Stage 3 tests exist yet (deferred). Run the PRE-EXISTING test suite ONLY to catch regressions. If a pre-existing test fails, that is a BLOCKER (`B-X (regression): <test name> now fails`). If the repo has no test command or running it is too expensive for a trivial cosmetic change, narrate the skip explicitly (`"Check A skipped: direct mode and no cheap test command available."`) and rely on Checks B and C.

**Check B. Lint / typecheck:**
```bash
<repo's lint command>     # e.g. ./gradlew detektAll, npm run lint, ruff check
<repo's typecheck>        # e.g. tsc --noEmit, mypy, ./gradlew compileKotlin
```
Detect commands by reading the repo's standard config (package.json scripts, build.gradle, pyproject.toml, etc.). If unclear, ask the dev once and persist as `metadata.lint_command` / `metadata.typecheck_command`. If a repo legitimately has no lint or typecheck, skip the check.

Failures here are BLOCKERs auto:
```
- B-3 (lint): src/login.kt:42: unused import
- B-4 (typecheck): src/auth.ts:18: Type 'string' is not assignable to 'number'
```

**Check C. Plan-driven file scope:**
Iterate `metadata.plan.files[]` to extract the expected change list. Compare with `git diff --name-only <base>..HEAD` from this stage's writer. Two cases:
- File in `metadata.plan.files[]` but NOT touched → BLOCKER (`B-5: plan called for src/foo.kt edit, not modified`)
- File touched but NOT in `metadata.plan.files[]` → INFO with note (could be legit follow-up; reviewer decides):
  ```
  - I-1 (scope): writer touched src/bar.kt which is not in metadata.plan.files. Reviewer should validate this is intentional.
  ```

**If any of A/B/C produced BLOCKERs**, end the iteration here. Do NOT invoke the reviewer for that iteration. Hand the BLOCKERs to the iter-N+1 fixer (see `${CLAUDE_PLUGIN_ROOT}/lib/loop.md`).

**If all clean**, proceed to invoke the reviewer (below) for the semantic review.

## Code reviewer prompt (skeleton)

The orchestrator MUST invoke the code reviewer as a sub-agent via the Agent tool. The orchestrator MUST NOT perform the code review inline.

```
You are the code reviewer for ticket <TICKET-ID>.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump>

== metadata.plan ==
<JSON dump>

== Last 2 metadata.changelog entries ==
<JSON dump>

== Implementation diff ==
<output of `git diff <base>..HEAD`>

== Testing strategy ==
<JSON dump of metadata.testing_strategy>

The deterministic checks already passed: tests green (or skipped in `direct`
mode), lint clean, typecheck clean, every file in metadata.plan.files was
touched. Focus on what those checks cannot catch:

1. AC match: does the behavior implement every AC? Trace each AC to test + code.
   In `direct` mode, tests do not exist yet; trace ACs to the diff alone.
2. Correctness: edge cases, error paths, concurrency, off-by-one, null handling.
3. Security: input validation, injection, secrets, auth, authz.
4. Test integrity (`bdd` only): were tests weakened to make them pass?
   In `direct` mode, this check does not apply.
5. Scope (semantic): any out-of-plan files touched (see INFO from Check C)?
   Are they justified, or should they be reverted?

Focus on the diff. Do NOT re-review files that were not touched.

Output findings as JSON code_review_entry per the Loop Pattern. Read budget:
5 source files (iter 1) or 3 source files (iter 2+) beyond the diff.
```

Run loop until convergence (max 3 iterations; see `${CLAUDE_PLUGIN_ROOT}/lib/loop.md`). On every loop iteration the orchestrator persists the writer's `changelog_appendix` to `metadata.changelog` and the reviewer's findings to `metadata.code_review`. Commit on convergence with a message tied to the testing strategy:

```bash
git add -A
# bdd:
git commit --no-verify -m "doer(<TICKET-ID>): implementation (BDD green)"
# direct:
git commit --no-verify -m "doer(<TICKET-ID>): implementation (direct)"
```

After the commit, persist the green-test marker so Stage 6 can skip re-running an unchanged tree (only when the test suite actually ran and passed in this stage; in `direct` mode where Check A may be skipped, leave `last_green_sha` unchanged):
```json
metadata.last_green_sha = <git rev-parse HEAD>   # MUST be the full 40-char SHA. NEVER abbreviated. The skip-safe check in Stage 6 compares this string-equal to `git rev-parse HEAD` of the new HEAD; an abbreviated SHA breaks the comparison.
metadata.last_green_test_command = <the test command that ran>
```

Run the Stage Finalization Checklist (`${CLAUDE_PLUGIN_ROOT}/lib/stage-checklist.md`) before transitioning.

## Direct return (advance after commit)

After Stage 4 commits and updates the green-test marker, decide where to advance based on `metadata.testing_strategy.mode`:

- **`bdd`**: set `metadata.current_stage = 5`, narrate *"Stage 4 complete. Continuing to Stage 5..."*, auto-proceed: Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/05-code-review.md` and ONLY that file.
- **`direct`**: set `metadata.current_stage = 3`, narrate *"Stage 4 complete. Returning to Stage 3 to write regression tests against the implemented change."*, auto-proceed: Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/03-tests.md` and ONLY that file (`direct` second-visit branch).
