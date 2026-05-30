# Stage Finalization Checklist (applies to every stage)

Before marking ANY `metadata.stages.<N>.status = "complete"` (or `"skipped"` / `"imported"` / `"blocked"` / `"deferred"`), the orchestrator MUST run a deterministic checklist that validates the per-stage required fields are present in metadata. This is a no-LLM check (just JSON field presence). It catches the common post-compaction failure mode where the orchestrator forgets which fields the schema requires.

**`deferred` status (Stage 3, `direct` mode only).** When Stage 3 sets `status = "deferred"` on first entry (because `metadata.testing_strategy.mode == "direct"`), the only required fields are `name`, `status`, `testing_strategy_mode`. `verified_with` is NOT required for `deferred` (the stage has not actually run yet); it is set when the stage transitions to `complete` after the second visit.

**If any required field is missing, the orchestrator MUST write it before transitioning.** If it cannot be derived (e.g. `started_at` was never recorded), use the best available proxy (e.g. `git log` of the stage's commit timestamp, or current time, or `null` with an explanatory note). Narrate which fields were back-filled and why.

## Required fields per stage

| Stage | Always required | Required when status is `complete` | Required when status is `skipped` |
|---|---|---|---|
| 1 ac-confirm | `name`, `status`, `verified_with` | `completed_at` | `skipped_reason` |
| 2 plan | `name`, `status`, `verified_with` | `completed_at`, `retry_used`, `agent_invocations` (integer >= 1) | `skipped_reason` |
| 3 tests | `name`, `status`, `verified_with`, `testing_strategy_mode` | `completed_at`, `retry_used`, `agent_invocations` (integer >= 1) | `skipped_reason` |
| 4 code | `name`, `status`, `verified_with` | `started_at`, `completed_at`, `iterations`, `loop_outcome`, `blockers_resolved_total`, `agent_invocations` (integer >= 1). When `preferences.sh get-flag stage4_per_task_gate` returns `true`: also `pre_stage4_sha` (40-char) and `per_task_gate.decisions` (one entry per processed step). When `preferences.sh get-flag stage4_parallel_subagents` returns `true` (and `stage4_per_task_gate` is `false`): also `pre_stage4_sha` (40-char) and `parallel_subagents.groups` (non-empty; one entry per dispatched group with `id`, `step_orders`, `dispatched`, `started_at`, `completed_at`). When `status = "blocked"` via reject (per-task gate) or via parallel error: `blocked_reason` is required instead of `iterations`/`loop_outcome`/`blockers_resolved_total` | n/a (Stage 4 is never skipped) |
| 5 code-review | `name`, `status`, `verified_with` | `started_at`, `completed_at`, `iterations`, `loop_outcome`, `blockers_resolved_total`, `agent_invocations` (integer >= 1). When `preferences.sh get-flag stage5_advisor_personas` returns a non-empty list AND iter 1 actually dispatched personas: also `metadata.code_review[iteration=1].advisor_personas_ran` (non-empty list of persona ids that ran) | n/a |
| 6 quality-gate | `name`, `status`, `verified_with` | `started_at`, `completed_at`, AND either (`test_summary` if tests ran) OR (`skipped_reason = "no diff since last green"` if skip-safe path) | `skipped_reason` |
| 7 runtime-verify | `name`, `status`, `verified_with` | `started_at`, `completed_at`, `ac_verdicts`, `agent_invocations` (integer >= 1) | `skipped_reason`, `skipped_acknowledged_by = "dev"` |
| 8 docs-sync | `name`, `status`, `verified_with` | `started_at`, `completed_at`, `agent_invocations` (integer >= 1) | `skipped_reason` |
| 9 wrapup | `name`, `status`, `verified_with` | `completed_at`, `commit_message_presented`, `pr_description_presented` | n/a |

**`agent_invocations` schema note.** `metadata.stages.<N>.agent_invocations` is an integer count of Agent tool calls dispatched for that stage. The orchestrator increments it after each successful Agent return. For stages `skipped`, `imported`, or `deferred`, the field is not required. For stages 1, 6, 9, the field is optional (those stages are state/coordination work with no LLM-heavy delegation).

### Agent-invocation gate

Before transitioning a delegating stage (2, 3, 4, 5, 7, 8) to `complete`, the orchestrator MUST verify `metadata.stages.<N>.agent_invocations >= 1`. If 0 or absent: this is a hard stop. The orchestrator MUST NOT mark the stage `complete`. Narrate: *"Stage <N> finalization blocked: no Agent invocations recorded. The orchestrator must delegate LLM-heavy work; inline execution is not allowed."* Then either resume the stage with a proper Agent dispatch, or mark `blocked` with `blocked_reason: "no_agent_invocations"`.

The `agent_invocations` counter is incremented by the orchestrator after each successful Agent return for the stage (see `${CLAUDE_PLUGIN_ROOT}/lib/narration.md`).

### Cost attribution (no per-stage gate)

Per-stage cost is NOT recorded during the stage. The Claude Code Agent tool does not expose token counts in its `tool_result`, so there is nothing to record at finalization time. Cost is recovered in full at Stage 9 by `cost-transcript.sh reconcile`, which reads the session transcript and builds `cost.by_model` / `cost.by_agent` / `cost.by_stage` from each sub-agent's own JSONL plus its sibling `meta.json`.

The only per-stage obligation is the `description` convention: when dispatching any Agent, the orchestrator sets its `description` to `doer:s<N>:<role> | <free text>` so the reconciler can attribute the call to a stage and role. There is no finalization-time check for this; an Agent dispatched without the prefix still counts toward totals but lands under `unassigned` in the breakdown. See `${CLAUDE_PLUGIN_ROOT}/lib/cost.md`.

## Top-level required fields when transitioning ticket to `status: "complete"`

When Stage 9 marks the ticket complete, the checklist also verifies:
- `metadata.completed_at` is set (ISO8601)
- `metadata.summary` is a non-empty string
- `metadata.performance` is a populated object (has at least `started`, `completed`, `wall_clock`)
- `metadata.last_green_sha` is a 40-character SHA (full length, never abbreviated)
- `metadata.last_green_test_command` is non-null

## Validation procedure

For each required field listed above:
1. Read `metadata.stages.<N>.<field>` (or top-level `metadata.<field>`).
2. If absent or null when it should not be, narrate: *"Finalization check: `metadata.stages.<N>.<field>` missing. Back-filling from <source>."* Then write it.
3. If a value is present but obviously wrong (e.g. `last_green_sha` is fewer than 40 characters, `iterations` is negative, `loop_outcome` is not in the enum), narrate the issue and correct it.
4. Re-read after writing to confirm the value persisted.

Only after all required fields validate clean, write the final `status` and continue.
