---
name: doer
description: >-
  Ticket execution orchestrator. Takes a pre-defined ticket (feature, bug,
  refactor) from acceptance criteria to implementation-ready code on a feature
  branch. Invoke with "/doer <TICKET-ID>" to start a new ticket, or use
  "/doer continue <TICKET-ID>", "/doer status <TICKET-ID>", "/doer list".
  Also activates implicitly when the user references an active /doer ticket
  in natural language (e.g. "continue", "pause", "keep going with ABC-123").
  Skips PRD, architecture design, ticket creation, PR assembly, and deployment.
  Keeps spec, plan, tests, code, review, docs, and lessons learned.
version: 3.0.5
user-invocable: true
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, AskUserQuestion, Agent]
---

# Doer. Ticket Execution Orchestrator

User-facing orchestrator for executing a single ticket end-to-end on a feature branch. Runs 9 sequential stages with doer/reviewer convergence loops. Narrates every action so the user can pause at any point. State persists on disk so work can be resumed across sessions.

**Scope:** one ticket, one branch, end-to-end implementation up to (but not including) PR and deploy.

**Out of scope:** PRD creation, architecture design, ticket creation, pull request assembly, CI, deployment. By design.

---

## Core Principles

1. **Narration first (every action, every decision).** The orchestrator narrates EVERY action it takes and EVERY internal decision it makes, not just stage transitions. This includes: before each tool call ("Reading X to determine Y"), before each Agent invocation ("Invoking parser agent because Z"), per-step progress in multi-step operations ("Step 3 of 11: parsing changelog.md..."), and reasoning the orchestrator would otherwise keep internal ("Detected X in metadata, doing Y because Z"). The user must NEVER face a silent stretch longer than a single tool call. Long-running operations (migration, multi-file logger injection, multi-iteration loops) MUST emit progress narration, not just a final summary. Output-token cost of narration is a tiny fraction of total ticket cost; the UX win of "the user can always pause" outweighs it. The user should be able to pause at any moment because they always know where the orchestrator is.
2. **One branch, one ticket**: All work happens on a single feature branch. Stages that produce real code commit it; stages that only produce `.doer/` artifacts do NOT commit (see principle 8).
3. **Delta-aware reviewers**: After iteration 1, reviewers receive prior findings + the last `metadata.changelog` entries from the doer (inlined in their prompt). They verify fixes and scan for new issues, rather than re-analyzing from scratch.
4. **Bounded loops**: Stages 4 (Code) and 5 (Code Review) loop with a max of **3 iterations**. Stages 2 (Plan) and 3 (Tests) are single-pass with one optional retry on deterministic-check failure. If still not converged after the cap or retry, the user decides.
5. **Lessons accumulate**: Every ticket captures what went well and what did not. Future tickets read those lessons before planning.
6. **No hidden state**: Everything the orchestrator knows lives in `./.doer/` on disk. Context compression never loses progress.
7. **All commits use `git commit --no-verify`.** Hard rule.
   - The orchestrator runs in developer mode, pre-commit hooks (linters, formatters, fast tests) interrupt flow mid-stage without value (agents may produce intermediate states that fail a hook but are correct for the stage).
   - Every commit and amend in the SKILL shows `--no-verify` explicitly (portable, no aliases needed).
   - **Dev runs real checks manually before PR** (`pre-commit run`, lint, full tests, etc.), then squashes/reorders and pushes. Orchestrator does not push.

8. **`.doer/` NEVER reaches the team's git history.** Non-negotiable.
   - Intake adds `.doer/` to `.git/info/exclude` (per-clone, never committed). The team sees nothing.
   - Commits MUST NOT include paths under `.doer/`. Use `git add <code-paths>` or `git add -A` (respects exclude). NEVER `git add .doer/...` (that bypasses the ignore).
   - Stages whose only output is `.doer/` (1 AC, 2 Plan, 9 Wrapup) SKIP the commit entirely. Stages with real code (3 Tests, 4 Code, 5 Review, 7 Runtime, 8 Docs) commit code only.
   - Stage 7 (Runtime Verify) temp commit + revert still works because it touches real source files, not `.doer/`.

9. **EM-DASHES ARE PROHIBITED.** Across every output the orchestrator and its subagents produce: chat narration, questions, summaries, every value persisted into `metadata.json` (string fields like `summary`, `changelog[].items[].text`, `ac.in_scope`, `plan.steps`, `code_review[].blockers[].text`), generated commit messages, generated PR descriptions, global lessons under `<doer-skill-dir>/lessons/`, comments injected into code. ZERO `, ` characters anywhere.
   - Use commas, periods, semicolons, parentheses, colons, or full sentence breaks instead.
   - Examples:
     - Wrong: `Stage 2 complete — proceeding to Stage 3.`
     - Right: `Stage 2 complete. Proceeding to Stage 3.`
     - Wrong: `Tests pass — all green.`
     - Right: `Tests pass. All green.`
     - Wrong: `Code review found 3 BLOCKERs — see metadata.code_review.`
     - Right: `Code review found 3 BLOCKERs (see metadata.code_review).`
   - This rule is a strong stylistic preference of the dev. The orchestrator and every subagent prompt MUST enforce it. When invoking any subagent, append: *"Em-dashes (`—`) are forbidden. Use commas, periods, or parentheses instead."*
   - Self-check before any output: scan for `—` (em-dash, U+2014) and `–` (en-dash, U+2013). If found, rewrite before sending.

---

## Context Continuity (Anti-Compaction)

The Claude Code harness compacts long conversations to fit in context. When that happens mid-pipeline, the orchestrator can lose: locale (drifts to English), narration discipline, schema knowledge (forgets which `metadata.stages.<N>` fields are required), full-SHA convention, Migration Check timing, and other rules baked into SKILL.md. Symptoms observed in prior tickets: abbreviated SHAs, missing `loop_outcome` / `iterations` / `started_at` fields, silent skips of Stage 7 ask-rule, locale flip from `es` to English, `metadata.skill_version` not bumped on PATCH upgrades.

### Heartbeat anchor

This SKILL contains a known anchor string the orchestrator must be able to quote verbatim from context:

> **DOER-HEARTBEAT-v3: every action narrated, every field validated, every SHA full-length, every Migration Check explicit.**

(That exact line. 18 words. Treat it as a checksum for context freshness.)

### Self-check protocol

At every **stage transition** AND at the start of every **`/doer continue` invocation** (which includes implicit resumes after natural-language messages), the orchestrator MUST perform a heartbeat self-check BEFORE doing anything else:

1. Self-question: *"Can I quote the DOER-HEARTBEAT anchor from my current context, verbatim?"*
2. If **YES** → context is fresh. Skip re-hydration. Continue normally.
3. If **NO** → context was compacted. Trigger **forced re-hydration** (next subsection) before doing anything else. Do NOT proceed to the stage logic until re-hydration completes.

The cost of the self-check itself is zero (pure reasoning, no tool call). The cost of re-hydration is paid only when compaction is detected, which is rare in normal operation.

### Forced re-hydration steps

When the heartbeat is missing, perform these reads BEFORE the next stage logic. Narrate each step (per Core Principle 1):

1. *"Compaction detected: heartbeat anchor missing from context. Re-hydrating."*
2. Read `<doer-skill-dir>/preferences.md` → re-establish operating locale. After reading, the orchestrator MUST immediately switch ALL output to the locale language. This is not a hint; it is a binding commitment for the rest of the session. Narrate the locale confirmation IN the target language as the very next sentence (e.g. if `locale: es`, write: `"Locale: es. Todo el output de ahora en adelante sera en espanol."`). If the next output line is in the wrong language, that is a VIOLATION of this rule. Locale drift after re-hydration is prohibited.
3. Read `./.doer/tickets/<TICKET-ID>/metadata.json` → re-establish ticket state, mode, current_stage, prior changelog/code_review entries.
4. Read the relevant section of `SKILL.md` for `metadata.current_stage` (e.g. if current_stage is 4, re-read the "Stage 4. Code" section). One section, not the whole file.
5. Read this Context Continuity section + the Versioning & Migrations section (Migration Check Phase 1 must run after re-hydration if `metadata.skill_version` is behind the SKILL frontmatter version).
6. Narrate in the locale language: *"Re-hydration complete. Resuming at Stage <N> (<name>) in <mode> mode, locale <locale>."* (This line MUST be in the locale language, not English.)
7. Run Migration Check Phase 1 + Phase 2 explicitly (see Versioning & Migrations).
8. Continue with the original stage logic.

This treats every detected compaction as if the dev had just typed `/doer continue <TICKET-ID>` from a fresh session. The goal is uniform behavior regardless of whether compaction happened.

**Locale self-check after re-hydration:** At the next stage transition after re-hydration, the orchestrator MUST ask itself: "Is my current output in the locale from preferences.md?" If not, stop, re-apply the locale, and continue. Locale is never optional once established.

### What re-hydration is NOT

- Not "re-read the entire SKILL on every turn" (too expensive).
- Not "re-read on every tool call" (too expensive).
- Not "always run on stage transition unconditionally" (wastes tokens when context is fresh).

The trigger is the heartbeat self-check at stage boundaries. That is all.

---

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
4. After every successful **forced re-hydration** (see Context Continuity section). Compaction can land mid-pipeline; the heartbeat-triggered re-hydration must re-run the Migration Check because the orchestrator may have lost track of `skill_version` mismatches.
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
| 2 plan | Re-run the three deterministic checks (file existence, AC coverage, assumptions present) on `metadata.plan`. No LLM. If a check fails, reopen Stage 2 with that BLOCKER. |
| 3 tests | Re-run the three deterministic checks (parse/run, plan-driven presence, TDD red verified). No LLM. |
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

---

## Commands

| Command | Description |
|---------|-------------|
| `/doer <TICKET-ID>` | Start a new ticket OR resume an existing one (auto-detected by metadata.json presence). |
| `/doer status <TICKET-ID>` | Show current stage, loop state, and blockers. |
| `/doer list` | List all tickets in `./.doer/tickets/`. |
| `/doer verify <TICKET-ID>` | Run stages that exist in the current skill but were missing when the ticket was closed. |
| `/doer cleanup-history <TICKET-ID>` | Strip any `.doer/` content from commits on the ticket's feature branch. Auto-runs at wrapup; this command lets you re-run it manually. |

**Backward compat:** `/doer continue <ID>`, `/doer start <ID>`, etc. are accepted as aliases, the verb is parsed and ignored. `/doer <ID>` always does the right thing.

**There is no `/doer pause`.** State persists automatically after every Agent return. To stop, just close the session or write `stop` / `wait` / `hold on`. To resume, `/doer continue <TICKET-ID>` from any future session.

**Stages cannot be skipped manually.** Every stage must run. The only way to skip stages is through Stage 1's pre-existing-work detection (see Stage 1 below). This is by design: the orchestrator decides which stages to skip, not the user.

**Implicit activation:** If the user writes natural language (e.g. "keep going", "pause here", "the plan looks good") and an active ticket exists in `./.doer/tickets/*/metadata.json` with `status == "in_progress"`, treat the message as a directive to the active orchestrator rather than a new query.

---

## Knowledge & State Layout

All state lives under `./.doer/` in the current working directory (scoped to the target repo).

**Lessons are GLOBAL**: they live next to `SKILL.md` (so all repos share the same accumulated knowledge). **Everything else is per-ticket and lives in a single `metadata.json` per ticket.** No markdown sidecars, no scratch files, no per-stage review files.

```
<doer-skill-dir>/                  # ~/src/doer/ in this install (resolve symlinks)
├── SKILL.md
├── preferences.md                 # local config (gitignored)
└── lessons/                       # GLOBAL, cross-project, gitignored
    └── {slug}.md

./.doer/                           # per-repo (in CWD), gitignored via .git/info/exclude
├── knowledge/                     # reserved for future cross-ticket data; empty by default
└── tickets/
    └── {TICKET-ID}/
        └── metadata.json          # SINGLE file per ticket: state + intake + ac + plan + changelog + code_review + assumptions + wrapup
```

**Per ticket: 1 file (`metadata.json`).** Everything (ac, plan, changelog, code review history, assumptions, lessons captured, summary, performance) lives as structured fields inside `metadata.json`. One source of truth, no drift, no file-coordination cost. Sub-agents receive the relevant slices of metadata inlined in their prompts; they do not read sidecar files.

### `metadata.json` schema (v3.0.0)

```json
{
  "ticket_id": "<ID>",
  "title": "<title>",
  "branch": "<branch>",
  "status": "in_progress | complete",
  "current_stage": 1,
  "skill_version": "3.0.0",
  "mode": "lite | full",
  "created_at": "<ISO8601>",
  "completed_at": null,

  "intake": {
    "description": "<full pasted description>",
    "raw_acs": "<full pasted ACs or 'derive'>",
    "context": "<extra context or 'none'>",
    "prior_work": { "exists": false, "plan": null, "tests": null, "code": null, "docs": null }
  },

  "ac": {
    "in_scope": ["AC-1: ...", "AC-2: ..."],
    "out_of_scope": ["..."],
    "open_questions_resolved": [{"question": "...", "answer": "..."}],
    "applicable_lessons": ["<lesson-slug>"]
  },

  "plan": {
    "files": [{"path": "...", "change": "edit | new | delete", "reason": "..."}],
    "steps": [{"order": 1, "verb": "...", "what": "...", "where": "<file>:<line-range>"}],
    "tests": [{"name": "...", "covers": ["AC-N"], "what": "..."}],
    "risks": [{"risk": "...", "mitigation": "..."}],
    "assumptions": ["..."]
  },

  "stages": {
    "1": {"name": "ac-confirm",     "status": "pending | in_progress | complete | skipped | imported | blocked | retroactive_in_progress", "verified_with": "3.0.0", "completed_at": "<ISO8601>"},
    "2": {"name": "plan",           "status": "...", "verified_with": "3.0.0", "retry_used": false},
    "3": {"name": "tests",          "status": "...", "verified_with": "3.0.0", "retry_used": false},
    "4": {"name": "code",           "status": "...", "verified_with": "3.0.0", "iterations": 0, "loop_outcome": "converged | accepted_with_residuals"},
    "5": {"name": "code-review",    "status": "...", "verified_with": "3.0.0", "iterations": 0, "loop_outcome": "..."},
    "6": {"name": "quality-gate",   "status": "...", "verified_with": "3.0.0"},
    "7": {"name": "runtime-verify", "status": "...", "verified_with": "3.0.0", "ac_verdicts": {}},
    "8": {"name": "docs-sync",      "status": "...", "verified_with": "3.0.0"},
    "9": {"name": "wrapup",         "status": "...", "verified_with": "3.0.0"}
  },

  "changelog": [
    {"stage": 2, "iteration": 1, "kind": "initial | fixes", "items": [
      {"type": "decision | step | fix | auto_fix", "text": "<one-line>", "blocker_id": "<optional, only for fix>", "id": "<optional, only for auto_fix>"}
    ]}
  ],

  "code_review": [
    {"iteration": 1, "blockers": [{"id": "B-1", "text": "..."}], "auto_fixes": [], "suggestions": [], "info": [], "verdict": "needs_revision | converged"},
    {"iteration": 2, "prior_blockers_resolved": ["B-1"], "prior_blockers_still_open": [], "new_blockers": [], "auto_fixes": [], "suggestions": [], "info": [], "verdict": "..."}
  ],

  "assumptions_validation": [{"text": "...", "status": "VALIDATED | INVALIDATED | UNVERIFIED", "reason": "..."}],
  "lessons_captured": [{"slug": "<lesson-slug>", "takeaway": "..."}],
  "summary": "<wrapup paragraph>",
  "performance": {"started": "...", "completed": "...", "wall_clock": "...", "active": "...", "stages": [], "code": {}, "agents": {}, "convergence": {}, "reviewer_roi": "..."},

  "blocking_conditions": [],
  "commits": [],
  "workspace_guard": "ok",
  "runtime_build_command": null,
  "lint_command": null,
  "typecheck_command": null,
  "test_command": null,
  "last_green_sha": null,
  "last_green_test_command": null
}
```

**Field ownership:** `intake` (intake step), `mode` (intake's final sub-step, after a heuristic suggestion + dev confirmation), `ac` (Stage 1), `plan` (Stage 2), `changelog` (every doer stage appends), `code_review` (Stage 5 appends), `assumptions_validation` / `lessons_captured` / `summary` / `performance` (Stage 9). The `stages` block is the state machine; the orchestrator updates per-stage `status`, `verified_with`, and stage-specific fields (`retry_used` for 2/3, `iterations`/`loop_outcome` for 4/5, `ac_verdicts` for 7).

**`mode` semantics.** `full` runs the complete pipeline as documented in each stage. `lite` is for trivial tickets (small diff, no architecture work, single area) and skips the heaviest Stage 9 ceremony, skips Stage 8 entirely, and forces single-pass behavior on Stage 4 and Stage 5 (no iter 2+, no convergence loop). See each stage's "Lite branch" subsection for the exact divergence. **`mode` is set ONCE at intake and never changes mid-ticket** (no escalation; if a lite ticket grows beyond what lite can handle, the dev aborts and reruns under full).

**Path resolution for `lessons/`:** the orchestrator MUST resolve the directory of the running `SKILL.md` (following symlinks, most installs put it under `~/.claude*/skills/doer/SKILL.md` symlinked to `~/src/doer/SKILL.md`) and treat `<resolved-dir>/lessons/` as the canonical lessons directory. Use `readlink` or `realpath` if needed.

The global `lessons/` directory must already exist next to the skill. The per-repo `./.doer/` directory and the `tickets/` subdir under it are created on first invocation if missing. The `knowledge/` subdir is reserved for future use and is created lazily when something writes to it.

---

## Entry point: `/doer <TICKET-ID>`

This single command handles BOTH **starting a new ticket** AND **resuming an existing one**. The orchestrator detects which case applies by checking for `./.doer/tickets/<TICKET-ID>/metadata.json`:

- **File exists** → resume the ticket from its last persisted state. Skip directly to the resume flow (see `Resume flow` section below). Do NOT re-ask any intake question.
- **File does NOT exist** → run intake (this section).

The dev never has to remember whether a ticket already exists. `/doer ABC-123` always does the right thing.

**Backward-compat note:** `/doer continue <TICKET-ID>` is treated as a synonym for `/doer <TICKET-ID>`, the leading `continue` is parsed and ignored. Same for any other verb the user might type out of habit.

### Intake (when ticket does NOT exist)

Ask the following questions **one at a time** via `AskUserQuestion`. Do not batch.

   | # | Question |
   |---|----------|
   | 1 | "What is the title of `<TICKET-ID>`?" |
   | 2 | "Paste the full description of the ticket." |
   | 3 | "Does the ticket already have acceptance criteria? If yes, paste them. If no, type `derive` and we'll build them together in Stage 1." |
   | 4 | "Any extra context? (related issues, prior decisions, links, constraints). Type `skip` if none." |
   | 5 | "What name should the feature branch use? (e.g. `feature/fix-login-timeout`)" |
   | 6 | "Have you already done any work on this ticket before invoking `/doer`? [y/N]" |

   **Only if question 6 was answered `y`**, ask the four follow-ups one at a time (also via `AskUserQuestion`):

   | # | Question | Notes |
   |---|----------|-------|
   | 6a | "Do you have a written plan (mental or in a file)?" | If yes, capture summary or path |
   | 6b | "Did you write tests already?" | If yes, capture file paths and pass/fail status |
   | 6c | "Did you write implementation code?" | If yes, capture file paths and commit/staged/uncommitted state |
   | 6d | "Did you update any documentation?" | If yes, capture file paths |

   Persist all answers under `metadata.intake.prior_work`. If question 6 was `N`, write `prior_work: { "exists": false, "plan": null, "tests": null, "code": null, "docs": null }` and skip the follow-ups.

2. **Compute lite signal score and ask the dev to pick `mode`.** After all six intake questions are answered (and the prior-work follow-ups if applicable), but BEFORE initializing `metadata.json`, compute a lite-suitability score from the captured intake data:

   | Signal | Score |
   |---|---|
   | `description.length < 500` chars | +1 |
   | `raw_acs` has ≤ 3 enumerated items OR `raw_acs.length < 300` chars | +1 |
   | `prior_work.exists == false` | +1 |
   | Description (case-insensitive) contains any of: `default`, `preselect`, `prefill`, `rename`, `typo`, `copy`, `config flag`, `placeholder`, `hotfix`, `translation`, `locale string` | +1 per keyword, capped at +2 |
   | Description (case-insensitive) contains any of: `architecture`, `system`, `refactor`, `migration`, `pipeline`, `framework`, `epic` | −2 (subtracted from total) |

   **Total score ≥ 2 → suggest lite. Total score < 2 → suggest full.**

   Then ask via `AskUserQuestion`:

   ```
   Question: Doer detected this ticket as a candidate for [lite | full] mode. Which execution mode do you want?

   Options:
     - Lite: single-pass stages 2-5 (no iter 2+, no convergence loops on 4 and 5),
             skip Stage 8 entirely, minimal Stage 9 wrapup, history cleanup runs
             without confirmation. Best for trivial tickets (default-value changes,
             copy edits, prefills). If Stage 4 or 5 does not converge in iter 1,
             you choose: accept residuals, pause, or abort + restart in full mode.
     - Full: complete pipeline with Stages 4 and 5 looping up to 3 iterations,
             Stage 8 docs sync (with classify pre-check), full Stage 9 wrapup
             (assumptions validation, lessons capture, confirmed history cleanup).
   ```

   The recommended option (per the heuristic) is presented first in the option list. Persist the dev's answer to `metadata.mode`. **Once set, `mode` does NOT change for the remainder of the ticket** (no escalation; if the ticket grows past lite's capacity, the dev aborts and reruns under full).

3. Initialize `metadata.json` (intake fields + chosen mode are embedded, see Knowledge & State Layout for the full schema):

   ```json
   {
     "ticket_id": "<TICKET-ID>",
     "title": "<title>",
     "branch": "<branch-name>",
     "status": "in_progress",
     "current_stage": 1,
     "skill_version": "<read from frontmatter at intake time, e.g. 3.0.0>",
     "mode": "<lite | full chosen in step 2>",
     "created_at": "<ISO8601>",
     "completed_at": null,
     "intake": {
       "description": "<full description from intake>",
       "raw_acs": "<pasted ACs or 'derive'>",
       "context": "<extra context or 'none'>",
       "prior_work": {
         "exists": false, "plan": null, "tests": null, "code": null, "docs": null
       }
     },
     "stages": {
       "1": {"name": "ac-confirm",     "status": "pending"},
       "2": {"name": "plan",           "status": "pending"},
       "3": {"name": "tests",          "status": "pending"},
       "4": {"name": "code",           "status": "pending"},
       "5": {"name": "code-review",    "status": "pending"},
       "6": {"name": "quality-gate",   "status": "pending"},
       "7": {"name": "runtime-verify", "status": "pending"},
       "8": {"name": "docs-sync",      "status": "pending"},
       "9": {"name": "wrapup",         "status": "pending"}
     },
     "changelog": [],
     "code_review": [],
     "blocking_conditions": [],
     "commits": [],
     "workspace_guard": null
   }
   ```

   The remaining top-level fields (`ac`, `plan`, `assumptions_validation`, `lessons_captured`, `summary`, `performance`, etc.) are populated by their owning stages and start absent.

   **Per-stage `verified_with` rule.** When a stage transitions to `status: "complete"` (or `"skipped"`, or `"imported"`), the orchestrator MUST also write `verified_with: "<current SKILL frontmatter version>"` on that stage. Example after Stage 2 finishes under SKILL 2.10.0:
   ```json
   "2": {"name": "plan", "status": "complete", "verified_with": "3.0.0", "completed_at": "...", ...}
   ```
   This is the only mechanism that lets the auto-reverify check (see Versioning & Migrations) know which stages to spot-check after a SKILL upgrade.

4. Create the feature branch in the current repo:

   ```bash
   git checkout -b "<branch-name>"
   ```

   If the branch already exists (local or remote), ask:
   "Branch `<branch-name>` already exists. Options: 1) Check out existing, 2) Pick a different name. Which?"

5. **Workspace setup**: run the **Workspace Guard** (see section below). This is MANDATORY before Stage 1.

6. Narrate to the user: "Ticket <TICKET-ID> initialized on branch `<branch-name>`. `.doer/` is gitignored locally, your team will never see these files. Starting Stage 1: AC Confirm."

7. Proceed to Stage 1.

---

## Workspace Guard

Idempotent check that prevents `.doer/` from ever being committed in this clone. MUST run at every entry point: intake (after creating branch), `/doer continue`, `/doer verify`, any first action after context reset.

### Steps

1. **Idempotency check.** If `metadata.workspace_guard == "ok"` AND `.git/info/exclude` contains `.doer/` → skip rest silently.

2. **Ensure exclude contains `.doer/`:**
   ```bash
   mkdir -p .git/info
   [ -f .git/info/exclude ] || touch .git/info/exclude
   grep -qxF '.doer/' .git/info/exclude || echo '.doer/' >> .git/info/exclude
   ```
   `.git/info/exclude` is per-clone, never committed, team sees nothing.

3. **Verify it works:**
   ```bash
   mkdir -p .doer && touch .doer/.guard-test
   STATUS=$(git status --porcelain .doer/.guard-test 2>/dev/null)
   rm .doer/.guard-test
   ```
   `STATUS` MUST be empty. If not, investigate (global gitignore override, repo `.gitignore` un-ignoring `.doer/`). Stop and report.

4. **Detect already-tracked `.doer/`:** `TRACKED=$(git ls-files .doer/ 2>/dev/null | head -1)`. If non-empty, ask the user **once per ticket**:
   ```
   ⚠ .doer/ is currently tracked. Options to untrack:
   1) Commit `git rm -r --cached .doer/` on this branch (one extra commit in PR)
   2) Skip, keep tracking, clean manually later
   3) Untrack silently (stage but don't commit)
   ```
   Default to **3** if no response.

5. **Migrate stale per-repo lessons → global pool.** Idempotent. The per-repo lessons location was deprecated in favor of `<doer-skill-dir>/lessons/` (global, cross-project). Old tickets still have files at `./.doer/knowledge/lessons/` from before the change. Migrate them so the user keeps a single global pool.

   ```bash
   GLOBAL_LESSONS=$(dirname "$(realpath <SKILL.md path>)")/lessons
   LOCAL_LESSONS=.doer/knowledge/lessons
   if [ -d "$LOCAL_LESSONS" ]; then
     mkdir -p "$GLOBAL_LESSONS"
     for f in "$LOCAL_LESSONS"/*.md; do
       [ -f "$f" ] || continue
       NAME=$(basename "$f")
       if [ -f "$GLOBAL_LESSONS/$NAME" ]; then
         if cmp -s "$f" "$GLOBAL_LESSONS/$NAME"; then
           rm "$f"   # identical → just delete local
         else
           # Conflict, ask user once per file: overwrite | keep both (rename) | skip
           # Default to "keep both" (rename local with -from-<repo-name> suffix) if no answer.
         fi
       else
         mv "$f" "$GLOBAL_LESSONS/$NAME"
       fi
     done
     rmdir "$LOCAL_LESSONS" 2>/dev/null || true
     # Also remove .doer/knowledge if now empty
     rmdir .doer/knowledge 2>/dev/null || true
   fi
   ```
   Narrate the migration outcome only if any file was moved or a conflict was raised. Silent no-op when there's nothing to migrate.

6. **Migration Check.** If a ticket is active, run the **Migration Check** (see Versioning & Migrations). Auto-applies any pending migration silently. Idempotent, once at current version, no-op.

7. **Mark satisfied:** if a ticket is active, write `metadata.workspace_guard = "ok"`. (No-op if no active ticket, next ticket-scoped invocation sets it.)

For deep cleanup of historical `.doer/` content from earlier commits on the feature branch, use `/doer cleanup-history <TICKET-ID>`, out of scope for the Guard.

---

## Narration Protocol

**Per-stage narration:**
- Before: `"Starting Stage {N}, {name}. {one-sentence goal}."` + write `stages.<N>.started_at`.
- After: write `stages.<N>.completed_at` + `"Stage {N} complete{, committed as {sha}}. Continuing to Stage {N+1}..."` then END TURN. (The `committed as {sha}` clause is included only when the stage actually produced a real-code commit. Stages 1, 2, and 9 typically do not commit — they only update `metadata.json` which is gitignored — so they omit the clause.)
- Inside loop: `"Iteration {i}/{max}: invoking {agent}... agent returned {status}, {findings} findings ({blockers} blockers)."` (`{max}` is `3` for Stage 4 and Stage 5.)

### Turn boundaries, granularity is the WHOLE iteration

A single doer/reviewer **iteration** is the atomic unit of work. The orchestrator MAY chain multiple Agent calls within ONE turn as long as they belong to the same iteration of the same loop:

```
Iteration N (single turn allowed):
  Agent(doer) → narrate result
  → Agent(reviewer) → narrate result
  → (if AUTO_FIXes) Agent(fixer) → narrate result
  → END TURN
```

Then **MUST END TURN before the next iteration or the next stage.** The next user message resumes automatically.

| Boundary | Same turn OK? |
|----------|---------------|
| Within one loop iteration (doer → reviewer → fixer) | YES |
| Between iteration N and N+1 | **NO. END TURN** |
| Between stages | **NO. END TURN** |
| Between subagent and a major file write that informs the next subagent | YES |

**MUST rules:**

1. End the turn at every stage boundary. Narrate "Stage N complete. Continuing to Stage N+1..." then STOP.
2. End the turn between iterations of the same loop. Narrate iteration result, then STOP.
3. **Never bundle multiple stages or multiple loop iterations in one turn.** One stage = one or more turns. One iteration = one turn. Never collapse iterations.
4. **If an Agent call inside an iteration returns an error**, end the turn before invoking anything else. Surface the error to the user; do not silently retry the next subagent.

**Self-check before every response:** *"Am I about to start a new iteration or a new stage?"* If yes. STOP, narrate where you ended, do not start the new unit.

### SUGGESTIONs never pause

Zero BLOCKERs = converged. SUGGESTIONs are persisted as part of the stage's `metadata.code_review[<iteration>]` entry. Orchestrator narrates `"Converged with N SUGGESTIONs logged. Continuing."` then auto-proceeds (next stage, in a new turn).

### Interrupt detection, and the auto-resume rule

At any turn boundary, the user's next message is interpreted as:

| User message contains... | Interpretation |
|--------------------------|----------------|
| `stop`, `wait`, `hold on`, or a clear halt signal | **HALT**: narrate "Stopping. Run `/doer continue <TICKET-ID>` to resume." Stop. State already persisted in metadata. |
| **Anything else** (including empty, `ok`, `yes`, `continue`, `go`, `y`, an unrelated comment, a question about the work) | **RESUME**: read `metadata.json`, do the next pending action without further prompting |

**MUST NOT** ask the user "Continue? [Y/n]" / "Shall I proceed?" / "Ready for the next stage?" between iterations OR between stages. Continuation is implicit. The narration template is informative, not inquisitive:

- ✅ Right: *"Stage 2 complete. Continuing to Stage 3..."* + END TURN.
- ❌ Wrong: *"Stage 2 complete. Continue to Stage 3? [Y/n]"*
- ❌ Wrong: *"Stage 2 complete. Shall I move on to Stage 3?"*
- ❌ Wrong: *"Stage 2 complete. Ready to start Stage 3?"*

The user already opted in by starting the ticket. Asking again on every stage boundary makes the orchestrator feel like it's babysitting. Stages are auto-chained; the only stop is a halt signal in the next message.

**MUST NOT** require the user to type `/doer continue <TICKET-ID>` to advance work in flight. `/doer continue` is for resuming **across sessions**, not for nudging the next step. Within a session, any non-halt message advances.

**State persistence:** all progress (current iteration, BLOCKERs found, files written, etc.) is persisted to `metadata.json` after every Agent return. Closing the session at any point preserves state, the next `/doer continue <TICKET-ID>` resumes intact. There is no separate "pause" command needed; abandoning the session = pausing.

**To stop mid-Agent (the Agent is already running):** terminal users can use `Ctrl+C` in the parent shell or `Esc` if their client supports it. The orchestrator cannot be interrupted mid-Agent from inside.

### Performance counters (consumed by Stage 9 wrapup)

Counters are written into `metadata.json` as the ticket progresses. Stage 9 reads them as-is into `metadata.performance` (no separate aggregation pass needed).

Per-stage runtime fields (live under each `metadata.stages.<N>`):

```json
"<N>": {
  "name": "...",
  "status": "...",
  "verified_with": "3.0.0",
  "started_at":   "<ISO8601>",
  "completed_at": "<ISO8601>",
  "iterations": <int>,                                  // for stages 4 and 5 only
  "loop_outcome": "converged | accepted_with_residuals",
  "blockers_resolved_total": <int>                      // for stages 4 and 5 only
}
```

Top-level runtime counter for agent invocations (lives at `metadata.performance.agents`, populated incrementally on every Agent call):

```json
"performance": {
  "agents": {"<agent-name>": <count>, ...}
  // The remaining performance fields (started, completed, wall_clock, active, code, convergence, reviewer_roi)
  // are filled in by Stage 9 step 3 from these per-stage and agents counters plus git log/diff.
}
```

Increment `metadata.performance.agents[<name>]` on every Agent call. Set `metadata.stages.<N>.started_at` when the stage begins and `completed_at` on transition to `complete | skipped | imported`. Set `iterations`/`loop_outcome`/`blockers_resolved_total` on loop exit (stages 4 and 5 only).

There is no `pauses` array and no `active_duration_seconds` field. There is no `/doer pause` command; state persists after every Agent return, so closing the session IS pausing. Wall-clock duration in `metadata.performance.wall_clock` is computed from `metadata.created_at` to `metadata.completed_at`; "active" duration is the same value (no paused intervals to subtract).

---

## Doer/Reviewer Loop Pattern (Delta-Aware)

**Stages 4 (Code) and 5 (Code Review) use this pattern. Max iterations: 3.** Iterations 3+ rarely add value commensurate to cost; if 3 iterations don't converge, narrate and let the dev decide.

Stages 2 (Plan) and 3 (Tests) do NOT use this loop. They are single-pass with deterministic pre-checks plus an optional single retry. See those stages' sections.

### Findings severity (4 buckets)

| Bucket | Behavior | Examples |
|--------|----------|----------|
| **BLOCKER** | Loop continues until resolved | Failing test, missing AC coverage, security issue, broken build |
| **AUTO_FIX** | Applied automatically same iteration before convergence check | Reference to deleted function, unused import, test name stale after rename, typo |
| **SUGGESTION** | Logged to `metadata.code_review`, never applied, never blocks | "Consider extracting", "could use map instead of ifs", design tweaks |
| **INFO** | Observational only | "This file is 500 LOC", "pattern used in 3 places" |

**Test for AUTO_FIX vs SUGGESTION:** *"Is there anything to decide?"* No → AUTO_FIX. Yes (trade-off, preference, design judgment) → SUGGESTION. When in doubt → SUGGESTION (be conservative. AUTO_FIX runs without user approval).

**Convergence = zero BLOCKERs remaining.** AUTO_FIXes are applied within the same iteration, do not block convergence.

### Review entries (in `metadata.code_review`)

Stage 5 appends one object per iteration to `metadata.code_review` (a JSON array). NEVER write to a sidecar file. Shape:

```json
{
  "iteration": <N>,
  "blockers":   [{"id": "B-1", "text": "<finding>"}, ...],          // iter 1 form
  "prior_blockers_resolved":   ["B-1", ...],                         // iter 2+ form
  "prior_blockers_still_open": ["B-2", ...],                         // iter 2+ form
  "new_blockers": [{"id": "B-3", "text": "..."}, ...],              // iter 2+ form
  "auto_fixes":  [{"id": "AF-1", "text": "<mechanical change>"}, ...],
  "suggestions": [{"id": "S-1",  "text": "<observation>"}, ...],
  "info":        [{"id": "I-1",  "text": "..."}, ...],
  "verdict": "needs_revision | converged"
}
```

The reviewer reads ONLY the most recent `metadata.code_review[-1]` entry plus prior unresolved BLOCKERs (both passed inline in the prompt). Old SUGGESTIONs stay logged for the dev but are NOT re-analyzed.

### Changelog entries (in `metadata.changelog`)

Every stage that produces output (planner, test writer, code writer, code reviewer fix-pass, runtime logger, etc.) APPENDs an entry to `metadata.changelog` (JSON array). Append-only. NEVER rewrite or compress prior entries. Shape:

```json
{
  "stage": <N>,
  "iteration": <N>,
  "kind": "initial | fixes",
  "items": [
    {"type": "decision", "text": "<one-line>"},
    {"type": "step",     "text": "<one-line>"},
    {"type": "fix",      "blocker_id": "B-1", "text": "<what + why>"},
    {"type": "auto_fix", "id": "AF-1",        "text": "<mechanical change>"}
  ]
}
```

One-line items only. No prose. Sub-agents reading the changelog look at the last 1-3 entries inline in their prompt. Terse means cheap to read AND cheap to write.

### Read budgets (per iteration, per role)

Sub-agent read budgets are SOFT limits expressed in their prompt. Goal: cap exploration cost without forbidding necessary reads. **No scratch files**: every piece of context the sub-agent needs arrives inline in the prompt (extracted from `metadata.ac`, `metadata.plan`, last N `metadata.changelog` entries, and `git diff <base>..HEAD`).

| Role | Budget |
|------|--------|
| Iter 1 doer | Up to 15 source files + lessons. Free to grep. Receives `metadata.ac` and `metadata.plan` inline. |
| Iter 1 reviewer | `git diff <base>..HEAD` + last 1-2 `metadata.changelog` entries (inline) + up to 5 source files for spot-checks. Receives `metadata.ac` and `metadata.plan` inline. |
| Iter 2+ combined fixer-reviewer | `git diff <base>..HEAD` + last 2 `metadata.changelog` entries + last `metadata.code_review` entry (all inline) + up to 3 source files specifically tied to BLOCKER targets. NO scratch reads. |
| AUTO_FIX fixer | The lines named in the AUTO_FIX list. No exploration. |

Add this line to every sub-agent prompt: *"Read budget: <N> source files. Stay within it. If a BLOCKER genuinely requires more, note the extra reads in your changelog appendix and proceed."*

### Iteration 1 (clean-slate, two agent calls)

1. Invoke **doer** → produces artifact (the code/tests/etc. the stage owns) and returns a `changelog_appendix` object that the orchestrator persists into `metadata.changelog`.
2. Invoke **reviewer** → returns findings JSON (BLOCKER / AUTO_FIX / SUGGESTION / INFO). Orchestrator persists as a new entry in `metadata.code_review`.
3. **Apply AUTO_FIXes** (if any): invoke fixer pass with *"Apply each mechanically. No design changes. Return a changelog appendix with `{type: 'auto_fix', id: '<id>', text: '<change>'}` items."*
4. Zero BLOCKERs → converged. Narrate `"Converged. N AUTO_FIXes applied. M SUGGESTIONs logged."`, auto-proceed.
5. BLOCKERs > 0 → Iteration 2.

### Iteration 2+ (delta-aware, ONE combined agent call)

Iter 2+ is targeted fix verification. No need for fresh-eyes review on small changes the same agent just made. Halve the calls:

1. Invoke **ONE combined "fixer-reviewer" agent** with the following payload **inlined in the prompt** (NOT as file reads):
   - `metadata.ac` (in_scope, out_of_scope)
   - `metadata.plan` (files, steps, tests)
   - Last 2 `metadata.changelog` entries (what changed and why)
   - Last `metadata.code_review` entry (prior verdict)
   - Prior BLOCKERs with IDs
   - The diff: `git diff <base>..HEAD`
   - Instruction:
     ```
     Step 1: Address each prior BLOCKER. Update code/tests in-place.
       For each fix, add to your output: {type: "fix", blocker_id: "<id>", text: "<what + why>"}

     Step 2: Self-review your fix. For each prior BLOCKER, mark RESOLVED or STILL_OPEN. Scan ONLY the lines you just touched for new issues.

     Step 3: Output JSON:
     {
       "changelog_appendix": {
         "stage": <N>, "iteration": <N>, "kind": "fixes",
         "items": [{type, text, ...}, ...]
       },
       "code_review_entry": {
         "iteration": <N>,
         "prior_blockers_resolved": ["id-1", ...],
         "prior_blockers_still_open": ["id-2", ...],
         "new_blockers": [{"id": "B-X", "text": "..."}, ...],
         "auto_fixes": [...],
         "suggestions": [...],
         "info": [...],
         "verdict": "needs_revision | converged"
       }
     }

     Read budget: 3 source files max beyond the diff.
     ```
2. Apply AUTO_FIXes (separate fixer pass if needed).
3. Remaining BLOCKERs = still_open + new. Zero → converged. Otherwise → next iteration (subject to max 3).

**Why combined:** for iter 2+, the changes are small and the reviewer would re-read the same context the doer just wrote. One agent does both with the changelog as its trail. Trade-off: weaker than fresh-eyes review, but iter 1 already had a fresh-eyes review pass, so the high-impact biases were caught upfront. The dev can always force a fresh-eyes pass by setting `metadata.stages.<N>.force_fresh_review = true`.

### Max iterations reached (3) without convergence

Narrate: *"Stage {N} did not converge after 3 iterations. {N} BLOCKERs remain: {list}. Options: 1) one more iteration, 2) accept and continue, 3) pause."* If option 1 converges → `loop_outcome = "converged"`. If option 2 → `loop_outcome = "accepted_with_residuals"`. If option 3 → leave `metadata.stages.<N>.status = "in_progress"` and do NOT set `loop_outcome` (the dev resumes later via `/doer continue`).

---

## Stage Finalization Checklist (applies to every stage)

Before marking ANY `metadata.stages.<N>.status = "complete"` (or `"skipped"` / `"imported"` / `"blocked"`), the orchestrator MUST run a deterministic checklist that validates the per-stage required fields are present in metadata. This is a no-LLM check (just JSON field presence). It catches the common post-compaction failure mode where the orchestrator forgets which fields the schema requires.

**If any required field is missing, the orchestrator MUST write it before transitioning.** If it cannot be derived (e.g. `started_at` was never recorded), use the best available proxy (e.g. `git log` of the stage's commit timestamp, or current time, or `null` with an explanatory note). Narrate which fields were back-filled and why.

### Required fields per stage

| Stage | Always required | Required when status is `complete` | Required when status is `skipped` |
|---|---|---|---|
| 1 ac-confirm | `name`, `status`, `verified_with` | `completed_at` | `skipped_reason` |
| 2 plan | `name`, `status`, `verified_with` | `completed_at`, `retry_used` | `skipped_reason` |
| 3 tests | `name`, `status`, `verified_with` | `completed_at`, `retry_used` | `skipped_reason` |
| 4 code | `name`, `status`, `verified_with` | `started_at`, `completed_at`, `iterations`, `loop_outcome`, `blockers_resolved_total` | n/a (Stage 4 is never skipped) |
| 5 code-review | `name`, `status`, `verified_with` | `started_at`, `completed_at`, `iterations`, `loop_outcome`, `blockers_resolved_total` | n/a |
| 6 quality-gate | `name`, `status`, `verified_with` | `started_at`, `completed_at`, AND either (`test_summary` if tests ran) OR (`skipped_reason = "no diff since last green"` if skip-safe path) | `skipped_reason` |
| 7 runtime-verify | `name`, `status`, `verified_with` | `started_at`, `completed_at`, `ac_verdicts` | `skipped_reason`, `skipped_acknowledged_by = "dev"` |
| 8 docs-sync | `name`, `status`, `verified_with` | `started_at`, `completed_at` | `skipped_reason` (and `skipped_acknowledged_by = "lite_mode"` if mode is lite) |
| 9 wrapup | `name`, `status`, `verified_with` | `completed_at` | n/a |

### Top-level required fields when transitioning ticket to `status: "complete"`

When Stage 9 marks the ticket complete, the checklist also verifies:
- `metadata.completed_at` is set (ISO8601)
- `metadata.summary` is a non-empty string
- `metadata.performance` is a populated object (has at least `started`, `completed`, `wall_clock`)
- `metadata.last_green_sha` is a 40-character SHA (full length, never abbreviated)
- `metadata.last_green_test_command` is non-null

### Validation procedure

For each required field listed above:
1. Read `metadata.stages.<N>.<field>` (or top-level `metadata.<field>`).
2. If absent or null when it should not be, narrate: *"Finalization check: `metadata.stages.<N>.<field>` missing. Back-filling from <source>."* Then write it.
3. If a value is present but obviously wrong (e.g. `last_green_sha` is fewer than 40 characters, `iterations` is negative, `loop_outcome` is not in the enum), narrate the issue and correct it.
4. Re-read after writing to confirm the value persisted.

Only after all required fields validate clean, write the final `status` and continue.

---

## Stage 1. AC Confirm

**Goal:** produce testable ACs in `metadata.ac` + detect/import any pre-existing work.

**No subagent, orchestrator runs this directly.** No commit at end (only `.doer/` writes, which is gitignored).

### Step 1: Load context

1. Read `metadata.json`. Pull `title`, `intake.description`, `intake.raw_acs`, `intake.context`, and `intake.prior_work` (all captured during intake).
2. Read `<doer-skill-dir>/lessons/*.md` (global, cross-project, see Knowledge & State Layout for path resolution). Note any whose `when_it_applies` matches this ticket.

### Step 2: Branch on prior work (no question, read metadata)

The intake already asked "Have you done any work?" and the four follow-ups (plan, tests, code, docs). Do NOT ask again.

- `metadata.intake.prior_work.exists == false` → skip Steps 3-5. Go to Step 6 (AC confirm) with entry stage = 1.
- `metadata.intake.prior_work.exists == true` → continue to Step 3 (inspect).

### Step 3: Inspect the repo (only when prior_work.exists)

Detect base branch (prefer `main`, fall back to `master`, ask if unclear). Then:

```bash
git branch --show-current
git status --porcelain
git log --oneline <base>..HEAD
git diff <base>...HEAD     # full committed diff
git diff                    # unstaged
git diff --cached           # staged
```

For each commit ahead of base: `git show --stat <sha>` then read key files. Classify touched files:
- Tests (`*_test.*`, `*.test.*`, `tests/`, `spec/`) → user has tests
- Other code → user has implementation
- `.md`, `docs/` → user has documentation
- `PLAN.md` or `.doer/` → user has plan

If tests detected, run them via repo's test command, note pass/fail to identify TDD red/green/broken state.

Narrate the analysis (no question, just summary, then proceed to Step 4):
```
Based on your commits:
- Plan: <yes/no + where>
- Tests: <N> files (<X pass, Y fail>)
- Implementation: <N> files (~<LOC>)
- Docs: <N> files

Summary: <one-paragraph inferred state>
```

If the inference is wrong, the dev will see it surface in the entry-stage suggestion (Step 4) and can correct there with a single decision.

### Step 4: Decide entry point

| User has... | Entry stage | Mark imported |
|-------------|-------------|---------------|
| Nothing | 1 |, |
| Plan only | 3 (tests) | 2 |
| Plan + failing tests | 4 (code) | 2, 3 |
| Plan + tests + partial code | 4 (code) | 2, 3 |
| Plan + tests + complete code | 5 (code-review) | 2, 3, 4 |

Confirm with user: *"Suggesting entry at Stage {N}, importing {list}. Proceed? [Y / start at 1 / pick stage]"*

### Step 5: Baseline + import

If there are uncommitted changes:
```bash
git add -A
git commit --no-verify -m "doer(<TICKET-ID>): import pre-existing work as baseline"
```
If there are already commits ahead of base, no extra commit needed.

Mark imported stages in `metadata.json`:
```json
"stages": {
  "2": {"name": "plan",  "status": "imported", "imported_at": "<ISO8601>", "note": "<what user had>"},
  "3": {"name": "tests", "status": "imported", "imported_at": "<ISO8601>", "note": "..."}
}
```

If a plan was imported but isn't written down, prompt the user to paste/summarize it. Either way, persist the result into `metadata.plan` using the schema documented in Knowledge & State Layout (or orchestrator drafts the structured plan from the summary + diff and the user confirms). Same pattern for imported tests/code (note their file paths in `metadata.stages.<N>.imported_paths`).

### Step 6: AC confirmation (single combined check)

Build the full draft (ACs + Out of Scope + Open Questions) BEFORE asking anything. Present everything as one block, ask ONE question, iterate.

1. Build the AC list:
   - **Raw ACs from intake:** restate each in Given/When/Then form.
   - **ACs to derive:** propose 3 to 7 Given/When/Then items based on description + context (and any imported code/tests).
2. Build the **Out of Scope** list (items the dev should NOT confuse for in-scope).
3. Build the **Open Questions** list with proposed resolutions for each.
4. Present the entire draft as one block:

   ```
   Draft for Stage 1:

   ## Acceptance Criteria
   - AC-1: GIVEN ... WHEN ... THEN ...
   - AC-2: ...

   ## Out of Scope
   - <item 1>
   - <item 2>

   ## Open Questions (proposed resolutions)
   - Q: <question> → A: <proposed answer>

   Approve the whole block, or tell me what to edit. [Y / edit <section>:<change> / redo]
   ```

5. If the user replies `Y` → accept all and proceed to Step 7.
6. If the user gives edits → apply them and re-present the block (loop until approved).
7. If the user says `redo` → start over from item 1.

ONE question for the entire Stage 1 contract. No item-by-item drilling.

### Step 7: Write artifacts

Persist the confirmed Stage 1 output into `metadata.ac`:

```json
"ac": {
  "in_scope": ["AC-1: GIVEN ... WHEN ... THEN ...", "AC-2: ..."],
  "out_of_scope": ["<item>", "..."],
  "open_questions_resolved": [{"question": "<Q>", "answer": "<A>"}],
  "applicable_lessons": ["<lesson-slug>", "..."]
}
```

Each `in_scope` entry is a complete Given/When/Then string starting with the AC ID. `applicable_lessons` lists slugs of global lessons (`<doer-skill-dir>/lessons/{slug}.md`) whose `when_it_applies` matches this ticket; downstream agents read those lesson files when relevant.

No sidecar `ac.md` file. No separate assumptions file (assumptions surface in Stage 2 inside `metadata.plan.assumptions`).

### Step 8: Finalize

Update `metadata.json`: stage 1 complete, advance `current_stage` to the entry point decided in Step 5.

Narrate: *"Stage 1 complete. Imported stages: {list}. Continuing to Stage {N}..."* then END TURN. Auto-resume on next non-halt message.

---

## Stage 2. Plan (Single-Pass + Deterministic Checks)

**Goal:** produce a structured implementation plan persisted into `metadata.plan`.

**No loop. No reviewer LLM.** A single planner agent produces the plan, then deterministic checks validate structure and coverage. If checks fail, the planner is invoked **once more** (single retry) with the BLOCKERs inline. Second failure aborts the stage and hands control to the dev.

**Why no loop:** the plan reviewer judged an LLM artifact before any evidence existed (no tests, no code). Most of its useful output (file existence, AC coverage, assumption presence) is mechanical and is now caught by deterministic checks. Semantic plan critique is moved downstream where the reviewer has real evidence to look at (Stage 4 / 5).

**Doer agent:** general-purpose, prompted as "implementation planner".

### Planner prompt (skeleton)

```
You are the implementation planner for ticket <TICKET-ID>.

The orchestrator has already loaded these and inlined them below:

== metadata.ac ==
<JSON dump of metadata.ac: in_scope, out_of_scope, open_questions_resolved, applicable_lessons>

== metadata.intake ==
<JSON dump of metadata.intake: description, raw_acs, context, prior_work>

== Applicable lessons (read these files in full before planning) ==
<for each slug in metadata.ac.applicable_lessons, the resolved file path
under <doer-skill-dir>/lessons/{slug}.md>

Explore the codebase to understand the structure relevant to this ticket.
Read budget: up to 10 source files in `full` mode, up to 5 in `lite` mode (the orchestrator inlines the chosen mode in the prompt). Free to grep within the budget.

Produce the plan as a JSON object matching this exact shape:

{
  "files": [
    {"path": "<repo-relative path>", "change": "edit | new | delete", "reason": "<one-line>"}
  ],
  "steps": [
    {"order": 1, "verb": "<add | modify | delete | rename | refactor>", "what": "<thing>", "where": "<file>:<line-range or 'new'>"}
  ],
  "tests": [
    {"name": "<test function or describe block name>", "covers": ["AC-1", "AC-3"], "what": "<one-line of what the test asserts>"}
  ],
  "risks": [
    {"risk": "<one-line>", "mitigation": "<one-line>"}
  ],
  "assumptions": ["<one-line>", "..."]
}

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
- Read budget: 10 source files in `full` mode, 5 in `lite` mode. Stay within it. If a BLOCKER from the deterministic checks needs more, add it on retry.

Do NOT write code. Do NOT run tests. Plan only.
```

### Deterministic checks (post-planner)

Run all three. They are mechanical, free of LLM cost, and cover what the prior reviewer judged.

**Check A. File existence matches `change`.**
For each `metadata.plan.files[i]`:
- `change: "edit" | "delete"` → the file MUST exist at that path.
- `change: "new"` → the file MUST NOT exist at that path.
Mismatches → BLOCKER:
```
- B-1 (file exists/missing): src/foo.kt is `change: edit` but does not exist
- B-2 (file already exists): src/bar.ts is `change: new` but already exists
```

**Check B. AC coverage by tests.**
For each entry in `metadata.ac.in_scope`, extract the `AC-N` ID prefix and verify at least one entry in `metadata.plan.tests` lists it under `covers[]`. Missing → BLOCKER:
```
- B-3 (coverage): AC-3 has no test in plan.tests
```

**Check C. Assumptions field present.**
`metadata.plan.assumptions` MUST exist as an array (may be empty `[]`). Missing or wrong type → BLOCKER:
```
- B-4 (assumptions): plan.assumptions field absent or not an array
```

### Single retry policy

If Checks A/B/C produce any BLOCKERs:
1. Re-invoke the planner ONCE with the BLOCKERs inline:
   ```
   Your prior plan failed deterministic validation:
   <list BLOCKERs>

   Produce a corrected plan as the same JSON shape. Address every BLOCKER. Do not introduce unrelated changes.
   ```
2. Re-run the three checks on the new plan.
3. Set `metadata.stages.2.retry_used = true`.
4. If still failing → ABORT the stage. Narrate to the dev:
   ```
   Stage 2 failed validation twice. Remaining BLOCKERs: <list>.
   The plan is in metadata.plan; review and correct, then run /doer continue.
   ```
   Set `metadata.stages.2.status = "blocked"`. Do not proceed to Stage 3.

   **Resuming from `blocked`:** when the dev re-runs `/doer <ID>` after fixing `metadata.plan` by hand, the orchestrator detects `metadata.stages.2.status == "blocked"` and re-runs ONLY the three deterministic checks (file existence, AC coverage, assumptions present) on the corrected plan. No new planner agent invocation. If checks pass → mark stage complete, proceed to Stage 3. If checks still fail → re-narrate the BLOCKERs and stay `blocked`.

If checks pass (first try or after retry):
1. Persist the planner's `plan` object into `metadata.plan` (overwriting any prior value).
2. Append the planner's `changelog_appendix` into `metadata.changelog`.
3. Add each new assumption to `metadata.plan.assumptions` (the planner already did this; nothing extra needed).
4. Set `metadata.stages.2.status = "complete"`, `metadata.stages.2.verified_with = <SKILL version>`, `metadata.stages.2.completed_at = <ISO8601>`, `metadata.stages.2.retry_used = <true|false>`.
5. Narrate `"Stage 2 complete: N files, M tests planned. Continuing to Stage 3."` Auto-proceed.

**No commit.** `metadata.json` lives in `.doer/` which is gitignored.

---

## Stage 3. Tests (Single-Pass + Deterministic Checks, TDD Red)

**Goal:** write failing tests that encode the ACs. No implementation yet.

**No loop. No reviewer LLM.** A single test-writer agent produces the tests, then deterministic checks validate. If checks fail, the writer is invoked **once more** (single retry) with the BLOCKERs inline. Second failure aborts the stage.

**Why no loop:** the test reviewer asked questions like "are all ACs covered?" and "do the tests actually fail?", both of which are mechanical. The semantic critique (brittle assertions, over-mocking) is moved into the Stage 4 reviewer where the diff makes it obvious.

**Doer agent:** general-purpose, prompted as "test writer".

### Test writer prompt (skeleton)

```
You are the test writer for ticket <TICKET-ID>. TDD red phase: write tests
that currently FAIL because no implementation exists yet.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump of metadata.ac>

== metadata.plan ==
<JSON dump of metadata.plan>

== Last changelog entries ==
<JSON dump of metadata.changelog[-2:] for context>

Read 2-3 existing test files in the repo to learn local conventions (framework,
file layout, naming). Read budget: 5 source files for convention discovery, plus
any source file referenced in metadata.plan.files that you need to understand
the surface you are testing.

Write every test listed in metadata.plan.tests. Each test MUST currently fail
with a MEANINGFUL assertion failure (the expected behavior is missing), NOT an
import error, NOT a typo, NOT a setup crash.

DO NOT add explanatory comments like `// RED:` / `// TDD red:` / `// fails because X`
on test bodies or KDoc/JSDoc blocks. The test name and the failing assertion
are self-documenting. Those comments become stale the moment Stage 4 makes them
pass and confuse PR reviewers.

Output a single JSON object describing what you did:

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
```

### Deterministic checks (post-writer)

Run all three. They cover what a test reviewer LLM would have asked.

**Check A. Tests parse and run.**
```bash
<repo's test command>   # e.g. npm test, pytest, ./gradlew test, go test ./...
```
If the output shows syntax errors, import errors, missing references, or compile errors (the tests do not RUN at all), classify each as a BLOCKER:
```
- B-1 (syntax): <file>:<line>: <error>
- B-2 (import): <file>: <error>
```

**Check B. Plan-driven test presence.**
For each `metadata.plan.tests[i]`, verify a test with that name was added (use the writer's reported `tests_added[]` plus a grep for the test name in repo test files for confirmation). For each missing → BLOCKER:
```
- B-3 (presence): plan called for `testLoginRetryAfterTimeout` (covers AC-3), not found.
```

**Check C. TDD red verified by execution.**
Parse the test runner output from Check A. For each test in `metadata.plan.tests`, verify it FAILED (assertion failure). If any test PASSED, that is wrong (no implementation should exist yet) → BLOCKER:
```
- B-4 (TDD red): testLoginSuccess passed unexpectedly. Either the assertion is too weak, or unrelated code already satisfies it.
```

### Single retry policy

If Checks A/B/C produce any BLOCKERs:
1. Re-invoke the test writer ONCE with the BLOCKERs inline. Same prompt body, prepended with:
   ```
   Your prior tests failed validation:
   <list BLOCKERs>

   Address every BLOCKER. Output the same JSON shape.
   ```
2. Re-run the three checks.
3. Set `metadata.stages.3.retry_used = true`.
4. If still failing → ABORT. Narrate:
   ```
   Stage 3 failed validation twice. Remaining BLOCKERs: <list>.
   Inspect the tests, then run /doer continue.
   ```
   Set `metadata.stages.3.status = "blocked"`. Do not proceed.

   **Resuming from `blocked`:** when the dev re-runs `/doer <ID>` after fixing the tests by hand, the orchestrator detects `metadata.stages.3.status == "blocked"` and re-runs ONLY the three deterministic checks (parse/run, plan-driven presence, TDD red verified). No new test-writer agent invocation. If checks pass → mark stage complete, proceed to Stage 4. If checks still fail → re-narrate and stay `blocked`.

If checks pass:
1. Append the writer's `changelog_appendix` into `metadata.changelog`.
2. Set `metadata.stages.3.status = "complete"`, `verified_with`, `completed_at`, `retry_used`.
3. Commit the failing tests:
   ```bash
   git add -A
   git commit --no-verify -m "doer(<TICKET-ID>): failing tests (TDD red)"
   ```
4. Narrate `"Stage 3 complete: N tests added, all failing as expected. Continuing to Stage 4."` Auto-proceed.

---

## Stage 4. Code (Doer/Reviewer Loop, TDD Green)

**Goal:** make the failing tests pass. Implement per `metadata.plan`. Loop with **max 3 iterations** in `full` mode (see Doer/Reviewer Loop Pattern). In `lite` mode, single-pass only (see "Lite branch" subsection at the end).

**Mode check.** At entry, read `metadata.mode`. If `lite`, follow the "Lite branch" rules at the end of this section. If `full`, run the full doer/reviewer loop documented below.

### Code writer prompt (skeleton)

```
You are the code writer for ticket <TICKET-ID>. TDD green phase.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump of metadata.ac>

== metadata.plan ==
<JSON dump of metadata.plan>

== Tests added in Stage 3 ==
<list of test file paths from metadata.changelog Stage 3 entries; the agent
reads them as part of its source budget>

== Last changelog entries ==
<JSON dump of metadata.changelog[-2:]>

Implement the plan. Follow existing codebase conventions. Do not add new
dependencies unless metadata.plan specifies them (if you must, return a
changelog item flagging it).

After implementation, run the full test suite. All tests (new and pre-existing)
MUST pass.

Output JSON:
{
  "changelog_appendix": {
    "stage": 4, "iteration": <N>, "kind": "initial",
    "items": [
      {"type": "step", "text": "<plan step + how it was executed + file path>"},
      ...
    ]
  }
}

Read budget: 15 source files (iter 1, `full` mode) or 8 source files (iter 1, `lite` mode) or 3 source files beyond the diff (iter 2+, `full` mode only; lite has no iter 2+).
```

### Pre-reviewer deterministic checks

Run these BEFORE invoking the code-reviewer. Each catches a class of obvious failures without burning an LLM call.

**Check A. Tests pass (TDD green achieved):**
```bash
<repo's test command>
```
If ANY test fails (new or pre-existing regression), classify as BLOCKER per failure and skip the reviewer this iteration:
```
- B-1 (test fail): tests/login_test.kt::testLoginSuccess expected "ok", got "null"
- B-2 (regression): tests/auth_test.kt::testTokenRefresh now fails (was passing pre-Stage 4)
```

**Check B. Lint / typecheck:**
```bash
<repo's lint command>     # e.g. ./gradlew detektAll, npm run lint, ruff check
<repo's typecheck>        # e.g. tsc --noEmit, mypy, ./gradlew compileKotlin
```
Detect commands by reading the repo's standard config (package.json scripts, build.gradle, pyproject.toml, etc.). If unclear, ask the dev once and persist as `metadata.lint_command` / `metadata.typecheck_command`. If a repo legitimately has no lint or typecheck, skip the check.

Failures here are BLOCKERs auto:
```
- B-3 (lint): src/login.kt:42: unused import
- B-4 (typecheck): src/auth.ts:18: Type 'string' is not assignable to 'number'
```

**Check C. Plan-driven file scope:**
Iterate `metadata.plan.files[]` to extract the expected change list. Compare with `git diff --name-only <base>..HEAD` from this stage's writer. Two cases:
- File in `metadata.plan.files[]` but NOT touched → BLOCKER (`B-5: plan called for src/foo.kt edit, not modified`)
- File touched but NOT in `metadata.plan.files[]` → INFO with note (could be legit follow-up; reviewer decides):
  ```
  - I-1 (scope): writer touched src/bar.kt which is not in metadata.plan.files. Reviewer should validate this is intentional.
  ```

**If any of A/B/C produced BLOCKERs**, end the iteration here. Do NOT invoke the reviewer for that iteration. Hand the BLOCKERs to the iter-N+1 fixer (see Loop Pattern).

**If all clean**, proceed to invoke the reviewer (below) for the semantic review.

### Code reviewer prompt (skeleton)

```
You are the code reviewer for ticket <TICKET-ID>.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump>

== metadata.plan ==
<JSON dump>

== Last 2 metadata.changelog entries ==
<JSON dump>

== Implementation diff ==
<output of `git diff <base>..HEAD`>

The deterministic checks already passed: all tests green, lint clean,
typecheck clean, every file in metadata.plan.files was touched. Focus on what
those checks cannot catch:

1. AC match: does the behavior implement every AC? Trace each AC to test + code.
2. Correctness: edge cases, error paths, concurrency, off-by-one, null handling.
3. Security: input validation, injection, secrets, auth, authz.
4. Test integrity: were tests weakened to make them pass?
5. Scope (semantic): any out-of-plan files touched (see INFO from Check C)?
   Are they justified, or should they be reverted?

Focus on the diff. Do NOT re-review files that were not touched.

Output findings as JSON code_review_entry per the Loop Pattern. Read budget:
5 source files (iter 1) or 3 source files (iter 2+) beyond the diff.
```

Run loop until convergence (max 3 iterations). On every loop iteration the orchestrator persists the writer's `changelog_appendix` to `metadata.changelog` and the reviewer's findings to `metadata.code_review`. Commit on convergence:
```bash
git add -A
git commit --no-verify -m "doer(<TICKET-ID>): implementation (TDD green)"
```

After the commit, persist the green-test marker so Stage 6 can skip re-running an unchanged tree:
```json
metadata.last_green_sha = <git rev-parse HEAD>   # MUST be the full 40-char SHA. NEVER abbreviated. The skip-safe check in Stage 6 compares this string-equal to `git rev-parse HEAD` of the new HEAD; an abbreviated SHA breaks the comparison.
metadata.last_green_test_command = <the test command that ran>
```

### Lite branch (`metadata.mode == "lite"`)

Single-pass only. No iter 2+. No convergence loop.

1. Invoke the **code writer** ONCE (iter 1). Persist its `changelog_appendix` to `metadata.changelog`.
2. Run the deterministic pre-checks (A: tests pass, B: lint/typecheck, C: plan-driven file scope) exactly as in the full branch.
3. If any pre-check produces BLOCKERs, narrate to the dev:
   ```
   Stage 4 lite: iter 1 deterministic checks failed. BLOCKERs: <list>.
   Lite mode does not iterate. Options:
     1) Accept residuals (mark stage complete with metadata.stages.4.loop_outcome = "accepted_with_residuals").
     2) Pause (status stays in_progress; rerun /doer continue after fixing manually).
     3) Abort and restart in full mode. Once-lite-always-lite: we do NOT mutate metadata.mode mid-ticket. To restart cleanly: (a) `git reset --hard <base>` if you want to discard code/test commits made under lite, (b) `rm .doer/tickets/<ID>/metadata.json`, (c) `/doer <ID>` to re-enter intake and pick full mode.
   ```
   Persist the dev's choice in `metadata.stages.4`. Option 1 → status complete with residuals. Option 2 → leave status in_progress, no `loop_outcome`. Option 3 → narrate the cleanup steps; do NOT modify `metadata.mode`.
4. If pre-checks are clean, invoke the **code reviewer** ONCE (iter 1). Persist its findings to `metadata.code_review`.
5. If reviewer finds zero BLOCKERs → converged. Apply any AUTO_FIXes. Commit. Persist `metadata.stages.4.loop_outcome = "converged"` and `metadata.stages.4.iterations = 1`.
6. If reviewer finds BLOCKERs → narrate the same 3-option prompt as step 3, and persist the dev's choice with the same semantics (option 1 → complete with residuals, option 2 → in_progress, option 3 → abort instructions).

After commit (whichever path), persist the green-test marker the same as the full branch.

---

## Stage 5. Code Review (Hybrid: Deterministic + Reviewer LLM)

**Goal:** PR-readiness check. Catch the mechanical "should never reach a PR" issues with deterministic greps, then invoke the reviewer LLM only for the semantic judgements that require it.

**Mode check.** At entry, read `metadata.mode`. If `lite`, follow the "Lite branch" rules at the end of this section. If `full`, run the full hybrid loop documented below.

### Pre-reviewer deterministic checks

Run all four. Each catches a class of PR-readiness issues without an LLM call.

**Check A. Stale TDD-red markers in test files.**
```bash
git diff --name-only <base>..HEAD | grep -E '(test|spec)' | while read f; do
  grep -nE '(// |# |/\* +)?(RED:|TDD red:|fails because)' "$f" || true
done
```
Each match → AUTO_FIX (delete the comment line; the test now passes so the marker is wrong).

**Check B. Secrets in the diff.**
Use `gitleaks` if available; otherwise a regex sweep:
```bash
git diff <base>..HEAD | grep -nEi '(api[_-]?key|secret|token|password|bearer|aws_)[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{8,}'
```
Any match → BLOCKER. Do not auto-fix; the dev must rotate credentials and amend.

**Check C. Smoke / end-to-end test exists.**
Inspect `metadata.plan.tests` + the actual tests added in Stage 3 (paths in `metadata.changelog` Stage 3 entries). Look for at least one test that exercises the full flow described in the ACs (not just unit isolation). If none → SUGGESTION (not BLOCKER, since some tickets legitimately have only unit-level tests):
```
- S-1 (smoke): no end-to-end test detected. Consider adding one if the
  ticket touches a user-facing flow.
```

**Check D. Swallow-all error handlers in the diff.**
```bash
git diff <base>..HEAD | grep -nE '(except\s*:|except\s+Exception\s*:|catch\s*\(\s*\w*\s*\)\s*\{?\s*\}?)' | grep -v test
```
Any match → SUGGESTION (the dev may have intentional reasons; do not auto-fix):
```
- S-2 (error handling): bare `except:` at <file>:<line>. Consider catching
  a specific exception or logging.
```

### Reviewer LLM (only if pre-checks did not produce BLOCKERs)

If Check B (secrets) produced any BLOCKERs, end the iteration and hand them to the iter-N+1 fixer (the dev cannot proceed with secrets in the diff). Skip the reviewer LLM for that iteration.

Otherwise, invoke the reviewer LLM with a TIGHT scope. Stage 4's reviewer already validated correctness; do not duplicate that work here:

```
You are the PR-readiness reviewer for ticket <TICKET-ID>.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump>

== metadata.plan ==
<JSON dump>

== Last 2 metadata.changelog entries ==
<JSON dump>

== Diff ==
<output of `git diff <base>..HEAD`>

The deterministic checks already ran (RED markers, secrets, swallow-all
handlers). Stage 4's reviewer already validated correctness and AC behavior.

Your scope is narrow. Judge ONLY:

1. ONE logical unit: does the diff describe a single coherent change,
   or does it mix unrelated work that should split into separate PRs?
   If mixed, classify as BLOCKER with a "recommended split" suggestion.

2. Semantic error handling: where the dev DID handle errors (not bare
   except), are the handlers appropriate? Specific exception types?
   Meaningful recovery or fallback? Logging? Or silently swallowing in
   a way that will hide bugs in production?

3. Stale or misleading comments in the diff (other than RED markers
   which Check A catches): TODO that should have been done, comments
   that contradict what the code now does, dead code commented out.

Output findings as BLOCKER / AUTO_FIX / SUGGESTION / INFO. See Doer/Reviewer
Loop Pattern for classification rules.

Read budget: 3 files max beyond what's in the diff.
```

### Loop convergence

Standard delta-aware loop applies. Iter 2+ uses the combined fixer-reviewer per the Loop Pattern.

Commit at convergence:
```bash
git add -A
git commit --no-verify -m "doer(<TICKET-ID>): address code review"
```

If the dev had nothing to fix (all pre-checks clean and reviewer found zero BLOCKERs), no commit is needed (no diff vs HEAD).

If a commit happened, run the test suite once more and update the green-test marker so Stage 6 can skip:
```json
metadata.last_green_sha = <git rev-parse HEAD>   # MUST be the full 40-char SHA. NEVER abbreviated. The skip-safe check in Stage 6 compares this string-equal to `git rev-parse HEAD` of the new HEAD; an abbreviated SHA breaks the comparison.
metadata.last_green_test_command = <the test command that ran>
```
If the post-commit test run fails, that is a regression: surface as a BLOCKER and re-enter the iter loop. Do not advance.

### Lite branch (`metadata.mode == "lite"`)

Single-pass only. No iter 2+. No convergence loop.

1. Run all four deterministic pre-checks (A: stale TDD-red markers, B: secrets, C: smoke, D: swallow-all handlers) exactly as in the full branch.
2. Apply any AUTO_FIXes that came out of pre-checks.
3. If Check B (secrets) produced BLOCKERs → narrate and abort the stage. Lite does not loop. The dev must rotate credentials and rerun manually.
4. If pre-checks are clean of BLOCKERs (SUGGESTIONs are OK), invoke the **PR-readiness reviewer LLM ONCE** with the full scope (one logical unit, semantic error handling, stale comments). Same prompt as the full branch.
5. If reviewer returns zero BLOCKERs → converged. Persist findings to `metadata.code_review` (one entry, iteration 1). Apply any AUTO_FIXes. Commit if there was anything to fix.
6. If reviewer returns BLOCKERs → narrate to the dev:
   ```
   Stage 5 lite: reviewer found N BLOCKERs in iter 1. Lite mode does not iterate.
   BLOCKERs: <list>
   Options:
     1) Accept residuals (mark stage complete with metadata.stages.5.loop_outcome = "accepted_with_residuals").
     2) Pause (status stays in_progress; rerun /doer continue after fixing manually).
     3) Abort and restart in full mode (same procedure as Stage 4 lite: git reset, rm metadata.json, rerun /doer <ID>).
   ```
   Persist the dev's choice in `metadata.stages.5`. Same semantics as Stage 4 lite: option 1 completes with residuals, option 2 stays in_progress, option 3 narrates abort steps.

Persist `metadata.stages.5.iterations = 1` always. `metadata.stages.5.loop_outcome` is set ONLY when the stage actually completes (option 1 → `accepted_with_residuals`, or step 5 path → `converged`). Option 2 (pause) leaves status in_progress without `loop_outcome`.

---

## Stage 6. Quality Gate (Validation, Not Loop)

**Goal:** fast sanity check. No agents. Just run tests, with a skip when the diff hasn't changed since the last green run.

### Setup

The last green test run is tracked in `metadata.last_green_sha`. Stages 4 and 5 update this field whenever they finish a successful test suite execution:
```json
{
  "last_green_sha": "<HEAD SHA at the moment all tests passed; MUST be the full 40-char output of `git rev-parse HEAD`, never abbreviated>",
  "last_green_test_command": "<the command that produced green>"
}
```

### Stage 6 logic

1. Detect the repo's test command (`npm test`, `pytest`, `./gradlew test`, etc.). If unclear, ask the user once and persist as `metadata.test_command`.

2. **Skip-safe check.** Read `metadata.last_green_sha`. If it equals `git rev-parse HEAD` AND `metadata.last_green_test_command` matches the current test command, skip the test run entirely:
   ```
   Quality gate: HEAD unchanged since Stage 4/5 last green run (<sha>).
   Skipping re-run. Continuing to Stage 7.
   ```
   Set `metadata.stages.6.status = "complete"`, `metadata.stages.6.skipped_reason = "no diff since last green"`, end turn.

3. **Otherwise run the full test suite.**

4. **If any test fails:** narrate the failures and ask: *"Tests failing: {list}. Options: 1) Return to Stage 4 to fix, 2) Return to Stage 5 to re-review, 3) Pause for manual fix. Which?"*

5. **If all tests pass:**
   - Persist a brief summary in `metadata.stages.6.test_summary = "<N>/<N> tests passed in <duration>"` (counts and timing only; the dev's terminal already has the full output, no need to duplicate it on disk).
   - Update `metadata.last_green_sha = <full 40-char output of git rev-parse HEAD; MUST NOT abbreviate>` and `metadata.last_green_test_command`.
   - Narrate *"Quality gate passed: <N>/<N> tests green. Continuing to Stage 7."* and proceed.

---

## Stage 7. Runtime Verify (Live Debug Logs, Temporary)

**Goal:** verify on-device behavior against ACs via dense temporary debug logs. Logs NEVER reach the final branch.

### Always ask (Stage 7 is NEVER auto-skipped)

**Stage 7 MUST be explicitly approved or skipped by the dev.** The orchestrator MUST NOT skip Stage 7 silently under any circumstance, including when the diff is 100% docs/config and no runtime code was touched. Silent auto-skip is forbidden because it produces false-positive skips that hide real verification gaps.

Classify the diff first to inform the default suggestion (this is for UX only, NOT a skip decision):

```bash
git diff --name-only <base>..HEAD
```

Classify each path:
- **Non-runtime:** `*.md`, files under `docs/`, `README*`, `CHANGELOG*`, `*.yml`/`*.yaml`/`*.json` config, `*.env.example`, `.github/`, `.gitlab-ci.yml`, `package.json` (only version/dep edits), `build.gradle` (only version/dep edits).
- **Runtime:** anything else (source code, real config that the app reads at runtime, migrations, etc.).

Then ALWAYS ask via `AskUserQuestion`. The classification picks the default suggestion but does NOT bypass the prompt:

**Case A. All paths are non-runtime:**
```
Question: Stage 7 is runtime verification on device. The diff in this ticket is
100% non-runtime (docs/config only). There is likely nothing to exercise on
device. How do you want to proceed?

Options:
  - Skip Stage 7 (recommended): mark as skipped with reason "no runtime code in diff"
  - Run Stage 7 anyway: I will inject debug logs and you exercise on device
```

**Case B. At least one path is runtime:**
```
Question: Stage 7 is runtime verification on device. The diff touches runtime
code. Do you want to exercise the ACs on a real device/simulator now?

Options:
  - Run Stage 7 (recommended): I will inject debug logs and walk you through
  - Skip Stage 7: mark as skipped, you take responsibility for runtime correctness
```

In BOTH cases, the dev's choice is recorded:

- **If skipped:**
  ```json
  metadata.stages.7.status = "skipped"
  metadata.stages.7.skipped_reason = "<dev's chosen reason or default text from the option>"
  metadata.stages.7.skipped_acknowledged_by = "dev"
  narrate: "Stage 7 skipped at dev's request: <reason>. Continuing to Stage 8."
  ```
- **If run:** proceed to Step 1 (Inject logs) below.

**Why no silent auto-skip:** even on a doc-only diff, the dev may have manually changed runtime behavior outside the doer flow (e.g. a hotfix on another branch that got merged in), or the classification heuristic may misjudge a file (e.g. a YAML that the app actually reads at runtime). Asking always is cheap (one prompt) and prevents Claude from quietly dropping the only on-device verification step.

### Log format (language-aware)

The orchestrator instructs the logger agent to use the language's basic stdout/console output (NOT the app's logger framework). The format is:

```
<basic-stdout-of-the-language>("DOER - <message>")
```

| Language | Output | Example |
|----------|--------|---------|
| Kotlin / Scala | `println(...)` | `println("DOER - LoginViewModel.onSubmit validating credentials")` |
| Java | `System.out.println(...)` | `System.out.println("DOER - AuthService refreshing token")` |
| Swift | `print(...)` | `print("DOER - LoginVC tapped submit button")` |
| TypeScript / JavaScript | `console.log(...)` | `console.log("DOER - useAuth state=loading")` |
| Python | `print(...)` | `print("DOER - login_handler validating user")` |
| Go | `fmt.Println(...)` | `fmt.Println("DOER - HandleLogin received request")` |
| Rust | `println!(...)` | `println!("DOER - validate_login start")` |
| Ruby | `puts(...)` | `puts "DOER - LoginController#create called"` |

**Rules for the message:**
- ALWAYS prefix with `DOER - ` (with the trailing space). The grep tag for cleanup.
- The message itself must include enough context to identify origin (class name, function name, key=value pairs as needed). The agent decides how much context.
- Single ticket active in runtime-verify at a time. Concurrent runtime-verify on multiple tickets is not supported (the grep tag `DOER - ` would mix them).

### Step 1: Inject logs

Invoke a general-purpose agent:

```
You are the runtime-logger agent for ticket <TICKET-ID>.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump>

== metadata.plan ==
<JSON dump>

== Diff ==
<output of `git diff <base>..HEAD`>

Scope: every file in the diff PLUS every file in the call path the ACs
exercise (deps, helpers, repositories, view models). Follow imports
outward from the diff. Stop at framework/SDK boundaries.

Read budget: every file in the diff (mandatory; you must read all of them)
PLUS up to 5 additional source files for call-path exploration. The +5 caps
exploration, not diff reads. If a BLOCKER genuinely requires more than 5
extra files, note the extra reads in your output and proceed.

Log: function entry (args), conditional branches (which + why), state
changes, external boundaries (API/DB/IO/threads/coroutines), exception
catches, function exit (return or void).

Format MANDATORY: <basic stdout for the file's language>("DOER - <message>")

The "basic stdout" varies per language. Detect by file extension:
- .kt / .kts / .scala  ->  println(...)
- .java                ->  System.out.println(...)
- .swift               ->  print(...)
- .ts / .tsx / .js / .jsx / .mjs  ->  console.log(...)
- .py                  ->  print(...)
- .go                  ->  fmt.Println(...)   (import "fmt" if missing)
- .rs                  ->  println!(...)
- .rb                  ->  puts ...
Default for any other: pick the language's most basic stdout/console output.
NEVER use the app's logger framework (Timber, log4j, structlog, winston, etc.).

The message must:
- Start with literal `DOER - ` (with the trailing space). This is the grep tag.
- Include enough context to identify origin (class name, fn name, key=value).
- Be concise. One line per call site.

Rules: never modify business logic, never touch existing logs, run the
build after to verify syntax.

DO NOT (these survive cleanup and pollute the PR):
- Create a variable solely to print its value. Inline the expression.
    Wrong:  val endpoint = if (x) "a" else "b"; println("DOER - ... endpoint=$endpoint")
    Right:  println("DOER - ... endpoint=${if (x) "a" else "b"}")
- Refactor existing code to enable logging. Do not split returns,
  chains, or expressions just to capture an intermediate value.
    Wrong:  val r = foo(); println("DOER - ... $r"); return r
    Right:  println("DOER - ... calling foo"); return foo()    (or skip this log)
- Add helpers, factories, or any function that is not a print/log line.
  The logger's only job is to add stdout calls. Anything else is out of scope.

Return a JSON list of files touched + one-line reason each. Do NOT
write a summary file, the orchestrator narrates it inline.
```

### Step 2: Temporary commit

```bash
git add -A
git commit --no-verify -m "doer(<TICKET-ID>): [TEMP] runtime debug logs. DO NOT MERGE"
```

Commit is identified later by its unique message prefix.

### Step 3: Hand off to dev

Narrate the file list inline + build/filter commands. **Project-aware filter suggestion**: detect the project type from the diff's file extensions and offer the simplest filter as the primary recommendation, with native OS log streams as fallback for release builds.

| Project type | Primary filter (simplest) | Fallback (release builds, no Metro/dev server) |
|---|---|---|
| React Native (`.tsx`/`.jsx` in diff) | Metro bundler stdout: pipe `pnpm run bundle:ios` (or equivalent) through `grep "DOER - "` | iOS: `xcrun simctl spawn booted log stream --predicate 'eventMessage CONTAINS "DOER - "'` / Android: `adb logcat \| grep "DOER - "` |
| Native iOS (`.swift` in diff) | `xcrun simctl spawn booted log stream --predicate 'eventMessage CONTAINS "DOER - "'` | Xcode console |
| Native Android (`.kt`/`.java` in diff) | `adb logcat \| grep "DOER - "` | Android Studio Logcat |
| Web (`.ts`/`.js` not in RN tree) | Browser DevTools console | Node test runner stdout |
| Backend (Python, Go, Rust, Ruby, Java server) | Process stdout / `tail -f` of the run command | Container logs / journald |

Use the table to pick the filter. If unclear, offer the top two options and let the dev pick.

```
Runtime logs injected across N files: <list>.
Build & run: <build command, detect or ask once, persist as metadata.runtime_build_command>
Exercise each AC, filter with: <primary filter from the table for this project type>
                       (fallback: <fallback filter from the table>)
Paste filtered output here when ready.
```

### Step 4: Analyze logs

When the dev pastes the log output, pass it **directly in the prompt** to the analyzer (no intermediate `runtime-log-output.txt`, the logs may be huge, no point persisting them):

```
You are the runtime-log analyzer for ticket <TICKET-ID>.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump>

== metadata.plan ==
<JSON dump>

Log excerpt from the dev's session:
<<<
{paste the user's log output here verbatim}
>>>

For each AC: was the code path hit? Did values match expected? Any
unexpected errors? Any branch that should have been exercised but wasn't?

Read budget: 0 source files. You receive metadata.ac, metadata.plan, and the
log paste inline. Do NOT read code. Your job is pure analysis on the inputs.

Return JSON:
{
  "ac_verdicts": {"AC-1": "PASS|FAIL|NOT_EXERCISED", ...},
  "evidence": {"AC-1": "<which log lines support the verdict>", ...},
  "anomalies": [...],
  "recommendation": "APPROVE | RETURN_TO_STAGE_2 | RETURN_TO_STAGE_3 | RETURN_TO_STAGE_4 | NEED_MORE_DATA",
  "rationale": "<one paragraph>"
}
```

Present the recommendation to dev: *"Analyzer recommends: <action>. <rationale>. Apply? [Y / explain / override]"*

Branches:
- **APPROVE** → Step 5
- **RETURN_TO_STAGE_N** → cleanup first, then jump back to N with findings as BLOCKERs
- **NEED_MORE_DATA** → keep logs, loop back to Step 3
- **Override** → honor dev's choice, record reason

### Step 5: Cleanup

```bash
TEMP_SHA=$(git log --grep="^doer(<TICKET-ID>): \[TEMP\] runtime debug logs" --format="%H" | head -n1)
[ -z "$TEMP_SHA" ] && { echo "ERROR: temp commit not found"; exit 1; }

git revert --no-edit "$TEMP_SHA"
git commit --no-verify --amend -m "doer(<TICKET-ID>): remove runtime debug logs"

# 5a. Tag check, zero printlns with the DOER tag must remain.
if git grep -l "DOER - " -- .; then
  echo "ERROR: Residual DOER logs found"; exit 1
fi

# 5b. Out-of-temp-commit drift check, anything that was changed by
# the temp commit but is no longer present in the revert means a debug
# artifact was added in a different commit and survived the revert.
TEMP_FILES=$(git show --pretty=format: --name-only "$TEMP_SHA" | sort -u)
DRIFT=$(for f in $TEMP_FILES; do
  if [ -f "$f" ] && ! git diff "$TEMP_SHA^" -- "$f" | grep -q .; then continue; fi
  # Compare file vs base for changes that don't match the temp commit's reverse:
  diff <(git show "$TEMP_SHA":"$f" 2>/dev/null) <(cat "$f" 2>/dev/null) > /dev/null 2>&1 || echo "$f"
done)
# Heuristic check: variables introduced and never referenced, helper
# functions added without callers, single-expression returns split into
# val + return. These often slip past the tag grep. The orchestrator
# MUST diff <base>..HEAD on every file the temp commit touched and
# scan for these patterns:
echo "Reviewing files touched by temp commit for non-log debug artifacts..."
for f in $TEMP_FILES; do
  CURRENT_DIFF=$(git diff <base>..HEAD -- "$f")
  if [ -n "$CURRENT_DIFF" ]; then
    echo "WARNING: $f still has changes after revert, likely a debug helper or refactor not in the temp commit."
    echo "Inspect manually:  git diff <base>..HEAD -- $f"
  fi
done
```

If residuals or drift detected:
- Tag residuals: re-invoke logger with *"Remove every line matching `DOER - `. Touch nothing else."*
- Drift residuals: invoke a general-purpose agent with the diff and the instruction *"This file was touched during runtime-verify. Remove any change that was added solely to enable debug logging, variables that captured a value just to print it, expressions split into val+return, helper functions with no real callers. Keep only the changes that belong to the ticket's actual implementation per `metadata.plan` (inlined in this prompt: <JSON dump>)."*

After the agent completes, amend onto the previous commit:
```bash
git add -A
git commit --no-verify --amend --no-edit
```

### Step 6: Record outcome

Persist to `metadata.stages.7`:
```json
{
  "name": "runtime-verify",
  "status": "complete",
  "ac_verdicts": {"AC-1": "PASS", ...},
  "returns_triggered": [],
  "completed_at": "<ISO8601>"
}
```
No SHAs persisted (git history IS the source of truth). No commit needed (`.doer/` gitignored).

---

## Stage 8. Docs Sync

**Goal:** update user-facing documentation when the change actually affects it. Skip aggressively when it doesn't. The doc updater never freelances; it gets an exact list of what to update.

**Mode check.** At entry, read `metadata.mode`. If `lite`, skip Stage 8 ENTIRELY without running any pre-check:
```
metadata.stages.8.status = "skipped"
metadata.stages.8.skipped_reason = "lite mode"
metadata.stages.8.skipped_acknowledged_by = "lite_mode"
narrate: "Stage 8 skipped: lite mode. Continuing to Stage 9."
```
Continue to Stage 9. The pre-checks below only run in `full` mode.

### Pre-check A: classify ticket (should docs even run?)

Auto-skip Stage 8 entirely when the ticket clearly does NOT affect user-facing docs. Heuristics:

- Title or description mentions: `fix bug`, `bug`, `internal`, `refactor`, `rename`, `cleanup`, `chore`, `revert`, `typo`, `comment`, `test only`, `restructure`.
- Diff touches ONLY paths classified as internal: `internal/`, `private/`, `*Test.*`, `__tests__/`, `spec/`, `.github/`, `docs/.doer-internal/`, build/CI config.
- Diff does NOT add or modify any public surface (no new exports, no new public functions, no new CLI flags, no new HTTP endpoints, no new env vars).

If ALL three signals point to "no public-facing change" → skip silently:
```
metadata.stages.8.status = "skipped"
metadata.stages.8.skipped_reason = "no public-facing change in this ticket"
narrate: "Stage 8 skipped: ticket is internal/refactor only, no doc updates needed."
```
Continue to Stage 9.

### Pre-check B: grep for stale references

If we did NOT skip in A, scan docs for references to identifiers the ticket REMOVED or RENAMED. This catches docs that point to functions or classes that no longer exist.

```bash
# Identifiers that disappeared from the diff:
REMOVED=$(git diff <base>..HEAD | grep -E '^-' | grep -oE '\b(fun|def|function|class|interface|object|public|export|const|let)\s+\w+' | awk '{print $NF}' | sort -u)

# Identifiers that appeared (potential renames target):
ADDED=$(git diff <base>..HEAD | grep -E '^\+' | grep -oE '\b(fun|def|function|class|interface|object|public|export|const|let)\s+\w+' | awk '{print $NF}' | sort -u)

# Doc files to scan:
DOC_FILES=$(find . -type f \( -name 'README*' -o -name 'CHANGELOG*' -o -path '*/docs/*' -o -path '*/documentation/*' \) ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/.doer/*')

# For each removed identifier, grep doc files:
for ident in $REMOVED; do
  for doc in $DOC_FILES; do
    grep -nH "\b${ident}\b" "$doc" 2>/dev/null
  done
done
```

Each match is a "stale reference" → BLOCKER if the identifier is gone (not renamed); AUTO_FIX if a clear rename target exists in `ADDED`.

### Pre-check C: detect new public surface

Scan the diff for newly added public API:
- New `export` / `public function` / `public class`
- New CLI flag definitions (look for argparse / clap / cobra / yargs patterns by file)
- New HTTP route definitions (look for `@Get`, `@Post`, `app.get(`, `router.get(`, etc.)
- New env vars referenced (`process.env.X`, `os.getenv("X")`, `System.getenv("X")`)

Build a list of NEW public surface items. Each one is a candidate for a new entry in README/CHANGELOG/docs.

### Build the exact update list

Combine A's candidate doc files (the ones that exist in the repo) with B's stale references and C's new public surface, into a structured list:

```
Update list for docs-updater:

Stale references (BLOCKER unless rename):
- README.md:42 mentions removed function `oldLogin()` (no rename target detected)
- docs/api.md:18 mentions removed class `LegacyAuth` (rename target: `AuthV2`?)

New public surface to document:
- New CLI flag `--retry-count` added in src/cli.ts
- New public function `validateOtpEmail` in src/auth.ts

Doc files to potentially update:
- README.md (mentions are above)
- CHANGELOG.md (always candidate when public surface added)
- docs/api.md (mentions stale identifier)
```

If the update list is EMPTY (no stale references AND no new public surface), skip Stage 8 silently:
```
metadata.stages.8.status = "skipped"
metadata.stages.8.skipped_reason = "no stale doc references, no new public surface"
```
Continue to Stage 9.

### Invoke docs-updater (only if there is an explicit list)

```
You are the docs-updater agent for ticket <TICKET-ID>.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump>

== metadata.plan ==
<JSON dump>

== Last 2 metadata.changelog entries ==
<JSON dump>

== Diff ==
<output of `git diff <base>..HEAD`>

Update list (this is your ENTIRE scope, do not freelance beyond it):
<paste the structured list from the pre-check>

Read budget: ONLY the doc files named in the update list above. 0 source
files (the diff is already inlined; pre-checks already validated stale refs
and new public surface). If you feel you need to read a source file to apply
a doc edit, that is a sign the pre-check missed something; flag it in the
output instead of exploring.

For each stale reference: rename if a clear target exists, otherwise
remove or rewrite that mention to reflect what now exists.

For each new public surface item: add the appropriate entry in
README/CHANGELOG/docs as called out by the list. Match the existing
style of those files.

Rules:
- Do NOT touch sections of doc files that are not in the update list.
- Do NOT introduce marketing language or superlatives.
- Do NOT add em-dashes.
- Keep changes minimal and factual.

Output JSON: {"changelog_appendix": {"stage": 8, "iteration": 1, "kind": "initial",
"items": [{"type": "step", "text": "<one-line summary of doc edit>"}, ...]}}.
```

### Commit

```bash
git add -A
git commit --no-verify -m "doer(<TICKET-ID>): sync documentation"
```

If the docs-updater produced no diff (rare; the list was non-empty but the agent declined to change anything), narrate that and skip the commit.

---

## Stage 9. Wrapup (Lessons + Assumptions + Performance)

**Goal:** validate assumptions, capture lessons, persist a one-paragraph summary plus performance stats into `metadata.json`, clean `.doer/` from branch history. No `wrapup.md` sidecar (everything goes into `metadata.summary`, `metadata.performance`, `metadata.assumptions_validation`, `metadata.lessons_captured`).

**Mode-dependent steps.** Steps 1 and 2 run only in `full` mode. In `lite` mode, skip them and jump to step 3 (the orchestrator still produces `metadata.summary` and `metadata.performance`, but auto-generates without dev interaction). Step 5 (history cleanup) skips its confirmation prompt in `lite` mode and runs the cleanup directly after creating the backup ref. All other steps run identically in both modes.

1. **Validate assumptions.** *(`full` mode only; skipped in `lite`.)* Read `metadata.plan.assumptions`. For each assumption, decide VALIDATED, INVALIDATED (with reason), or UNVERIFIED based on what actually happened during Stages 4-7. Persist as `metadata.assumptions_validation`:
   ```json
   "assumptions_validation": [
     {"text": "<assumption from metadata.plan.assumptions>", "status": "VALIDATED | INVALIDATED | UNVERIFIED", "reason": "<one-line, only if INVALIDATED>"}
   ]
   ```

2. **Capture lessons (with auto-detected candidates).** *(`full` mode only; skipped in `lite`.)*

   Before asking the user, scan `metadata.json` for signals that often produce a lesson worth keeping. Build a candidate list:

   | Signal | Suggested lesson framing |
   |--------|--------------------------|
   | A looped stage (4 or 5) hit the max of 3 iterations and was accepted with residuals | "Stage <N> didn't fully converge. What unresolved class of issue is worth flagging for next time?" |
   | A looped stage took 3 iterations to converge | "Stage <N> ({name}) needed 3 iterations. What pattern made it slow?" |
   | Stage 2 or Stage 3 used its single retry (`metadata.stages.<N>.retry_used == true`) | "Stage <N> failed deterministic checks once. What kept the planner/test-writer from getting it right the first time?" |
   | Stage 7 (Runtime Verify) returned RETURN_TO_STAGE_<N> | "Runtime behavior diverged from tests. What gap in the test strategy let this through?" |
   | An assumption was marked INVALIDATED in step 1 | "Assumption '{text}' turned out wrong. What should we check up front next time?" |
   | Stage X had BLOCKERs categorized as 'security' or 'data integrity' | "A {category} BLOCKER appeared late. Is this a class of mistake we keep making?" |

   Present the candidates to the user IF any exist:
   ```
   Lesson candidates detected from this ticket:
   1. <signal>: <framing>
   2. ...

   Reply with: comma-separated numbers to accept, `add: <your lesson>` to add another, `none` to skip, or `edit <N>: <new framing>` to reword.
   ```

   For each accepted candidate, ask the user to fill in: `what happened`, `why it matters`, `takeaway`. Or accept the orchestrator's draft based on `metadata.changelog` and let the user edit. **Read budget for any agent invoked here: 0 source files.** Lessons drafting reads only `metadata.json` fields and `git log/diff`; it does NOT explore the codebase.

   If NO signals detected, ask once: *"Any lesson worth saving for future tickets? Reply with one, or `none`."* (one prompt, not multiple).

   For each lesson, write to the GLOBAL pool at `<doer-skill-dir>/lessons/{slug}.md` (lessons remain as files; they are cross-project knowledge, not per-ticket state). Format:
   ```markdown
   ---
   slug: <kebab-case>
   captured_from: <TICKET-ID>
   captured_at: <ISO8601>
   when_it_applies: <short context>
   ---
   ## What happened
   ## Why it matters
   ## Takeaway
   ```

   Then persist a reference to each lesson in `metadata.lessons_captured`:
   ```json
   "lessons_captured": [
     {"slug": "<kebab-case>", "takeaway": "<one-line>"}
   ]
   ```

3. **Persist summary + performance into `metadata.json`.** Pull data from `metadata.json` itself (stage timestamps, iteration counts, retry flags), `git log/diff` (commits/LOC), and the repo test command (pass/fail). Write into:

   ```json
   "summary": "<one-paragraph plain prose: what the ticket delivered, what was actually changed, any notable surprises>",

   "performance": {
     "started":     "<ISO8601, from metadata.created_at>",
     "completed":   "<ISO8601, now>",
     "wall_clock":  "<duration string>",
     "active":      "<duration string; equals wall_clock since there is no pause concept>",
     "stages": [
       {"n": 1, "name": "ac-confirm", "status": "complete", "duration": "<HH:MM:SS>"},
       {"n": 2, "name": "plan",       "status": "complete", "duration": "...", "retry_used": false},
       {"n": 4, "name": "code",       "status": "complete", "duration": "...", "iterations": 2, "blockers_resolved": 1},
       ...
     ],
     "code": {"commits": <N>, "files": {"total": <N>, "src": <N>, "tests": <N>, "docs": <N>}, "loc": {"add": <N>, "rem": <N>}, "tests_passing": "<X/Y>"},
     "agents": {"<agent-name>": <invocation-count>, ...},
     "convergence": {"iter1": <N>, "iter2+": <N>, "max_iter_hit": <N>, "avg": <N>},
     "reviewer_roi": "<X>/<Y> looped stages converged on iter 1 with zero BLOCKERs (<%>%). Use this over time to decide if the reviewer should become opt-in."
   }
   ```

   No sidecar file. Everything is in `metadata.json` and the dev (or `/doer status`) reads it from there.

4. **Update `metadata.json`:** `status: "complete"`, `completed_at: <ISO8601>`. Set `metadata.stages.9.status = "complete"`, `metadata.stages.9.verified_with = <SKILL version>`.

5. **PR-ready history cleanup**: remove `.doer/` from prior commits on the feature branch:
   ```bash
   DIRTY=$(git log --format=%H --diff-filter=ACMR -- '.doer/*' "<base>..HEAD" 2>/dev/null)
   ```
   If empty → skip to step 6. Otherwise:

   **`full` mode:** confirm with user (destructive, changes SHAs). On approval, proceed with the cleanup commands below. On decline, narrate *"Skipping history cleanup. Run /doer cleanup-history later."*

   **`lite` mode:** skip the confirmation prompt and run the cleanup commands directly (the backup ref is still created so rollback remains possible). Narrate *"Stage 9 lite: history cleanup ran without confirmation. Backup ref: refs/doer-backup/<TICKET-ID>-pre-cleanup-<ts>."*

   Cleanup commands (both modes):
   ```bash
   git update-ref "refs/doer-backup/<TICKET-ID>-pre-cleanup-$(date +%s)" HEAD
   git filter-branch -f --index-filter 'git rm -r --cached --ignore-unmatch .doer/' --prune-empty "<base>..HEAD"
   git update-ref -d refs/original/refs/heads/<branch-name> 2>/dev/null || true
   ```
   Verify `git log --diff-filter=ACMR -- '.doer/*' "<base>..HEAD"` is empty. In `full` mode, tell the user the backup ref (rollback: `git reset --hard <ref>`).

6. **Final commit** (only if uncommitted real changes, wrapup itself has none since it only writes to `.doer/`):
   ```bash
   if ! git diff --quiet || ! git diff --cached --quiet; then
     git add -A
     git commit --no-verify -m "doer(<TICKET-ID>): wrapup"
   fi
   ```

7. **Recommend a final commit message.** The dev typically squashes the per-stage commits into a single PR-ready commit. Generate a recommendation based on:
   - `metadata.ac.in_scope` (what the ticket promised)
   - `metadata.changelog` (what was actually done across all stages)
   - `git log <base>..HEAD --oneline` (commit history of the branch)

   Format MANDATORY: `<TICKET-ID>: <imperative subject line, ≤72 chars>`

   The subject line should:
   - Use imperative mood ("Add X", "Fix Y", "Refactor Z", not "Added", "Fixes", "Refactoring")
   - Be specific (mention the actual change, not just "implement ticket")
   - Stay under 72 characters total (including the `<TICKET-ID>: ` prefix)

   Present the recommendation in a fenced code block so the dev can copy-paste:

   ````
   Recommended commit message for the squashed PR commit:

   ```
   <TICKET-ID>: <imperative subject>
   ```

   You can use this as-is or adjust it before squashing your branch commits.
   ````

8. **Help with the PR description.**

   First, auto-detect a template in the repo. Standard locations (in priority order):

   ```
   .github/PULL_REQUEST_TEMPLATE.md
   .github/pull_request_template.md
   .github/PULL_REQUEST_TEMPLATE/*.md          (multi-template folder)
   .gitlab/merge_request_templates/*.md
   .gitlab/merge_request_templates/Default.md
   docs/pull_request_template.md
   PULL_REQUEST_TEMPLATE.md                    (repo root)
   ```

   Three cases:

   **Case 1: exactly one template found.** Use it directly, no prompt. Narrate: *"Detected PR template at <path>. Filling it in."* Then proceed to fill it (logic same as "user pastes a template" below).

   **Case 2: multiple templates found** (multi-template folder). Ask: *"Found <N> PR templates: <list>. Which one? [number / `default` / `skip`]"*. Use the chosen one, or fall through to `default`/`skip`.

   **Case 3: no template found.** Ask via `AskUserQuestion`:

   *"No PR template detected in standard locations. Paste your team's template (markdown is fine), reply `default` for a generic structure, or `skip` to handle it yourself."*

   Three branches for case 3:

   **a. User pastes a template:** Detect every section heading and `<!-- comment -->` placeholder. Fill each section using:
   - `metadata.ac` (what was promised) for "What is the story about" / "Change Summary" / "Current bug behavior" sections.
   - `metadata.changelog` (what was actually done) for "My solution" / "My fix" / "How I solved it" sections.
   - `metadata.stages.7.ac_verdicts` (if Stage 7 ran) for "Verification" / "Testing" sections.
   - `metadata.lessons_captured` and `metadata.assumptions_validation` for "Notes" / "Risks" sections.
   - `metadata.ticket_id` and `metadata.title` for ticket ID and title.

   If a section in the template does not apply to this ticket (example: a "Regression" section in a feature ticket), keep the heading present but write `> N/A for this ticket.` so the dev sees the orchestrator considered it.

   Preserve the template verbatim: every heading, every HTML comment, every `/label` or `/cc` directive at the bottom. Only fill the body slots.

   **b. User replies `default`:** Generate a generic structure:

   ```markdown
   ## Summary
   <one-paragraph description of what this ticket delivered, taken from metadata.summary or metadata.ac.in_scope>

   ## Changes
   <bulleted list of what was implemented, taken from metadata.changelog (decision and step items)>

   ## How to test
   <bulleted list of test scenarios, taken from metadata.ac.in_scope rendered as Given/When/Then>

   ## Verification
   <if Stage 7 ran: AC verdict summary from metadata.stages.7.ac_verdicts. Otherwise: "Unit tests pass: <X/Y>.">

   ## Notes
   <relevant entries from metadata.lessons_captured or metadata.assumptions_validation (INVALIDATED items), if any. Otherwise omit this section.>
   ```

   **c. User replies `skip`:** Skip the PR description step entirely. Continue to step 9.

   **Formatting rules for whatever is generated (a or b):**
   - Apply Core Principle 9 (no em-dashes anywhere).
   - Use plain prose plus bullets. No marketing language, no superlatives.
   - Keep it terse. Reviewers read PR descriptions fast.

   Present the result in a fenced code block so it copy-pastes directly into GitHub/GitLab/etc.:

   ````
   Suggested PR description (copy-paste ready):

   ```markdown
   <generated description>
   ```
   ````

9. Narrate: *"Ticket <TICKET-ID> complete. {N} commits on `<branch>` (post-cleanup). Summary and performance stats persisted to .doer/tickets/<TICKET-ID>/metadata.json (`summary`, `performance`). Run your pre-commit checks, squash with the recommended message, paste the PR description, then push and open the PR manually."*

---

## Resume flow (entered when `/doer <TICKET-ID>` finds existing metadata)

This is the path that runs when `/doer <TICKET-ID>` detects `./.doer/tickets/<TICKET-ID>/metadata.json` already exists. The dev did NOT have to type a separate "continue" command, the orchestrator detected the existing ticket and switched modes automatically.

1. Read `./.doer/tickets/<TICKET-ID>/metadata.json`.
2. If `status == "complete"`, warn the user (use `/doer verify` for closed tickets, not resume).
3. Check out the feature branch if not already on it:
   ```bash
   git checkout <branch-name>
   ```
4. **Workspace Guard. RUN INLINE, do NOT just reference it.** These exact bash commands MUST execute before step 5. Do NOT skip, do NOT defer, do NOT replace with a comment saying "the Guard will run".

   ```bash
   # 4a. Cheap idempotency check
   GUARD_OK=$(jq -r '.workspace_guard // empty' .doer/tickets/<TICKET-ID>/metadata.json 2>/dev/null)
   EXCLUDE_HAS_DOER=$(grep -qxF '.doer/' .git/info/exclude 2>/dev/null && echo yes || echo no)
   if [ "$GUARD_OK" = "ok" ] && [ "$EXCLUDE_HAS_DOER" = "yes" ]; then
     echo "Workspace Guard: already satisfied (skipping)."
   else
     # 4b. Ensure exclude file exists and contains .doer/
     mkdir -p .git/info
     [ -f .git/info/exclude ] || touch .git/info/exclude
     grep -qxF '.doer/' .git/info/exclude || echo '.doer/' >> .git/info/exclude

     # 4c. Verify the rule actually takes effect
     mkdir -p .doer && touch .doer/.guard-test
     STATUS=$(git status --porcelain .doer/.guard-test 2>/dev/null)
     rm -f .doer/.guard-test
     if [ -n "$STATUS" ]; then
       echo "ERROR: .doer/ exclude rule did not take effect. Investigate before proceeding."
       exit 1
     fi

     # 4d. Detect already-tracked .doer/ files (handle once per ticket)
     TRACKED=$(git ls-files .doer/ 2>/dev/null | head -1)
     # If TRACKED non-empty, surface the 3-option prompt to the user (see Workspace Guard section
     # for the exact prompt text and default to option 3).

     # 4e. Migrate stale per-repo lessons → global pool (see Workspace Guard step 5
     # for the full bash + conflict-handling rules). Idempotent: silent no-op
     # when .doer/knowledge/lessons/ doesn't exist or is empty.

     # 4f. Migration Check (see Versioning & Migrations). If
     # metadata.skill_version < current SKILL frontmatter version, apply each
     # registered migration in order. Auto-silent. Narrate one summary line at end.

     # 4g. Mark satisfied: write workspace_guard = "ok" to metadata.json
     echo "Workspace Guard: applied."
   fi
   ```

5. **Self-check before proceeding.** Verify both conditions are now true:
   - `.git/info/exclude` contains `.doer/` (run `grep -qxF '.doer/' .git/info/exclude`)
   - The active ticket's `metadata.json` has `"workspace_guard": "ok"`

   If either fails, STOP. Do NOT continue resuming. Narrate the failure and ask the user how to proceed. The Guard is a precondition, not a suggestion, proceeding without it pollutes the team's PR.

6. Read `metadata.stages.<current_stage>.status`:
   - `pending` → start the stage normally.
   - `in_progress` → resume at the same iteration (read loop state if any).
   - `blocked` (Stages 2 and 3 only) → re-run ONLY the deterministic checks for that stage (no new agent invocation). See "Resuming from `blocked`" subsection in the stage's docs. If checks pass, mark complete and proceed.
   - `complete | skipped | imported` → unexpected here (current_stage should not point at one of these). Treat as data drift: advance current_stage to the next pending stage and continue.
7. Narrate: "Resuming <TICKET-ID> at Stage {N} ({name}){, iteration {i}}{, status: {status}} in {mode} mode." (Read `metadata.mode` for the mode label.) Then proceed (the user invoked `/doer continue` explicitly, so resume is the implicit intent, do NOT ask for further confirmation).
8. Proceed.

---

## `/doer status <TICKET-ID>`

Render:

```
Ticket: <TICKET-ID>, <title>
Mode: <lite | full>  Branch: <branch>  Status: <status>
Current Stage: {N} ({name})

Progress:
  [✓] 1 ac-confirm
  [✓] 2 plan
  [✓] 3 tests
  [~] 4 code      (iteration 2/3, 1 BLOCKER open)
  [ ] 5 code-review
  ...

Blockers: <list or "none">
Commits: <count>
```

---

## `/doer list`

List every directory under `./.doer/tickets/`, one line each:

```
ABC-123   [in_progress]  Stage 4 (code)         fix-login-timeout
ABC-119   [complete]    ,                      add-redis-cache
ABC-110   [in_progress]  Stage 2 (plan)         refactor-auth  (last touched 3d ago)
```

---

## `/doer verify <TICKET-ID>`

**Two purposes** since 2.10.0:

1. **Missing-stage verify (original):** run stages that exist in the current SKILL but did NOT exist in `metadata.stages` when the ticket closed. Additive.
2. **Forced reverify (escape hatch):** force the spot-check pass on stages whose `verified_with` is current but the dev wants to re-validate anyway. Useful for debug or when the dev suspects something despite version match.

The auto-reverify path inside the Migration Check (Phase 2) already handles 99% of cases automatically. This command is only needed when:
- A ticket is `complete` and the dev declined the auto-reverify prompt earlier but now wants it.
- The dev wants to force a fresh spot-check even though the SKILL version matches.

### Step 1: Load + Guard

1. Read `metadata.json`. Error if not found.
2. Error if `status != "complete"` (use `/doer continue` instead).
3. **Workspace Guard. RUN INLINE** (same bash block as `/doer continue` step 4). Self-check: `.git/info/exclude` contains `.doer/` AND `metadata.workspace_guard == "ok"`. STOP if either fails.

### Step 2: Compute missing stages

`missing = current_skill_stage_names \ ticket_executed_stage_names` (preserve current-skill order). If empty → narrate *"Nothing to verify."* and stop.

### Step 3: Per-stage approval

Present the missing list with one-line descriptions. Ask per stage via `AskUserQuestion`: *"Run `<stage-name>` retroactively? [Y/n/skip-all]"*. `skip-all` aborts remaining questions; only previously approved stages run.

### Step 4: Checkout branch

```bash
git fetch --all
# Check out metadata.branch if it still exists.
# If branch was deleted post-merge, check out metadata.commits[-1] (detached HEAD)
# and warn the user.
```

### Step 5: Run each approved stage

For each approved stage, in current-skill order:

1. Narrate: *"Running retroactive stage: <name>."*
2. Mark in metadata BEFORE running (resume safety):
   ```json
   "stages": {"<N>": {"name": "...", "status": "retroactive_in_progress", "added_retroactively": true, "started_at": "..."}}
   ```
3. Execute using the current skill's logic for that stage (same subagent calls, loops, commits as a normal run).
4. On completion, update metadata: `status: "complete"`, `added_retroactively: true`, `retroactive_verdict: <APPROVED | RETURN_TO_STAGE_N | ...>`, `completed_at`.
5. **If verdict is RETURN_TO_STAGE_N (reopen signal):**
   - Set top-level `status: "in_progress"`, `current_stage: N`.
   - Add blocking condition: `{"type": "retroactive-return", "from_stage": "<name>", "reason": "..."}`.
   - Narrate: *"Retroactive `<name>` returned <verdict>. Ticket reopened at Stage N. Run `/doer continue <TICKET-ID>` to proceed."*
   - STOP. Do not run remaining retroactive stages.

### Step 6: Finalize

Append to `metadata.verify_runs[]` (preserve prior entries):
```json
{
  "verified_at": "<ISO8601>",
  "stages_added_retroactively": ["runtime-verify", "..."],
  "all_verdicts_approved": true
}
```

No commit needed, `metadata.json` is in `.doer/` (gitignored). Per-stage commits during Step 5 already captured any real code changes.

Narrate: *"Verify complete. <N> stages added retroactively. Ticket <TICKET-ID> is up to date."*

### Edge cases

- Different name in metadata vs current skill → treated as not-missing (name match is the contract). Manual override only.
- Ticket has stages the current skill doesn't → fine, kept. Verify is additive.
- Aborted mid-verify → state persisted via Step 5.2 mark; next verify recomputes from where it left off.

---

## `/doer cleanup-history <TICKET-ID>`

Standalone version of the wrapup's history cleanup step. Use it when:

- A ticket already wrapped up but the cleanup was skipped (or declined at the prompt), and you now want to do it before opening the PR.
- A ticket is mid-flight and you want to preview / verify the cleanup will work before reaching wrapup.
- You imported pre-existing work that included `.doer/` files in earlier commits.

### Steps

1. Read `./.doer/tickets/<TICKET-ID>/metadata.json`. Resolve `branch-name` and `base-branch` (default `main`, fall back to `master`).
2. Verify the user is currently on `branch-name`. If not, ask before checking it out.
3. Run the **Workspace Guard** (idempotent, ensures `.doer/` is excluded going forward).
4. Run the same logic as Stage 9 step 5 (PR-ready history cleanup): detect dirty commits via `git log --diff-filter=ACMR -- '.doer/*'`, confirm with user (always, even if `metadata.mode == "lite"`; this command is invoked manually so the dev should explicitly approve), create backup ref, `git filter-branch` to strip `.doer/` from history, verify the strip succeeded, reset housekeeping refs, narrate the backup ref name.
5. Narrate the result. Do NOT commit anything new, this command is purely a history rewrite.

### Safety

- Always creates a backup ref under `refs/doer-backup/<TICKET-ID>-pre-cleanup-<timestamp>` before rewriting. Tell the user the ref name; they can `git reset --hard <ref>` to roll back.
- Refuses to run if the branch has been pushed AND has commits other people may have based work on. Detect via `git rev-list --count HEAD@{u}..HEAD` and `git rev-list --count HEAD..HEAD@{u}` if upstream is set; warn if the upstream tracking suggests rewrite would be disruptive.

### Skip when not needed

If the cleanup detection finds zero dirty commits, narrate *"Nothing to clean, branch already free of .doer/ content."* and exit without prompting.

---

## Error Handling

- **Agent returns error:** narrate the error, ask user to retry (max 3), or pause.
- **Git operation fails:** narrate, present options (resolve manually, pause, abort stage).
- **Tests cannot be detected:** ask the user for the test command. Save it to `metadata.test_command` for future stages.
- **User says `stop` / `wait` / `hold on`:** state is already persisted after each Agent return. Narrate the current position and stop. Resume via `/doer continue <TICKET-ID>` later.

---

## Agent Invocation Contract

All subagents (doer or reviewer) must:
- Receive a prompt that contains the relevant `metadata.json` slices inlined (no sidecar file reads), specifies the artifacts to produce (code, tests, docs), success criteria, and the "do not" list (e.g. "do not ask the user questions, the orchestrator handles that").
- Write code/test/doc artifacts directly to the working tree (not to `.doer/`).
- Return a JSON object containing a `changelog_appendix` (which the orchestrator persists into `metadata.changelog`) plus any stage-specific output (e.g. `code_review_entry`, `tests_added`, `plan`).
- For doer agents: also include `{"status": "success" | "failed", "summary": "<one line>"}` at the top level.

The orchestrator (this skill) is the sole user-facing voice. Subagents must NOT invoke `AskUserQuestion`.

---

## Locale resolution (READ THIS FIRST)

**Mandatory first action of every `/doer ...` invocation, before any other tool call:** read `preferences.md` next to this SKILL.md. If it has `locale: <code>`, set the operating locale.

**The first user-facing word MUST be in the operating locale**: anchors the conversation against English drift.

### Priority (highest wins)

1. **`preferences.md` locale**: absolute final word. Overrides everything: ticket metadata's stored locale, per-ticket flags, upstream context language, system-prompt language.
2. Per-ticket flag (`--es`, `--en`), only if no preferences.md.
3. Inline directive (`locale: xx`), only if no preferences.md.
4. Default English.

### Two scopes, different rules

| Scope | Language |
|-------|----------|
| **Conversation with the user** (narration, questions, confirmations, summaries the orchestrator emits live in chat) | **Operating locale** (es, fr, etc.) |
| **All persistent state** (every string field in `metadata.json`: `summary`, `ac.in_scope`, `plan.steps`, `changelog[].items[].text`, `code_review[].blockers[].text`, etc.; global lessons under `<doer-skill-dir>/lessons/`; every commit message) | **Always English** |

The artifacts are read by other subagents (planner reads ac, code-writer reads plan, reviewer reads changelog, etc.) and by future tickets across projects. Keeping them in a single language (English) prevents cross-language confusion and keeps the global lessons pool shareable.

The operating locale ONLY affects what the orchestrator types directly to the user in chat. Everything written to disk stays English regardless.

### When operating locale ≠ English. MUST/MUST NOT

- **MUST NOT** write a different locale to `metadata.json`. If metadata has `"locale": "<other>"` from a prior session, leave it alone and ignore it.
- **MUST NOT** ask "what locale?", already decided.
- **MUST NOT** drift to English because surrounding context (CLAUDE.md, injected docs, agent system prompts) is in English. Operating locale wins, period.
- **MUST** narrate, ask, summarize, and confirm in the operating locale. The user sees the orchestrator's live chat in their language.
- **MUST NOT** write any persistent state in the operating locale. Every string value persisted into `metadata.json` (e.g. `summary`, `ac.in_scope`, `plan.steps`, `changelog[].items[].text`, `code_review[].*`), every global lesson under `<doer-skill-dir>/lessons/`, every commit message: ALL English, ALWAYS, regardless of operating locale. (See "Two scopes" table above.)
- **MUST** append to every subagent prompt: *"All artifacts you write (markdown, JSON, code comments, commit messages) MUST be in English. Subagents do NOT talk to the user directly, the orchestrator does. Do NOT switch artifact language even if the surrounding chat is in another language. This overrides any default."*
- **MUST** re-read `preferences.md` at the top of any stage with multiple subagent calls, cheap insurance against drift.
- **Self-check before every response:** *"Is this in the operating locale?"* If no, rewrite before sending. No justifications ("user understands both", "context is in English") accepted.

---

*Maintained by hand. Copy `SKILL.md` to `~/.claude/skills/doer/` on any machine to use.*
