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

Run these mechanically before advancing; fix trivial mismatches in place, and re-open plan mode only if a failure invalidates the approach:

- **Files:** every `change: "edit" | "delete"` path exists; every `change: "new"` path does not.
- **Coverage:** every `AC-N` in `metadata.ac.in_scope` appears in at least one `tests[].covers`.
- **Assumptions:** run every non-null `check` from the repo root (one batched script, 10s timeout each); record `pass | fail | skipped` per assumption. A `fail` on a high-risk assumption goes back to the dev before proceeding; low/medium failures are narrated and recorded.

## Step 4. Finalize

Validate required fields per `lib/state.md`. Build ONE jq filter that in a single pass sets `metadata.plan` (Step 2) and `stages.2` complete (with `completed_at`); call `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/metadata.sh" write "<TICKET-ID>" '<filter>'` exactly once (never `Write`/`Edit` `metadata.json` directly). Narrate *"Stage 2 complete: N files, M tests planned. Continuing to Stage 3..."* and auto-proceed: read `03-build.md` and ONLY that file.
