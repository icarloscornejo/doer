# Stage 3. Tests (Direct | BDD)

**Goal:** write tests appropriate to the ticket's `testing_strategy`. Mode is determined at intake and stored in `metadata.testing_strategy.mode`.

**Stage 3 does NOT use `${CLAUDE_PLUGIN_ROOT}/lib/loop.md`.** It is single-pass with a single optional retry on deterministic-check failure. Do NOT apply loop semantics by analogy.

**No loop. No reviewer LLM.** The orchestrator MUST invoke a single test-writer sub-agent via the Agent tool to produce the tests (when applicable for the branch); the orchestrator MUST NOT write the tests inline. Deterministic checks validate. If checks fail, the test-writer sub-agent MUST be invoked **once more** (single retry) via the Agent tool with the BLOCKERs inline. Second failure aborts the stage.

**Why no loop:** "are all ACs covered?" and "do the tests actually fail (or pass, in `direct` mode)?" are mechanical questions. The semantic critique (brittle assertions, over-mocking) is moved into the Stage 4 reviewer where the diff makes it obvious.

## Mode check (entry)

On every entry to Stage 3, the orchestrator MUST:

1. Read `metadata.testing_strategy.mode`.
2. Set `metadata.stages.3.testing_strategy_mode = <mode>` (always, even on re-entry; idempotent write).
3. Branch to one of the two sections below.

The two branches use different writer prompts, different deterministic checks, different commit messages, and (in the `direct` case) a different position in the pipeline (Stage 3 runs AFTER Stage 4 instead of before).

## Branch: `direct` (deferred path)

The `direct` branch DEFERS Stage 3 at first entry, lets Stage 4 commit the change, then comes back to Stage 3 to write regression tests against the implemented code. There is no red phase.

### First entry to Stage 3 (status = `pending`)

1. Set `metadata.stages.3.status = "deferred"`.
2. Set `metadata.stages.3.testing_strategy_mode = "direct"`.
3. Set `metadata.current_stage = 4`.
4. Narrate: *"Stage 3 deferred (direct mode). Writing the change first, regression tests after Stage 4. Continuing to Stage 4."*
5. Auto-proceed: Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/04-code.md` and ONLY that file. Do NOT invoke any Stage 3 agent on this entry.

### Second entry to Stage 3 (status = `deferred`, returning from Stage 4)

The orchestrator advances to this entry from Stage 4 (see Stage 4's "Direct return" subsection). On entry, set `metadata.stages.3.status = "in_progress"` and MUST invoke a regression test writer sub-agent via the Agent tool. The orchestrator MUST NOT write the regression tests inline:

```
You are the regression test writer for ticket <TICKET-ID>. The change is
already implemented (Stage 4 is done). Your job is to add MINIMAL regression
tests that verify the FINAL state. Do NOT write tests before the change exists;
the change exists. These tests are about future-proofing.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump of metadata.ac>

== metadata.plan ==
<JSON dump of metadata.plan>

== Last 2 metadata.changelog entries ==
<JSON dump of metadata.changelog[-2:]>

== Diff so far ==
<output of `git diff <base>..HEAD`>

Read 2-3 existing test files in the repo to learn local conventions (framework,
file layout, naming). Read budget: 5 source files for convention discovery, plus
any source file in the diff that you need to understand the surface you are testing.

Write tests that:
- Verify the changed value/label/string/constant is present where the ticket
  said it should be.
- Cover at most one or two paths per acceptance criterion. Minimal coverage is the goal.
- Are EXPECTED to PASS now (no red phase).

DO NOT add explanatory comments like `// REGRESSION:` or `// regression test`.
The test name and assertion are self-documenting.

NEVER include AC-N identifiers (e.g. AC-1, AC-3) anywhere in test files -- not
in inline comments, not in KDoc, not in test names. These are internal doer
orchestration labels with no meaning to future codebase readers; the `covers`
field in your JSON output is the only place an AC-N belongs. Any
Given/When/Then or behavioral comment you write MUST be complete, plain
business language, never shorthand and never referencing an AC number.

Output a single JSON object:

{
  "tests_added": [
    {"name": "<test name>", "file": "<repo-relative path>", "covers": ["AC-N"]}
  ],
  "changelog_appendix": {
    "stage": 3, "iteration": 1, "kind": "initial",
    "items": [
      {"type": "step", "text": "Added <test name> in <file> covering <AC-N>"},
      ...
    ]
  }
}

Em-dashes are forbidden. Use commas, periods, or parentheses instead.
All artifacts you write (tests, code comments, JSON values) MUST be in English.
```

### Deterministic checks (`direct` branch, post-writer)

- **Check A. Tests parse and run.** Same as the `bdd` branch: invoke the repo's test command. Compile/import/syntax errors are BLOCKERs.
- **Check B. Regression coverage per AC.** For each entry in `metadata.ac.in_scope`, verify at least one entry in the writer's `tests_added[]` lists the entry's `AC-N` ID under `covers[]`. Missing → BLOCKER.
- **Skip Check C entirely.** Tests in `direct` mode are EXPECTED to PASS, not fail. If any regression test FAILS, that is a real BLOCKER (regression caught), classify it as `B-X (regression failed): <test name> failed unexpectedly. Stage 4 may have an issue.` and abort with `status = "blocked"` so the dev can decide.

### On checks pass

1. Append the writer's `changelog_appendix` into `metadata.changelog`.
2. Run the Stage Finalization Checklist (`${CLAUDE_PLUGIN_ROOT}/lib/stage-checklist.md`).
3. Set `metadata.stages.3.status = "complete"`, write `verified_with`, `completed_at`, `retry_used`, `testing_strategy_mode = "direct"`.
4. Commit:
   ```bash
   git add -A
   git commit --no-verify -m "doer(<TICKET-ID>): regression tests (direct)"
   ```
5. Update `last_green_sha` to the new HEAD so Stage 6 can skip re-running the test suite:
   ```bash
   git rev-parse HEAD
   ```
   Write `metadata.last_green_sha = <new HEAD sha>`. This is mandatory in `direct` mode: Stage 4 set `last_green_sha` before this commit existed, so without this update Stage 6 always sees a stale SHA and re-runs the full test suite unnecessarily.
6. Set `metadata.current_stage = 5` (Stage 4 already complete; jump straight to Stage 5).
7. Narrate `"Stage 3 complete (direct): N regression tests added, all passing. Continuing to Stage 5."` Auto-proceed: Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/05-code-review.md` and ONLY that file.

## Branch: `bdd`

Given/When/Then scenarios derived from each AC, expressed as failing executable tests. Stage 4 implements code derived from the scenarios.

The orchestrator MUST invoke a single BDD scenario + test writer sub-agent via the Agent tool. The orchestrator MUST NOT write the BDD tests inline.

### BDD scenario + test writer prompt (skeleton)

```
You are the BDD scenario + test writer for ticket <TICKET-ID>.

For each AC in metadata.ac.in_scope, derive one or more Given/When/Then
scenarios. Write each scenario as an executable test using the repo's test
framework (JUnit, Espresso, XCTest, Jest, etc.) following existing conventions.
If the repo uses a BDD-style DSL (Cucumber, Kotest BDD, etc.), use it.
Otherwise, express Given/When/Then as comments + structured test body.

Tests MUST currently FAIL because no implementation exists yet (red phase
derived from scenarios, not technical units).

Each test function name MUST reference the scenario, e.g.
given_user_has_cart_when_bap_loads_then_promos_shown.

DO NOT add explanatory comments like `// RED:` or `// BDD red:` or
`// fails because X` on test bodies. The test name and the failing assertion
are self-documenting.

NEVER include AC-N identifiers (e.g. AC-1, AC-3) anywhere in test files -- not
in inline comments, not in KDoc, not in test names. These are internal doer
orchestration labels with no meaning to future codebase readers; the `covers`
field in your JSON output is the only place an AC-N belongs. When you express
Given/When/Then as comments (non-DSL path), write each line as complete,
plain business language describing user or system behavior (e.g.
`// Given the user has items in their cart`), not shorthand, not half-sentences,
and never referencing an AC number.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump of metadata.ac>

== metadata.plan ==
<JSON dump of metadata.plan>

== Last 2 metadata.changelog entries ==
<JSON dump of metadata.changelog[-2:]>

Read 2-3 existing test files for conventions. Read budget: 5 source files for
convention discovery, plus any source file referenced in metadata.plan.files.

Output a single JSON object:

{
  "tests_added": [
    {"name": "<scenario test function name>", "file": "<repo-relative path>", "covers": ["AC-N"]}
  ],
  "changelog_appendix": {
    "stage": 3, "iteration": 1, "kind": "initial",
    "items": [
      {"type": "step", "text": "Added scenario <name> in <file> covering <AC-N>"},
      ...
    ]
  }
}

Em-dashes are forbidden. Use commas, periods, or parentheses instead.
All artifacts you write (tests, code comments, JSON values) MUST be in English.
```

### Deterministic checks (`bdd` branch)

- **Check A. Tests parse and run.** Compile/import/syntax errors are BLOCKERs.
- **Check B. Scenario per AC.** Every entry in `metadata.ac.in_scope` MUST have at least one scenario test (cross-reference `tests_added[i].covers[]` to AC IDs).
- **Check C. Scenario tests currently FAIL.** Red-phase requirement: a passing scenario test is a BLOCKER.

### On checks pass

1. Append the writer's `changelog_appendix` into `metadata.changelog`.
2. Run the Stage Finalization Checklist (`${CLAUDE_PLUGIN_ROOT}/lib/stage-checklist.md`).
3. Set `metadata.stages.3.status = "complete"`, `verified_with`, `completed_at`, `retry_used`, `testing_strategy_mode = "bdd"`.
4. Commit:
   ```bash
   git add -A
   git commit --no-verify -m "doer(<TICKET-ID>): BDD scenarios + failing tests"
   ```
5. Narrate `"Stage 3 complete (BDD): N scenario tests added, all failing as expected. Continuing to Stage 4."` Auto-proceed: Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/04-code.md` and ONLY that file.

## Cost attribution (Agent `description` convention)

Cost is recovered from the session transcript at Stage 9 (`cost-transcript.sh reconcile`), not from the Agent return. To make the per-stage / per-agent breakdown attributable, set the `description` of EACH test-writer Agent (`bdd` or `direct` branch, initial dispatch and the optional retry) to the canonical prefix when dispatching it:

```
doer:s3:test-writer | <free text describing the call>
```

Increment `metadata.stages.3.agent_invocations` after each test-writer return. The reconciler parses `doer:s<N>:<role>` from each sub-agent's `meta.json` to build `cost.by_stage` / `cost.by_agent`; without the prefix the call lands under `unassigned`. See `${CLAUDE_PLUGIN_ROOT}/lib/cost.md`.

## Single retry policy (all branches)

If the deterministic checks for the active branch produce any BLOCKERs:

1. Re-invoke the active branch's writer ONCE with the BLOCKERs inline. Same prompt body, prepended with:
   ```
   Your prior tests failed validation:
   <list BLOCKERs>

   Address every BLOCKER. Output the same JSON shape.
   ```
2. Re-run the deterministic checks for the active branch (A/B for `direct`, A/B/C for `bdd`).
3. Set `metadata.stages.3.retry_used = true`.
4. If still failing → ABORT. Narrate:
   ```
   Stage 3 failed validation twice. Remaining BLOCKERs: <list>.
   Inspect the tests, then run /doer continue.
   ```
   Set `metadata.stages.3.status = "blocked"`. Do not proceed.

   **Resuming from `blocked`:** when the dev re-runs `/doer <ID>` after fixing the tests by hand, the orchestrator detects `metadata.stages.3.status == "blocked"` and re-runs ONLY the deterministic checks for the recorded `metadata.stages.3.testing_strategy_mode`. No new test-writer agent invocation. If checks pass → mark stage complete, advance to the appropriate next stage (Stage 4 for `bdd`, Stage 5 for `direct`). If checks still fail → re-narrate and stay `blocked`.
