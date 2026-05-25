# Stage 2. Plan (Single-Pass + Deterministic Checks)

**Goal:** produce a structured implementation plan persisted into `metadata.plan`.

**Stage 2 does NOT use `${CLAUDE_PLUGIN_ROOT}/lib/loop.md`.** It is single-pass with a single optional retry on deterministic-check failure. Do NOT apply loop semantics by analogy.

**No loop. No reviewer LLM.** The orchestrator MUST invoke a single planner sub-agent via the Agent tool to produce the plan; the orchestrator MUST NOT write the plan inline. Deterministic checks validate structure and coverage. If checks fail, the planner sub-agent MUST be invoked **once more** (single retry) via the Agent tool with the BLOCKERs inline. Second failure aborts the stage and hands control to the dev.

**Why no loop:** the plan reviewer judged an LLM artifact before any evidence existed (no tests, no code). Most of its useful output (file existence, AC coverage, assumption presence) is mechanical and is now caught by deterministic checks. Semantic plan critique is moved downstream where the reviewer has real evidence to look at (Stage 4 / 5).

**Doer agent:** general-purpose, prompted as "implementation planner". MUST be invoked via the Agent tool.

## Planner prompt (skeleton)

```
You are the implementation planner for ticket <TICKET-ID>.

The orchestrator has already loaded these and inlined them below:

== metadata.ac ==
<JSON dump of metadata.ac: in_scope, out_of_scope, open_questions_resolved, applicable_lessons>

== metadata.intake ==
<JSON dump of metadata.intake: description, raw_acs, context, prior_work>

== Applicable lessons (read these files in full before planning) ==
<for each slug in metadata.ac.applicable_lessons, the resolved file path
under ${CLAUDE_PLUGIN_ROOT}/lessons/{slug}.md>

Explore the codebase to understand the structure relevant to this ticket.
Read budget: up to 10 source files. Free to grep within the budget.

Produce the plan as a JSON object matching this exact shape:

{
  "files": [
    {"path": "<repo-relative path>", "change": "edit | new | delete", "reason": "<one-line>"}
  ],
  "steps": [
    {"order": 1, "verb": "<add | modify | delete | rename | refactor>", "what": "<thing>", "where": "<file>:<line-range or 'new'>", "parallel_group": "<optional string id; omit or set null when the step must run alone>"}
  ],
  "tests": [
    {"name": "<test function or describe block name>", "covers": ["AC-1", "AC-3"], "what": "<one-line of what the test asserts>"}
  ],
  "risks": [
    {"risk": "<one-line>", "mitigation": "<one-line>"}
  ],
  "assumptions": [
    {
      "id": "A-1",
      "statement": "<one-line; what is being assumed about the codebase, environment, or contract>",
      "check": "<bash one-liner; exit 0 = assumption holds, non-zero = fails. May be null when the assumption is not mechanically verifiable, in which case Check D treats the entry as statement-only.>",
      "expected": "<one-line; what a passing check looks like (e.g. 'file present', 'function defined', 'flag enabled')>",
      "risk": "low | medium | high"
    }
  ]
}

Pre-flight assumptions guidance (read carefully):
- Every assumption MUST have `id` (`A-N`, contiguous), `statement`, `expected`, `risk`. `check` is optional but strongly preferred.
- Prefer mechanically verifiable checks: `test -f path/to/file`, `grep -q pattern path`, `command -v tool`, `jq -e '.field' file > /dev/null`. The orchestrator executes each `check` from the repo root before dispatching the plan to Stage 3 / Stage 4.
- If an assumption cannot be expressed as a bash one-liner (depends on runtime behavior or human judgment), set `check: null` and write a precise `statement` so it is captured but not enforced.
- `risk: "high"` flags assumptions that, if wrong, would invalidate the whole plan. Stage 2 posts an inbox advisory to Stage 4 for every high-risk assumption that validated, so the code writer keeps it in mind.
- Do NOT use the legacy string shape (`"<one-line>"`); always emit objects matching the schema above.

Parallel-group guidance (read carefully):
- `parallel_group` is OPTIONAL on each step. Set it to a short string id (e.g. `"g1"`, `"backend-files"`) when two or more steps are independent and could run concurrently. Steps sharing the same `parallel_group` are independent of each other; steps with no `parallel_group` (or `null`) MUST run alone in their `order` slot.
- Two steps are independent only when: (a) they touch DISJOINT files, AND (b) neither reads outputs the other writes, AND (c) their commits would compose cleanly in any order.
- Prefer FEWER, larger groups over many small groups. A group of 1 is wasted bookkeeping; if you cannot find a safe peer, omit `parallel_group` entirely.
- Do NOT mix steps that touch the same file in one group. The orchestrator detects file overlap pre-dispatch and serializes such groups, but planner intent should be correct upfront.
- Assume `parallel_group` is ignored when the dev does not opt in (`stage4_parallel_subagents: false`). Always plan as if the steps may run sequentially in `order`.

Also produce a changelog appendix:

{
  "stage": 2, "iteration": 1, "kind": "initial",
  "items": [
    {"type": "decision", "text": "<one-line decision + brief why>"},
    ...
  ]
}

Output BOTH as a single JSON object: {"plan": {...}, "changelog_appendix": {...}}.

Constraints:
- Every entry in metadata.ac.in_scope MUST be referenced by at least one test in `tests[].covers`.
- Every file path in `files[]` MUST be relative to the repo root (no leading `./` or absolute paths).
- Use `change: "new"` only if the file does NOT currently exist; `change: "edit"` only if it does.
- Be terse, no prose, one-line items.
- Read budget: 10 source files. Stay within it. If a BLOCKER from the deterministic checks needs more, add it on retry.

Do NOT write code. Do NOT run tests. Plan only.
```

## Deterministic checks (post-planner)

Run all five. They are mechanical, free of LLM cost, and cover what the prior reviewer judged.

### Check A. File existence matches `change`

For each `metadata.plan.files[i]`:
- `change: "edit" | "delete"` → the file MUST exist at that path.
- `change: "new"` → the file MUST NOT exist at that path.
Mismatches → BLOCKER:
```
- B-1 (file exists/missing): src/foo.kt is `change: edit` but does not exist
- B-2 (file already exists): src/bar.ts is `change: new` but already exists
```

### Check B. AC coverage by tests

For each entry in `metadata.ac.in_scope`, extract the `AC-N` ID prefix and verify at least one entry in `metadata.plan.tests` lists it under `covers[]`. Missing → BLOCKER:
```
- B-3 (coverage): AC-3 has no test in plan.tests
```

### Check C. Assumptions field shape

`metadata.plan.assumptions` MUST exist as an array (may be empty `[]`). Each entry MUST be an object with `id`, `statement`, `expected`, `risk` (and optionally `check`). Legacy strings or missing fields → BLOCKER:
```
- B-4 (assumptions): plan.assumptions field absent or not an array
- B-5 (assumptions shape): A-2 missing required field `risk`
- B-6 (assumptions shape): A-3 uses legacy string form (must be object with id/statement/expected/risk)
```

### Check D. Pre-flight assumption execution

For each `metadata.plan.assumptions[i]` whose `check` is non-null, run the command from the repo root via `bash -c "<check>"` (timeout 10s per check). Record results into `metadata.plan.assumptions[i].validation`:

```json
{
  "validation": {
    "ran_at": "<ISO8601>",
    "exit_code": <int>,
    "status": "pass | fail | skipped",
    "stdout_excerpt": "<first 200 chars, single line>",
    "stderr_excerpt": "<first 200 chars, single line>"
  }
}
```

Status mapping:
- `exit_code == 0` → `status: "pass"`.
- `exit_code != 0` → `status: "fail"`.
- `check == null` → `status: "skipped"` (statement-only; recorded but never blocks).

Any `status: "fail"` is a BLOCKER:
```
- B-7 (assumption fail): A-2 ('lib/helpers/lock.sh exists') exit 1; expected: 'file present'
```

After Check D completes (pass or after retry-fix), for every assumption with `status: "pass"` AND `risk: "high"`, post one inbox advisory to Stage 4:
```bash
${CLAUDE_PLUGIN_ROOT}/lib/helpers/inbox.sh post "<TICKET-ID>" \
  --from 2 --to 4 --kind advisory \
  --text "High-risk assumption validated at plan time: <A-N statement>" \
  --details "Verified by: <check>. Expected: <expected>. Re-confirm during implementation."
```
Stage 4 narrates and auto-acks per the inbox protocol. See `${CLAUDE_PLUGIN_ROOT}/lib/inbox.md`. Skipped (statement-only) high-risk assumptions are NOT posted (no validation evidence to anchor the advisory); they remain in `metadata.plan.assumptions` for the dev to keep an eye on.

### Check E. Parallel-group shape (only when present)

For each `metadata.plan.steps[i]`, if the entry has a `parallel_group` field, it MUST be either `null` or a non-empty string. Empty strings, integers, arrays, or objects are invalid. The field is optional; absent or `null` is fine and means the step runs alone in its `order` slot.
```
- B-8 (parallel_group shape): step 3 has parallel_group of type number; must be a non-empty string or null
- B-9 (parallel_group shape): step 5 has parallel_group as empty string; use null or omit the field
```
This check costs zero LLM tokens and is independent of whether `preferences.sh get-flag stage4_parallel_subagents` returns `true`. Validating shape at plan time keeps Stage 4 simple.

## Single retry policy

If Checks A/B/C/D/E produce any BLOCKERs:
1. Re-invoke the planner ONCE with the BLOCKERs inline:
   ```
   Your prior plan failed deterministic validation:
   <list BLOCKERs>

   Produce a corrected plan as the same JSON shape. Address every BLOCKER. Do not introduce unrelated changes.
   ```
2. Re-run the four checks on the new plan.
3. Set `metadata.stages.2.retry_used = true`.
4. If still failing → ABORT the stage. Narrate to the dev:
   ```
   Stage 2 failed validation twice. Remaining BLOCKERs: <list>.
   The plan is in metadata.plan; review and correct, then run /doer continue.
   ```
   Set `metadata.stages.2.status = "blocked"`. Do not proceed to Stage 3.

   **Resuming from `blocked`:** when the dev re-runs `/doer <ID>` after fixing `metadata.plan` by hand, the orchestrator detects `metadata.stages.2.status == "blocked"` and re-runs ONLY the five deterministic checks (file existence, AC coverage, assumptions shape, assumptions execution, parallel-group shape) on the corrected plan. No new planner agent invocation. If checks pass → mark stage complete, proceed to Stage 3. If checks still fail → re-narrate the BLOCKERs and stay `blocked`.

If checks pass (first try or after retry):
1. Persist the planner's `plan` object into `metadata.plan` (overwriting any prior value).
2. Append the planner's `changelog_appendix` into `metadata.changelog`.
3. Add each new assumption to `metadata.plan.assumptions` (the planner already did this; nothing extra needed).
4. Run the Stage Finalization Checklist (`${CLAUDE_PLUGIN_ROOT}/lib/stage-checklist.md`).
5. Set `metadata.stages.2.status = "complete"`, `metadata.stages.2.verified_with = <SKILL version>`, `metadata.stages.2.completed_at = <ISO8601>`, `metadata.stages.2.retry_used = <true|false>`.
6. Narrate `"Stage 2 complete: N files, M tests planned. Continuing to Stage 3."` Auto-proceed: Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/03-tests.md` and ONLY that file.

**No commit.** `metadata.json` lives in `.doer/` which is gitignored.
