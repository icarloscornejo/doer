---
name: doer
description: >-
  Ticket execution orchestrator. Takes a pre-defined ticket (feature, bug,
  refactor) from acceptance criteria to implementation-ready code on a feature
  branch. Invoke with "/doer <TICKET-ID>" to start a new ticket, or use
  "/doer continue <TICKET-ID>", "/doer status <TICKET-ID>", "/doer list".
  Also activates implicitly when the user references an active /doer ticket
  in natural language (e.g. "continue", "pause", "keep going with ABC-123").
  Skips PRD, architecture design, Jira creation, PR assembly, and deployment.
  Keeps spec, plan, tests, code, review, docs, and lessons learned.
version: 1.0.0
user-invocable: true
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, AskUserQuestion, Agent]
---

# Doer — Ticket Execution Orchestrator

User-facing orchestrator for executing a single ticket end-to-end on a feature branch. Runs 9 sequential stages with doer/reviewer convergence loops. Narrates every action so the user can pause at any point. State persists on disk so work can be resumed across sessions.

**Scope:** one ticket, one branch, end-to-end implementation up to (but not including) PR and deploy.

**Out of scope:** PRD creation, architecture design, Jira creation, pull request assembly, deployment.

---

## Core Principles

1. **Narration first** — The orchestrator announces what it is about to do, what it is doing, and what just happened. The user should be able to pause at any moment.
2. **One branch, one ticket** — All work happens on a single feature branch. Stages that produce real code commit it; stages that only produce `.doer/` artifacts do NOT commit (see principle 8).
3. **Delta-aware reviewers** — After iteration 1, reviewers receive prior findings + a changelog from the doer. They verify fixes and scan for new issues, rather than re-analyzing from scratch.
4. **Bounded loops** — Max 5 iterations per doer/reviewer loop. If not converged, the user decides.
5. **Lessons accumulate** — Every ticket captures what went well and what did not. Future tickets read those lessons before planning.
6. **No hidden state** — Everything the orchestrator knows lives in `./.doer/` on disk. Context compression never loses progress.
7. **All commits use `git commit --no-verify`.** Hard rule.
   - The orchestrator runs in developer mode — pre-commit hooks (linters, formatters, fast tests) interrupt flow mid-stage without value (agents may produce intermediate states that fail a hook but are correct for the stage).
   - Every commit and amend in the SKILL shows `--no-verify` explicitly (portable, no aliases needed).
   - **Dev runs real checks manually before PR** (`pre-commit run`, lint, full tests, etc.), then squashes/reorders and pushes. Orchestrator does not push.

8. **`.doer/` NEVER reaches the team's git history.** Non-negotiable.
   - Intake adds `.doer/` to `.git/info/exclude` (per-clone, never committed) — team sees nothing.
   - Commits MUST NOT include paths under `.doer/`. Use `git add <code-paths>` or `git add -A` (respects exclude). NEVER `git add .doer/...` (that bypasses the ignore).
   - Stages whose only output is `.doer/` (1 AC, 2 Plan, 5 Reflect, 10 Wrapup) SKIP the commit entirely. Stages with real code (3 Tests, 4 Code, 6 Review, 8 Runtime, 9 Docs) commit code only.
   - Stage 8 temp commit + revert still works because it touches real source files, not `.doer/`.

---

## Commands

| Command | Description |
|---------|-------------|
| `/doer <TICKET-ID>` | Start a new ticket. Orchestrator asks for title, description, type, ACs, context, branch name. |
| `/doer continue <TICKET-ID>` | Resume a paused ticket from its last stage. |
| `/doer status <TICKET-ID>` | Show current stage, loop state, and blockers. |
| `/doer list` | List all tickets in `./.doer/tickets/`. |
| `/doer verify <TICKET-ID>` | Run stages that exist in the current skill but were missing when the ticket was closed. |
| `/doer cleanup-history <TICKET-ID>` | Strip any `.doer/` content from commits on the ticket's feature branch. Auto-runs at wrapup; this command lets you re-run it manually. |
| `/doer pause` | Persist current state and stop. |

**Stages cannot be skipped manually.** Every stage must run. The only way to skip stages is through Stage 1's pre-existing-work detection (see Stage 1 below). This is by design: the orchestrator decides which stages to skip, not the user.

**Implicit activation:** If the user writes natural language (e.g. "keep going", "pause here", "the plan looks good") and an active ticket exists in `./.doer/tickets/*/metadata.json` with `status == "in_progress"`, treat the message as a directive to the active orchestrator rather than a new query.

---

## Knowledge & State Layout

All state lives under `./.doer/` in the current working directory (scoped to the target repo).

**Lessons are GLOBAL** — they live next to `SKILL.md` (so all repos share the same accumulated knowledge). **Assumptions are per-ticket** (specific to one piece of work).

```
<doer-skill-dir>/                  # ~/src/doer/ in this install (resolve symlinks)
├── SKILL.md
├── preferences.md                 # local config (gitignored)
└── lessons/                       # GLOBAL — cross-project, gitignored
    └── {slug}.md

./.doer/                           # per-repo (in CWD), gitignored via .git/info/exclude
├── knowledge/
│   └── assumptions/
│       └── {TICKET-ID}.md         # per-ticket, validated at wrapup
└── tickets/
    └── {TICKET-ID}/
        ├── metadata.json           # workflow state — single source of truth
        ├── ticket.md               # intake (title, description, type, context)
        ├── ac.md                   # confirmed ACs (Stage 1)
        ├── plan.md                 # implementation plan (Stage 2)
        ├── reflect.md              # self-review notes (Stage 5)
        ├── wrapup.md               # captured lessons + summary (Stage 10)
        └── review/
            ├── plan-review-{iter}.md
            ├── tests-review-{iter}.md
            └── code-review-{iter}.md
```

**Path resolution for `lessons/`:** the orchestrator MUST resolve the directory of the running `SKILL.md` (following symlinks — most installs put it under `~/.claude*/skills/doer/SKILL.md` symlinked to `~/src/doer/SKILL.md`) and treat `<resolved-dir>/lessons/` as the canonical lessons directory. Use `readlink` or `realpath` if needed.

On first invocation in a repo, create `./.doer/knowledge/assumptions/` if it does not exist. The global `lessons/` directory must already exist next to the skill.

---

## Intake: `/doer <TICKET-ID>`

When the user invokes `/doer <TICKET-ID>` with no other flags:

1. Verify `./.doer/tickets/<TICKET-ID>/metadata.json` does NOT already exist.
   - If it does, ask: "Ticket <TICKET-ID> already exists (stage {current_stage}). Continue it instead? [Y/n]"
2. Ask the following questions **one at a time** via `AskUserQuestion`. Do not batch.

   | # | Question |
   |---|----------|
   | 1 | "What is the title of `<TICKET-ID>`?" |
   | 2 | "Paste the full description of the ticket." |
   | 3 | "What type is it? (feature / bug / refactor / other)" |
   | 4 | "Does the ticket already have acceptance criteria? If yes, paste them. If no, type `derive` and we'll build them together in Stage 1." |
   | 5 | "Any extra context? (related issues, prior decisions, links, constraints). Type `skip` if none." |
   | 6 | "What name should the feature branch use? (e.g. `feature/fix-login-timeout`)" |

3. Write `./.doer/tickets/<TICKET-ID>/ticket.md` with the raw intake:

   ```markdown
   # <TICKET-ID>: <title>
   **Type:** <type>
   **Branch:** <branch-name>

   ## Description
   <description>

   ## Raw Acceptance Criteria
   <ACs or "to derive">

   ## Context
   <context or "none">
   ```

4. Initialize `metadata.json`:

   ```json
   {
     "ticket_id": "<TICKET-ID>",
     "title": "<title>",
     "type": "<type>",
     "branch": "<branch-name>",
     "status": "in_progress",
     "current_stage": 1,
     "created_at": "<ISO8601>",
     "stages": {
       "1":  {"name": "ac-confirm",      "status": "pending"},
       "2":  {"name": "plan",            "status": "pending", "loop": true},
       "3":  {"name": "tests",           "status": "pending", "loop": true},
       "4":  {"name": "code",            "status": "pending", "loop": true},
       "5":  {"name": "reflect",         "status": "pending"},
       "6":  {"name": "code-review",     "status": "pending", "loop": true},
       "7":  {"name": "quality-gate",    "status": "pending"},
       "8":  {"name": "runtime-verify",  "status": "pending"},
       "9":  {"name": "docs-sync",       "status": "pending"},
       "10": {"name": "wrapup",          "status": "pending"}
     },
     "blocking_conditions": [],
     "commits": []
   }
   ```

5. Create the feature branch in the current repo:

   ```bash
   git checkout -b "<branch-name>"
   ```

   If the branch already exists (local or remote), ask:
   "Branch `<branch-name>` already exists. Options: 1) Check out existing, 2) Pick a different name. Which?"

6. **Workspace setup** — run the **Workspace Guard** (see section below). This is MANDATORY before Stage 1.

7. Narrate to the user: "Ticket <TICKET-ID> initialized on branch `<branch-name>`. `.doer/` is gitignored locally — your team will never see these files. Starting Stage 1: AC Confirm."

8. Proceed to Stage 1.

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
   `.git/info/exclude` is per-clone, never committed — team sees nothing.

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
   2) Skip — keep tracking, clean manually later
   3) Untrack silently (stage but don't commit)
   ```
   Default to **3** if no response.

5. **Mark satisfied:** if a ticket is active, write `metadata.workspace_guard = "ok"`. (No-op if no active ticket — next ticket-scoped invocation sets it.)

For deep cleanup of historical `.doer/` content from earlier commits on the feature branch, use `/doer cleanup-history <TICKET-ID>` — out of scope for the Guard.

---

## Narration Protocol

**Per-stage narration:**
- Before: `"Starting Stage {N} — {name}. {one-sentence goal}."` + write `stages.<N>.started_at`.
- After: write `stages.<N>.completed_at` + `"Stage {N} complete. Committed as {sha}. Continue to Stage {N+1}? [Y/n/pause]"`.
- Inside loop: `"Iteration {i}/{max}: invoking {agent}... agent returned {status}, {findings} findings ({blockers} blockers)."`

### Turn boundaries — ABSOLUTE rules

Default behavior is **auto-proceed** (narrate next step, end turn, continue on next turn unless user interrupted). Confirmation is the exception.

| Boundary | Behavior |
|----------|----------|
| Auto-proceed | After every subagent return, between doer↔reviewer, between stages, after major file writes |
| Confirm (wait) | Plan/AC drafts presented, before final wrapup commit, loop hit max iterations |
| Decide (wait) | Pre-existing-work import, skip docs, RETURN_TO_STAGE_N |

**MUST rules (no efficiency exceptions):**

1. End the turn after every Agent tool invocation. One-line status + next-step announce, then STOP.
2. **Never invoke Agent twice in one turn.** If already called once this turn, STOP — the next call is a new turn.
   - Wrong: `Agent(planner) → Agent(reviewer)` in same turn (FORBIDDEN)
   - Right: `Agent(planner) → narrate → END TURN` → next turn: `Agent(reviewer) → narrate → END TURN`
3. End the turn after every Write/Edit to a meaningful artifact.
4. End the turn at every stage boundary.
5. End the turn between doer/reviewer and reviewer/next-doer (2+ turn breaks per loop iteration).
6. Never bundle multiple stages in one turn.

**Self-check before every response:** *"Did I call Agent more than once?"* If yes — STOP, narrate what was done, do not bundle more work.

### SUGGESTIONs never pause

Zero BLOCKERs = converged. SUGGESTIONs are logged to `review/{stage}-review-{iter}.md` and the orchestrator narrates `"Converged with N SUGGESTIONs logged. Continuing."` then auto-proceeds. Do NOT ask the user whether to apply them.

### Interrupt detection

At any auto-proceed boundary, if the user's latest message contains `pause`, `stop`, `wait`, `hold on`, `n`, `no`, `espera`, `para`, or any clear halt signal → treat as pause request: persist `status: "paused"` + `paused_at` to metadata, acknowledge, stop. Otherwise proceed.

### Pause persistence

On pause: write `metadata.status = "paused"`, `paused_at = <ISO8601>`. Reply with the resume command (`/doer continue <TICKET-ID>`). Stop.

For immediate interruption mid-subagent the user can press `Esc` (CLI-level). Frequent turn boundaries minimize the need.

### Performance counters (consumed by Stage 10 report)

Persist these in `metadata.json`:

```json
{
  "agent_invocations": {"agent-name": <count>, ...},
  "stages": {
    "<N>": {
      "started_at": "<ISO8601>",
      "completed_at": "<ISO8601>",
      "pauses": [{"paused_at": "...", "resumed_at": "..."}],
      "active_duration_seconds": <int>,
      "convergence_loop": {
        "iterations": <int>,
        "converged_on_iteration": <int>,
        "blockers_resolved_total": <int>,
        "exit_reason": "converged | max_iterations | user_accepted"
      }
    }
  }
}
```

Increment `agent_invocations[<name>]` on every Agent call. Update `convergence_loop` on loop exit. Active duration excludes paused intervals.

---

## Doer/Reviewer Loop Pattern (Delta-Aware)

Stages 2, 3, 4, 6 use this pattern. Max iterations: **5**.

### Findings severity (4 buckets)

| Bucket | Behavior | Examples |
|--------|----------|----------|
| **BLOCKER** | Loop continues until resolved | Failing test, missing AC coverage, security issue, broken build |
| **AUTO_FIX** | Applied automatically same iteration before convergence check | Reference to deleted function, unused import, test name stale after rename, typo |
| **SUGGESTION** | Logged to review file, never applied, never blocks | "Consider extracting", "could use map instead of ifs", design tweaks |
| **INFO** | Observational only | "This file is 500 LOC", "pattern used in 3 places" |

**Test for AUTO_FIX vs SUGGESTION:** *"Is there anything to decide?"* No → AUTO_FIX. Yes (trade-off, preference, design judgment) → SUGGESTION. When in doubt → SUGGESTION (be conservative — AUTO_FIX runs without user approval).

**Convergence = zero BLOCKERs remaining.** AUTO_FIXes are applied within the same iteration, do not block convergence.

### Iteration 1 (clean-slate)

1. Invoke **doer** → produces artifact + `changelog.md` (what was done, why).
2. Invoke **reviewer** → produces findings categorized BLOCKER / AUTO_FIX / SUGGESTION / INFO.
3. **Apply AUTO_FIXes** (if any): invoke fixer pass with *"Apply each mechanically. No design changes. Append to changelog as `AutoFix #<id>: ...`"*.
4. Zero BLOCKERs → converged. Log SUGGESTIONs/INFO to review file, narrate `"Converged. N AUTO_FIXes applied. M SUGGESTIONs logged."`, auto-proceed.
5. BLOCKERs > 0 → Iteration 2.

### Iteration 2+ (delta-aware)

1. Invoke **doer** with: current artifact, prior BLOCKERs (with IDs), instruction *"Address each BLOCKER. Append to changelog: `Fix #<id>: <what + why>`."*
2. Invoke **reviewer** with: updated artifact, prior findings, new changelog, instruction *"Mark each prior BLOCKER RESOLVED or STILL_OPEN. Scan areas the doer touched (per changelog) for new issues. Do NOT re-analyze untouched areas."*
3. Reviewer output:
   ```json
   {
     "prior_blockers_resolved": ["id-1", ...],
     "prior_blockers_still_open": ["id-2", ...],
     "new_blockers": [...],
     "auto_fixes": [...],
     "suggestions": [...],
     "info": [...]
   }
   ```
4. Apply AUTO_FIXes.
5. Remaining BLOCKERs = still_open + new. Zero → converged. Otherwise → next iteration.

### Max iterations reached (5) without convergence

Narrate: *"Stage {N} did not converge after 5 iterations. {N} BLOCKERs remain: {list}. Options: 1) one more iteration, 2) accept and continue, 3) pause."* Record choice in `metadata.stages.<N>.loop_outcome`.

---

## Stage 1 — AC Confirm

**Goal:** produce testable ACs in `ac.md` + detect/import any pre-existing work.

**No subagent — orchestrator runs this directly.** No commit at end (only `.doer/` writes, which is gitignored).

### Step 1: Load context

1. Read `ticket.md`.
2. Read `<doer-skill-dir>/lessons/*.md` (global, cross-project — see Knowledge & State Layout for path resolution). Note any whose `when_it_applies` matches this ticket.

### Step 2: Pre-existing work — ASK FIRST

**MUST ask the user before running ANY git command, reading existing `.doer/` files, or inspecting diffs:**

> "Have you already done any work on this ticket before invoking `/doer`? [y/N]"

**MUST NOT:** auto-detect via git, infer from uncommitted changes, skip the question because "it seems obvious". Ask verbatim, every time.

- **NO** → skip Steps 3-6. Go to Step 7 with entry stage = 1 (no imports).
- **YES** → continue to Step 3.

### Step 3: Probe the user (only on YES)

Ask each one-at-a-time via `AskUserQuestion`:

| Question | Follow-up if yes |
|----------|------------------|
| "Plan written somewhere?" | "Paste or summarize." |
| "Tests written?" | "Where? Pass or fail?" |
| "Implementation code?" | "Where? Committed, staged, uncommitted?" |
| "Docs updated?" | "Which files?" |

### Step 4: Inspect the repo (only on YES)

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

If tests detected, run them via repo's test command — note pass/fail to identify TDD red/green/broken state.

Present the analysis:
```
Based on your commits:
- Plan: <yes/no + where>
- Tests: <N> files (<X pass, Y fail>)
- Implementation: <N> files (~<LOC>)
- Docs: <N> files

Summary: <one-paragraph inferred state>
Is this accurate? [Y/n/correct-me]
```

### Step 5: Decide entry point

| User has... | Entry stage | Mark imported |
|-------------|-------------|---------------|
| Nothing | 1 | — |
| Plan only | 3 (tests) | 2 |
| Plan + failing tests | 4 (code) | 2, 3 |
| Plan + tests + partial code | 4 (code) | 2, 3 |
| Plan + tests + complete code | 5 (reflect) | 2, 3, 4 |
| Everything, ready for review | 6 (code-review) | 2, 3, 4, 5 |

Confirm with user: *"Suggesting entry at Stage {N}, importing {list}. Proceed? [Y / start at 1 / pick stage]"*

### Step 6: Baseline + import

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

If a plan was imported but isn't written down, prompt the user to paste/summarize it into `plan.md` (or orchestrator drafts from summary + diff and user confirms). Same pattern for imported tests/code (note their file paths in metadata).

### Step 7: AC confirmation

- **Raw ACs provided in intake:** restate in Given/When/Then, present, iterate until approved.
- **ACs to derive:** propose 3–7 Given/When/Then based on description + context (+ any imported code/tests). Present, iterate until approved.

Surface **Out of Scope** items and **Open Questions** and confirm each.

### Step 8: Write artifacts

Write `ac.md`:
```markdown
# <TICKET-ID> — Acceptance Criteria
## In Scope
- AC-1: GIVEN ... WHEN ... THEN ...
## Out of Scope
## Open Questions (resolved)
## Applicable Lessons
```

Initialize `./.doer/knowledge/assumptions/<TICKET-ID>.md` with assumptions surfaced.

### Step 9: Finalize

Update `metadata.json`: stage 1 complete, advance `current_stage` to the entry point decided in Step 5.

Narrate: *"Stage 1 complete. Imported stages: {list}. Next at Stage {N}. Continue? [Y/n]"*

---

## Stage 2 — Plan (Doer/Reviewer Loop)

**Goal:** produce an implementation plan written to `plan.md`.

**Doer agent:** general-purpose, prompted as "implementation planner".
**Reviewer agent:** general-purpose, prompted as "plan reviewer".

### Planner prompt (skeleton)

```
Read:
- ./.doer/tickets/<TICKET-ID>/ticket.md
- ./.doer/tickets/<TICKET-ID>/ac.md
- <doer-skill-dir>/lessons/*.md (global lessons — apply those whose scope matches)
- ./.doer/knowledge/assumptions/<TICKET-ID>.md

Explore the codebase to understand current structure relevant to this ticket.

Produce `./.doer/tickets/<TICKET-ID>/plan.md` with:
1. Affected files (list with one-line reason each)
2. Ordered steps (each step small enough to implement in one edit)
3. Test strategy (what tests to add, what existing tests to update)
4. Risks & mitigations
5. Assumptions made (append new ones to assumptions/<TICKET-ID>.md)

Also produce `changelog.md` in the same directory describing your key decisions.

Do NOT write code. Do NOT run tests. Plan only.
```

### Plan reviewer prompt (skeleton)

```
Read plan.md, ticket.md, ac.md, changelog.md.

Judge the plan against:
- AC coverage: does every AC have a clear path in the plan?
- Step granularity: are steps small and independently verifiable?
- Test strategy: does it cover the ACs and edge cases?
- Risk awareness: are real risks identified? Any hand-wavy "should work" steps?
- New dependencies: any new libraries proposed without justification?

Output findings as BLOCKER / AUTO_FIX / SUGGESTION / INFO. (See Doer/Reviewer Loop Pattern section for the classification rules and the AUTO_FIX-vs-SUGGESTION decision test.)
```

Run the doer/reviewer loop until convergence. **No commit** — `plan.md` lives in `.doer/` (gitignored).

---

## Stage 3 — Tests (Doer/Reviewer Loop, TDD Red)

**Goal:** write failing tests that encode the ACs. No implementation yet.

### Test writer prompt (skeleton)

```
Read ticket.md, ac.md, plan.md.

Write the tests described in plan.md's test strategy. Tests MUST currently fail
(no implementation exists yet). Follow the repo's existing test conventions
(framework, file layout, naming). Run the test suite and confirm the new tests
fail with meaningful messages — not import errors, not typos.

Write `changelog.md` describing which tests were added and which AC each covers.
```

### Test reviewer prompt (skeleton)

```
Read plan.md, ac.md, the new tests, and changelog.md.

Judge:
- Does every AC have at least one test?
- Are tests failing for the right reason? (missing behavior, not syntax errors)
- Do tests follow the repo's existing style?
- Are edge cases from the plan covered?
- Any brittle assertions or over-mocking?

Output findings as BLOCKER / AUTO_FIX / SUGGESTION / INFO. (See Doer/Reviewer Loop Pattern section for the classification rules and the AUTO_FIX-vs-SUGGESTION decision test.)
```

Run loop until convergence. Commit:
```bash
git add -A
git commit --no-verify -m "doer(<TICKET-ID>): failing tests (TDD red)"
```

---

## Stage 4 — Code (Doer/Reviewer Loop, TDD Green)

**Goal:** make the failing tests pass. Implement per plan.md.

### Code writer prompt (skeleton)

```
Read ticket.md, ac.md, plan.md, and the tests added in Stage 3.

Implement the plan. Follow existing codebase conventions. Do not add new
dependencies unless the plan specifies them (and even then, flag it in
changelog.md).

After implementation, run the full test suite. All tests (new and pre-existing)
MUST pass.

Write `changelog.md` describing each plan step and how it was executed, with
file paths and a one-line rationale.
```

### Code reviewer prompt (skeleton)

```
Read ac.md, plan.md, tests, the implementation diff (git diff against the
branch base), and changelog.md.

Review scope (in priority order):
1. AC match: does the behavior implement every AC? Trace each AC to test + code.
2. Correctness: edge cases, error paths, concurrency, off-by-one, null handling.
3. Security: input validation, injection, secrets, auth, authz.
4. Test integrity: do the new tests still cover real behavior, or were they
   weakened to make them pass?
5. Dependencies: any new deps introduced without plan approval?
6. Scope: any changes outside the plan?

Focus on the diff. Do NOT re-review files that were not touched.

Output findings as BLOCKER / AUTO_FIX / SUGGESTION / INFO. (See Doer/Reviewer Loop Pattern section for the classification rules and the AUTO_FIX-vs-SUGGESTION decision test.)
```

Run loop until convergence. Commit:
```bash
git add -A
git commit --no-verify -m "doer(<TICKET-ID>): implementation (TDD green)"
```

---

## Stage 5 — Reflect (Self-Review)

**Goal:** cheap self-review by the code-writer before the heavier code reviewer in Stage 6.

**No separate reviewer.** Just invoke the code-writer agent again with:

```
You just finished implementing <TICKET-ID>. Before the formal code review,
re-read your own diff with fresh eyes.

Read: ac.md, plan.md, changelog.md, git diff against branch base.

Ask yourself:
- Did I actually cover every AC, or did I skip something?
- Any TODOs, hacks, or shortcuts I told myself I'd fix later?
- Any files I changed that weren't in the plan?
- Any test I weakened to avoid debugging?

Read <doer-skill-dir>/lessons/*.md (global lessons) and check if any past lesson applies to
what you just wrote.

Write `./.doer/tickets/<TICKET-ID>/reflect.md` with:
- Self-identified issues (if any) — BLOCKER / SUGGESTION
- Lessons that applied
- Confidence level (low / medium / high) + reason

If you find BLOCKERs, fix them now in the same commit.
```

Commit:
```bash
git add -A
git commit --no-verify -m "doer(<TICKET-ID>): self-reflect"
```

---

## Stage 6 — Code Review (Doer/Reviewer Loop, External Review)

**Goal:** independent review against a concrete checklist.

Reuse the Stage 4 code reviewer, but this time the "doer" is the code-writer responding to the reviewer's findings. Same delta-aware loop.

### Explicit review checklist (append to reviewer prompt)

```
In addition to the standard review scope, explicitly verify:

[ ] Every AC traces to a test AND to code.
[ ] External interfaces and public APIs have tests.
[ ] Edge cases the spec mentions are handled.
[ ] No new dependency was introduced without plan approval.
[ ] Diff touches ONE logical unit — if it touches multiple, flag as BLOCKER
    and recommend splitting in a follow-up ticket.
[ ] No secrets, API keys, or credentials in the diff.
[ ] Error handling is specific (not bare `except:` or swallow-all).
[ ] At least one smoke test or script-level verification exists.
```

Commit:
```bash
git add -A
git commit --no-verify -m "doer(<TICKET-ID>): address code review"
```

---

## Stage 7 — Quality Gate (Validation, Not Loop)

**Goal:** fast sanity check. No agents. Just run tests.

1. Run the full test suite (detect the command from the repo — `npm test`, `pytest`, `go test ./...`, etc. If unclear, ask user).
2. If any test fails:
   - Narrate the failures.
   - Ask: "Tests failing: {list}. Options: 1) Return to Stage 4 to fix, 2) Return to Stage 6 to re-review, 3) Pause for manual fix. Which?"
3. If all tests pass, write the log to `.doer/tickets/<TICKET-ID>/test-log.txt` for the dev's reference (lives on disk only — gitignored, no commit).
4. Narrate "Quality gate passed: <N>/<N> tests green. Continuing." and proceed.

---

## Stage 8 — Runtime Verify (Live Debug Logs, Temporary)

**Goal:** verify on-device behavior against ACs via dense temporary debug logs. Logs NEVER reach the final branch.

**Skip:** ask once: *"Does this ticket produce runtime behavior worth exercising on device? [Y/n]"*. If `n`, mark `stages.8.status = "skipped"` and proceed to Stage 9.

**Log format (exact):** `println("DOER - <TICKET-ID> - <ClassName.fnName> - <message or key=value>")`. The prefix `DOER - <TICKET-ID>` is the unique grep tag — nothing else in the codebase matches.

### Step 1: Inject logs

Invoke a general-purpose agent with this prompt:

```
You are the runtime-logger agent for ticket <TICKET-ID>.

Read: .doer/tickets/<TICKET-ID>/ac.md, plan.md, and `git diff <base>..HEAD`.

Scope: every file in the diff PLUS every file in the call path the ACs
exercise (deps, helpers, repositories, view models). Follow imports
outward from the diff until full runtime flow is covered. Stop at
framework/SDK boundaries.

What to log: function entry (with args), every conditional branch (which
+ why), state changes ("set X to Y"), external boundaries (API/DB/IO/
threads/coroutines), exception catches, function exit (return or void).

Format MANDATORY: println("DOER - <TICKET-ID> - <ClassName.fnName> - <message>")

Rules: use println (not app logger), never modify business logic, never
touch existing logs, run the build after to verify syntax.

Write summary to .doer/tickets/<TICKET-ID>/runtime-logs-added.md
(file touched + one-line reason each).
```

### Step 2: Temporary commit

```bash
git add -A
git commit --no-verify -m "doer(<TICKET-ID>): [TEMP] runtime debug logs — DO NOT MERGE"
```

The commit is identified later by its unique message prefix, not by a stored SHA.

### Step 3: Hand off to dev

Narrate:
```
Runtime logs injected across N files. Build and run the app:
  <build/install command — detect from repo or ask once and persist as
   metadata.runtime_build_command>

Exercise each AC manually. Filter logs:
  <log filter, e.g. `adb logcat | grep "DOER - <TICKET-ID>"`>

Paste filtered output (or tell me the file path) and say "ready" to analyze.
```

### Step 4: Analyze logs

When the dev provides log output, invoke an analyzer agent:

```
You are the runtime-log analyzer for ticket <TICKET-ID>.

Read: ac.md, plan.md, and the log excerpt at
.doer/tickets/<TICKET-ID>/runtime-log-output.txt

For each AC: was the code path hit? Did values match expected? Any
unexpected errors? Any branch that should have been exercised but wasn't?

Write .doer/tickets/<TICKET-ID>/runtime-analysis.md with sections:
  ## AC-by-AC verdict
    AC-1: PASS | FAIL | NOT_EXERCISED — <evidence>
  ## Anomalies
  ## Recommended next action
    One of: APPROVE | RETURN_TO_STAGE_2 | RETURN_TO_STAGE_3 |
            RETURN_TO_STAGE_4 | NEED_MORE_DATA  (with rationale)
```

Present `runtime-analysis.md` to dev and ask: *"Analyzer recommends: <action>. <summary>. Apply? [Y / explain / override]"*

Branches:
- **APPROVE** → Step 5 (cleanup)
- **RETURN_TO_STAGE_N** → cleanup first, then jump back to stage N with findings pre-loaded as BLOCKERs
- **NEED_MORE_DATA** → keep logs, loop back to Step 3
- **Override** → honor dev's choice, record reason

### Step 5: Cleanup

```bash
TEMP_SHA=$(git log --grep="^doer(<TICKET-ID>): \[TEMP\] runtime debug logs" --format="%H" | head -n1)
if [ -z "$TEMP_SHA" ]; then echo "ERROR: temp commit not found"; exit 1; fi

git revert --no-edit "$TEMP_SHA"
git commit --no-verify --amend -m "doer(<TICKET-ID>): remove runtime debug logs"

# Verify zero residuals
if git grep -l "DOER - <TICKET-ID>" -- .; then
  echo "ERROR: Residual DOER logs found"; exit 1
fi
```

If residuals (shouldn't happen): re-invoke the logger agent: *"Remove every line matching `DOER - <TICKET-ID>`. Touch nothing else."*

Narrate: *"Runtime logs removed. Proceeding to docs sync."*

### Step 6: Record outcome

Update `metadata.json → stages.8`:
```json
{
  "name": "runtime-verify",
  "status": "complete",
  "ac_verdicts": {"AC-1": "PASS", ...},
  "returns_triggered": [],
  "completed_at": "<ISO8601>"
}
```
No SHAs persisted — git history is the source of truth. No commit needed (`.doer/` is gitignored).

---

## Stage 9 — Docs Sync

**Goal:** update user-facing documentation if the change affects it.

1. Detect candidates:
   - `README.md` if public API / CLI / user flow changed.
   - `CHANGELOG.md` if the repo maintains one.
   - Docs under `docs/`, `documentation/` that reference changed behavior.
2. If candidates exist, invoke the general-purpose agent to update them based on the diff. Constrain: "Only update documentation that describes behavior we actually changed. Do NOT rewrite unrelated sections."
3. If no doc candidates exist, note it in metadata and skip.
4. Commit:
   ```bash
   git add -A
   git commit --no-verify -m "doer(<TICKET-ID>): sync documentation"
   ```

---

## Stage 10 — Wrapup (Lessons & Assumptions)

**Goal:** capture lessons, validate assumptions, generate performance report, clean `.doer/` from branch history.

1. **Validate assumptions.** Read `./.doer/knowledge/assumptions/<TICKET-ID>.md`. Mark each VALIDATED, INVALIDATED (with reason), or UNVERIFIED.

2. **Capture lessons.** Ask: *"Any lesson worth saving for future tickets? Reply with one or more, or `none`."* For each lesson, write to the GLOBAL lessons dir at `<doer-skill-dir>/lessons/{slug}.md` (resolve symlinks to find the real path — the same dir where SKILL.md lives). Lessons are cross-project; do NOT write them under `.doer/`. Format:
   ```markdown
   ---
   slug: <kebab-case>
   captured_from: <TICKET-ID>
   captured_at: <ISO8601>
   when_it_applies: <short context description>
   ---
   ## What happened
   ## Why it matters
   ## Takeaway
   ```

3. **Write `wrapup.md`** with sections: Assumptions (status per item), Lessons captured (slug + takeaway), Commits (SHA list from metadata).

4. **Generate `performance.md`.** Sources: `metadata.json` (stage timestamps, agent_invocations, convergence_loop), `git log/diff` for commits/LOC, repo test command for pass/fail. Format:
   ```markdown
   # <TICKET-ID> — Performance Report

   ## Timing
   Started / Completed / Wall clock / Active (excludes paused)

   ## Stage breakdown
   | Stage | Status | Duration | Iterations | Blockers resolved |

   ## Code metrics
   Commits / Files changed (src/tests/docs) / Lines +/- / Tests added/modified / Pass-fail status

   ## Agent invocations
   <agent-name>: <count>

   ## Convergence stats
   Converged iter 1 / iter 2+ / max-iterations / avg
   ```

5. **Update `metadata.json`:** `status: "complete"`, `completed_at: <ISO8601>`.

6. **PR-ready history cleanup** — remove `.doer/` from prior commits on the feature branch.

   ```bash
   DIRTY=$(git log --format=%H --diff-filter=ACMR -- '.doer/*' "<base>..HEAD" 2>/dev/null)
   ```
   If empty → skip to step 7.

   Otherwise: confirm with user (destructive, changes SHAs). On approval:
   ```bash
   git update-ref "refs/doer-backup/<TICKET-ID>-pre-cleanup-$(date +%s)" HEAD
   git filter-branch -f --index-filter 'git rm -r --cached --ignore-unmatch .doer/' --prune-empty "<base>..HEAD"
   git update-ref -d refs/original/refs/heads/<branch-name> 2>/dev/null || true
   ```
   Verify `git log --diff-filter=ACMR -- '.doer/*' "<base>..HEAD"` is empty. Tell user the backup ref name (rollback: `git reset --hard <ref>`).

   On user decline: narrate `"Skipping history cleanup. .doer/ will appear in PR. Run /doer cleanup-history <TICKET-ID> later."`

7. **Final wrapup commit** (only if there are uncommitted real changes — wrapup itself usually has none since it only writes to `.doer/`):
   ```bash
   if ! git diff --quiet || ! git diff --cached --quiet; then
     git add -A
     git commit --no-verify -m "doer(<TICKET-ID>): wrapup"
   fi
   ```

8. Narrate: *"Ticket <TICKET-ID> complete. {N} commits on `<branch>` (post-cleanup). Performance report: .doer/tickets/<TICKET-ID>/performance.md. Run your pre-commit checks (lint, format, full tests), then push and open the PR manually."*

---

## `/doer continue <TICKET-ID>`

1. Read `./.doer/tickets/<TICKET-ID>/metadata.json`.
2. If `status != "paused"` and `status != "in_progress"`, warn the user.
3. Check out the feature branch if not already on it:
   ```bash
   git checkout <branch-name>
   ```
4. **Workspace Guard — RUN INLINE, do NOT just reference it.** These exact bash commands MUST execute before step 5. Do NOT skip, do NOT defer, do NOT replace with a comment saying "the Guard will run".

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

     # 4e. Mark satisfied
     # Update metadata.json: set workspace_guard = "ok"
     echo "Workspace Guard: applied."
   fi
   ```

5. **Self-check before proceeding.** Verify both conditions are now true:
   - `.git/info/exclude` contains `.doer/` (run `grep -qxF '.doer/' .git/info/exclude`)
   - The active ticket's `metadata.json` has `"workspace_guard": "ok"`

   If either fails, STOP. Do NOT continue resuming. Narrate the failure and ask the user how to proceed. The Guard is a precondition, not a suggestion — proceeding without it pollutes the team's PR.

6. Read the last stage's loop state (if any). If mid-loop, resume at the same iteration.
7. Narrate: "Resuming <TICKET-ID> at Stage {N} ({name}){, iteration {i}}. Continue? [Y/n]"
8. Proceed.

---

## `/doer status <TICKET-ID>`

Render:

```
Ticket: <TICKET-ID> — <title>
Type: <type>  Branch: <branch>  Status: <status>
Current Stage: {N} ({name})

Progress:
  [✓] 1 ac-confirm
  [✓] 2 plan
  [~] 3 tests     (iteration 2/5, 1 BLOCKER open)
  [ ] 4 code
  ...

Blockers: <list or "none">
Commits: <count>
```

---

## `/doer list`

List every directory under `./.doer/tickets/`, one line each:

```
ABC-123   [in_progress]  Stage 4 (code)         fix-login-timeout
ABC-119   [complete]     —                      add-redis-cache
ABC-110   [paused]       Stage 2 (plan)         refactor-auth
```

---

## `/doer verify <TICKET-ID>`

**Goal:** run stages added to the skill AFTER this ticket closed. Additive only — never re-runs stages whose internal logic changed.

### Step 1: Load + Guard

1. Read `metadata.json`. Error if not found.
2. Error if `status != "complete"` (use `/doer continue` instead).
3. **Workspace Guard — RUN INLINE** (same bash block as `/doer continue` step 4). Self-check: `.git/info/exclude` contains `.doer/` AND `metadata.workspace_guard == "ok"`. STOP if either fails.

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

No commit needed — `metadata.json` is in `.doer/` (gitignored). Per-stage commits during Step 5 already captured any real code changes.

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
3. Run the **Workspace Guard** (idempotent — ensures `.doer/` is excluded going forward).
4. Run steps **a through g** of the wrapup's "PR-ready history cleanup" (detect dirty commits → confirm with user → backup ref → `git filter-branch` → verify → reset housekeeping refs → narrate). Same logic, no duplication.
5. Narrate the result. Do NOT commit anything new — this command is purely a history rewrite.

### Safety

- Always creates a backup ref under `refs/doer-backup/<TICKET-ID>-pre-cleanup-<timestamp>` before rewriting. Tell the user the ref name; they can `git reset --hard <ref>` to roll back.
- Refuses to run if the branch has been pushed AND has commits other people may have based work on. Detect via `git rev-list --count HEAD@{u}..HEAD` and `git rev-list --count HEAD..HEAD@{u}` if upstream is set; warn if the upstream tracking suggests rewrite would be disruptive.

### Skip when not needed

If the cleanup detection finds zero dirty commits, narrate *"Nothing to clean — branch already free of .doer/ content."* and exit without prompting.

---

## Error Handling

- **Agent returns error:** narrate the error, ask user to retry (max 3), or pause.
- **Git operation fails:** narrate, present options (resolve manually, pause, abort stage).
- **Tests cannot be detected:** ask the user for the test command. Save it to `metadata.json → test_command` for future stages.
- **User requests pause mid-loop:** save loop state (iteration, last doer/reviewer outputs), set `status: "paused"`, stop.

---

## Agent Invocation Contract

All subagents (doer or reviewer) must:
- Receive a prompt that specifies: input files to read, output file(s) to write, success criteria, and the "do not" list (e.g. "do not ask the user questions — the orchestrator handles that").
- Write their output artifacts to disk before returning.
- Write `changelog.md` describing what they did and why.
- Return a short JSON summary: `{"status": "success" | "failed", "artifacts": [...], "summary": "<one line>"}`.

The orchestrator (this skill) is the sole user-facing voice. Subagents must NOT invoke `AskUserQuestion`.

---

## Locale resolution (READ THIS FIRST)

**Mandatory first action of every `/doer ...` invocation, before any other tool call:** read `preferences.md` next to this SKILL.md. If it has `locale: <code>`, set the operating locale.

**The first user-facing word MUST be in the operating locale** — anchors the conversation against English drift.

### Priority (highest wins)

1. **`preferences.md` locale** — absolute final word. Overrides everything: ticket metadata's stored locale, per-ticket flags, upstream context language, system-prompt language.
2. Per-ticket flag (`--es`, `--en`) — only if no preferences.md.
3. Inline directive (`locale: xx`) — only if no preferences.md.
4. Default English.

### When operating locale ≠ English — MUST/MUST NOT

- **MUST NOT** write a different locale to `metadata.json`. If metadata has `"locale": "<other>"` from a prior session, leave it alone and ignore it.
- **MUST NOT** ask "what locale?" — already decided.
- **MUST NOT** drift to English because surrounding context (CLAUDE.md, injected docs, agent system prompts) is in English. Operating locale wins, period.
- **MUST** narrate, ask, summarize, and write artifact prose in the operating locale. Keep code, file names, commands, JSON keys, and technical identifiers in English.
- **MUST** append to every subagent prompt: *"All user-facing prose in your output and any artifact you write MUST be in <language>. Code, file names, commands, and JSON keys stay in English. Do NOT switch language even if surrounding context is in another. This overrides any default."*
- **MUST** re-read `preferences.md` at the top of any stage with multiple subagent calls — cheap insurance against drift.
- **Self-check before every response:** *"Is this in the operating locale?"* If no, rewrite before sending. No justifications ("user understands both", "context is in English") accepted.

---

*Maintained by hand. Copy `SKILL.md` to `~/.claude/skills/doer/` on any machine to use.*
