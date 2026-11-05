# Stage 2. Plan (Native Plan Mode)

**Goal:** a structured implementation plan persisted into `metadata.plan`, designed in Claude Code's native plan mode so the dev approves it before any code exists. No sub-agent, no loop. No commit (only `.doer/` writes).

## Step 1. Enter plan mode

Call `EnterPlanMode`. Inside it, use only read-only tools (`Read`/`Grep`/`Glob`), never `Bash`: plan mode does not inherit the session's own permission mode, so a `Bash` call in here prompts for approval on every invocation and turns the stage into a click-through instead of a one-shot.

1. Re-read `metadata.ac` and `metadata.intake`; read the lesson files listed in `ac.applicable_lessons` in full.
2. Explore the codebase relevant to the ticket (read budget: ~10 source files; grep freely via the `Grep` tool).
3. When the ticket integrates an SDK or library whose mechanism the ticket does not document, explore its sources (e.g. `~/.gradle/caches/`, `node_modules/`) to find the API that controls the behavior BEFORE planning, and capture the finding as an assumption.
4. When the ticket contains a wire-format contract (JSON schema, WebSocket payload), derive field names from the contract, never from AC prose.
5. Write the plan to the plan file, covering: files to change, ordered steps, tests per AC, risks, and assumptions.

Call `ExitPlanMode`. The dev's approval of the plan file is the stage's quality gate; there is no separate reviewer.

## Step 2. Structure the plan

After approval, translate the approved plan into the `metadata.plan` shape (held for Step 4's single write, not persisted yet):

```json
"plan": {
  "files": [{"path": "<repo-relative>", "change": "edit | new | delete", "reason": "<one-line>"}],
  "steps": [{"order": 1, "verb": "add | modify | delete | rename | refactor", "what": "<thing>", "where": "<file>"}],
  "tests": [{"name": "<test name>", "covers": ["AC-1"], "what": "<one-line>"}],
  "risks": [{"risk": "<one-line>", "mitigation": "<one-line>"}],
  "assumptions": [{"id": "A-1", "statement": "<one-line>", "check": "<bash one-liner or null>", "risk": "low | medium | high"}]
}
```

## Step 3. Deterministic checks

```bash
printf '%s' '<plan-object-from-Step-2>' | "${CLAUDE_PLUGIN_ROOT}/lib/helpers/stage-checks.sh" plan "<TICKET-ID>"
```

Files (every `change: "edit" | "delete"` path exists, every `change: "new"` path does not), coverage (every `AC-N` in `metadata.ac.in_scope` appears in at least one `tests[].covers`), and assumptions (every non-null `check` run from the repo root, 10s timeout each, recorded `pass | fail | skipped`) all in one call, against the plan object exactly as it will be persisted in Step 4. Exit 0: advance. Exit 1: fix trivial file/coverage mismatches in place and re-run; a `fail` on a high-risk assumption goes back to the dev before proceeding, re-open plan mode only if it invalidates the approach; low/medium failures are narrated and recorded as-is.

## Step 4. Finalize

Build ONE jq filter that in a single pass sets `metadata.plan` (Step 2) and `stages.2` complete (with `completed_at`); call `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/metadata.sh" write "<TICKET-ID>" '<filter>' --require 2:complete` exactly once (never `Write`/`Edit` `metadata.json` directly). `--require` validates the required fields per `lib/state.md` against the transformed document before swapping; on failure, back-fill and write again as a NEW transition. Narrate *"Stage 2 complete: N files, M tests planned. Continuing to Stage 3..."* and auto-proceed: read `03-build.md` and ONLY that file.

## Mechanical steps through scripts

Not part of the plan-mode steps. A mechanical step becomes a script only if, measuring the characters of one invocation's tool result as it reaches the orchestrator, EITHER (a) ONE invocation produces raw output above 8,000 characters (about 2,000 tokens), OR (b) it chains 3 or more tool calls with filtering or a loop between them that one script call replaces. It also needs the orchestrator itself to be able to run Bash at that point (plan mode forbids it) and an output cap below the raw output it replaces; otherwise it stays a plain tool call. Figures below were measured earlier on this plugin's own tickets.

| Step | Raw output | (a) | (b) | Decision |
|---|---|---|---|---|
| Orchestrator runs the repo suite directly (Stage 1 prior work, Stage 3 exit gate, bugfix full relevant suite) | about 70 KB per run | yes | n/a | convert with `bounded.sh run` |
| Bugfix check that bug tests fail and regression tests pass | a handful of named tests | no | n/a | keep: `failed` is the expected outcome and each test is confirmed by name |
| Suite run by the code-writer | inside its Agent | n/a | n/a | not the orchestrator's context |
| The pre-review check | blockers JSON | no | n/a | already a script |
| Code searches in this stage | median far below 8,000 | rare | no | keep: Bash is forbidden here |
| Reading logs or large files | largest about 13,000 | borderline | no | keep: Read with offset and limit |

The command is `bounded.sh run --timeout 540 -- sh -c '<command>'`. Shape: a `status:` of `ok`, `failed`, `timeout` or `error`, the exit code, counts, a `fails:` line, the last `Results:` lines, every FAIL line with up to 5 non-PASS/FAIL lines after it, and a raw tail of the last log lines. OUTPUT BUDGET: at most 55 lines plus a FAIL section of at most 16,000 characters, total at most 27,000 characters; when the FAIL section does not fit, the `fails:` line says so and the full redacted list is in `.doer/bounded-fails.txt`, which you Read with offset and limit.

What is not guaranteed: the helper reads and writes only inside the worktree, but the configured test command is the project's own and cannot be sandboxed. Output is redacted for values and `KEY=value` texts of `.env*` files anywhere in the worktree (except under `.git`) and for environment values of secret-named variables (6 or more characters); secrets under other names or in other files, and a bare 1 or 2 character value, are not guaranteed. Redaction wins over completeness: a non-secret value that collides with test text shows as `[REDACTED]`. A failure in a shape the helper does not recognize shows as `fails: unparsed` with the tail and exit code, never green.
