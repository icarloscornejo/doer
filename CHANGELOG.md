# Changelog

All releases follow SemVer. For migration details, see `lib/migrations.md`.

## 6.5.0 (per-stage cost recording, orchestrator-only status view, Stage 1 silent draft)

**Type:** MINOR (additive protocol changes; no `metadata.json` schema incompatibilities with 6.4.x tickets).

### What changed

**Per-stage cost recording (Stages 1–5, 7, 8)**
- Each delegating stage (1–5, 7, 8) now has an explicit "Record cost" section mandating `cost.sh record` after every Agent return, with canonical `<role>` strings per stage (`ac-reviewer`, `planner`, `test-writer`, `code-writer`, `code-reviewer`, `code-fixer-reviewer`, `auto-fix-fixer`, `runtime-logger`, `log-analyzer`, `runtime-cleanup`, `docs-writer`, `advisor:<persona-id>`).
- `lib/loop.md` promotes the record rule to orchestrator-level, applying to every Agent dispatched by the loop.
- `lib/stage-checklist.md` adds a soft gate at finalization: when `agent_invocations >= 1` but `cost.by_stage[N].calls == 0`, the orchestrator narrates a warning. Never blocks.

**`cost.sh status` orchestrator-only render path**
- When the recorded sub-agent total is `0` but a transcript total exists, `cost.sh status` now renders a degraded "orchestrator-only" summary instead of the misleading `"No cost recorded for this ticket yet."`. Shows transcript totals, by-model breakdown (with cache token columns), and an `[INFO]` note explaining why per-stage breakdown is absent.
- The `"No cost recorded"` message is now reserved for the rare case where both layers (recorded sub-agents AND transcript reconciler) have zero data.
- Stage 9 wrapup gains a two-layer framing narration (verbatim, before the status output) and tiered delta thresholds: >50% triggers a note about orchestrator-heavy inline work; >20% triggers the prior "notable orchestrator inline work" note.

**Stage 1 silent draft**
- Step 6 now builds the AC draft (ACs + Out of Scope + Open Questions) silently in memory. It does NOT present anything to the dev.
- Step 6.5 is the sole point of presentation and the single approval question, whether self-review ran successfully or fell back.
- `01-ac-self-review.md` gains a formal "Fallback path" section (flag disabled or failure) with the standard presentation block and iteration rules.
- Code-writer prompt (Stage 4) now explicitly bans `AC-N` identifiers (e.g. `AC-1`, `AC-3`) from source files, inline comments, KDoc, and test names.

### Migration

No metadata changes. In-flight 6.4.x tickets resume without modification.

`metadata.skill_version` bumps to `6.5.0` on next stage transition.

## 6.4.0 (auto-squash, cost breakdown, version check)

**Type:** MINOR (three new dev-facing behaviors; no breaking changes, no `metadata.json` schema incompatibilities with 6.3.x tickets).

### What changed

**Auto-squash at wrapup (Stage 9, Step 7)**
- After presenting the recommended commit message, doer now asks: *"Want me to squash all branch commits into one now?"*
- On `Yes`: creates a backup ref, runs `git reset --soft <base> && git commit --no-verify -m "<message>"`, verifies exactly 1 commit remains, narrates the backup ref for rollback.
- On `No`: behavior unchanged — dev squashes manually with the recommended message.
- If only 1 commit exists already, skips the squash silently.
- Persists `metadata.stages.9.squash_performed` and `squash_backup_ref` for audit.
- Closing narration branches: if squash was done, says "1 commit (squashed)" and drops the manual squash instruction.

**Full cost breakdown by stage, agent, and model (always-on)**
- `cost.sh record` now persists `input_tokens` and `output_tokens` inside `by_stage` entries (previously only `calls` and `usd`).
- New `by_agent` bucket: when `--agent <name>` is passed, accumulates `calls`, `input_tokens`, `output_tokens`, and `usd` per agent role.
- `cost.sh status` replaced one-paragraph prose with a structured report: `=== Cost Summary ===` + sections `--- By Stage ---`, `--- By Agent ---`, `--- By Model ---`, transcript reconciliation delta (if available), and stale-rates warning.
- Stage 9 Step 12 now prints the full `cost.sh status` output verbatim instead of paraphrasing it.
- `narration.md` updated: `--agent` is now required on every `cost.sh record` call, with canonical role names (`planner`, `code-writer`, `code-reviewer`, etc.).
- `WK_COST_DISABLED=1` explicitly documented as test-only. Cost tracking is always-on by default and must not be disabled in developer environments.

**Version check at startup**
- New Entry-point Step 2 in `skills/doer/SKILL.md`: on every `/wk:doer` invocation, fetches `.claude-plugin/plugin.json` from `origin/main` via `curl` (5s timeout, best-effort).
- If a newer version is available, narrates a one-line banner at the top of the response with update instructions, in the dev's locale (EN/ES).
- Network failure or timeout: silent, never blocks ticket work.
- README updated: `/plugins` panel "Update now" is now the recommended update path (Option A); CLI sequence is Option B.

### Migration

No metadata changes. In-flight 6.3.x tickets resume without modification.

`metadata.skill_version` bumps to `6.4.0` on next stage transition.

## 6.3.1 (protocol and docs slimming)

**Type:** PATCH (file reorganization plus README/AGENTS slim; no orchestrator behavior change, no `metadata.json` shape change).

### What changed

- `skills/publish/SKILL.md` slimmed from 469 to 330 lines. The `--reuse` flow and abort scenarios moved to `skills/publish/{reuse.md, edge-cases.md}` and are loaded on demand from the dispatcher. Invocation Forms collapsed to a table; create commands compacted.
- `skills/doer/stages/01-ac-confirm.md` slimmed from 326 to 172 lines. The full Step 6.5 AC self-review protocol (taxonomy, sub-agent prompt, finding promotion, dev iteration, failure modes) moved to `skills/doer/stages/01-ac-self-review.md`. The dispatcher keeps a one-paragraph contract pointer.
- `lib/migrations.md` slimmed from 724 to 340 lines. All migration blocks from `1.x -> 2.0.0` through `4.0.1 -> 5.0.0` (eight blocks) archived to `lib/migrations/legacy.md`. The Migration Check loads `legacy.md` ONLY when `metadata.skill_version < 5.0.0` and walks its blocks until the ticket version reaches `5.0.0`, then resumes against the live blocks.
- `README.md` slimmed from 423 to 321 lines. Per-version changelog paragraph removed (CHANGELOG.md is the source of truth), `metadata.json` schema table replaced by a pointer to `lib/memory-paths.md`, ancillary mermaid diagrams replaced with tables/bullets, locale and opt-in feature sections compacted.
- `AGENTS.md` repo tree updated to reflect the current state (stages directory, per-skill auxiliary files, new `lib/` files). Legacy `WK-N` framing dropped from the "add a feature" guidance.
- `preferences.md` (the legacy 6.2.0 markdown shim, replaced by `${CLAUDE_CONFIG_DIR}/wk/preferences.json`) and `ROADMAP.md` (closed WK-1 through WK-11, no pending tickets) deleted from the repo.
- `lib/debugging.md` brought under version control. Already referenced by Stage 4, Stage 5, Stage 7, the doer dispatcher, and AGENTS.md prior to this version; the file body is unchanged from how those references already use it.
- `metadata.skill_version` bumps to `6.3.1`.

### Why

Three skills (`publish`, `01-ac-confirm`, `migrations`) had grown above the recommended 300-line cap, with the heaviest content (rarely-combined flows, opt-in protocols, archived migrations) loaded eagerly even when the dispatcher never needed it. The README also duplicated CHANGELOG content and several large mermaid diagrams that were less scannable than tables. Splitting them along the existing "rarely used together" / "load on demand" boundary keeps the dispatchers lean without changing any contract.

### Migration

- Migration block `lib/migrations.md` 6.3.0 -> 6.3.1 is a single `jq` skill_version bump. `affected_stages: []`, so Phase 2 auto-reverify is a no-op for this version.
- Subagents that previously read inline Step 6.5 / `--reuse` / pre-5.0.0 migration blocks now follow pointers; protocols are byte-equivalent to the prior versions, just relocated.

## 6.3.0 (Stage 1 AC self-review)

**Type:** MINOR (additive metadata field, additive opt-in flag, new sub-step in Stage 1; no existing field shape changed).

### What changed

- `skills/doer/SKILL.md` Stage 1 gains Step 6.5 between the existing Step 6 (AC confirmation) and Step 7 (Write artifacts). When `preferences.sh get-flag stage1_ac_self_review` returns empty or `true`, the orchestrator dispatches a single `ac-reviewer` sub-agent (general-purpose, read budget 0, single round, no loop) via the Agent tool. The reviewer compares the AC draft built in Step 6 against `intake.description`, `intake.raw_acs`, and `intake.context` and emits findings under a fixed three-tier taxonomy: `affirmation` (mandatory; at least one per AC ID), `gap` (with `optional: true` for granularity preferences vs structural omissions), `blocker` (direct contradiction with the description).
- Blocker findings are promoted into `metadata.ac.open_questions_resolved[]` with `source: "self_review"` and a proposed resolution. Existing dev-authored Open Questions carry `source: "dev"` (or absent, interpreted as `"dev"` for backward compatibility). The dev still answers ONE question for the entire Stage 1 contract; Step 6.5 enriches the Step 6 block with a Self-review notes section, never asks a second question.
- New dev action: `drop <F-id>[,<F-id>...]` removes a promoted blocker from Open Questions and records the finding under `metadata.ac.self_review.dev_rejected`. The existing `Y / edit / redo` actions are unchanged.
- Orchestrator NEVER auto-applies suggested fixes. The dev keeps full agency over AC text, Out of Scope, and Open Questions. Findings + dev decisions persist into `metadata.ac.self_review = {ran, iteration, findings[], dev_accepted[], dev_rejected[]}`.
- New opt-in flag `stage1_ac_self_review: true` (default ON) added to `lib/helpers/preferences.sh` `ensure_file()` defaults. Existing preferences files written before 6.3.0 do not contain the key; `get-flag` returns empty for them and the orchestrator treats empty as `true` (the default-on semantics). The dev can opt out at any time via `preferences.sh set-flag stage1_ac_self_review false`.
- `lib/memory-paths.md` documents the new `metadata.ac.self_review` field, the `open_questions_resolved[].source` extension, and the failure-mode contract.
- `metadata.stages.1.agent_invocations` increments by 1 on each Step 6.5 dispatch. The Stage Finalization Checklist still treats the field as optional for Stage 1, so existing tickets without the field stay valid.

### Why

The dev validated the value of an automated AC self-review by running it manually with another Claude instance against a real ticket. The output was high-signal: confirmed solid ACs, flagged a granularity preference, and surfaced a real gap (description mentioned session-only persistence with no AC for it). Doer's pipeline today produces ACs in Step 6 and goes straight to dev approval; nothing confronts the draft against the original description before the dev signs off. Shifting that confrontation left (Stage 1, before plan/tests/code investment) catches scope omissions and misalignments at the cheapest possible point.

### Migration

- `metadata.skill_version` bumps to `6.3.0`. Migration block at `lib/migrations.md` (6.2.0 -> 6.3.0) is a no-op for in-flight tickets: `metadata.ac.self_review` is purely additive (absent on pre-6.3.0 tickets) and the orchestrator interprets absence as "Stage 1 ran on an older skill version, no self-review evidence". `open_questions_resolved[].source` is also additive (absent treated as `"dev"`).
- `affected_stages: [1]`. Phase 2 auto-reverify offers a spot-check on completed Stage 1 entries whose `verified_with < 6.3.0`; declining is safe because no runtime behavior of later stages depends on `ac.self_review`.

### Smoke tests

- `tests/helpers.sh` extends the `preferences.sh` JSON shape assertion to require `stage1_ac_self_review == true` after `init`, and adds an explicit `get-flag` round-trip case verifying the default-true behavior on a fresh preferences file.

## 6.2.0 (locale and preferences moved out of versioned plugin cache)

**Type:** MINOR (new helper, new command, behavior change to locale resolution; no metadata shape change).

### What changed

- `${CLAUDE_PLUGIN_ROOT}/preferences.md` (markdown, gitignored, lived inside the versioned plugin cache `cache/wk/wk/<version>/`) is replaced by `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json` (JSON, lives next to the active Claude Code config). The new path survives plugin uninstall, install, and upgrade. Each Claude Code config (claude-tm, claude-sephora, claude-personal, etc.) has its own isolated preferences.
- New helper `lib/helpers/preferences.sh` is the single read/write surface: `get-locale`, `set-locale`, `get-flag`, `set-flag`, `detect-locale`, `path`, `init`, `migrate-from-md`. All `preferences.md`-referencing logic in `lib/narration.md`, `lib/heartbeat.md`, `lib/memory-paths.md`, and `skills/doer/SKILL.md` rewritten to call the helper.
- New command `/doer locale <code>` (and `/wk:doer locale <code>`) persists the global locale via `preferences.sh set-locale`. There is no `--global` flag because the global file is the only locale source. There is no per-ticket override and no `metadata.locale` field.
- New first-message heuristic: when the global preferences file has no `locale` set, the orchestrator runs `preferences.sh detect-locale "<first user message>"` and asks ONE confirmation. On `Y`, the locale persists globally; on `N`, the orchestrator proceeds in English without persisting (the heuristic will run again next invocation; the user can run `/doer locale en` to silence it permanently).

### Why

Real-world failure: claude-sephora, after a plugin upgrade, lost its `preferences.md` (the file lived in `cache/wk/wk/6.0.0/` and 6.1.0 ships in `cache/wk/wk/6.1.0/`, so the new install does not inherit the markdown). The orchestrator fell through to `default English` and narrated in the wrong language, despite the dev expecting Spanish for that machine. The fix is structural: move preferences out of the versioned cache so they survive every upgrade.

### Migration

- `metadata.skill_version` bumps to `6.2.0`. Migration block at `lib/migrations.md` (6.1.0 -> 6.2.0) calls `preferences.sh migrate-from-md` against any legacy `${CLAUDE_PLUGIN_ROOT}/preferences.md` and bumps `metadata.skill_version`. Idempotent (existing JSON keys are preserved; only missing keys are filled from the markdown).
- `affected_stages: []`. Phase 2 auto-reverify is a no-op for this bump because no per-stage artifact format changed.

### Smoke tests

- `tests/helpers.sh` gains 6 smoke tests for `preferences.sh` covering get/set, env override, JSON shape, idempotent init, and Spanish detection.

## 6.1.0 (sub-agent delegation contract + transcript-based cost backstop)

**Type:** MINOR (additive metadata fields, behavior reinforcement, new helper).

### Sub-agent delegation contract

- `skills/doer/SKILL.md` now requires the orchestrator to delegate LLM-heavy work via the Agent tool at every stage that produces artifacts. Stages 2 (planner), 3 (test-writer), 4 (doer / reviewer / fixer-reviewer / AUTO_FIX fixer / parallel subagents), 5 (advisor personas, PR-readiness reviewer), 7 (runtime-logger, log analyzer), and 8 (docs-updater) gained MUST / MUST NOT clauses at every delegation point.
- New section "Sub-agent delegation contract (orchestrator MUST NOT execute LLM-heavy work inline)" added before the read-budgets table. Codifies that the orchestrator dispatches and validates; it does not produce artifacts.
- Stage Finalization Checklist gains a hard-stop gate: `metadata.stages.<N>.agent_invocations >= 1` is required-when-complete for stages 2, 3, 4, 5, 7, 8. The orchestrator increments this counter after each successful Agent return.
- Rationale: cost tracking via `cost.sh record` only fires on Agent returns. Tickets observed completing with `metadata.cost = null` traced back to the orchestrator drifting toward inline execution under context pressure. The MUST language plus the deterministic gate make the drift detectable and rejectable.

### Transcript-based cost backstop

- New helper `lib/helpers/cost-transcript.sh` with the `reconcile <TICKET-ID>` operation. Parses Claude Code session JSONL transcripts (`~/.claude/projects/<slug>/<sessionId>.jsonl` and the matching `subagents/agent-*.jsonl` files), filters by the ticket's time window, deduplicates by `message.id`, excludes compaction overhead, and writes orchestrator-side token usage to `metadata.cost.transcript_reconciled`. Best-effort: never blocks the pipeline.
- `lib/cost-rates.json` gains a `cache_multipliers` block (`creation_5m: 1.25`, `creation_1h: 2.0`, `read: 0.1`) used by `cost-transcript.sh` to compute realistic cache pricing.
- `lib/cost.md` documents the `transcript_reconciled` schema, the new `reconcile` operation, and the cache multiplier rule.
- Stage 9 step 12 now runs `cost-transcript.sh reconcile` before the existing `cost.sh status` and narrates the delta between recorded (Agent-side) and reconciled (full session) cost. A large delta is a hint that the orchestrator drifted toward inline execution.
- `metadata.json` schema gains `session_ids: []` and `session_ids_source: <"env" | "fallback" | null>`. Captured at intake from `$CLAUDE_CODE_SESSION_ID`; appended on every `/doer continue` if the new session id is not already present.

### Smoke tests

- `tests/helpers.sh` gains 7 smoke tests for `cost-transcript.sh` covering the happy path, deduplication, session-id tracking, missing-transcript fallback, empty `session_ids`, and `WK_COST_DISABLED`. All 24 tests pass.

### Migration

- `metadata.skill_version` bumps to `6.1.0`. Migration block at `lib/migrations.md` (6.0.0 -> 6.1.0) initializes `session_ids` / `session_ids_source` and back-fills `agent_invocations` on completed stages 2, 3, 4, 5, 7, 8 with `agent_invocations_backfilled: true` so the gate is forward-looking and does not retroactively block in-flight tickets.
- `affected_stages: [2, 3, 4, 5, 7, 8]`. Phase 2 auto-reverify offers spot-checks on completed stages whose `verified_with < 6.1.0`; declining is safe because runtime artifacts are unchanged.

## 6.0.0 (plugin migration + WK-1 lock protocol + WK-2 inbox + WK-3 cost + WK-4 pre-flight assumptions + WK-5 per-task gate + WK-6 parallel subagents + WK-7 wk:load tracker import + WK-8 wk:advise persona reviewer + WK-9 wk:review external PR review + WK-10 wk:publish MR creation + WK-11 wire wk:advise into Stage 5)

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

### WK-7: wk:load tracker import

- `skills/load/SKILL.md` operational (replacing the placeholder). `/wk:load <ID>` imports a ticket from Jira, Linear, or GitHub Issues into `.doer/tickets/<ID>/metadata.json` and prints a `Next: /wk:doer <ID>` hand-off line.
- Auto-detection by ID shape: GitHub when the input contains `#` (`owner/repo#N` or bare `#N` inside a clone with a single GitHub remote), Jira when the ID matches `^[A-Z][A-Z0-9_]+-\d+$` and `WK_JIRA_BASE_URL` is set, Linear when the same pattern matches and `WK_LINEAR_API_KEY` is set. Ambiguity falls back to `--tracker jira|linear|gh`.
- Backends shell out to native CLIs / HTTP: `gh issue view <ref>` for GitHub, `curl` against `${WK_JIRA_BASE_URL}/rest/api/3/issue/<ID>` for Jira (env vars `WK_JIRA_BASE_URL`, `WK_JIRA_EMAIL`, `WK_JIRA_TOKEN`), `curl` against `https://api.linear.app/graphql` with `Authorization: ${WK_LINEAR_API_KEY}`.
- Output writes via `jq` to a temp file then `mv`, never partial. Populates `ticket_id`, `title`, `branch` (default `<ID>-<slugified-title>`, override with `--branch`), `status: "in_progress"`, `current_stage: 1`, `skill_version: "6.0.0"`, `created_at`, and a full `intake` block with `description`, `raw_acs` (verbatim AC section if found, else `"derive"`), `context` (labels + tracker status as one-liner), `prior_work` (zeroed), and `intake.tracker = {kind, source_id, source_url, imported_at}` for provenance.
- AC extraction heuristic in `skills/load/lib/extract-acs.sh` (executable; pure bash + awk). Recognizes `## Acceptance Criteria`, `**AC:**`, `AC:` headings; emits the verbatim block; prints nothing when no AC section is present (the skill then writes `"derive"`).
- Idempotent: aborts when `intake.description` is non-empty unless `--force`. With `--force`, only the `intake` block and identifying fields are overwritten; `plan`, `changelog`, `code_review`, etc. are preserved untouched.
- Other flags: `--branch <name>` overrides the proposed branch; `--dry-run` prints what would be written without persisting.

### WK-8: wk:advise persona reviewer

- `skills/advise/SKILL.md` operational (replacing the placeholder). `/wk:advise` runs configurable advisor personas against files, diffs, ticket plans, or ad-hoc text. Standalone or pipeline use.
- Persona model: each persona is a JSON file at `lib/advisor-personas/<id>.json` with `id`, `display_name`, `summary`, `system_prompt`, `focus_checklist`, `out_of_scope`, `severity_scale`, `output_schema`. The skill reads the directory at invocation; adding a persona requires only dropping a valid JSON file and `jq empty` validation. No code changes, no registration step.
- Personas shipped by default: `security`, `performance`, `mobile`, `accessibility`, `api`. Each `system_prompt` is 150 to 300 words, em-dashes prohibited; each `focus_checklist` lists at least 12 items.
- Invocation forms: `--list` prints id/display_name/summary for each persona, `--persona <id> --explain` prints the persona's prompt and checklists, `--persona <id> --target <target>` runs a single review, `--personas a,b,c --target <target>` dispatches one Agent call per persona in parallel within a single tool block (same pattern as Stage 4 parallel subagents in WK-6).
- Targets: `file:<path>` reads and inlines a single file, `diff:<base>..<head>` collects `git diff` output, `ticket:<TICKET-ID>` reads `metadata.ac` + `metadata.plan` from `.doer/tickets/<TICKET-ID>/metadata.json`, `text:<inline-text>` passes verbatim text. Default for `diff:` is `main..HEAD`.
- Output: standalone runs print findings to stdout grouped by persona then sorted by severity (blocker, high, medium, low). For `target ticket:<TICKET-ID>` the skill ALSO writes `.doer/tickets/<TICKET-ID>/advisor-findings/<persona-id>.json` with `{persona_id, target, ran_at, findings[]}` for downstream pipeline stages.
- Forward-looking Stage 5 integration documented (NOT implemented yet): when `preferences.md` contains `stage5_advisor_personas: ["security", "performance"]`, Stage 5 will call `/wk:advise --target ticket:<ID>` before its reviewer LLM and treat persona blockers as Stage 5 BLOCKERs in the doer/reviewer convergence loop. The doer skill owns this wiring; advise does not modify Stage 5 behavior on its own.
- `lib/advisor-personas/README.md` documents the JSON shape, the default persona table, and the 5-step guide for adding new personas.

### WK-9: wk:review external PR review

- `skills/review/SKILL.md` operational (replacing the placeholder). `/wk:review <pr-ref>` fetches an external GitHub PR or GitLab MR and runs advisor personas (shared with `/wk:advise`) against it. Targets coworkers' PRs that the dev did NOT generate via the local pipeline.
- PR-ref forms: full URL (`https://github.com/<owner>/<repo>/pull/<N>`, `https://gitlab.com/<group>/<repo>/-/merge_requests/<N>`), short form (`<owner>/<repo>#<N>`, `<group>/<repo>!<N>`), bare number (`#<N>`, `!<N>`) inside a clone with a single remote. Bare numbers without a sigil prompt once. Platform auto-detected from host or sigil.
- Required CLIs: `gh` for GitHub, `glab` for GitLab. The skill exits with a clear install/auth message when the CLI is missing. Does NOT fall back to raw `curl`/`git`; auth, pagination, and field normalization are delegated to the platform CLI.
- Workspace Guard: cwd MUST NOT be `~` or `/`. Same pattern as the rest of the `wk` plugin (see `lib/workspace-guard.md`).
- Persona resolution: reads `preferences.md` for `review_default_personas` (defaults to `["security"]` if unset). `--personas <id1>,<id2>` overrides; `--persona <id>` is the single-persona shortcut. Missing IDs are dropped with a warning; empty resolved list is a hard error.
- Fetch step (in-memory only, never written to disk): `gh pr view --json ...` + `gh pr diff` + `gh pr view --comments` for GitHub; `glab mr view -F json` + `glab mr diff` + `glab mr note list` for GitLab. The fetched content is ephemeral context; no `.env` or local secrets are inlined into Agent prompts.
- Dispatch: one Agent call per persona in a single tool block (parallel). Each Agent receives the persona JSON verbatim, the PR metadata, the diff, and the comments inline. Each returns a JSON array of findings matching the persona's `output_schema` shape (`severity`, `title`, `where`, `explain`, `fix`).
- Aggregation: findings sorted by severity (blocker, high, medium, low, info) per persona. Deterministic vote rule applied in order: any blocker across any persona = `request_changes`; else any high = `comment`; else `approve`. Vote line printed at the end of the report.
- Posting: without `--post`, the report goes to stdout only. With `--post` on GitHub, calls `gh pr review --request-changes` or `--comment` (NEVER `--approve`; approval requires human intent). With `--post` on GitLab, posts a comment via `glab mr note create` only (does NOT call `glab mr approve` or `glab mr merge`); the vote line still narrates the recommended manual action.
- `--list-personas` lists every persona JSON in `lib/advisor-personas/` with id and one-line description, then exits without fetching.
- Skill is a CONSUMER of `lib/advisor-personas/` (does not define or modify the schema). Persona ownership stays with WK-8.

### WK-10: wk:publish MR creation

- `skills/publish/SKILL.md` operational (replacing the placeholder). `/wk:publish <TICKET-ID>` is the explicit final hop the dev runs after `/wk:doer` reports `status: complete`. Pushes the feature branch and creates a PR on GitHub or an MR on GitLab. The doer pipeline still stops before push by design.
- Platform detection: parses `git remote get-url origin` and matches against GitHub cloud, GitHub Enterprise (`ghe.` host or `GH_HOST` env var), GitLab cloud, and GitLab self-hosted patterns. Aborts with a clear message when the URL matches none. Verifies `gh` or `glab` is installed AND authenticated before proceeding.
- Four pre-flight checks (run in order, abort on first failure with a named reason): (1) workspace guard (`.git/` present; cwd not `~` or `/`); (2) metadata invariants: `status == "complete"`, `branch` non-empty, `summary` non-empty, `last_green_sha` exactly 40 hex chars matching `git rev-parse <branch>`; (3) `git rev-parse HEAD` matches `last_green_sha` (catches drift after Stage 9); (4) `git ls-remote origin HEAD` reachable.
- PR/MR body composed from `metadata` and written to a temp file (`/tmp/wk-publish-<TICKET-ID>.md`, cleaned up on exit). Sections: `## Summary` from `metadata.summary`, `## ACs` from `metadata.ac.in_scope`, `## Plan` from `metadata.plan.steps[].what` in order, `## Tests` from `metadata.plan.tests[].name`, `## Lessons captured` from `metadata.lessons_captured[]` (`(none)` when empty), `## Tracker` from `metadata.intake.tracker.source_url` when present.
- Title format: `[<TICKET-ID>] <metadata.title>`. Issued via `gh pr create --base ... --head ... --title ... --body-file ... [--draft]` or `glab mr create --target-branch ... --source-branch ... --title ... --description-file ... [--draft]`.
- Persists `metadata.publish` after success: `{platform, url, branch, base, draft, created_at, reused, last_updated_at?, jira_transition?}`. Without `--reuse`, the skill aborts when `metadata.publish` already exists or when the branch is already on remote, preventing duplicate PRs/MRs.
- `--reuse` updates the existing PR/MR via `gh pr edit` or `glab mr update` (non-force push only; diverged history aborts and asks the dev to resolve manually). Sets `reused: true` and `last_updated_at`.
- Optional Jira transition via `--transition <state>` requires `metadata.intake.tracker.kind == "jira"` (provenance from `/wk:load`) and env vars `WK_JIRA_EMAIL`, `WK_JIRA_TOKEN`, `WK_JIRA_BASE_URL`. Resolves transition id by case-insensitive name match against `GET /rest/api/3/issue/<id>/transitions`, then `POST` to the same endpoint. HTTP 204 = success. Failures (missing env, mismatched tracker kind, transition not found, non-204) are NEVER rolled back; the PR/MR stays live, the error is persisted to `metadata.publish.jira_transition.error`, and the dev is instructed to re-run with `--reuse --transition` after fixing.
- Flags: `--draft`, `--base <branch>` (default `main`), `--dry-run` (prints would-do preview without any write or push), `--reuse`, `--transition <state>`. Combinations are allowed.
- Edge cases handled with named aborts: detached HEAD, missing remote, missing CLI, auth failure, missing `metadata.json`, ticket not complete, drifted `last_green_sha`. Jira auth failures (HTTP 401/403) are recorded in `metadata.publish.jira_transition.error` and exit non-zero.

### WK-11: wire wk:advise into Stage 5

- New opt-in flag in `preferences.md`: `stage5_advisor_personas: [<id>, ...]` (default `[]`). When non-empty, Stage 5 invokes `/wk:advise --target ticket:<TICKET-ID> --personas <list>` ONCE at the start of iteration 1, BEFORE the deterministic Pre-reviewer Checks A/B/C. Personas do NOT re-run in iter 2 or 3. Closes the forward-looking integration documented in WK-8.
- Persona-id validation: missing `${CLAUDE_PLUGIN_ROOT}/lib/advisor-personas/<id>.json` produces a single warning per missing id and the id is dropped. Empty list after validation skips the block silently.
- Findings ingested from `.doer/tickets/<TICKET-ID>/advisor-findings/<persona-id>.json` (written by `/wk:advise` per WK-8). Routing by `severity`: `blocker` -> `metadata.code_review[iteration=1].blockers[]` (loop continues until resolved, exactly like reviewer-sourced blockers); `high`/`medium`/`low` -> `suggestions[]` (severity preserved as a `[<SEVERITY>]` prefix in `text`); `info` -> `info[]`. Blocker ids continue the iteration's existing `B-<n>` numbering across reviewer + advisor sources.
- Each promoted entry in `blockers`, `suggestions`, and `info` carries an optional `source` field: `"reviewer"` (default; covers reviewer LLM and Pre-reviewer Check output) or `"advisor:<persona-id>"`. Absent field is interpreted as `"reviewer"` for backward compatibility with pre-WK-11 tickets. Schema documented in `lib/memory-paths.md`.
- New iter-1-only field `metadata.code_review[iteration=1].advisor_personas_ran` lists the persona ids that successfully dispatched and returned (excluding dropped-missing ones). Absent on iter 2/3 because personas do not re-run.
- Reviewer LLM prompt extended: when advisor findings exist for the iteration, an `== Advisor findings (already ingested into metadata.code_review) ==` section is appended with the JSON dump grouped by persona. The reviewer is instructed to acknowledge but NOT re-judge advisor blockers; its scope remains the three judgement axes (one logical unit, semantic error handling, stale comments).
- Convergence interaction: advisor blockers and reviewer/Pre-check blockers share the same iteration entry. Iter 2/3 combined fixer-reviewer receives the prior `metadata.code_review` entry inline and applies the standard `RESOLVED` / `STILL_OPEN` rule to every prior blocker regardless of `source`. The `source` annotation is preserved when a blocker is recorded as `STILL_OPEN`.
- Failure modes are non-fatal: a persona returning non-JSON or empty findings is treated as zero findings with a warning; a malformed persona file is dropped with a warning; if all requested personas fail, Stage 5 narrates a single warning and proceeds with deterministic checks only. Stage 5 is NEVER aborted by an advisor failure.
- Stage Finalization Checklist for Stage 5 extended: when `preferences.md` has a non-empty `stage5_advisor_personas` AND iter 1 actually dispatched personas, `metadata.code_review[iteration=1].advisor_personas_ran` is required (non-empty list of ids).
- No automatic migration needed: pre-WK-11 tickets continue to work because all new fields (`source`, `advisor_personas_ran`) are optional and absent values are interpreted via the documented defaults.

### Runtime

- No change in 9-stage pipeline behavior.
- `metadata.json` schema unchanged.
- Global lessons: same on-disk path; resolver updated to `${CLAUDE_PLUGIN_ROOT}/lessons/`.

### Automatic migration

In-flight tickets with `skill_version: "5.0.0"` migrate on the first `/wk:doer continue <ID>` after the plugin update. See the `5.0.0 -> 6.0.0` block in `lib/migrations.md`.

## Earlier versions

(Documented inline in the `## Versioning & Migrations` block of `skills/doer/SKILL.md`, which from 6.0.0 onward references `lib/migrations.md`.)
