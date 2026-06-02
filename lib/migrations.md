# Versioning & Migrations

Status: protocol shared by all skills in the `wk` plugin.


## Versioning & Migrations

The SKILL frontmatter declares the current version (SemVer: MAJOR.MINOR.PATCH).

| Bump | When | Migration block? |
|------|------|------------------|
| **MAJOR** | Structural change (renames/removes stages, changes metadata shape, removes/renames artifact files) | REQUIRED |
| **MINOR** | Adds capability OR changes the shape of any persistent field in `metadata.json` (e.g. `metadata.plan.tests[]` schema), OR changes the format of a global lesson file | REQUIRED if any persistent format changed; optional otherwise |
| **PATCH** | Bug fix to orchestrator behavior, doc edit, no file format change | None |

**Rule of thumb:** if a bump changes how an existing artifact file is shaped, **register a migration block**. Tickets in flight should never be stuck reading verbose old formats just because they were created before the optimization. Token-cost reductions are real wins; auto-applying them keeps every ticket on the latest cheapest format.

Each ticket persists `skill_version` in `metadata.json` at intake. The orchestrator runs the **Migration Check** below at every one of these explicit trigger points (NOT only at `/doer continue`):

1. Start of every `/doer <TICKET-ID>` invocation, after the Workspace Guard finishes.
2. Start of every `/doer continue <TICKET-ID>` (same path; `/doer continue` is just an alias).
3. Start of every `/doer verify <TICKET-ID>`.
4. As part of every **Transition Sync** (see `${CLAUDE_PLUGIN_ROOT}/lib/heartbeat.md`). Because the Transition Sync is unconditional at every stage transition, this subsumes the old "after re-hydration" trigger.
5. Before every stage transition where `metadata.skill_version` does not match the SKILL frontmatter version (cheap deterministic comparison; if equal, skip).

The "every entry point" phrasing is too vague and gets dropped from context after compaction. The five explicit triggers above are non-negotiable.

### How to read each version (mandatory Bash execution; no inference)

Both versions in the comparison MUST be extracted from their authoritative source via a Bash tool call whose output is then shown verbatim in the narration. Inferring a version value from memory, from a migration block header, from a schema example, from prior narration, or from any other string in the SKILL is a **VIOLATION** of the Migration Check protocol. The orchestrator may not assert either version value unless it has just shown the corresponding Bash output in this turn.

**Mandatory narration template** (the orchestrator MUST emit something equivalent to this; the four lines marked `MUST` are not optional):

```
Migration Check (this turn):
[MUST] $ grep '^version:' <absolute path to SKILL.md> | head -1 | awk '{print $2}'
[MUST] -> <verbatim stdout of the command above, e.g. "3.0.4">
[MUST] $ jq -r '.skill_version' .doer/tickets/<TICKET-ID>/metadata.json
[MUST] -> <verbatim stdout of the command above, e.g. "3.0.0">
Comparison: <metadata value> vs <SKILL value> -> <decision: no-op | silent bump | run migration block | error: downgrade>
```

The two Bash tool calls MUST execute as actual tool invocations (so the user sees them in the trace). The orchestrator MUST NOT shortcut by stating values from memory.

**Forcing rule for self-check:** before stating either version value in any narration, ask: *"Did I show a Bash output for this value in this turn?"* If no, run the Bash command first. If you find yourself about to write *"SKILL frontmatter = X.Y.Z"* without a preceding Bash output line, STOP and run the grep command first.

**Comparison procedure (after both outputs are shown):**

1. Compare the two strings literally.
2. If the SKILL value is greater than the metadata value → run Phase 1 (case 4 if a migration block matches; case 5 silent bump otherwise). Narrate which case applies.
3. If equal → narrate "no migration needed" and continue.
4. If metadata is greater than SKILL → unexpected (downgrade). Narrate and stop; do not continue.

**Common failure mode this prevents:** the orchestrator parses `3.0.0` from a migration block header like `### Migration: From 2.10.0 → 3.0.0`, from a schema example like `verified_with: "3.0.0"`, or from associative memory of a prior session, and reports it as the current SKILL version without ever running the grep command. Those strings are NOT the SKILL version. Only the frontmatter `^version:` line, read fresh via Bash this turn, is authoritative. This failure was observed in v3.0.2 and v3.0.3 (the spec said "do not infer" but lacked a forcing function); v3.0.4 adds the mandatory Bash execution + verbatim output narration as the forcing function.

### Migration Check (auto, silent)

Runs as part of the Workspace Guard sequence (right after the exclude check, before any stage logic). Two phases:

**Phase 1: file-format / data migration (existing behavior)**

1. Read `metadata.skill_version` (default `"1.0.0"` if missing, pre-versioning era).
2. Read current SKILL frontmatter `version`.
3. If equal → no-op for Phase 1.
4. If ticket version < current version → walk every migration block below in chronological order. For each block whose `from` matches the ticket's current version: apply it, then bump `metadata.skill_version` to the block's `to`. Continue until the ticket's version equals the current SKILL version.
5. If the ticket version is behind the SKILL but no migration block matches the gap (e.g. a PATCH bump): silently bump `metadata.skill_version` to current. No file changes.
6. **Always auto-apply without asking the user**, but **NOT silently in execution**. Per Core Principle 1 (Narration first), the orchestrator MUST narrate progress per step inside any non-trivial migration block (one narration line per step is the minimum: *"Migration step 3/11: parsing changelog.md → metadata.changelog..."*, then *"...done"* on completion). The "no confirmations" rule is about not pausing for user input; it is NOT a license to go silent for minutes while parser agents run. At the end, narrate ONE summary line IF any migration block actually executed: *"Migrated ticket X.Y.Z → A.B.C: N steps, M files changed."* If only a silent version-bump happened (case 5, no actual block ran), narrate nothing.

**Phase 2: per-stage auto-reverify (introduced in 2.10.0)**

Every migration block declares `affected_stages: [<stage names>]` listing the stages whose runtime behavior changed in that bump. When the ticket version moved across one or more migration blocks (Phase 1), the orchestrator computes the union of `affected_stages` across all migrations applied this run. Then:

1. For each stage in that union, look up `metadata.stages.<N>.verified_with`.
2. If the stage has `status` in `("complete", "skipped", "imported")` AND `verified_with < current SKILL version`, mark it as a **reverify candidate**.
3. If the ticket is `complete` and there are reverify candidates, ask ONCE via `AskUserQuestion`:
   ```
   Question: Ticket already complete. SKILL upgraded to <X.Y.Z>; <N> stages
   changed behavior since this ticket finished: <list>. Re-verify them now?

   Options:
     - Re-verify (recommended): run the spot-checks
     - Skip: leave the ticket as is
   ```
   On "Skip" → narrate, do nothing else. On "Re-verify" → run spot-checks (next bullet).
4. If the ticket is `in_progress`, run spot-checks AUTOMATICALLY (no prompt) before resuming. The dev expected to keep working; verify-first is the safer default.

**Spot-check mechanics per stage:**

| Stage | Spot-check |
|-------|------------|
| 1 ac-confirm | Re-run a lightweight AC validation: read `metadata.ac` and `metadata.intake`, confirm the AC list still aligns. No subagent unless validation fails. |
| 2 plan | Re-run the four deterministic checks (file existence, AC coverage, assumptions shape, assumptions execution) on `metadata.plan`. No LLM. If a check fails, reopen Stage 2 with that BLOCKER. |
| 3 tests | Re-run the deterministic checks for the recorded `metadata.stages.3.testing_strategy_mode` (parse/run + presence + red-phase for `bdd`; parse/run + regression coverage for `direct`). No LLM. |
| 4 code | Re-run pre-checks (test pass + lint + typecheck + plan-driven scope). Skip LLM reviewer unless pre-checks find new issues. |
| 5 code-review | Re-run pre-checks (RED grep, secrets, smoke, bare except). Skip LLM reviewer unless pre-checks find new issues. |
| 6 quality-gate | Re-run test suite via the skip-safe check (`last_green_sha` lookup; usually no-op). |
| 7 runtime-verify | CANNOT auto-rerun (needs device + dev). Ask via `AskUserQuestion` (two options: `Re-exercise on device` / `Skip`): *"Stage 7 changed behavior in <X.Y.Z>. Re-exercise on device?"*. On `Skip`, mark `verified_with: <new>` with note `dev_acknowledged_skip`. |
| 8 docs-sync | Re-run pre-checks A/B/C. Skip LLM agent unless update list non-empty. |
| 9 wrapup | No spot-check. Wrapup is the terminal stage; if its behavior changed, the dev re-runs `/doer <ID>` to refresh `metadata.summary` and `metadata.performance` only if they want updated stats. |

**Spot-check outcomes:**

- All clean → update each stage's `verified_with` to current SKILL version. Continue normal flow.
- Any spot-check produced BLOCKERs → reopen the ticket at the FIRST affected stage with the BLOCKERs preloaded. Set `metadata.status = "in_progress"`, `metadata.current_stage = N`, narrate which stage and why. The dev resumes from there.

The orchestrator narrates ONE summary at the end:
```
Auto-reverify complete: <K> stages spot-checked.
- 5 clean (verified_with bumped to <X.Y.Z>)
- 1 reopened: Stage 4 found new BLOCKERs from updated lint rules.
Resuming at Stage 4.
```

### Legacy migrations (pre 5.0.0)

Migration blocks for `1.x → 2.0.0`, `2.0.0 → 2.1.0`, `2.1.0 → 2.2.0`, `2.2.0 → 2.3.0`, `2.3.0 → 2.4.0`, `2.4.0 → 2.10.0`, `2.10.0 → 3.0.0`, `3.0.6 → 4.0.0`, and `4.0.1 → 5.0.0` live in `${CLAUDE_PLUGIN_ROOT}/lib/migrations/legacy.md`. The Migration Check loads that file ONLY when `metadata.skill_version < 5.0.0` and walks its blocks in order until the ticket version reaches `5.0.0`, then resumes against the live blocks below.

For any ticket already at `5.0.0` or later (the expected case), `legacy.md` is never read.

### Migration: From 5.0.0 -> 6.0.0

`affected_stages: [all]`

MAJOR bump. Restructures the install from a single skill (`doer`) into a formal Claude Code plugin (`wk`) with five skills. The skill runtime behavior is equivalent; only the install path and version label change.

**What this bump changes:**
- The skill `doer` is now part of plugin `wk`. Invocation moves from `/doer ABC-123` to `/wk:doer ABC-123`. Backward-compat: if the user types `/doer ABC-123`, the orchestrator detects this is the migrated skill and accepts it.
- Path resolution for `lessons/` moves from the heuristic `<doer-skill-dir>/lessons/` to the canonical `${CLAUDE_PLUGIN_ROOT}/lessons/`. The lessons themselves did NOT move on disk (they always lived next to SKILL.md); only the resolver changed.
- Path resolution for shared protocols moves from inline definitions in SKILL.md to `${CLAUDE_PLUGIN_ROOT}/lib/<file>.md` references.
- Per-ticket lock protocol shipped (WK-1). Workspace Guard now acquires `.doer/tickets/<ID>/lock.json` on every entry point, every stage transition refreshes the heartbeat via `${CLAUDE_PLUGIN_ROOT}/lib/helpers/lock.sh touch`, and Stage 9 wrapup releases the lock. Concurrent sessions on the same ticket fail fast.
- Inter-stage inbox protocol shipped (WK-2). New top-level `metadata.inbox` array (created lazily on first post). Each stage drains its unacked messages on entry; Stage 9 wrapup clears acked messages.
- Per-ticket cost tracking shipped (WK-3). New top-level `metadata.cost` object (created lazily on first record). Token usage from each Agent return is multiplied by rates from `lib/cost-rates.json` (lazy fallback for unknown models). Stage 9 wrapup surfaces the summary.
- Pre-flight assumptions integrated into Stage 2 (WK-4). `metadata.plan.assumptions[]` switches from a string array to an object array (`id`, `statement`, `check`, `expected`, `risk`). Stage 2 gains Check D, which executes each non-null `check` from the repo root and posts an inbox advisory to Stage 4 for every high-risk assumption that validated. Legacy string entries from pre-WK-4 tickets are preserved at the file-format layer; they are auto-rewritten on the next Stage 2 run.
- `metadata.json` schema gains two optional top-level fields: `inbox: []` (array) and `cost: {}` (object). Both lazy (absent until first write). `metadata.plan.assumptions[]` element shape changes from string to object (additive: prior strings still parse; the planner emits objects from now on).
- `metadata.skill_version` bumps to `"6.0.0"`.

**Per-ticket changes:**

```bash
TICKET_DIR=.doer/tickets/<TICKET-ID>
META=$TICKET_DIR/metadata.json

# Narrate before each step (per Core Principle 1).

# 1. Convert legacy string-form assumptions to object form (WK-4 schema).
#    Idempotent: skips entries already in object form. If metadata.plan
#    is absent or assumptions is empty, no-op.
#    Narrate: "Migration 5.0.0 -> 6.0.0, step 1/2: converting assumptions to object form."
jq '
  if (.plan?.assumptions // null) == null then .
  else .plan.assumptions = (
    [ .plan.assumptions
      | range(0; length) as $i
      | .[$i] as $a
      | if ($a | type) == "string"
        then {
          id: ("A-" + (($i + 1) | tostring)),
          statement: $a,
          check: null,
          expected: "preserved from pre-WK-4 plan; verify manually",
          risk: "low"
        }
        else $a
        end
    ]
  ) end
' "$META" > "$META.tmp" && mv "$META.tmp" "$META"

# 2. Bump skill_version to 6.0.0.
#    Narrate: "Migration 5.0.0 -> 6.0.0, step 2/2: bumping skill_version to 6.0.0."
jq '.skill_version = "6.0.0"' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
```

**Important migration notes:**

- The only schema rewrite is `metadata.plan.assumptions[]` (string → object). The conversion preserves the original statement verbatim, defaults `risk` to `"low"`, and leaves `check` as `null` (statement-only). Phase 2 auto-reverify on Stage 2 will re-run Check D, which is a no-op for `check: null` entries.
- The behavioral changes (path resolution, plugin namespacing, lock/inbox/cost helpers, Stage 2 Check D) apply on the next `/wk:doer <ID>` invocation.
- Stage 2 / Stage 3 / Stage 4 / Stage 5 retain their behavior. Phase 2 auto-reverify will spot-check completed stages because `affected_stages: [all]`, but in practice no spot-check should fail because runtime semantics are identical.
- Tickets in flight at any stage continue from where they were. The orchestrator on the next `/wk:doer continue <ID>` reads `metadata.skill_version`, sees it is < 6.0.0, applies this block, and resumes.
- After 6.0.0 ships, future tickets (WK-2 through WK-10) will introduce more migrations as `lib/inbox`, `lib/cost`, satellite skills, and core enhancements land.

The behavioral changes apply on the next `/wk:doer <ID>` invocation.

### Migration: From 6.0.0 -> 6.1.0

`affected_stages: [2, 3, 4, 5, 7, 8]`

**Plugin-wide changes:**

- Sub-agent delegation contract: stages 2, 3, 4, 5, 7, 8 MUST delegate LLM-heavy work via the Agent tool. The orchestrator MUST NOT execute planning, code-writing, test-writing, reviewing, runtime-logging, log analysis, or doc updates inline. Wording in `skills/doer/SKILL.md` reinforced with MUST / MUST NOT clauses at every delegation point and a new "Sub-agent delegation contract" section.
- Stage Finalization Checklist gains a hard-stop gate: `metadata.stages.<N>.agent_invocations >= 1` is required-when-complete for stages 2, 3, 4, 5, 7, 8. The orchestrator increments this counter after each successful Agent return alongside the existing `cost.sh record` call.
- Cost protocol gains a transcript-based reconciliation pass: `lib/helpers/cost-transcript.sh reconcile <ID>` parses the Claude Code session JSONL transcripts and records orchestrator-side token usage under `metadata.cost.transcript_reconciled`. Best-effort, never blocks. Stage 9 step 12 now runs reconcile before `cost.sh status`.
- `lib/cost-rates.json` gains a `cache_multipliers` block (`creation_5m: 1.25`, `creation_1h: 2.0`, `read: 0.1`) used by `cost-transcript.sh`.
- `metadata.json` schema gains three new fields: `session_ids: []` (array of Claude Code session ids captured at intake and at every `/doer continue`), `session_ids_source: <"env" | "fallback" | null>`, and `metadata.cost.transcript_reconciled: {}` (lazy; absent until first reconcile).
- `metadata.skill_version` bumps to `"6.1.0"`.

**Per-ticket changes:**

```bash
TICKET_DIR=.doer/tickets/<TICKET-ID>
META=$TICKET_DIR/metadata.json

# Narrate before each step (per Core Principle 1).

# 1. Initialize session_ids and session_ids_source if missing. Best-effort
#    capture of the current session id; falls back to null if not available.
#    Narrate: "Migration 6.0.0 -> 6.1.0, step 1/3: initializing session_ids."
CURRENT_SESSION="${CLAUDE_CODE_SESSION_ID:-}"
if [ -n "$CURRENT_SESSION" ]; then
  jq --arg s "$CURRENT_SESSION" '
    .session_ids = ((.session_ids // []) + [$s] | unique)
    | .session_ids_source = (.session_ids_source // "env")
  ' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
else
  jq '
    .session_ids = (.session_ids // [])
    | .session_ids_source = (.session_ids_source // null)
  ' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
fi

# 2. Back-fill stages.<N>.agent_invocations for delegating stages already
#    marked complete. Derive from metadata.performance.agents when possible
#    (best-effort: total agent invocations on the ticket, attributed
#    proportionally is unreliable, so we mark legacy stages as 1 when the
#    ticket has any agent activity, else null with an explanatory note).
#    The Agent-invocation gate only enforces on FUTURE transitions; legacy
#    stages with null are accepted to avoid retroactive blocking.
#    Narrate: "Migration 6.0.0 -> 6.1.0, step 2/3: back-filling agent_invocations on completed stages."
jq '
  (.performance.agents // {}) as $agents
  | ([ $agents | to_entries[] | .value ] | add // 0) as $total
  | .stages = (
      .stages
      | with_entries(
          if (.key | tonumber? // -1) as $n
             | ($n | IN(2, 3, 4, 5, 7, 8))
             and (.value.status == "complete")
             and (.value.agent_invocations == null or (.value | has("agent_invocations") | not))
          then .value.agent_invocations =
                 (if $total > 0 then 1 else null end)
               | .value.agent_invocations_backfilled = true
          else .
          end
        )
    )
' "$META" > "$META.tmp" && mv "$META.tmp" "$META"

# 3. Bump skill_version to 6.1.0.
#    Narrate: "Migration 6.0.0 -> 6.1.0, step 3/3: bumping skill_version to 6.1.0."
jq '.skill_version = "6.1.0"' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
```

**Important migration notes:**

- The Agent-invocation gate is forward-looking. Legacy stages back-filled with `agent_invocations: null` (because the ticket had zero recorded agent activity) are NOT retroactively blocked from being `complete`; the gate only fires when a stage transitions to `complete` after this migration. The `agent_invocations_backfilled: true` marker lets a dev later distinguish back-filled values from real counts.
- Phase 2 auto-reverify on stages 2, 3, 4, 5, 7, 8 will offer spot-checks for completed stages whose `verified_with < 6.1.0`. The dev may decline; declining is safe because runtime artifacts are unchanged. The reverify exists so that tickets that completed before this rule existed can be inspected for inline-execution drift if the dev wants.
- Tickets in flight continue from where they were. On the next `/wk:doer continue <ID>` the orchestrator runs the Migration Check, applies this block, captures the current session id, and resumes.
- `metadata.cost.transcript_reconciled` is created lazily on first reconcile (typically Stage 9). No back-fill needed.

The behavioral changes apply on the next `/wk:doer <ID>` invocation.

### Migration: From 6.1.0 -> 6.2.0

`affected_stages: []` (no per-stage artifact changes; the only change is the location of preferences and the locale-resolution mechanism)

**Plugin-wide changes:**

- Locale and opt-in flags moved out of the versioned plugin cache. The previous `${CLAUDE_PLUGIN_ROOT}/preferences.md` (markdown, gitignored, lived next to `SKILL.md` and was wiped on every `uninstall + install` cycle) is replaced by `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json` (JSON, lives next to the active Claude Code config). The new path survives plugin upgrades.
- New helper `${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh` is the single read/write surface (`get-locale`, `set-locale`, `get-flag`, `set-flag`, `detect-locale`, `init`, `path`, `migrate-from-md`).
- New command `/doer locale <code>` persists the global locale via `preferences.sh set-locale`.
- Heuristic locale detection runs at most once per Claude Code config: when the global file has no `locale` key set, the orchestrator runs `preferences.sh detect-locale "<first user message>"` and confirms before persisting.
- All `preferences.md`-referencing logic in `lib/narration.md`, `lib/heartbeat.md`, `lib/memory-paths.md`, and `skills/doer/SKILL.md` rewritten to call `preferences.sh` instead.
- `metadata.json` schema is unchanged. There is intentionally NO `metadata.locale` field; the global preferences file is the only locale source.
- `metadata.skill_version` bumps to `"6.2.0"`.

**Per-ticket changes:**

```bash
TICKET_DIR=.doer/tickets/<TICKET-ID>
META=$TICKET_DIR/metadata.json

# Narrate before each step (per Core Principle 1).

# 1. One-time global migration: import a legacy preferences.md into the new
#    JSON file, if present in the active plugin cache. Idempotent: if the
#    JSON already exists, the helper preserves existing keys and only fills
#    missing ones from the markdown source. Safe to run on every ticket;
#    the import only does work the first time.
#    Narrate: "Migration 6.1.0 -> 6.2.0, step 1/2: importing legacy preferences.md if present."
LEGACY_PREFS="${CLAUDE_PLUGIN_ROOT:-}/preferences.md"
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$LEGACY_PREFS" ]; then
  "${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh" migrate-from-md "$LEGACY_PREFS"
fi

# 2. Bump skill_version to 6.2.0.
#    Narrate: "Migration 6.1.0 -> 6.2.0, step 2/2: bumping skill_version to 6.2.0."
jq '.skill_version = "6.2.0"' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
```

**Important migration notes:**

- No metadata shape change. Phase 2 auto-reverify is a no-op for this bump (`affected_stages: []`).
- The legacy `preferences.md` file in the plugin cache is left untouched. Subsequent plugin upgrades will replace the cache directory anyway, so the markdown file disappears naturally. The new JSON lives outside the cache and persists.
- Tickets in flight continue from where they were. On the next `/wk:doer continue <ID>` the orchestrator runs the Migration Check, applies this block, and resumes. The first chat output uses the locale resolved from the new JSON file (which inherits from the legacy markdown if present, else falls through to the heuristic + confirmation).
- Multiple Claude Code installs on the same machine (claude-tm, claude-sephora, claude-personal) each have their own `$CLAUDE_CONFIG_DIR` and therefore their own preferences file. Migrations run independently per install.

The behavioral changes apply on the next `/wk:doer <ID>` invocation.

### Migration: From 6.2.0 -> 6.3.0

`affected_stages: [1]` (Stage 1 gains Step 6.5 AC self-review; spot-check is non-blocking)

**Plugin-wide changes:**

- Stage 1 gains Step 6.5 between AC confirmation (Step 6) and Write artifacts (Step 7): a single-round `ac-reviewer` sub-agent compares the AC draft against `intake.description`, `intake.raw_acs`, and `intake.context` under a fixed three-tier taxonomy (`affirmation` / `gap` / `blocker`).
- Blocker findings are promoted into `metadata.ac.open_questions_resolved[]` with `source: "self_review"` and a proposed resolution. Existing dev-authored Open Questions carry `source: "dev"` (or absent, interpreted as `"dev"` for backward compatibility).
- New top-level field `metadata.ac.self_review = {ran, iteration, findings[], dev_accepted[], dev_rejected[]}`. Purely additive; absent on pre-6.3.0 tickets is interpreted as "Stage 1 ran on an older skill version, no self-review evidence".
- New opt-in flag `stage1_ac_self_review: true` (default ON) added to `lib/helpers/preferences.sh` `ensure_file()` defaults. `get-flag` returns empty for older preference files; the orchestrator treats empty as `true`.
- `metadata.skill_version` bumps to `"6.3.0"`.

**Per-ticket changes:**

```bash
TICKET_DIR=.doer/tickets/<TICKET-ID>
META=$TICKET_DIR/metadata.json

# Narrate before each step (per Core Principle 1).

# 1. Bump skill_version to 6.3.0. No metadata rewrite needed; metadata.ac.self_review
#    and open_questions_resolved[].source are both purely additive.
#    Narrate: "Migration 6.2.0 -> 6.3.0, step 1/1: bumping skill_version to 6.3.0."
jq '.skill_version = "6.3.0"' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
```

**Important migration notes:**

- No data backfill. Pre-6.3.0 tickets that already finished Stage 1 keep their existing `metadata.ac` shape; the new `self_review` sub-object is only written when Step 6.5 actually runs (which only happens on Stage 1 entry).
- Phase 2 auto-reverify on Stage 1 is offered for completed tickets whose `verified_with < 6.3.0`. Declining is safe; runtime behavior of later stages does not depend on `ac.self_review`.
- The orchestrator NEVER auto-applies suggested fixes. The dev keeps full agency over AC text, Out of Scope, and Open Questions.
- Failure modes (sub-agent returns malformed JSON, times out, etc.) are non-fatal: Stage 1 records the failure under `metadata.ac.self_review.error` and continues to Step 7 with the dev's approved AC draft unchanged.

The behavioral changes apply on the next `/wk:doer <ID>` invocation.

### Migration: From 6.3.0 -> 6.3.1

`affected_stages: []` (no metadata shape change; pure file reorg + docs slim)

**Plugin-wide changes:**

- `skills/publish/SKILL.md` extracts the `--reuse` flow and abort scenarios into `skills/publish/{reuse.md, edge-cases.md}`. Loaded on demand from the dispatcher.
- `lib/migrations.md` archives all migration blocks from `1.x -> 2.0.0` through `4.0.1 -> 5.0.0` into `lib/migrations/legacy.md`. The Migration Check loads `legacy.md` ONLY when `metadata.skill_version < 5.0.0` and walks its blocks until the ticket version reaches `5.0.0`, then resumes against the live blocks (5.0 -> 6.0 onward).
- `skills/doer/stages/01-ac-confirm.md` extracts the full Step 6.5 AC self-review protocol (taxonomy, sub-agent prompt, finding promotion, dev iteration, failure modes) into `skills/doer/stages/01-ac-self-review.md`. The dispatcher keeps a one-paragraph contract pointer.
- `README.md` slimmed: redundant per-version changelog paragraph dropped, `metadata.json` schema table replaced by a pointer to `lib/memory-paths.md`, ancillary mermaid diagrams replaced with tables/bullets, locale and opt-in feature sections compacted.
- `AGENTS.md` repo tree updated to reflect the new files; legacy references removed.
- `preferences.md` (the legacy 6.2.0 markdown shim) and `ROADMAP.md` (closed WK-1 through WK-11) deleted from the repo.
- New file `lib/debugging.md` brought under version control. Already referenced by Stage 4, Stage 5, Stage 7, the doer dispatcher, and AGENTS.md prior to this version; the file body is unchanged from how those references already use it.
- `metadata.skill_version` bumps to `"6.3.1"`.

**Per-ticket changes:**

```bash
TICKET_DIR=.doer/tickets/<TICKET-ID>
META=$TICKET_DIR/metadata.json

# Narrate before the step (per Core Principle 1).

# 1. Bump skill_version to 6.3.1. No metadata rewrite needed; nothing in this
#    bump changes the shape of any persistent field.
#    Narrate: "Migration 6.3.0 -> 6.3.1, step 1/1: bumping skill_version to 6.3.1."
jq '.skill_version = "6.3.1"' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
```

**Important migration notes:**

- No data backfill. The bump is a no-op beyond writing the new version string.
- Phase 2 auto-reverify is a no-op (`affected_stages: []`); no completed stage needs spot-checking.
- Subagents that previously read the inline Step 6.5 / `--reuse` / pre-5.0.0 migration blocks now follow the pointers; the protocols themselves are byte-equivalent to the prior versions, just relocated.

The behavioral changes apply on the next `/wk:doer <ID>` invocation.

### Migration: From 6.3.1 -> 6.4.0

`affected_stages: []` (no metadata shape change; additive behavior + new `squash_performed` / `squash_backup_ref` optional fields written only by Stage 9)

**Per-ticket changes:**

```bash
TICKET_DIR=.doer/tickets/<TICKET-ID>
META=$TICKET_DIR/metadata.json

# 1. Bump skill_version to 6.4.0. No metadata rewrite needed.
#    Narrate: "Migration 6.3.1 -> 6.4.0, step 1/1: bumping skill_version to 6.4.0."
jq '.skill_version = "6.4.0"' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
```

**Important migration notes:**

- No data backfill. The new `metadata.stages.9.squash_performed` and `squash_backup_ref` fields are only written when Stage 9 runs the auto-squash prompt. Pre-6.4.0 tickets that already completed Stage 9 do not need them.
- Phase 2 auto-reverify is a no-op (`affected_stages: []`).

The behavioral changes apply on the next `/wk:doer <ID>` invocation.

### Migration: From 6.5.1 -> 6.6.0

`affected_stages: []` (no metadata shape change; all changes are orchestrator instructions and helpers)

**Per-ticket changes:**

```bash
TICKET_DIR=.doer/tickets/<TICKET-ID>
META=$TICKET_DIR/metadata.json

# 1. Bump skill_version to 6.6.0. No metadata rewrite needed.
#    Narrate: "Migration 6.5.1 -> 6.6.0, step 1/1: bumping skill_version to 6.6.0."
jq '.skill_version = "6.6.0"' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
```

**Important migration notes:**

- Cost tracking moved from `cost.sh record` (per-Agent return) to transcript reconciliation as the source of truth. The Claude Code Agent tool does not expose token counts in its `tool_result`, so `record` was effectively a no-op; `cost-transcript.sh reconcile` now builds `by_model` / `by_agent` / `by_stage` from the session JSONLs. `record` is retained only for backward compatibility.
- New orchestrator obligation: when dispatching any Agent, set its `description` to the convention `doer:s<N>:<role> | <free text>`. Without it the call still counts toward totals but lands under `unassigned`. No backfill: in-flight tickets reconcile fine; stages dispatched before 6.6.0 without the prefix simply group under `unassigned`.
- `cost-transcript.sh` is now resilient to jq version differences (renamed a reserved-word variable that broke on macOS jq 1.6) and degrades to exit 0 on any jq failure (true best-effort; a compile error no longer aborts wrapup).
- Stage 7 (runtime-verify) log injection now targets the full vertical slice (entry -> boundary -> observable result) instead of anchoring on the diff, with no file-count cap. Orchestrator-side; takes effect on the next Stage 7 run.
- Phase 2 auto-reverify is a no-op (`affected_stages: []`).

The behavioral changes apply on the next `/wk:doer <ID>` invocation.

### Migration: From 6.6.0 -> 6.7.0

`affected_stages: []` (no metadata shape change; all changes are orchestrator instructions and prompts)

**Per-ticket changes:**

```bash
TICKET_DIR=.doer/tickets/<TICKET-ID>
META=$TICKET_DIR/metadata.json

# 1. Bump skill_version to 6.7.0. No metadata rewrite needed.
#    Narrate: "Migration 6.6.0 -> 6.7.0, step 1/1: bumping skill_version to 6.7.0."
jq '.skill_version = "6.7.0"' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
```

**Important migration notes:**

- No data backfill. All changes are prompt and protocol text: the AC-N leak prohibition in Stage 3 writers, the new Stage 5 Check D (deterministic `AC-N` grep), the AskUserQuestion-vs-plain-chat rule in `lib/narration.md`, the intake question restructure, and the Stage 4 gate option-count fix. They take effect on the next stage that runs them.
- Stage 5 gains a deterministic Check D that BLOCKS when an internal `AC-N` label leaks into a source or test file. In-flight tickets whose Stage 5 already passed are not retroactively re-checked; the check runs on the next Stage 5 entry.
- Phase 2 auto-reverify is a no-op (`affected_stages: []`).

The behavioral changes apply on the next `/wk:doer <ID>` invocation.

### Migration: From 6.7.0 -> 6.8.0

`affected_stages: []` (no metadata shape change; all changes are orchestrator instructions and prompts)

**Per-ticket changes:**

```bash
TICKET_DIR=.doer/tickets/<TICKET-ID>
META=$TICKET_DIR/metadata.json

# 1. Bump skill_version to 6.8.0. No metadata rewrite needed.
#    Narrate: "Migration 6.7.0 -> 6.8.0, step 1/1: bumping skill_version to 6.8.0."
jq '.skill_version = "6.8.0"' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
```

**Important migration notes:**

- No data backfill. All changes are prompt and protocol text: new Core Principle 10 (internal orchestration vocabulary never reaches team-facing artifacts), the comment-economy rule in the Stage 4 code-writer prompt, the "tighten comment means shorten" clarification in `lib/loop.md`, the comment-economy axis in the Stage 5 reviewer scope, and the Stage 9 anti-leak rules plus the post-generation validation grep on the recommended commit message and PR description. They take effect on the next stage that runs them.
- Stage 9 now grep-validates the recommended commit message (step 7) and the PR description (step 8) for leaked internal labels (`AC-N`, `DOER`, `doer(`), mirroring the Stage 5 Check D that already guards committed code. In-flight tickets whose Stage 9 already produced those artifacts are not retroactively re-checked; the validation runs on the next Stage 9 entry.
- Phase 2 auto-reverify is a no-op (`affected_stages: []`).

The behavioral changes apply on the next `/wk:doer <ID>` invocation.

### Migration: From 6.5.0 -> 6.5.1

`affected_stages: []` (no metadata shape change; all changes are orchestrator instructions and helpers)

**Per-ticket changes:**

```bash
TICKET_DIR=.doer/tickets/<TICKET-ID>
META=$TICKET_DIR/metadata.json

# 1. Bump skill_version to 6.5.1. No metadata rewrite needed.
#    Narrate: "Migration 6.5.0 -> 6.5.1, step 1/1: bumping skill_version to 6.5.1."
jq '.skill_version = "6.5.1"' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
```

**Important migration notes:**

- No data backfill. All changes are orchestrator-side behavioral improvements; they take effect on the next stage dispatch.
- In-flight `direct` mode tickets that already passed Stage 3 may have a stale `last_green_sha`; Stage 6 will re-run tests once on next touch, then the fix takes effect from the next ticket onward.
- Phase 2 auto-reverify is a no-op (`affected_stages: []`).

The behavioral changes apply on the next `/wk:doer <ID>` invocation.

### Migration: From 6.4.0 -> 6.5.0

`affected_stages: []` (no metadata shape change; protocol changes are in orchestrator instructions only)

**Per-ticket changes:**

```bash
TICKET_DIR=.doer/tickets/<TICKET-ID>
META=$TICKET_DIR/metadata.json

# 1. Bump skill_version to 6.5.0. No metadata rewrite needed.
#    Narrate: "Migration 6.4.0 -> 6.5.0, step 1/1: bumping skill_version to 6.5.0."
jq '.skill_version = "6.5.0"' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
```

**Important migration notes:**

- No data backfill. The per-stage cost recording instructions (Stages 1–5, 7, 8) are orchestrator-side; they take effect on the next Agent dispatch in any stage. In-flight tickets that already completed stages before 6.5.0 will simply have no `cost.sh record` entries for those stages, which is already the normal pre-6.5.0 behavior.
- The `cost.sh status` orchestrator-only render path activates automatically when `total_usd == 0` but a transcript exists; no migration step required.
- Phase 2 auto-reverify is a no-op (`affected_stages: []`).

The behavioral changes apply on the next `/wk:doer <ID>` invocation.
