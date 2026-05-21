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
version: 6.0.0
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

9. **EM-DASHES ARE PROHIBITED.** Across every output the orchestrator and its subagents produce: chat narration, questions, summaries, every value persisted into `metadata.json` (string fields like `summary`, `changelog[].items[].text`, `ac.in_scope`, `plan.steps`, `code_review[].blockers[].text`), generated commit messages, generated PR descriptions, global lessons under `${CLAUDE_PLUGIN_ROOT}/lessons/`, comments injected into code. ZERO `, ` characters anywhere.
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


---

## Context Continuity (Anti-Compaction)

Follow the protocol in `${CLAUDE_PLUGIN_ROOT}/lib/heartbeat.md`. The doer skill MUST run the heartbeat self-check at every stage transition and at every `/wk:doer continue` invocation, per that document.

---

## Versioning & Migrations

Follow the protocol in `${CLAUDE_PLUGIN_ROOT}/lib/migrations.md`. That file owns the SemVer rules, the Migration Check (Phase 1 + Phase 2 with auto-reverify), the mandatory Bash-execution rule for reading versions, and every per-version migration block from `1.x -> 2.0.0` through `5.0.0 -> 6.0.0`.


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

---

## Knowledge & State Layout

The per-repo `./.doer/` layout, the global `lessons/` location, and the full `metadata.json` schema are documented in `${CLAUDE_PLUGIN_ROOT}/lib/memory-paths.md`. Read that file before reading or writing any persistent ticket state.


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

2. **Infer testing strategy, then ask ONE confirmation.** After all six intake questions are answered (and the prior-work follow-ups if applicable), but BEFORE initializing `metadata.json`, the orchestrator infers `testing_strategy.mode` (no question, orchestrator decides) and presents the inference in a single `AskUserQuestion` for confirmation.

   **Step 2A. Infer `testing_strategy.mode` (no question).**

   Read `metadata.intake.title`, `metadata.intake.description`, and `metadata.intake.raw_acs`. Apply the following signal rules; each matched signal contributes to its bucket. Persist the matched signal IDs into `signals[]`.

   **Signals for `direct`:**
   - Title contains an update-class verb (`update`, `change`, `edit`, `rename`, `fix`, `tweak`) AND a small-thing noun (`label`, `copy`, `string`, `constant`, `config`, `default`, `placeholder`, `typo`, `text`, `value`); both anywhere in the title (not contiguous). Signal ID: `direct.title.verb_noun`.
   - Title contains any of the contiguous compounds: `rename`, `update label`, `change label`, `update copy`, `fix typo`, `update string`, `update constant`, `update config`, `update default`, `update placeholder`. Signal ID: `direct.title.compound`.
   - Description has no ACs (`raw_acs == "derive"` or empty) AND no conditional-logic language (no `if`, no `when`, no `should`). Signal ID: `direct.no_acs_no_logic`.
   - Description length < 300 chars AND no Given/When/Then language. Signal ID: `direct.short_description`.
   - Description matches `change X to Y` or `update X from Y to Z` patterns. Signal ID: `direct.change_x_to_y`.
   - Title contains: `mapper`, `transformer`, `util`, `utility`, `extension`, `helper`, `parser`, `calculator`, `converter`, `validator`. Signal ID: `direct.technical_unit_title`.
   - Ticket is a refactor with no behavior change. Signal ID: `direct.refactor_no_behavior`.

   **Signals for `bdd`:**
   - Title or description contains user-story language: `as a user`, `should see`, `should be able to`, `when user`, `given`, `when`, `then`. Signal ID: `bdd.user_story_language`.
   - Raw ACs are written in Given/When/Then format (case-insensitive `GIVEN`/`WHEN`/`THEN` markers). Signal ID: `bdd.gwt_in_acs`.
   - Description suggests an observable behavior change from a user or QA perspective. Signal ID: `bdd.observable_behavior`.
   - Description suggests a bug reported by QA or a user (not a dev-internal issue). Signal ID: `bdd.bug_user_reported`.
   - Description involves analytics instrumentation with AC (events, STag, GA4, SOT). Signal ID: `bdd.analytics_with_ac`.
   - Description involves a flow with multiple states or actors. Signal ID: `bdd.flow_multi_state`.

   **Decision logic:**
   - Count signals per mode. Highest count wins.
   - Tie between `direct` and `bdd` → `bdd` wins (safer default for coverage).
   - If no signals match at all → default to `bdd`.

   Persist a draft of `testing_strategy = { mode, rationale, signals }` to local memory (NOT to disk yet; the dev still has to confirm in step 2B).

   **Step 2B. Confirmation.** Present the inference in ONE `AskUserQuestion` block:

   ```
   Question: Doer inferred the following for this ticket. Confirm or override?

   Testing strategy: <DIRECT | BDD> (<one-sentence rationale>)
     Signals: <comma-separated list of matched signal IDs>

   Options:
     - Y: accept
     - change strategy:<direct|bdd>: override testing strategy
   ```

   Acceptance rules:
   - `Y` → accept; persist `testing_strategy` as inferred; `overridden_by_dev = false`.
   - `change strategy:<value>` → override `testing_strategy.mode` to the given value; set `testing_strategy.overridden_by_dev = true`. Re-narrate the final state for the dev (one short summary line) before proceeding.

   After confirmation, persist:
   - `metadata.testing_strategy = { mode, rationale, signals, overridden_by_dev }`

   **Once set, `testing_strategy.mode` does not change for the remainder of the ticket.**

3. Initialize `metadata.json` (intake fields + chosen mode are embedded, see `${CLAUDE_PLUGIN_ROOT}/lib/memory-paths.md` for the full schema):

   ```json
   {
     "ticket_id": "<TICKET-ID>",
     "title": "<title>",
     "branch": "<branch-name>",
     "status": "in_progress",
     "current_stage": 1,
     "skill_version": "<read from frontmatter at intake time, e.g. 6.0.0>",
     "testing_strategy": {
       "mode": "<direct | bdd chosen in step 2>",
       "rationale": "<one-sentence rationale>",
       "signals": ["<signal-id>", "..."],
       "overridden_by_dev": false
     },
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

   **Per-stage `verified_with` rule.** When a stage transitions to `status: "complete"` (or `"skipped"`, or `"imported"`), the orchestrator MUST also write `verified_with: "<current SKILL frontmatter version>"` on that stage. Example after Stage 2 finishes under SKILL 6.0.0:
   ```json
   "2": {"name": "plan", "status": "complete", "verified_with": "6.0.0", "completed_at": "...", ...}
   ```
   This is the only mechanism that lets the auto-reverify check (see `${CLAUDE_PLUGIN_ROOT}/lib/migrations.md`) know which stages to spot-check after a SKILL upgrade.

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

---

## Workspace Guard

Follow the protocol in `${CLAUDE_PLUGIN_ROOT}/lib/workspace-guard.md`. The Guard MUST run at every entry point (intake, `/wk:doer continue`, `/wk:doer verify`, any first action after context reset).

---

## Narration Protocol

Follow the protocol in `${CLAUDE_PLUGIN_ROOT}/lib/narration.md`. That file owns Core Principles 1 and 9 (narration first, em-dashes prohibited), turn boundary rules, the auto-proceed contract, performance counters, and locale resolution (`preferences.md` is the authoritative source for the operating locale).

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

Before marking ANY `metadata.stages.<N>.status = "complete"` (or `"skipped"` / `"imported"` / `"blocked"` / `"deferred"`), the orchestrator MUST run a deterministic checklist that validates the per-stage required fields are present in metadata. This is a no-LLM check (just JSON field presence). It catches the common post-compaction failure mode where the orchestrator forgets which fields the schema requires.

**`deferred` status (Stage 3, `direct` mode only).** When Stage 3 sets `status = "deferred"` on first entry (because `metadata.testing_strategy.mode == "direct"`), the only required fields are `name`, `status`, `testing_strategy_mode`. `verified_with` is NOT required for `deferred` (the stage has not actually run yet); it is set when the stage transitions to `complete` after the second visit.

**If any required field is missing, the orchestrator MUST write it before transitioning.** If it cannot be derived (e.g. `started_at` was never recorded), use the best available proxy (e.g. `git log` of the stage's commit timestamp, or current time, or `null` with an explanatory note). Narrate which fields were back-filled and why.

### Required fields per stage

| Stage | Always required | Required when status is `complete` | Required when status is `skipped` |
|---|---|---|---|
| 1 ac-confirm | `name`, `status`, `verified_with` | `completed_at` | `skipped_reason` |
| 2 plan | `name`, `status`, `verified_with` | `completed_at`, `retry_used` | `skipped_reason` |
| 3 tests | `name`, `status`, `verified_with`, `testing_strategy_mode` | `completed_at`, `retry_used` | `skipped_reason` |
| 4 code | `name`, `status`, `verified_with` | `started_at`, `completed_at`, `iterations`, `loop_outcome`, `blockers_resolved_total` | n/a (Stage 4 is never skipped) |
| 5 code-review | `name`, `status`, `verified_with` | `started_at`, `completed_at`, `iterations`, `loop_outcome`, `blockers_resolved_total` | n/a |
| 6 quality-gate | `name`, `status`, `verified_with` | `started_at`, `completed_at`, AND either (`test_summary` if tests ran) OR (`skipped_reason = "no diff since last green"` if skip-safe path) | `skipped_reason` |
| 7 runtime-verify | `name`, `status`, `verified_with` | `started_at`, `completed_at`, `ac_verdicts` | `skipped_reason`, `skipped_acknowledged_by = "dev"` |
| 8 docs-sync | `name`, `status`, `verified_with` | `started_at`, `completed_at` | `skipped_reason` |
| 9 wrapup | `name`, `status`, `verified_with` | `completed_at`, `commit_message_presented`, `pr_description_presented` | n/a |

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
2. Read `${CLAUDE_PLUGIN_ROOT}/lessons/*.md` (global, cross-project, see `${CLAUDE_PLUGIN_ROOT}/lib/memory-paths.md` for path resolution). Note any whose `when_it_applies` matches this ticket.

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

If tests detected, run them via repo's test command, note pass/fail to identify red/green/broken state.

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

**Branch on `metadata.testing_strategy.mode` before building the AC list:**

- **`direct`**: skip Given/When/Then restatement entirely. ACs are optional. If raw ACs from intake are empty (`raw_acs == "derive"` or empty), write a single placeholder into the draft list:
  ```
  - AC-1: DIRECT: verify <change description from intake.description, truncated to ~80 chars> renders correctly
  ```
  The `AC-N: ` prefix is mandatory so Stage 2's deterministic Check B (AC-coverage by tests) keeps working. If raw ACs DO exist, restate them as plain bullets without forcing Given/When/Then.

- **`bdd`**: restate ACs as Given/When/Then with a user or system actor (`GIVEN the user has ... WHEN they ... THEN the app ...`). Derived ACs follow the same user-centric framing. Propose 3 to 7 items.

Then in both branches:

1. Build the AC list per the branch above.
2. Build the **Out of Scope** list (items the dev should NOT confuse for in-scope).
3. Build the **Open Questions** list with proposed resolutions for each.
4. Present the entire draft as one block:

   ```
   Draft for Stage 1 (testing strategy: <DIRECT | BDD>):

   ## Acceptance Criteria
   - AC-1: <branch-appropriate format>
   - AC-2: ...

   ## Out of Scope
   - <item 1>
   - <item 2>

   ## Open Questions (proposed resolutions)
   - Q: <question> -> A: <proposed answer>

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

Each `in_scope` entry is a complete Given/When/Then string starting with the AC ID. `applicable_lessons` lists slugs of global lessons (`${CLAUDE_PLUGIN_ROOT}/lessons/{slug}.md`) whose `when_it_applies` matches this ticket; downstream agents read those lesson files when relevant.

No sidecar `ac.md` file. No separate assumptions file (assumptions surface in Stage 2 inside `metadata.plan.assumptions`).

### Step 8: Finalize

Update `metadata.json`: stage 1 complete, advance `current_stage` to the entry point decided in Step 5.

Narrate: *"Stage 1 complete. Imported stages: {list}. Continuing to Stage {N}..."* and immediately auto-proceed to Stage {N} in the same turn. Do NOT end the turn here.

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
under ${CLAUDE_PLUGIN_ROOT}/lessons/{slug}.md>

Explore the codebase to understand the structure relevant to this ticket.
Read budget: up to 10 source files. Free to grep within the budget.

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
- Read budget: 10 source files. Stay within it. If a BLOCKER from the deterministic checks needs more, add it on retry.

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

## Stage 3. Tests (Direct | BDD)

**Goal:** write tests appropriate to the ticket's `testing_strategy`. Mode is determined at intake and stored in `metadata.testing_strategy.mode`.

**No loop. No reviewer LLM.** A single test-writer agent produces the tests (when applicable for the branch), then deterministic checks validate. If checks fail, the writer is invoked **once more** (single retry) with the BLOCKERs inline. Second failure aborts the stage.

**Why no loop:** "are all ACs covered?" and "do the tests actually fail (or pass, in `direct` mode)?" are mechanical questions. The semantic critique (brittle assertions, over-mocking) is moved into the Stage 4 reviewer where the diff makes it obvious.

### Mode check (entry)

On every entry to Stage 3, the orchestrator MUST:

1. Read `metadata.testing_strategy.mode`.
2. Set `metadata.stages.3.testing_strategy_mode = <mode>` (always, even on re-entry; idempotent write).
3. Branch to one of the two sections below.

The two branches use different writer prompts, different deterministic checks, different commit messages, and (in the `direct` case) a different position in the pipeline (Stage 3 runs AFTER Stage 4 instead of before).

### Branch: `direct` (deferred path)

The `direct` branch DEFERS Stage 3 at first entry, lets Stage 4 commit the change, then comes back to Stage 3 to write regression tests against the implemented code. There is no red phase.

**First entry to Stage 3 (status = `pending`):**

1. Set `metadata.stages.3.status = "deferred"`.
2. Set `metadata.stages.3.testing_strategy_mode = "direct"`.
3. Set `metadata.current_stage = 4`.
4. Narrate: *"Stage 3 deferred (direct mode). Writing the change first, regression tests after Stage 4. Continuing to Stage 4."*
5. Auto-proceed to Stage 4 in the same turn. Do NOT invoke any Stage 3 agent on this entry.

**Second entry to Stage 3 (status = `deferred`, returning from Stage 4):**

The orchestrator advances to this entry from Stage 4 (see Stage 4's "Direct return" subsection). On entry, set `metadata.stages.3.status = "in_progress"` and invoke the regression test writer:

```
You are the regression test writer for ticket <TICKET-ID>. The change is
already implemented (Stage 4 is done). Your job is to add MINIMAL regression
tests that verify the FINAL state. Do NOT write tests before the change exists;
the change exists. These tests are about future-proofing.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump of metadata.ac>

== metadata.plan ==
<JSON dump of metadata.plan>

== Last 2 metadata.changelog entries ==
<JSON dump of metadata.changelog[-2:]>

== Diff so far ==
<output of `git diff <base>..HEAD`>

Read 2-3 existing test files in the repo to learn local conventions (framework,
file layout, naming). Read budget: 5 source files for convention discovery, plus
any source file in the diff that you need to understand the surface you are testing.

Write tests that:
- Verify the changed value/label/string/constant is present where the ticket
  said it should be.
- Cover at most one or two paths per AC placeholder. Minimal coverage is the goal.
- Are EXPECTED to PASS now (no red phase).

DO NOT add explanatory comments like `// REGRESSION:` or `// regression test`.
The test name and assertion are self-documenting.

Output a single JSON object:

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

Em-dashes are forbidden. Use commas, periods, or parentheses instead.
All artifacts you write (tests, code comments, JSON values) MUST be in English.
```

**Deterministic checks (`direct` branch, post-writer):**

- **Check A. Tests parse and run.** Same as the `bdd` branch: invoke the repo's test command. Compile/import/syntax errors are BLOCKERs.
- **Check B. Regression coverage per AC.** For each entry in `metadata.ac.in_scope`, verify at least one entry in the writer's `tests_added[]` lists the entry's `AC-N` ID under `covers[]`. Missing → BLOCKER.
- **Skip Check C entirely.** Tests in `direct` mode are EXPECTED to PASS, not fail. If any regression test FAILS, that is a real BLOCKER (regression caught), classify it as `B-X (regression failed): <test name> failed unexpectedly. Stage 4 may have an issue.` and abort with `status = "blocked"` so the dev can decide.

**On checks pass:**

1. Append the writer's `changelog_appendix` into `metadata.changelog`.
2. Set `metadata.stages.3.status = "complete"`, write `verified_with`, `completed_at`, `retry_used`, `testing_strategy_mode = "direct"`.
3. Commit:
   ```bash
   git add -A
   git commit --no-verify -m "doer(<TICKET-ID>): regression tests (direct)"
   ```
4. Set `metadata.current_stage = 5` (Stage 4 already complete; jump straight to Stage 5).
5. Narrate `"Stage 3 complete (direct): N regression tests added, all passing. Continuing to Stage 5."` Auto-proceed.

### Branch: `bdd`

Given/When/Then scenarios derived from each AC, expressed as failing executable tests. Stage 4 implements code derived from the scenarios.

**BDD scenario + test writer prompt (skeleton):**

```
You are the BDD scenario + test writer for ticket <TICKET-ID>.

For each AC in metadata.ac.in_scope, derive one or more Given/When/Then
scenarios. Write each scenario as an executable test using the repo's test
framework (JUnit, Espresso, XCTest, Jest, etc.) following existing conventions.
If the repo uses a BDD-style DSL (Cucumber, Kotest BDD, etc.), use it.
Otherwise, express Given/When/Then as comments + structured test body.

Tests MUST currently FAIL because no implementation exists yet (red phase
derived from scenarios, not technical units).

Each test function name MUST reference the scenario, e.g.
given_user_has_cart_when_bap_loads_then_promos_shown.

DO NOT add explanatory comments like `// RED:` or `// BDD red:` or
`// fails because X` on test bodies. The test name and the failing assertion
are self-documenting.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump of metadata.ac>

== metadata.plan ==
<JSON dump of metadata.plan>

== Last 2 metadata.changelog entries ==
<JSON dump of metadata.changelog[-2:]>

Read 2-3 existing test files for conventions. Read budget: 5 source files for
convention discovery, plus any source file referenced in metadata.plan.files.

Output a single JSON object:

{
  "tests_added": [
    {"name": "<scenario test function name>", "file": "<repo-relative path>", "covers": ["AC-N"]}
  ],
  "changelog_appendix": {
    "stage": 3, "iteration": 1, "kind": "initial",
    "items": [
      {"type": "step", "text": "Added scenario <name> in <file> covering <AC-N>"},
      ...
    ]
  }
}

Em-dashes are forbidden. Use commas, periods, or parentheses instead.
All artifacts you write (tests, code comments, JSON values) MUST be in English.
```

**Deterministic checks (`bdd` branch):**

- **Check A. Tests parse and run.** Compile/import/syntax errors are BLOCKERs.
- **Check B. Scenario per AC.** Every entry in `metadata.ac.in_scope` MUST have at least one scenario test (cross-reference `tests_added[i].covers[]` to AC IDs).
- **Check C. Scenario tests currently FAIL.** Red-phase requirement: a passing scenario test is a BLOCKER.

**On checks pass:**

1. Append the writer's `changelog_appendix` into `metadata.changelog`.
2. Set `metadata.stages.3.status = "complete"`, `verified_with`, `completed_at`, `retry_used`, `testing_strategy_mode = "bdd"`.
3. Commit:
   ```bash
   git add -A
   git commit --no-verify -m "doer(<TICKET-ID>): BDD scenarios + failing tests"
   ```
4. Narrate `"Stage 3 complete (BDD): N scenario tests added, all failing as expected. Continuing to Stage 4."` Auto-proceed.

### Single retry policy (all branches)

If the deterministic checks for the active branch produce any BLOCKERs:

1. Re-invoke the active branch's writer ONCE with the BLOCKERs inline. Same prompt body, prepended with:
   ```
   Your prior tests failed validation:
   <list BLOCKERs>

   Address every BLOCKER. Output the same JSON shape.
   ```
2. Re-run the deterministic checks for the active branch (A/B for `direct`, A/B/C for `bdd`).
3. Set `metadata.stages.3.retry_used = true`.
4. If still failing → ABORT. Narrate:
   ```
   Stage 3 failed validation twice. Remaining BLOCKERs: <list>.
   Inspect the tests, then run /doer continue.
   ```
   Set `metadata.stages.3.status = "blocked"`. Do not proceed.

   **Resuming from `blocked`:** when the dev re-runs `/doer <ID>` after fixing the tests by hand, the orchestrator detects `metadata.stages.3.status == "blocked"` and re-runs ONLY the deterministic checks for the recorded `metadata.stages.3.testing_strategy_mode`. No new test-writer agent invocation. If checks pass → mark stage complete, advance to the appropriate next stage (Stage 4 for `bdd`, Stage 5 for `direct`). If checks still fail → re-narrate and stay `blocked`.

---

## Stage 4. Code (Doer/Reviewer Loop)

**Goal:** implement the change per `metadata.plan`. The exact contract depends on `metadata.testing_strategy.mode`:

- `bdd`: implement code so the BDD scenario tests from Stage 3 pass; scenario names are the implementation contract.
- `direct`: implement the change directly. Tests do not exist yet; Stage 3 writes regression tests AFTER this stage commits.

Loop with **max 3 iterations** (see Doer/Reviewer Loop Pattern).

**Mode check.** At entry, read `metadata.testing_strategy.mode`. The value is inlined into the writer prompt and influences pre-reviewer Check A (see "Pre-reviewer deterministic checks"). After commit, the orchestrator decides where to advance based on `testing_strategy.mode` (see "Direct return" at the end).

### Code writer prompt (skeleton)

```
You are the code writer for ticket <TICKET-ID>.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump of metadata.ac>

== metadata.plan ==
<JSON dump of metadata.plan>

== Tests added in Stage 3 ==
<list of test file paths from metadata.changelog Stage 3 entries; the agent
reads them as part of its source budget. EMPTY if testing_strategy.mode is
"direct" (Stage 3 has not run yet).>

== Last changelog entries ==
<JSON dump of metadata.changelog[-2:]>

== Testing strategy ==
<JSON dump of metadata.testing_strategy>

If strategy.mode is "bdd": implement the code such that the BDD scenario tests
pass. Trace each scenario to the AC it covers. The scenario names in the test
files are your implementation contract.
If strategy.mode is "direct": implement the change directly. Tests do not exist
yet (they will be written in Stage 3 after this stage). Do not over-engineer.

Implement the plan. Follow existing codebase conventions. Do not add new
dependencies unless metadata.plan specifies them (if you must, return a
changelog item flagging it).

After implementation:
- For "bdd": run the full test suite. All tests (new and pre-existing) MUST pass.
- For "direct": no new tests exist yet. Run the pre-existing test suite to confirm no regression. If the repo has no test command or running it is too expensive, note that in the changelog and skip.

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

Read budget: 15 source files (iter 1) or 3 source files beyond the diff (iter 2+).

Em-dashes are forbidden. Use commas, periods, or parentheses instead.
All artifacts you write (code comments, JSON values, commit messages) MUST be in English.
```

### Pre-reviewer deterministic checks

Run these BEFORE invoking the code-reviewer. Each catches a class of obvious failures without burning an LLM call.

**Check A. Tests pass.** Behavior depends on `metadata.testing_strategy.mode`:

- **`bdd`**: run the repo's test command. ALL tests (the new failing ones added in Stage 3 plus all pre-existing tests) MUST now pass. Any failure is a BLOCKER:
  ```bash
  <repo's test command>
  ```
  ```
  - B-1 (test fail): tests/login_test.kt::testLoginSuccess expected "ok", got "null"
  - B-2 (regression): tests/auth_test.kt::testTokenRefresh now fails (was passing pre-Stage 4)
  ```
- **`direct`**: no Stage 3 tests exist yet (deferred). Run the PRE-EXISTING test suite ONLY to catch regressions. If a pre-existing test fails, that is a BLOCKER (`B-X (regression): <test name> now fails`). If the repo has no test command or running it is too expensive for a trivial cosmetic change, narrate the skip explicitly (`"Check A skipped: direct mode and no cheap test command available."`) and rely on Checks B and C.

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

== Testing strategy ==
<JSON dump of metadata.testing_strategy>

The deterministic checks already passed: tests green (or skipped in `direct`
mode), lint clean, typecheck clean, every file in metadata.plan.files was
touched. Focus on what those checks cannot catch:

1. AC match: does the behavior implement every AC? Trace each AC to test + code.
   In `direct` mode, tests do not exist yet; trace ACs to the diff alone.
2. Correctness: edge cases, error paths, concurrency, off-by-one, null handling.
3. Security: input validation, injection, secrets, auth, authz.
4. Test integrity (`bdd` only): were tests weakened to make them pass?
   In `direct` mode, this check does not apply.
5. Scope (semantic): any out-of-plan files touched (see INFO from Check C)?
   Are they justified, or should they be reverted?

Focus on the diff. Do NOT re-review files that were not touched.

Output findings as JSON code_review_entry per the Loop Pattern. Read budget:
5 source files (iter 1) or 3 source files (iter 2+) beyond the diff.
```

Run loop until convergence (max 3 iterations). On every loop iteration the orchestrator persists the writer's `changelog_appendix` to `metadata.changelog` and the reviewer's findings to `metadata.code_review`. Commit on convergence with a message tied to the testing strategy:

```bash
git add -A
# bdd:
git commit --no-verify -m "doer(<TICKET-ID>): implementation (BDD green)"
# direct:
git commit --no-verify -m "doer(<TICKET-ID>): implementation (direct)"
```

After the commit, persist the green-test marker so Stage 6 can skip re-running an unchanged tree (only when the test suite actually ran and passed in this stage; in `direct` mode where Check A may be skipped, leave `last_green_sha` unchanged):
```json
metadata.last_green_sha = <git rev-parse HEAD>   # MUST be the full 40-char SHA. NEVER abbreviated. The skip-safe check in Stage 6 compares this string-equal to `git rev-parse HEAD` of the new HEAD; an abbreviated SHA breaks the comparison.
metadata.last_green_test_command = <the test command that ran>
```

### Direct return (advance after commit)

After Stage 4 commits and updates the green-test marker, decide where to advance based on `metadata.testing_strategy.mode`:

- **`bdd`**: set `metadata.current_stage = 5`, narrate *"Stage 4 complete. Continuing to Stage 5..."*, auto-proceed to Stage 5 in the same turn.
- **`direct`**: set `metadata.current_stage = 3`, narrate *"Stage 4 complete. Returning to Stage 3 to write regression tests against the implemented change."*, auto-proceed to Stage 3's `direct` second-visit branch in the same turn.

---

## Stage 5. Code Review (Hybrid: Deterministic + Reviewer LLM)

**Goal:** PR-readiness check. Catch the mechanical "should never reach a PR" issues with deterministic greps, then invoke the reviewer LLM only for the semantic judgements that require it.

### Pre-reviewer deterministic checks

Run all three. Each catches a class of PR-readiness issues without an LLM call.

**Check A. Secrets in the diff.**
Use `gitleaks` if available; otherwise a regex sweep:
```bash
git diff <base>..HEAD | grep -nEi '(api[_-]?key|secret|token|password|bearer|aws_)[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{8,}'
```
Any match → BLOCKER. Do not auto-fix; the dev must rotate credentials and amend.

**Check B. Smoke / end-to-end test exists.**
Inspect `metadata.plan.tests` + the actual tests added in Stage 3 (paths in `metadata.changelog` Stage 3 entries). Look for at least one test that exercises the full flow described in the ACs (not just unit isolation). If none → SUGGESTION (not BLOCKER, since some tickets legitimately have only unit-level tests):
```
- S-1 (smoke): no end-to-end test detected. Consider adding one if the
  ticket touches a user-facing flow.
```

**Check C. Swallow-all error handlers in the diff.**
```bash
git diff <base>..HEAD | grep -nE '(except\s*:|except\s+Exception\s*:|catch\s*\(\s*\w*\s*\)\s*\{?\s*\}?)' | grep -v test
```
Any match → SUGGESTION (the dev may have intentional reasons; do not auto-fix):
```
- S-2 (error handling): bare `except:` at <file>:<line>. Consider catching
  a specific exception or logging.
```

### Reviewer LLM (only if pre-checks did not produce BLOCKERs)

If Check A (secrets) produced any BLOCKERs, end the iteration and hand them to the iter-N+1 fixer (the dev cannot proceed with secrets in the diff). Skip the reviewer LLM for that iteration.

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

The deterministic checks already ran (secrets, smoke test, swallow-all
handlers). Stage 4's reviewer already validated correctness and AC behavior.

Your scope is narrow. Judge ONLY:

1. ONE logical unit: does the diff describe a single coherent change,
   or does it mix unrelated work that should split into separate PRs?
   If mixed, classify as BLOCKER with a "recommended split" suggestion.

2. Semantic error handling: where the dev DID handle errors (not bare
   except), are the handlers appropriate? Specific exception types?
   Meaningful recovery or fallback? Logging? Or silently swallowing in
   a way that will hide bugs in production?

3. Stale or misleading comments in the diff: TODO that should have
   been done, comments that contradict what the code now does, dead
   code commented out.

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

### MUST-RUN steps (forcing rule, NEVER skip)

Stage 9 is a sequence of NINE numbered sub-steps. Steps 7 (commit message) and 8 (PR description) are the two most-skipped sub-steps in the wild because they fall after the visible "ticket complete" actions (history cleanup, final commit). Skipping them violates the dev's contract; they are mandatory output of every wrapup. To prevent the skip:

1. Before narrating any "Ticket complete" or "Stage 9 complete" message in step 9, the orchestrator MUST self-verify BOTH flags:
   - `metadata.stages.9.commit_message_presented` is `true` (or `"skipped"` if the dev explicitly said skip during step 7).
   - `metadata.stages.9.pr_description_presented` is `true` (or `"skipped"` if the dev replied `skip` in step 8).
2. If either flag is missing or `false`, STOP. Do NOT narrate the closing summary. Run the missing step now (jump back to step 7 or step 8 as appropriate) and ONLY THEN write the closing summary.
3. The Stage Finalization Checklist (see "Stage Finalization Checklist") already enforces both flags as required-when-complete fields. The forcing rule above is the runtime double-check that catches the failure mode where the orchestrator advances `metadata.stages.9.status = "complete"` without having presented either artifact.

**Order of sub-steps (MUST run in this order):**

| Sub-step | What |
|---|---|
| 1 | Validate assumptions |
| 2 | Capture lessons |
| 3 | Persist summary + performance into metadata |
| 4 | Set `metadata.status = "complete"` and `stages.9` baseline fields |
| 5 | History cleanup (filter-branch) — asks for confirmation |
| 6 | Final commit (only if uncommitted real changes) |
| 7 | **Recommend final commit message** (write `commit_message_presented`) |
| 8 | **Help with PR description** (write `pr_description_presented`) |
| 9 | Final closing narration |

Steps 7 and 8 are NEVER skipped automatically. The dev may decline step 8 by replying `skip`, in which case the flag is set to the literal string `"skipped"`; the step itself still runs to capture that decision. There is no auto-skip path for either step.

1. **Validate assumptions.** Read `metadata.plan.assumptions`. For each assumption, decide VALIDATED, INVALIDATED (with reason), or UNVERIFIED based on what actually happened during Stages 4-7. Persist as `metadata.assumptions_validation`:
   ```json
   "assumptions_validation": [
     {"text": "<assumption from metadata.plan.assumptions>", "status": "VALIDATED | INVALIDATED | UNVERIFIED", "reason": "<one-line, only if INVALIDATED>"}
   ]
   ```

2. **Capture lessons (with auto-detected candidates).**

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

   For each lesson, write to the GLOBAL pool at `${CLAUDE_PLUGIN_ROOT}/lessons/{slug}.md` (lessons remain as files; they are cross-project knowledge, not per-ticket state). Format:
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

   Confirm with the user (destructive, changes SHAs). On approval, proceed with the cleanup commands below. On decline, narrate *"Skipping history cleanup. Run /doer cleanup-history later."*

   Cleanup commands:
   ```bash
   git update-ref "refs/doer-backup/<TICKET-ID>-pre-cleanup-$(date +%s)" HEAD
   git filter-branch -f --index-filter 'git rm -r --cached --ignore-unmatch .doer/' --prune-empty "<base>..HEAD"
   git update-ref -d refs/original/refs/heads/<branch-name> 2>/dev/null || true
   ```
   Verify `git log --diff-filter=ACMR -- '.doer/*' "<base>..HEAD"` is empty. Tell the user the backup ref (rollback: `git reset --hard <ref>`).

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

   After presenting, write `metadata.stages.9.commit_message_presented = true` into `metadata.json`.

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

   **c. User replies `skip`:** Skip the PR description step entirely. Write `metadata.stages.9.pr_description_presented = "skipped"` into `metadata.json`. Continue to step 9.

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

   After presenting, write `metadata.stages.9.pr_description_presented = true` into `metadata.json`.

9. **Forcing rule before final narration.** Re-read `metadata.stages.9.commit_message_presented` and `metadata.stages.9.pr_description_presented` from disk. If either is absent or literal `false`, STOP. Do NOT proceed to the closing narration. Jump back to step 7 (if `commit_message_presented` is missing) or step 8 (if `pr_description_presented` is missing) and run them now. Only after BOTH flags read `true` (or the literal `"skipped"` for `pr_description_presented`) may the orchestrator continue to the closing narration below.

10. **Release the per-ticket lock.** Run:
    ```bash
    ${CLAUDE_PLUGIN_ROOT}/lib/helpers/lock.sh release "<TICKET-ID>"
    ```
    Idempotent. The lock file is removed; future invocations of `/wk:doer <TICKET-ID>` (e.g. `verify` on a closed ticket) will acquire fresh.

    Then narrate: *"Ticket <TICKET-ID> complete. {N} commits on `<branch>` (post-cleanup). Summary and performance stats persisted to .doer/tickets/<TICKET-ID>/metadata.json (`summary`, `performance`). Run your pre-commit checks, squash with the recommended commit message above, paste the PR description above, then push and open the PR manually."*

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
     # If TRACKED non-empty, surface the 3-option prompt to the user (see `${CLAUDE_PLUGIN_ROOT}/lib/workspace-guard.md`
     # for the exact prompt text and default to option 3).

     # 4e. Migrate stale per-repo lessons → global pool (see `${CLAUDE_PLUGIN_ROOT}/lib/workspace-guard.md` step 5
     # for the full bash + conflict-handling rules). Idempotent: silent no-op
     # when .doer/knowledge/lessons/ doesn't exist or is empty.

     # 4f. Migration Check (see `${CLAUDE_PLUGIN_ROOT}/lib/migrations.md`). If
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
   - `deferred` (Stage 3 only, `direct` testing strategy) → enter the Stage 3 `direct` second-visit branch (regression test writer). See "Branch: `direct` (deferred path)" in the Stage 3 docs.
   - `complete | skipped | imported` → unexpected here (current_stage should not point at one of these). Treat as data drift: advance current_stage to the next pending stage and continue.
7. Narrate: "Resuming <TICKET-ID> at Stage {N} ({name}){, iteration {i}}{, status: {status}}." Then proceed (the user invoked `/doer continue` explicitly, so resume is the implicit intent, do NOT ask for further confirmation).
8. Proceed.

---

## `/doer status <TICKET-ID>`

Render:

```
Ticket: <TICKET-ID>, <title>
Branch: <branch>  Status: <status>
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
4. Run the same logic as Stage 9 step 5 (PR-ready history cleanup): detect dirty commits via `git log --diff-filter=ACMR -- '.doer/*'`, confirm with user (this command is invoked manually so the dev should explicitly approve), create backup ref, `git filter-branch` to strip `.doer/` from history, verify the strip succeeded, reset housekeeping refs, narrate the backup ref name.
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

---

*Maintained by hand. Copy `SKILL.md` to `~/.claude/skills/doer/` on any machine to use.*
