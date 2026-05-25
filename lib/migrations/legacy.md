# Legacy Migrations (pre 5.0.0)

Reference-only. Loaded by the Migration Check ONLY when `metadata.skill_version < 5.0.0`. Active tickets (5.0.0+) never hit this file.

The protocol header (Phase 1, Phase 2, narration rules, Bash forcing rule) lives in `${CLAUDE_PLUGIN_ROOT}/lib/migrations.md`. This file ONLY contains the per-version migration blocks. Walk them in order: each block bumps `metadata.skill_version` to its `to`, then the walker re-evaluates against the next block. Stop when `metadata.skill_version >= 5.0.0`; control returns to `migrations.md` for the live blocks.

---

### Migration: From 1.x → 2.0.0

`affected_stages: [all]`. Every stage was renumbered or restructured.

Major bump: stage 5 (Reflect) removed, stages renumbered, several artifact files consolidated.

**Per-ticket changes:**

```bash
TICKET_DIR=.doer/tickets/<TICKET-ID>
META=$TICKET_DIR/metadata.json

# 1. Move ticket.md → metadata.raw (if ticket.md exists)
if [ -f "$TICKET_DIR/ticket.md" ]; then
  # Parse the markdown into description, raw_acs, context (regex on the section headings).
  # Write into metadata.json under "raw": {description, raw_acs, context}.
  # Then: rm "$TICKET_DIR/ticket.md"
fi

# 2. Renumber stages in metadata.stages
#    OLD → NEW: 6→5 (code-review), 7→6 (quality-gate), 8→7 (runtime-verify),
#               9→8 (docs-sync), 10→9 (wrapup)
#    Stage 5 (reflect) is dropped from the active map. If it had status="complete",
#    move it to metadata.deprecated_stages.reflect (preserve history). If pending,
#    just remove it.

# 3. Renumber metadata.current_stage
#    1,2,3,4 → unchanged
#    5 (reflect, pending) → 5 (code-review)   # skip the deprecated stage
#    6 → 5, 7 → 6, 8 → 7, 9 → 8, 10 → 9

# 4. Consolidate per-iteration review files into one per stage:
#    review/plan-review-1.md + plan-review-2.md + ... → review/plan-review.md
#    Same for tests-review-N.md and code-review-N.md.
#    Each old file becomes a "## Iteration N" section in the consolidated file.
#    Then: rm the old per-iteration files.

# 5. Orphaned files, leave on disk as historical (do NOT delete):
#    reflect.md, runtime-logs-added.md, runtime-log-output.txt, performance.md
#    The new pipeline doesn't reference them; they're inert.

# 6. Set metadata.skill_version = "2.0.0"
```

**Repository-level cleanup** (orchestrator does this once per repo if needed):
- Lessons in `.doer/knowledge/lessons/` already migrated by Workspace Guard step 5 (existing rule).

### Migration: From 2.0.0 → 2.1.0

`affected_stages: [2, 3, 4, 5]`. The format change to `plan.md` and `changelog.md` affects every stage that reads them.

MINOR bump that compacted `plan.md` and `changelog.md` formats. Existing tickets must be re-formatted so their downstream reads (test-writer, code-writer, reviewers) consume the cheaper format.

**Per-ticket changes:**

```bash
TICKET_DIR=.doer/tickets/<TICKET-ID>

# 1. Reformat plan.md if it exists and is not already compact.
#    Detect "already compact": presence of "## Files" with a markdown table
#    on the next non-empty line. If absent, run the format-converter agent:
if [ -f "$TICKET_DIR/plan.md" ] && ! grep -qE '^## Files' "$TICKET_DIR/plan.md"; then
  # Invoke a general-purpose agent with this prompt:
  #   "Read $TICKET_DIR/plan.md (verbose 1.x format).
  #    Re-write it IN-PLACE using the compact 2.1.0 format defined in
  #    Stage 2's planner prompt: ## Files (table), ## Steps (numbered
  #    bullets with file:line refs), ## Tests (bullets), ## Risks
  #    (bullets), ## Assumptions (bullets). Preserve EVERY piece of
  #    information from the original, only the shape changes.
  #    Do NOT add new content, do NOT drop content, do NOT reinterpret.
  #    Output only the rewritten file content."
fi

# 2. Reformat changelog.md if it exists and is not already compact.
#    Detect "already compact": every "## Iteration" section is followed
#    by bullets, no prose paragraphs. If prose detected, invoke same
#    agent with the changelog format (see Doer/Reviewer Loop Pattern
#    "Changelog file" subsection).

# 3. Set metadata.skill_version = "2.1.0"
```

**Notes:**
- The format-converter agent is a one-shot reformatter; it must NOT add or remove information.
- If reformatting fails (parse error, agent unsure), leave the file untouched and bump `skill_version` anyway. The verbose format is still readable; cost optimization just doesn't apply to that ticket.
- Tickets with no `plan.md` or `changelog.md` (early stages, e.g. just past intake) are no-ops for those steps.

### Migration: From 2.1.0 → 2.2.0

`affected_stages: []`. Orchestration / turn-boundary behavior only; no per-stage logic changed.

MINOR bump that changes orchestrator BEHAVIOR only, no file changes:
- An entire loop iteration (doer + reviewer + AUTO_FIX) now runs in a single turn. Previously each Agent call was its own turn. Fixes broken auto-resume in VS Code/IDE plugins.
- `/doer pause` removed. State persists after every Agent return; abandoning the session = pausing.

**Per-ticket changes:** none. Just bump `metadata.skill_version` to "2.2.0". The orchestrator's NEW behavior takes effect on the next iteration.

```bash
# 1. Set metadata.skill_version = "2.2.0"
# That's it. No file rewrites, no structural changes.
```

The `metadata.status` field continues to use `"in_progress"` and `"complete"`. The `"paused"` value, if present from old tickets, is treated as equivalent to `"in_progress"` (resume-able). New tickets never write `"paused"`.

### Migration: From 2.2.0 → 2.3.0

`affected_stages: [3, 5, 7]`. Test-writer (Stage 3), code-reviewer (Stage 5), runtime-logger / cleanup (Stage 7).

MINOR bump that tightens behavior in three places, no file format changes, no structural changes:
- Stage 7 runtime-logger: stricter "DO NOT" list (no variables-just-to-log, no refactors-to-enable-logging, no helpers). Stage 7 cleanup adds a post-revert drift check that scans the diff for non-log debug artifacts (variables, helpers, structural changes) that survive a clean revert.
- Stage 3 test-writer: prohibits `RED:` / `TDD red:` / "fails because X" comments. Stage 5 code-reviewer checklist now flags any residual ones as AUTO_FIX (mechanical removal).
- Stage boundaries: removed two narration templates that asked "Continue? [Y/n]" between stages (Stage 1 finalization + `/doer continue` resume). Hardened the no-prompt rule with explicit right/wrong examples. Stages auto-chain; the only stop is a halt signal in the next message.

**Per-ticket changes:** none. Just bump `metadata.skill_version` to "2.3.0". The orchestrator's stricter behavior takes effect on the next subagent invocation.

```bash
# 1. Set metadata.skill_version = "2.3.0"
# No file rewrites; the new prompts apply on the next agent call.
```

### Migration: From 2.3.0 → 2.4.0

`affected_stages: [1, 2, 3, 4, 5]`. Locale scope, intake reshape, Stage 1 confirmations, loop pattern overhaul (context.md + budgets + iter 2+ combined), Stage 3/4/5 pre-checks.

MINOR bump bundling several behavior changes, intake simplification, a hard global rule, and a loop-latency optimization pass. No persistent file format changes.

**Behavior + UX:**
- **Locale scope corrected.** When operating locale is not English, ONLY the live chat is in that locale. All persistent artifacts (`ac.md`, `plan.md`, `changelog.md`, review files, `wrapup.md`, lessons, JSON values, commit messages) are ALWAYS in English. Subagent prompt instruction updated accordingly.
- **Intake simplified.** The "What type is it?" question (feature / bug / refactor / other) was removed. The `type` field no longer exists in `metadata.json`. Nothing read it; ceremonial.
- **Pre-existing-work questions moved to intake.** The "Have you done prior work?" question and its 4 follow-ups (plan / tests / code / docs) used to live in Stage 1. Now captured during intake and persisted under `metadata.raw.prior_work`. Stage 1 reads from metadata; never re-asks.
- **Single entry-point command.** `/doer <TICKET-ID>` now handles both start and resume automatically (detected by metadata.json presence). `/doer continue <ID>` and `/doer start <ID>` are accepted as backward-compat aliases (the verb is parsed and ignored).
- **Stage 1 confirmations consolidated.** Down from 4 confirms to 1-2 (entry stage if applicable, plus a single combined "ACs + Out of Scope + Open Questions" approval).
- **PR helper at wrapup.** After the recommended commit message, the orchestrator offers to fill in a PR description (paste your template, ask for `default`, or `skip`).
- **Em-dashes globally prohibited (Core Principle 9).** Zero em-dash characters in any chat output, narration, artifact, commit message, PR description, comment, or anything the orchestrator or its subagents write. Subagent prompts must include the rule.

**Loop-latency optimization (the big one):**
- **`context.md` persistent scratch.** Iter 1 doer now writes a small `context.md` (touched paths, key signatures, module boundaries, decisions baked in). Iter 2+ agents read this instead of re-exploring the codebase. Biggest single latency win in the loop.
- **Read budgets per role.** Each sub-agent prompt now declares a soft file-read budget (iter 1 doer <=15, iter 1 reviewer <=5 for spot checks, iter 2+ combined <=3 in BLOCKER targets, AUTO_FIX fixer 0 exploration).
- **Iter 2+ uses ONE combined "fixer-reviewer" agent.** Instead of two sequential calls (doer -> reviewer), iter 2+ runs a single agent that fixes BLOCKERs and self-reviews the fixes. Halves the calls on the convergence tail. Iter 1 keeps the fresh-eyes review pass.

**Per-ticket changes:**

```bash
# 1. If metadata.json has a "type" field, remove it (purely cosmetic cleanup).
#    The orchestrator no longer references it.
# 2. If metadata.raw lacks a "prior_work" object, initialize it as
#    { "exists": false, "plan": null, "tests": null, "code": null, "docs": null }.
#    Old tickets that had been answered live in Stage 1 do not need backfill;
#    Stage 1 already passed.
# 3. Set metadata.skill_version = "2.4.0"
```

`context.md` is generated organically the next time iter 1 of a looped stage runs. No backfill needed for tickets already past iter 1; those continue with the old re-exploration cost on iter 2+ until wrapup. Negligible.

The behavioral changes apply on the next chat turn or subagent call.

### Migration: From 2.4.0 → 2.10.0

`affected_stages: [all]`. This release introduces per-stage `verified_with` tracking and Phase 2 of the Migration Check (auto-reverify). Every stage gains a new field; every future migration block declares which stages it touched.

Big version jump (2.4.0 → 2.10.0) signals the size of the change. SemVer-strict it is still MINOR (additive, no breaking), but the per-stage reverify is a structural shift in how doer treats SKILL upgrades.

**What this bump adds:**
- **Per-stage `verified_with` field.** Every stage that completes (or is marked skipped/imported) records the SKILL version that verified it.
- **`affected_stages` field on every migration block.** Lists which stages changed runtime behavior in that bump. Used by the auto-reverify mechanism.
- **Migration Check Phase 2.** After applying file/data migrations, the orchestrator computes the union of `affected_stages` across all migrations applied this run, looks up each affected stage's `verified_with`, and runs spot-checks (lightweight per-stage validation, see Phase 2 spec) on completed stages whose verification is stale.
- **Auto-reverify behavior:**
  - Ticket `in_progress`: spot-checks run automatically before resume.
  - Ticket `complete`: orchestrator asks once if the dev wants to reverify.
  - Spot-checks that find new BLOCKERs reopen the ticket at the affected stage.
- **`/doer verify` command stays as escape hatch** for the rare case the dev wants to force a reverify when version matches.

**Per-ticket changes:**

```bash
# 1. For each existing stage in metadata.stages where status is one of
#    ("complete", "skipped", "imported"), set verified_with = "2.4.0"
#    (the version they were last validated under, since this bump is the
#    first to introduce the field).

# 2. Set metadata.skill_version = "2.10.0"
```

After the bump, the next `/doer <TICKET-ID>` triggers Phase 2: it looks up the union of `affected_stages` across the chain of migrations the ticket walked through this run (in 2.4.0 → 2.10.0 case: just `[all]`). Spot-checks fire on all completed stages of in-flight tickets, or behind a one-time prompt for completed tickets.

The behavioral changes apply on the next `/doer <ID>` invocation.

### Migration: From 2.10.0 → 3.0.0

`affected_stages: [all]`. Structural overhaul: every per-ticket `.md` artifact is consolidated into `metadata.json` as structured fields, Stages 2 and 3 lose their doer/reviewer loops (single-pass + deterministic checks + single retry), Stages 4 and 5 keep loops but cap at 3 iterations (was 5), `context.md` is eliminated, sub-agents now receive metadata slices inlined in their prompts. **Stage 7 silent auto-skip is REMOVED**; Stage 7 now always asks the dev, even when the diff is 100% non-runtime (the classification only picks the default option in the prompt). **New `mode: lite | full` field**; migrated tickets default to `mode: "full"`. Lite mode is opt-in for new tickets via the intake heuristic + dev confirmation.

**MAJOR bump.** Removes/renames artifact files, changes metadata shape. Both Phase 1 (file/data migration) and Phase 2 (auto-reverify) execute on first `/doer <TICKET-ID>` after upgrade.

**Per-ticket changes:**

**Narration requirement** (per Core Principle 1): the orchestrator MUST narrate before EACH numbered step below, e.g. *"Migration 2.10.0 → 3.0.0, step 1/11: stashing existing .md files..."*. Do NOT execute the bash block silently. After the last step, narrate ONE summary line: *"Migrated ticket 2.10.0 → 3.0.0: 11 steps, N files parsed, M files dropped."*

**Parser agent read budget**: every parser agent invoked in steps 2-6 below MUST receive the explicit instruction *"Read budget: exactly 1 file (the one named in your prompt). No directory listings, no exploration of related files. If the named file is missing or unreadable, fail fast and let the orchestrator handle it."* Each parser is one-shot, single-file. Exploration is wasted tokens.

```bash
TICKET_DIR=.doer/tickets/<TICKET-ID>
META=$TICKET_DIR/metadata.json

# 1. Stash existing .md files for safe rollback if any parser fails.
#    Narrate: "Step 1/11: stashing .md files for rollback safety."
git -C "$TICKET_DIR" stash push -m "doer-3.0.0-migration-stash" 2>/dev/null || true
# (.doer/ is gitignored locally; stash is a fallback only when the dev had committed it.)

# 2. Parse ac.md → metadata.ac (one-shot LLM parser agent).
if [ -f "$TICKET_DIR/ac.md" ]; then
  # Invoke a general-purpose agent with this prompt:
  #   "Read $TICKET_DIR/ac.md (sections: ## In Scope, ## Out of Scope,
  #    ## Open Questions (resolved), ## Applicable Lessons).
  #    Convert to JSON matching this schema:
  #    {
  #      \"in_scope\": [\"<full Given/When/Then string>\", ...],
  #      \"out_of_scope\": [\"<item>\", ...],
  #      \"open_questions_resolved\": [{\"question\": \"...\", \"answer\": \"...\"}],
  #      \"applicable_lessons\": [\"<slug>\", ...]
  #    }
  #    Output ONLY the JSON. Preserve every line of content; do not summarize."
  # Validate: in_scope is a non-empty array of strings.
  # On success: persist into metadata.ac. Then: rm "$TICKET_DIR/ac.md".
  # On parse failure: leave ac.md in place, narrate the error, continue
  # the migration of the other files. The dev will hand-fix.
fi

# 3. Parse plan.md → metadata.plan (one-shot LLM parser agent).
if [ -f "$TICKET_DIR/plan.md" ]; then
  # Agent prompt:
  #   "Read $TICKET_DIR/plan.md (sections: ## Files (markdown table),
  #    ## Steps (numbered list), ## Tests (bullets), ## Risks (bullets),
  #    ## Assumptions (bullets)). Convert to JSON:
  #    {
  #      \"files\":  [{\"path\":\"...\",\"change\":\"edit|new|delete\",\"reason\":\"...\"}],
  #      \"steps\":  [{\"order\":N,\"verb\":\"...\",\"what\":\"...\",\"where\":\"<file>:<lines>\"}],
  #      \"tests\":  [{\"name\":\"...\",\"covers\":[\"AC-N\"],\"what\":\"...\"}],
  #      \"risks\":  [{\"risk\":\"...\",\"mitigation\":\"...\"}],
  #      \"assumptions\": [\"...\"]
  #    }
  #    Output ONLY the JSON. Preserve every item."
  # Validate: files/steps/tests/risks are arrays; assumptions is an array (may be empty).
  # On success: persist into metadata.plan. Then: rm "$TICKET_DIR/plan.md".
fi

# 4. Parse changelog.md → metadata.changelog (one-shot LLM parser agent).
if [ -f "$TICKET_DIR/changelog.md" ]; then
  # Agent prompt:
  #   "Read $TICKET_DIR/changelog.md. Each '## Iteration N. <stage> (<initial|fixes>)'
  #    section becomes one entry. Convert to JSON array:
  #    [
  #      {\"stage\":N,\"iteration\":N,\"kind\":\"initial|fixes\",
  #       \"items\":[{\"type\":\"decision|step|fix|auto_fix\",\"text\":\"...\",
  #                   \"blocker_id\":\"<optional>\",\"id\":\"<optional>\"}]}
  #    ]
  #    Map old bullets: 'Decision: X' -> {type:decision,text:X};
  #    'Fix #B-N: X' -> {type:fix,blocker_id:B-N,text:X};
  #    'AutoFix #AF-N: X' -> {type:auto_fix,id:AF-N,text:X};
  #    everything else -> {type:step,text:X}.
  #    Output ONLY the JSON array. Preserve order."
  # On success: persist into metadata.changelog. Then: rm "$TICKET_DIR/changelog.md".
fi

# 5. Parse review/code-review.md → metadata.code_review (one-shot LLM parser).
if [ -f "$TICKET_DIR/review/code-review.md" ]; then
  # Agent prompt:
  #   "Read $TICKET_DIR/review/code-review.md. Each '## Iteration N' section becomes
  #    one entry. Convert to JSON array per the metadata.code_review schema documented
  #    in Knowledge & State Layout. Output ONLY the JSON array."
  # On success: persist into metadata.code_review. Then: rm the file.
fi

# 6. Parse wrapup.md (if ticket was already complete pre-migration).
if [ -f "$TICKET_DIR/wrapup.md" ]; then
  # Agent prompt:
  #   "Read $TICKET_DIR/wrapup.md. Extract:
  #    - assumptions_validation: from '## Assumptions' section, each '- X -> STATUS: reason'
  #      becomes {text:X, status:STATUS, reason:reason or null}.
  #    - lessons_captured: from '## Lessons captured', each '- [slug], takeaway'
  #      becomes {slug:slug, takeaway:takeaway}.
  #    - summary: a one-paragraph synthesis of the wrapup file (or first paragraph if present).
  #    - performance: from '## Performance' section, parse into the metadata.performance
  #      schema documented in Knowledge & State Layout.
  #    Output JSON: {assumptions_validation:[...], lessons_captured:[...], summary:'...', performance:{...}}."
  # Persist into the four metadata fields. Then: rm "$TICKET_DIR/wrapup.md".
fi

# 7. Drop deprecated files unconditionally (no parsing needed):
rm -f "$TICKET_DIR/context.md"
rm -f "$TICKET_DIR/review/plan-review.md"
rm -f "$TICKET_DIR/review/tests-review.md"
rm -f ".doer/knowledge/assumptions/<TICKET-ID>.md"

# 8. Clean up empty review/ subdir (if all review files were removed):
rmdir "$TICKET_DIR/review" 2>/dev/null || true

# 9. Reset Stage 2 / Stage 3 if they were mid-loop (loops no longer exist for these stages):
#    For each of stages.2 and stages.3:
#    if status == "in_progress" AND iterations field exists with value > 1:
#      set status = "pending"
#      remove iterations, blockers, etc. (loop-specific fields)
#      Stage will re-run as single-pass when /doer <ID> resumes.

# 10. Set metadata.mode = "full" (migrated tickets default to full to preserve their existing pipeline behavior; v3.0.0 lite mode is opt-in for new tickets at intake).

# 11. Set metadata.skill_version = "3.0.0"
```

**Important migration notes:**

- The LLM parser agents are one-shot and operate per-file. If any agent fails (returns invalid JSON, refuses, etc.), the orchestrator narrates the failure for that file but continues with the others. The dev can run `/doer <ID>` again after fixing the offending file by hand (or accept that the field will be empty until they re-run the corresponding stage).
- Validation is structural only (right shape, right types). The orchestrator does NOT semantically validate that the parsed content matches the original; that is the dev's responsibility if they want to spot-check after migration.
- Stage 2 / Stage 3 reset (step 9) only applies to in-flight tickets that were stuck mid-loop. Tickets where Stage 2/3 already completed under the old loop (status=`complete`) remain `complete`; the auto-reverify (Phase 2) will spot-check them via the new deterministic checks.
- All file deletions in step 7 are safe: those files are no longer read by any code path.

After Phase 1 finishes, Phase 2 auto-reverify runs (because `affected_stages: [all]`). For in-flight tickets the spot-checks fire automatically; for complete tickets the orchestrator asks once per the standard prompt.

The behavioral changes apply on the next `/doer <ID>` invocation.

### Migration: From 3.0.6 -> 4.0.0

`affected_stages: [1, 3, 4]`

MAJOR bump. Adds unified `testing_strategy` + pipeline_mode inference at intake (single combined confirm replaces the standalone lite/full question), branches Stage 3 into three modes (direct, tdd, bdd), introduces a new `deferred` status for Stage 3 (used only in `direct` mode, where Stage 3 runs AFTER Stage 4), makes Stage 4 strategy-aware, and adds new persistent fields to `metadata.json` (`testing_strategy`, `mode_overridden_by_dev`, `metadata.stages.3.testing_strategy_mode`).

Why MAJOR: `metadata.json` shape changes (new top-level field, new per-stage field, new `deferred` value in the `status` enum); the Stage 3 state machine changes (a stage may now run after a later-numbered stage). Both Phase 1 (file/data migration) and Phase 2 (auto-reverify) execute on first `/doer <TICKET-ID>` after upgrade.

This block also covers any 3.0.x source via Phase 1 case 5 silent bump, then Phase 1 case 4 matches `from: 3.0.6` to apply the changes below. Patch versions 3.0.0 through 3.0.6 silently bump to 3.0.6 first.

**Per-ticket changes:**

```bash
TICKET_DIR=.doer/tickets/<TICKET-ID>
META=$TICKET_DIR/metadata.json

# Narrate before each step (per Core Principle 1).

# 1. Add metadata.testing_strategy with default tdd (preserves existing TDD-red behavior).
#    Narrate: "Migration 3.0.6 -> 4.0.0, step 1/3: defaulting testing_strategy to tdd for backward compatibility."
#    Idempotent: skip if metadata.testing_strategy already exists.
jq '.testing_strategy //= {
  "mode": "tdd",
  "rationale": "pre-existing ticket, defaulting to tdd for backward compatibility",
  "signals": ["migrated"],
  "overridden_by_dev": false
}' "$META" > "$META.tmp" && mv "$META.tmp" "$META"

# 2. Add metadata.mode_overridden_by_dev = false if absent (cosmetic flag, prior tickets
#    accepted the suggested mode without an explicit override marker).
jq '.mode_overridden_by_dev //= false' "$META" > "$META.tmp" && mv "$META.tmp" "$META"

# 3. Backfill metadata.stages.3.testing_strategy_mode = "tdd" if Stage 3 exists.
#    Idempotent: leave alone if already set.
jq '
  if (.stages | has("3")) and (.stages."3" | has("testing_strategy_mode") | not)
  then .stages."3".testing_strategy_mode = "tdd"
  else . end
' "$META" > "$META.tmp" && mv "$META.tmp" "$META"

# 4. Set metadata.skill_version = "4.0.0".
jq '.skill_version = "4.0.0"' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
```

**Important migration notes:**

- No file rewrites. The new branches and prompts apply on the next chat turn or subagent call.
- Tickets currently mid-Stage 3 (`status == "in_progress"` or `status == "blocked"`) keep their existing TDD-red contract because `testing_strategy.mode = "tdd"`. Phase 2 auto-reverify spot-checks Stage 3 with the same three deterministic checks (parse/run, plan-driven presence, TDD red verified) it used before; nothing changes for them.
- Tickets that have already completed Stage 3 keep `testing_strategy_mode = "tdd"`. They never use the `direct` deferred path.
- `deferred` is a new value in the Stage 3 `status` enum. Existing tickets never use it (their migration default is `tdd`). Only NEW tickets created after upgrade can land in `deferred` (when intake infers `direct`).

The behavioral changes apply on the next `/doer <ID>` invocation.

### Migration: From 4.0.1 -> 5.0.0

`affected_stages: [1, 3, 4, 5, 8, 9]`

MAJOR bump. Removes `metadata.mode` (lite/full pipeline mode) and `metadata.mode_overridden_by_dev`; collapses the testing_strategy enum from {direct, tdd, bdd} to {direct, bdd}. Pipeline always runs in what was previously called 'full'. Tickets with `testing_strategy.mode == "tdd"` are auto-rewritten to `"bdd"` with narration; bdd's red-phase contract has the same shape (failing tests first, deterministic parse/run + presence + red-phase check), so in-flight Stage 3 keeps its operational semantics.

Why MAJOR: schema-breaking. Top-level `mode` and `mode_overridden_by_dev` fields are removed; `testing_strategy.mode` enum is reduced; `stages.3.testing_strategy_mode` enum is reduced.

This block also covers any 4.0.x source via silent patch bump first (Phase 1 case 5), then matches `from: 4.0.1` to apply the changes below.

**Per-ticket changes:**

```bash
TICKET_DIR=.doer/tickets/<TICKET-ID>
META=$TICKET_DIR/metadata.json

# Narrate before each step (per Core Principle 1).

# 1. Rewrite testing_strategy.mode "tdd" -> "bdd" if present.
#    Narrate: "Migration 4.0.1 -> 5.0.0, step 1/4: rewriting testing_strategy.mode from tdd to bdd."
jq '
  if .testing_strategy.mode == "tdd"
  then .testing_strategy.mode = "bdd"
     | .testing_strategy.rationale = "auto-rewritten from tdd during 5.0.0 migration; bdd red-phase contract is equivalent"
  else . end
' "$META" > "$META.tmp" && mv "$META.tmp" "$META"

# 2. Rewrite stages.3.testing_strategy_mode "tdd" -> "bdd" if present.
#    Narrate: "Migration 4.0.1 -> 5.0.0, step 2/4: rewriting stages.3.testing_strategy_mode from tdd to bdd."
jq '
  if (.stages."3"?.testing_strategy_mode // null) == "tdd"
  then .stages."3".testing_strategy_mode = "bdd"
  else . end
' "$META" > "$META.tmp" && mv "$META.tmp" "$META"

# 3. Remove top-level mode and mode_overridden_by_dev fields.
#    Narrate: "Migration 4.0.1 -> 5.0.0, step 3/4: removing obsolete top-level fields mode and mode_overridden_by_dev."
jq 'del(.mode, .mode_overridden_by_dev)' "$META" > "$META.tmp" && mv "$META.tmp" "$META"

# 4. Bump skill_version to 5.0.0.
#    Narrate: "Migration 4.0.1 -> 5.0.0, step 4/4: bumping skill_version to 5.0.0."
jq '.skill_version = "5.0.0"' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
```

**Important migration notes:**

- Tickets mid-Stage 3 with `testing_strategy.mode == "tdd"` end up as `"bdd"`. The Stage 3 deterministic check (parse/run + plan-driven presence + red-phase verified) is the same shape; nothing changes operationally.
- Tickets that already completed Stage 3 with `testing_strategy_mode == "tdd"` are also rewritten to `"bdd"` for metadata consistency. The tests are already written and committed; only the metadata label changes.
- Tickets with `mode == "lite"` mid-pipeline lose the field and continue as the unified pipeline. No prior stages are mutated. If they were inside a Lite branch of Stage 4 or 5 and had not committed yet, the next turn places them on the standard convergence loop (max 3 iterations), which is strictly more permissive.
- `deferred` as a Stage 3 status value remains valid (used by `direct`).

The behavioral changes apply on the next `/doer <ID>` invocation.
