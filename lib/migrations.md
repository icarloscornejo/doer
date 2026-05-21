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
3. If the ticket is `complete` and there are reverify candidates, ask ONCE:
   ```
   Ticket already complete. SKILL upgraded to <X.Y.Z>; <N> stages changed
   behavior since this ticket finished:
   <list>
   Re-verify them now? [Y/n]
   ```
   If `n` → narrate, do nothing else. If `Y` → run spot-checks (next bullet).
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
| 7 runtime-verify | CANNOT auto-rerun (needs device + dev). Ask: *"Stage 7 changed behavior in <X.Y.Z>. Re-exercise on device? [Y/n]"*. If n, mark `verified_with: <new>` with note `dev_acknowledged_skip`. |
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
- **Em-dashes globally prohibited (Core Principle 9).** Zero `—` characters in any chat output, narration, artifact, commit message, PR description, comment, or anything the orchestrator or its subagents write. Subagent prompts must include the rule.

**Loop-latency optimization (the big one):**
- **`context.md` persistent scratch.** Iter 1 doer now writes a small `context.md` (touched paths, key signatures, module boundaries, decisions baked in). Iter 2+ agents read this instead of re-exploring the codebase. Biggest single latency win in the loop.
- **Read budgets per role.** Each sub-agent prompt now declares a soft file-read budget (iter 1 doer ≤15, iter 1 reviewer ≤5 for spot checks, iter 2+ combined ≤3 in BLOCKER targets, AUTO_FIX fixer 0 exploration).
- **Iter 2+ uses ONE combined "fixer-reviewer" agent.** Instead of two sequential calls (doer → reviewer), iter 2+ runs a single agent that fixes BLOCKERs and self-reviews the fixes. Halves the calls on the convergence tail. Iter 1 keeps the fresh-eyes review pass.

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
