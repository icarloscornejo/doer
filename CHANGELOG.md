# Changelog

All releases follow SemVer. For migration details, see `lib/migrations.md`.

## 6.0.0 (plugin migration + WK-1 lock protocol + WK-2 inbox + WK-3 cost + WK-4 pre-flight assumptions + WK-5 per-task gate + WK-6 parallel subagents)

**Type:** MAJOR (structural; no runtime change to the 9-stage pipeline).

### Plugin restructure

- Repo reorganized as a formal Claude Code plugin (`wk`).
- `doer` skill moved to `skills/doer/SKILL.md`. Invocation is now `/wk:doer ABC-123` (compat: `/doer ABC-123` still works).
- Official manifest added at `.claude-plugin/plugin.json` and catalog at `.claude-plugin/marketplace.json`.
- Shared protocols extracted from `SKILL.md` into `lib/`:
  - `lib/heartbeat.md` (anti-compaction)
  - `lib/migrations.md` (versioning + auto-migrate)
  - `lib/narration.md` (Core Principle 1, em-dash rule, locale)
  - `lib/workspace-guard.md`
  - `lib/memory-paths.md` (paths + `metadata.json` schema)
- Placeholders added for 4 planned satellite skills: `load`, `advise`, `review`, `publish`. Their implementations land in `WK-7` through `WK-10`.
- Stubs added for 2 future libs: `inbox.md`, `cost.md`. Implementations in `WK-2` and `WK-3`.
- `AGENTS.md` added for the marketplace install ritual.
- `ROADMAP.md` added with frozen design decisions + pending tickets.
- `README.md` updated for plugin format.

### WK-1: per-ticket lock protocol

- `lib/lock.md` operational: spec for the per-ticket lock (file at `.doer/tickets/<ID>/lock.json`, 30 min TTL, steal-if-stale, abort-if-fresh).
- `lib/helpers/lock.sh` executable: subcommands `acquire`, `touch`, `release`, `check`. No dependencies beyond bash + optionally `jq`.
- Workspace Guard: new step 7 invokes `lock.sh acquire`. If it returns non-zero, the orchestrator stops the run.
- Stage 9 wrapup: new step 10 invokes `lock.sh release`.
- Narration Protocol: every stage transition invokes `lock.sh touch` to refresh the heartbeat.
- Concurrent sessions on the same ticket fail fast with a clear message (PID + host + last touched). The user resolves manually.
- TTL override via env var `WK_LOCK_TTL_SECONDS=<seconds>`.

### WK-2: inter-stage inbox protocol

- `lib/inbox.md` operational: spec for the per-ticket inbox (`metadata.inbox` array). Three message kinds: `blocker`, `advisory`, `fyi`. Messages address a specific stage or broadcast to `*`.
- `lib/helpers/inbox.sh` executable: subcommands `post`, `list`, `ack`, `clear`. Requires `jq`. Idempotent post via `--id`.
- Narration Protocol: every stage entry drains its unacked inbox after `started_at`. `blocker` messages call `AskUserQuestion` before continuing; `advisory` and `fyi` are narrated and auto-acked in the same turn. Empty inbox is silent.
- Stage 9 wrapup: new step 11 verifies the inbox has no pending messages (anomaly path), then `clear --acked` keeps `metadata.inbox` from growing across reverify cycles.

### WK-3: per-ticket cost tracking

- `lib/cost.md` operational: spec for `metadata.cost` (totals, by_model, by_stage, unknown_models). Currency USD; rates measured per million tokens.
- `lib/cost-rates.json` seeded with current Claude rates (Opus 4.7, Sonnet 4.6, Haiku 4.5) plus a `lazy_fallback` for unknown model ids. Source: `https://claude.com/pricing#api`. TTL 7 days.
- `lib/helpers/cost.sh` executable: subcommands `record`, `total`, `status`. Lazy fallback warns to stderr and never blocks.
- `scripts/refresh-rates.sh` executable: interactive (editor) or non-interactive (`--from-stdin`); validates numeric `input_per_mtok` / `output_per_mtok`, bumps `fetched_at`.
- Narration Protocol: every Agent return that exposes token counts records to `metadata.cost`. Best-effort; missing rates or counts skip silently.
- Stage 9 wrapup: new step 12 narrates `cost.sh status`. Final narration mentions `metadata.cost` alongside `summary` / `performance`.

### WK-4: pre-flight assumptions in Stage 2

- Stage 2 planner prompt extends `metadata.plan.assumptions[]` from a string array to a structured object array. Each entry has `id`, `statement`, `check` (bash one-liner, may be `null`), `expected`, and `risk` (`low | medium | high`).
- Stage 2 deterministic checks now run four checks (was three). Check C reshape: validates each assumption is an object with required fields (BLOCKERs `B-4` missing-array, `B-5` missing-field, `B-6` legacy-string). Check D added: executes each non-null `check` via `bash -c` with a 10s timeout and records `assumptions[i].validation = { ran_at, exit_code, status, stdout_excerpt, stderr_excerpt }`. Non-zero exit is a BLOCKER (`B-7`); `check: null` records `status: "skipped"` and never blocks.
- After Check D, every assumption with `status: "pass"` AND `risk: "high"` posts one inbox advisory addressed to Stage 4 via `lib/helpers/inbox.sh post --from 2 --to 4 --kind advisory`. Skipped (null-check) high-risk assumptions are not posted.
- Single-retry policy text updated: covers the four deterministic checks (file existence, AC coverage, assumptions shape, assumptions execution).
- Automatic migration: legacy string-form assumptions in pre-WK-4 tickets convert to object form during 5.0.0 -> 6.0.0 migration. Defaults: `id: "A-<n>"`, `statement` preserved verbatim, `check: null`, `expected: "preserved from pre-WK-4 plan; verify manually"`, `risk: "low"`. Idempotent (objects pass through).

### WK-5: per-task review gate in Stage 4

- New opt-in flag in `preferences.md`: `stage4_per_task_gate: true|false` (default `false`). When `true`, Stage 4 implements one `metadata.plan.steps[]` entry at a time and pauses for a human gate after each.
- Stage 4 entry now reads `preferences.md` for the flag in addition to `metadata.testing_strategy.mode`. Legacy flow (single writer call against the full plan) is preserved when the flag is off.
- Per-step sub-loop captures `metadata.stages.4.pre_stage4_sha` (full 40-char SHA) at entry and per-step `pre_step_sha` for rollback. Each step invokes a single-step writer (read budget 5 files; payload restricted to the current step plus AC and lessons), runs `git add -A`, then presents the gate.
- Gate options: `[a]ccept` (keep diff, log decision, continue), `[e]dit` (sub-prompt for `manual` vs `via-writer`; manual pauses for hand-edit then resumes, via-writer re-invokes the writer with verbatim dev instructions inlined and re-presents the same gate), `[r]eject` (`git reset --hard <pre_step_sha>`, mark Stage 4 `blocked` with `blocked_reason`, end turn), `[s]kip` (`git reset --hard <pre_step_sha>`, log decision, advance), `[v]iew-full-diff` (print `git diff <pre_stage4_sha>..HEAD`, re-present the same gate; not counted as a decision).
- Empty-diff branch: if a step's writer produced no staged changes, the gate is skipped silently and the decision is logged as `auto_accepted_empty`.
- Decisions persisted at `metadata.stages.4.per_task_gate.decisions[]` with `step_order`, `decision`, `at`, and (only for `edited_via_writer`) `edit_instructions`.
- Reviewer LLM and Pre-reviewer Check A/B/C run ONCE at the end of the per-step loop against the full Stage 4 diff (base = `pre_stage4_sha`). The gate is PRE-reviewer.
- Stage Finalization Checklist for Stage 4 extended: when the flag is on, `pre_stage4_sha` and `per_task_gate.decisions` are required. When `status = "blocked"` via reject, `blocked_reason` is required instead of the loop counters.

### WK-6: parallel subagents in Stage 4

- New opt-in flag in `preferences.md`: `stage4_parallel_subagents: true|false` (default `false`). When `true`, Stage 4 dispatches independent steps as parallel Agent calls within a single tool block.
- Mutually exclusive with `stage4_per_task_gate`. If both are `true`, the per-task gate wins, parallelism is silently disabled, and the orchestrator narrates the collision at Stage 4 entry.
- Stage 2 planner schema extended: each `metadata.plan.steps[i]` may carry an optional `parallel_group: <string|null>`. Steps sharing the same id are independent and may dispatch concurrently. Steps without the field run alone in their `order` slot.
- Stage 2 deterministic Check E added: validates `parallel_group` is `null` or a non-empty string when present (BLOCKERs `B-8`, `B-9`). Single-retry policy and resume-from-blocked path updated to cover five checks (was four).
- Stage 4 dispatch loop: walks steps in `order`, groups them by `parallel_group` (singletons receive synthetic id `serial-<order>`), then for each group computes the union of declared file paths. Disjoint files = parallel Agent calls in one tool block (`dispatched: "parallel"`); overlap = sequential within the group (`dispatched: "serialized_due_to_overlap"`); singleton = single Agent call (`dispatched: "serial_singleton"`).
- Each parallel writer uses the same single-step writer prompt as WK-5 (read budget 5 source files; payload restricted to the current step). Writers edit the working tree directly; the orchestrator runs a single `git add -A` after the group resolves.
- Error handling: if any Agent in a group returns an error, sibling Agents are NOT cancelled. Successful changelog appendices are persisted; the failed step's `order` is recorded in `parallel_subagents.groups[g].errored_step_orders`; Stage 4 ends the turn with a `blocked` status. Successful work is preserved across the pause.
- Pre-reviewer Check A/B/C and the reviewer LLM still run ONCE at the end of Stage 4 against the cumulative diff (base = `metadata.stages.4.pre_stage4_sha`).
- Stage Finalization Checklist for Stage 4 extended: when `stage4_parallel_subagents` is on, `pre_stage4_sha` and a non-empty `parallel_subagents.groups[]` are required. When `status = "blocked"` via parallel error, `blocked_reason` is required instead of the loop counters.

### Runtime

- No change in 9-stage pipeline behavior.
- `metadata.json` schema unchanged.
- Global lessons: same on-disk path; resolver updated to `${CLAUDE_PLUGIN_ROOT}/lessons/`.

### Automatic migration

In-flight tickets with `skill_version: "5.0.0"` migrate on the first `/wk:doer continue <ID>` after the plugin update. See the `5.0.0 -> 6.0.0` block in `lib/migrations.md`.

## Earlier versions

(Documented inline in the `## Versioning & Migrations` block of `skills/doer/SKILL.md`, which from 6.0.0 onward references `lib/migrations.md`.)
