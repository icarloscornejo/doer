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
2. **One branch, one ticket** — All work happens on a single feature branch. Every stage ends with a commit that serves as evidence for future agents.
3. **Delta-aware reviewers** — After iteration 1, reviewers receive prior findings + a changelog from the doer. They verify fixes and scan for new issues, rather than re-analyzing from scratch.
4. **Bounded loops** — Max 5 iterations per doer/reviewer loop. If not converged, the user decides.
5. **Lessons accumulate** — Every ticket captures what went well and what did not. Future tickets read those lessons before planning.
6. **No hidden state** — Everything the orchestrator knows lives in `./.doer/` on disk. Context compression never loses progress.

---

## Commands

| Command | Description |
|---------|-------------|
| `/doer <TICKET-ID>` | Start a new ticket. Orchestrator asks for title, description, type, ACs, context, branch name. |
| `/doer continue <TICKET-ID>` | Resume a paused ticket from its last stage. |
| `/doer status <TICKET-ID>` | Show current stage, loop state, and blockers. |
| `/doer list` | List all tickets in `./.doer/tickets/`. |
| `/doer verify <TICKET-ID>` | Run stages that exist in the current skill but were missing when the ticket was closed. |
| `/doer pause` | Persist current state and stop. |

**Stages cannot be skipped manually.** Every stage must run. The only way to skip stages is through Stage 1's pre-existing-work detection (see Stage 1 below). This is by design: the orchestrator decides which stages to skip, not the user.

**Implicit activation:** If the user writes natural language (e.g. "keep going", "pause here", "the plan looks good") and an active ticket exists in `./.doer/tickets/*/metadata.json` with `status == "in_progress"`, treat the message as a directive to the active orchestrator rather than a new query.

---

## Knowledge & State Layout

All state lives under `./.doer/` in the current working directory (scoped to the target repo).

```
./.doer/
├── knowledge/
│   ├── lessons/          # Accumulated across tickets. Read before planning.
│   │   └── {slug}.md
│   └── assumptions/      # Per-ticket, validated at wrapup.
│       └── {TICKET-ID}.md
└── tickets/
    └── {TICKET-ID}/
        ├── metadata.json           # Workflow state — single source of truth
        ├── ticket.md               # Title, description, type, context from intake
        ├── ac.md                   # Confirmed acceptance criteria (Stage 1 output)
        ├── plan.md                 # Implementation plan (Stage 2 output)
        ├── reflect.md              # Self-review notes (Stage 5 output)
        ├── wrapup.md               # Captured lessons (Stage 10 output)
        └── review/
            ├── plan-review-{iter}.md
            ├── tests-review-{iter}.md
            └── code-review-{iter}.md
```

On first invocation in a repo, create `./.doer/` and `./.doer/knowledge/{lessons,assumptions}/` if they do not exist.

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

6. Narrate to the user: "Ticket <TICKET-ID> initialized on branch `<branch-name>`. Starting Stage 1: AC Confirm."

7. Proceed to Stage 1.

---

## Narration Protocol

Before each stage, narrate: "Starting Stage {N} — {name}. {one-sentence goal}." and write `stages.<N>.started_at = <ISO8601>` in `metadata.json`.

Inside a doer/reviewer loop, narrate: "Iteration {i} of {max}: invoking {agent}... [wait] agent returned {status}, {total_findings} findings ({blockers} blockers)."

After each stage, write `stages.<N>.completed_at = <ISO8601>` in `metadata.json`, then narrate: "Stage {N} complete. Committed as `{sha}`. Continue to Stage {N+1}? [Y/n/pause]"

### Pause windows (critical for user control)

**The orchestrator MUST keep turns short so the user can interject between them.** Long turns block the user's ability to pause — their messages queue and only get read after the current turn ends.

**Guiding principle: narrate then proceed, don't ask for confirmation at every step.** The user wants to run the pipeline, not babysit it. Only ask for explicit confirmation at genuinely irreversible decision points. Everything else: narrate what you are about to do, end the turn (so queued messages are processed), then continue automatically on the next turn.

**Three types of turn boundaries:**

| Type | When | Behavior |
|------|------|----------|
| **Auto-proceed** | Between subagent invocations, between doer and reviewer, between stages | Narrate "Doing X next..." and end the turn. On the next turn, check if the user queued an interrupt ("pause", "stop", "wait", "n"). If yes → pause. If no → proceed without asking. |
| **Confirm** | Before presenting artifacts the user should review (plan.md, ac.md, review findings), before the final wrapup, when a loop hits max iterations | End the turn with an explicit question and wait for the user's answer. |
| **Decide** | Genuine forks where the user must choose a path (import pre-existing work? skip docs?) | Same as Confirm — wait for answer. |

**Rules:**

1. **After every subagent invocation, end the turn.** Narrate one line of status, announce the next step, and stop. Default behavior: auto-proceed on the next turn unless the user interrupted.
2. **After every major file write**, end the turn with a one-line summary. Auto-proceed.
3. **At stage boundaries (1→2, 2→3, etc.)**, end the turn with: *"Stage N complete. Starting Stage N+1 ({name})..."*. Auto-proceed on the next turn unless interrupted.
4. **Inside loop iterations**, end the turn between doer and reviewer, AND between reviewer and next-doer. Auto-proceed.
5. **Never bundle multiple stages or subagent invocations into one turn.** One invocation per turn, max.

**When to Confirm (not auto-proceed):**
- After the planner finishes plan.md → present plan, ask "approve / edit / redo?"
- After the AC Confirm draft → present, ask "these accurate?"
- Before the final wrapup commit → ask "ready to close?"
- When a convergence loop hits max iterations → ask "retry / accept / pause?"

**SUGGESTIONs are NEVER a reason to pause.** When a reviewer returns findings with only SUGGESTIONs (zero BLOCKERs), the loop has converged. Do NOT ask the user whether to apply SUGGESTIONs. Instead:
1. Record all SUGGESTIONs in the review file (`review/{stage}-review-{iter}.md`) for the user's later reference.
2. Narrate one line at the turn boundary: *"Converged with N SUGGESTIONs logged in review/{stage}-review-{iter}.md. Continuing to next stage."*
3. Auto-proceed without waiting for an answer.

The user can read the review file anytime and manually apply suggestions outside the pipeline. The pipeline's job is forward motion; optional improvements are optional.

**Interrupt handling:** at any auto-proceed turn boundary, if the user's latest message contains "pause", "stop", "wait", "hold on", "n", "no", "espera", "para", or any clear halt signal, treat it as a pause request. Save state, acknowledge, stop. Otherwise proceed without asking.

**Why this matters:** the user explicitly does not want to type "Y" repeatedly. Frequent turn boundaries exist so queued interrupts get read, not so the user has to confirm every step. Default is forward motion; confirmation is the exception, not the rule.

### Pause handling

If the user writes "pause", "stop", or "n" at any turn boundary:
1. Persist current state to `metadata.json` (set `status: "paused"`, write `paused_at`).
2. Reply: "Paused at Stage {N} (iteration {i} if applicable). Resume with `/doer continue <TICKET-ID>`."
3. Stop immediately.

**Note for the user:** messages you type while the orchestrator is running a subagent queue up and are only read when that subagent returns. For immediate interruption, press `Esc`. The frequent turn boundaries above exist so you rarely need to.

### Performance tracking (for the Stage 10 report)

Every time the orchestrator calls the `Agent` tool, increment a counter in `metadata.json`:

```json
"agent_invocations": {
  "implementation-planner": 2,
  "plan-reviewer": 2,
  "test-creator": 3,
  "...": "..."
}
```

Every time a convergence loop exits, record its outcome in `stages.<N>.convergence_loop`:

```json
{
  "iterations": 3,
  "converged_on_iteration": 3,
  "blockers_resolved_total": 5,
  "exit_reason": "converged" | "max_iterations" | "user_accepted"
}
```

Every time a stage transitions from `in_progress` → `paused` → `in_progress`, accumulate active time only (exclude the paused interval):

```json
"stages": {
  "4": {
    "started_at": "...",
    "completed_at": "...",
    "pauses": [{"paused_at": "...", "resumed_at": "..."}],
    "active_duration_seconds": 2847
  }
}
```

---

## Doer/Reviewer Loop Pattern (Delta-Aware)

Stages 2, 3, 4, and 6 use this pattern. Max iterations: **5**.

### Findings severity

Reviewer returns findings in four buckets. The distinction between AUTO_FIX and SUGGESTION is critical — it determines whether the orchestrator applies the change automatically or just logs it.

- **BLOCKER** — must be fixed before advancing. Loop continues until resolved.
  Examples: failing tests, missing AC coverage, security issue, broken build, missing error handling for a known error path.

- **AUTO_FIX** — obvious, mechanical, low-risk fix with no design trade-off. There is one reasonable way to do it; nothing to decide. Applied automatically without asking the user.
  Examples: reference to a deleted/renamed function, unused import, test name that no longer matches the test body after a rename, typo in a string literal or comment, dead variable, stale file path in a comment, missing type hint that is trivially inferable.

- **SUGGESTION** — genuinely optional improvement that involves a design choice, taste, or trade-off. Logged for user review, never applied automatically, never blocks.
  Examples: "consider extracting this helper", "could use a map instead of a chain of ifs", "this name is less clear than X", "you might refactor this into a class", "consider adding caching here".

- **INFO** — observational, no action needed.
  Examples: "this file has grown to 500 LOC", "this pattern is used in 3 other places".

**The test for AUTO_FIX vs SUGGESTION:** *"Is there anything to decide?"*
- No → AUTO_FIX
- Yes (trade-off, preference, design judgment) → SUGGESTION

If in doubt, classify as SUGGESTION. The reviewer should be conservative with AUTO_FIX — when applied, the orchestrator does NOT ask for user approval.

Convergence = zero BLOCKERs remaining. AUTO_FIXes do NOT block convergence; they are applied in the same iteration before declaring convergence.

### Iteration 1 (clean-slate)

1. Invoke doer with the stage input.
2. Doer writes its artifact AND a `changelog.md` describing what it produced and why.
3. Invoke reviewer with the artifact. Reviewer produces findings categorized BLOCKER / AUTO_FIX / SUGGESTION / INFO.
4. **Apply AUTO_FIXes.** If the reviewer returned any AUTO_FIX items, the orchestrator invokes a short "fixer" pass (same agent as the doer, or a general-purpose agent) with the AUTO_FIX list and instructions: *"Apply each of these mechanically. No design changes. Append to changelog.md as `AutoFix #<id>: <what you changed>`."* This happens BEFORE checking for convergence.
5. If zero BLOCKERs → converged. Exit loop. Log SUGGESTIONs and INFO to the review file, narrate one line ("Convergió. N AUTO_FIXes aplicados. M SUGGESTIONs registradas."), and auto-proceed.
6. If BLOCKERs > 0 → proceed to Iteration 2.

### Iteration 2+ (delta-aware)

1. Invoke doer with:
   - Current artifact
   - Prior BLOCKER findings with IDs
   - Instruction: "Address each BLOCKER. Append to `changelog.md`: for each BLOCKER id, write `Fix #<id>: <what you changed and why>`."
2. Doer updates the artifact and appends to `changelog.md`.
3. Invoke reviewer with:
   - Updated artifact
   - Prior findings list
   - The new `changelog.md`
   - Instruction: "For each prior BLOCKER, mark it RESOLVED or STILL_OPEN. Scan areas the doer touched (per changelog) for new issues. Do NOT re-analyze untouched areas. Classify findings as BLOCKER / AUTO_FIX / SUGGESTION / INFO."
4. Reviewer output:
   ```json
   {
     "prior_blockers_resolved": ["id-1", "id-3"],
     "prior_blockers_still_open": ["id-2"],
     "new_blockers": [...],
     "auto_fixes": [...],
     "suggestions": [...],
     "info": [...]
   }
   ```
5. Apply any AUTO_FIXes (same as iteration 1 step 4).
6. Remaining BLOCKERs = still_open + new. If zero → converged. Otherwise → next iteration.

### Max iterations (5) reached without convergence

Narrate: "Stage {N} did not converge after 5 iterations. {count} BLOCKERs remain: {list}. Options: 1) Run one more iteration, 2) Accept remaining findings and continue, 3) Pause for manual intervention. Which?"

Record the choice in `metadata.json` under `stages.<N>.loop_outcome`.

---

## Stage 1 — AC Confirm

**Goal:** produce unambiguous, testable acceptance criteria written to `ac.md`. Also detect and incorporate any pre-existing work the user has already done on this ticket.

**No subagent — orchestrator does this directly.**

1. Read `ticket.md`.
2. Read all files in `./.doer/knowledge/lessons/` (if any) and note any lesson whose `when_it_applies` matches this ticket type or area.

3. **Pre-existing work detection** (ask the user):

   "Have you already done any work on this ticket before invoking `/doer`? [y/N]"

   If **no** → skip to step 4.

   If **yes** → ask each of these, one at a time via `AskUserQuestion`:

   | Question | If "yes", follow up with |
   |----------|--------------------------|
   | "Do you already have a written plan (mental or on paper/file)?" | "Paste or summarize it." |
   | "Did you already write tests?" | "Where are they? Do they currently pass or fail?" |
   | "Did you already write implementation code?" | "Where are the changes? Committed, staged, or uncommitted?" |
   | "Did you already update any documentation?" | "Which files?" |

   Also detect the repo state automatically:
   - Run `git branch --show-current` → confirm which branch the user is on
   - Run `git status --porcelain` → detect uncommitted changes
   - Run `git log --oneline <base-branch>..HEAD` → list commits ahead of base
   - Determine the base branch: prefer `main`, fall back to `master`, or ask the user if unclear

3b. **Inspect the existing work.** Do NOT just count commits — read them to understand what's already done:

   For each commit ahead of base, run:
   - `git show --stat <sha>` → see which files were touched and how much
   - `git show <sha>` (full diff) if the commit is small enough, OR read the commit message + stat and open key files directly

   For uncommitted changes, run:
   - `git diff <base-branch>...HEAD` → full diff of committed work
   - `git diff` → unstaged changes
   - `git diff --cached` → staged changes

   Based on the inspection, classify each file touched:
   - **Test files** (match repo test conventions: `*_test.*`, `*.test.*`, `tests/`, `spec/`) → user has tests
   - **Source files** (everything else that's code) → user has implementation
   - **Docs** (`.md`, `docs/`) → user has documentation
   - **Planning artifacts** (`.doer/` or PLAN.md at repo root) → user has a plan written down

   Then run tests if any were found:
   - `<detected-test-command>` → note which pass and which fail. This tells you whether you're in TDD red, TDD green, or a broken state.

   Present the analysis to the user:

   ```
   Based on your commits, I see:
   - Plan: <yes/no + where>
   - Tests: <count> test files touched (<X passing, Y failing>)
   - Implementation: <count> source files touched (~<LOC> changed)
   - Docs: <count> doc files touched

   Summary: <one-paragraph inferred description of where you are>

   Is this accurate? [Y/n/correct-me]
   ```

4. **Decide the entry point.** Based on what the inspection + user answers revealed:

   | User has... | Suggested entry stage | Mark as `imported` |
   |-------------|----------------------|--------------------|
   | Nothing | Stage 1 (this one) | — |
   | Plan only | Stage 3 (tests) | Stage 2 |
   | Plan + failing tests | Stage 4 (code) | Stages 2, 3 |
   | Plan + tests + partial code | Stage 4 (code) — continue coding | Stages 2, 3 |
   | Plan + tests + complete code | Stage 5 (reflect) | Stages 2, 3, 4 |
   | Everything, ready for review | Stage 6 (code-review) | Stages 2, 3, 4, 5 |

   Present the suggestion to the user: "Based on what you have, I suggest starting at Stage {N} ({name}) and importing stages {list} as pre-existing work. Proceed? [Y / start from Stage 1 anyway / pick a different stage]"

5. **Preserve the pre-existing work as a baseline commit**. Before imported stages are marked, create a checkpoint commit so future agents can see the baseline:

   ```bash
   # If there are uncommitted changes:
   git add -A
   git commit -m "doer(<TICKET-ID>): import pre-existing work as baseline"
   ```

   If there are already commits ahead of the base branch, no extra commit is needed — the existing commits serve as the baseline.

6. **Mark imported stages in `metadata.json`**:

   ```json
   "stages": {
     "2": {"name": "plan", "status": "imported", "imported_at": "<ISO8601>", "note": "<what the user had>"},
     "3": {"name": "tests", "status": "imported", "imported_at": "<ISO8601>", "note": "..."}
   }
   ```

   If the user imported a plan but it's not written down anywhere, ask them to write it quickly into `./.doer/tickets/<TICKET-ID>/plan.md` (or the orchestrator drafts it based on their summary + the diff, then the user confirms).

   Similarly, if tests/code are imported, note their file paths in the metadata so downstream agents know where to look.

7. Now proceed with **AC confirmation** proper (same logic as before, whether or not pre-existing work was imported):

   a. If raw ACs were provided in intake:
      - Present them back to the user, restated in **Given/When/Then** form.
      - Ask: "These are the restated ACs. Are they complete and accurate? [Y / edit / add]"
      - Apply changes until the user approves.

   b. If ACs are to be derived:
      - Based on description + context (+ any pre-existing code/tests if imported), propose 3–7 Given/When/Then ACs.
      - Present to user, iterate until approved.

8. Also surface: **Out of scope** items and **Open questions**. Ask the user to confirm each.

9. Write the final result to `ac.md`:

   ```markdown
   # <TICKET-ID> — Acceptance Criteria

   ## In Scope
   - AC-1: GIVEN ... WHEN ... THEN ...
   - AC-2: ...

   ## Out of Scope
   - ...

   ## Open Questions (resolved)
   - Q: ... → A: ...

   ## Applicable Lessons
   - [lesson-slug]: <one-line takeaway>
   ```

10. Initialize `./.doer/knowledge/assumptions/<TICKET-ID>.md` with any assumptions surfaced during AC confirmation.
11. Commit:
    ```bash
    git add .doer/tickets/<TICKET-ID>/ac.md .doer/knowledge/assumptions/<TICKET-ID>.md
    git commit -m "doer(<TICKET-ID>): confirm acceptance criteria"
    ```
12. Update `metadata.json`: stage 1 complete. Advance `current_stage` to the entry point decided in step 4 (not necessarily 2).
13. Narrate the full picture to the user: "Stage 1 complete. Imported stages: {list}. Starting next at Stage {N}. Continue? [Y/n]"

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
- ./.doer/knowledge/lessons/*.md (apply those whose scope matches)
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

Output findings as BLOCKER / AUTO_FIX / SUGGESTION / INFO.

Classification rules (apply strictly):
- BLOCKER: broken functionality, failing test, missing AC coverage, security issue, missing error handling for a known failure path.
- AUTO_FIX: obvious, mechanical, low-risk — one reasonable way to fix, nothing to decide. Examples: reference to deleted/renamed function, unused import, test name that no longer matches body after rename, typo, dead variable, stale path in comment.
- SUGGESTION: involves a design choice, trade-off, or taste. Examples: "consider extracting", "could use X pattern instead", "name could be clearer".
- INFO: observation, no action.

Decision test for AUTO_FIX vs SUGGESTION: "Is there anything to decide?" If no → AUTO_FIX. If yes → SUGGESTION. Be conservative — when in doubt, use SUGGESTION.
```

Run the doer/reviewer loop until convergence. Commit:
```bash
git add .doer/tickets/<TICKET-ID>/
git commit -m "doer(<TICKET-ID>): implementation plan"
```

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

Output findings as BLOCKER / AUTO_FIX / SUGGESTION / INFO.

Classification rules (apply strictly):
- BLOCKER: broken functionality, failing test, missing AC coverage, security issue, missing error handling for a known failure path.
- AUTO_FIX: obvious, mechanical, low-risk — one reasonable way to fix, nothing to decide. Examples: reference to deleted/renamed function, unused import, test name that no longer matches body after rename, typo, dead variable, stale path in comment.
- SUGGESTION: involves a design choice, trade-off, or taste. Examples: "consider extracting", "could use X pattern instead", "name could be clearer".
- INFO: observation, no action.

Decision test for AUTO_FIX vs SUGGESTION: "Is there anything to decide?" If no → AUTO_FIX. If yes → SUGGESTION. Be conservative — when in doubt, use SUGGESTION.
```

Run loop until convergence. Commit:
```bash
git add -A
git commit -m "doer(<TICKET-ID>): failing tests (TDD red)"
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

Output findings as BLOCKER / AUTO_FIX / SUGGESTION / INFO.

Classification rules (apply strictly):
- BLOCKER: broken functionality, failing test, missing AC coverage, security issue, missing error handling for a known failure path.
- AUTO_FIX: obvious, mechanical, low-risk — one reasonable way to fix, nothing to decide. Examples: reference to deleted/renamed function, unused import, test name that no longer matches body after rename, typo, dead variable, stale path in comment.
- SUGGESTION: involves a design choice, trade-off, or taste. Examples: "consider extracting", "could use X pattern instead", "name could be clearer".
- INFO: observation, no action.

Decision test for AUTO_FIX vs SUGGESTION: "Is there anything to decide?" If no → AUTO_FIX. If yes → SUGGESTION. Be conservative — when in doubt, use SUGGESTION.
```

Run loop until convergence. Commit:
```bash
git add -A
git commit -m "doer(<TICKET-ID>): implementation (TDD green)"
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

Read ./.doer/knowledge/lessons/*.md and check if any past lesson applies to
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
git commit -m "doer(<TICKET-ID>): self-reflect"
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
git commit -m "doer(<TICKET-ID>): address code review"
```

---

## Stage 7 — Quality Gate (Validation, Not Loop)

**Goal:** fast sanity check. No agents. Just run tests.

1. Run the full test suite (detect the command from the repo — `npm test`, `pytest`, `go test ./...`, etc. If unclear, ask user).
2. If any test fails:
   - Narrate the failures.
   - Ask: "Tests failing: {list}. Options: 1) Return to Stage 4 to fix, 2) Return to Stage 6 to re-review, 3) Pause for manual fix. Which?"
3. If all tests pass, commit the test log as evidence:
   ```bash
   git add .doer/tickets/<TICKET-ID>/test-log.txt
   git commit -m "doer(<TICKET-ID>): quality gate passed"
   ```
4. Narrate and continue.

---

## Stage 8 — Runtime Verify (Live Debug Logs, Temporary)

**Goal:** verify on-device/runtime behavior against the ACs by injecting dense temporary debug logs, having the dev exercise the feature, and analyzing the output together. Logs are NEVER kept in the final branch.

**Skip conditions:** if the dev says "no runtime context" for this ticket (pure helper, config-only, docs-only, etc.), the orchestrator records `stages.8.status = "skipped"` with a reason and proceeds to Stage 9. Ask once at the start: *"Does this ticket produce runtime behavior worth exercising on device? [Y/n]"*. If `n`, skip.

### Log format

All temporary logs use the same shape for easy filtering:

```
println("DOER - <TICKET-ID> - <function/context> - <message or key=value>")
```

The prefix `DOER - <TICKET-ID>` is the unique tag. Nothing in the target codebase matches it, so cleanup at the end is a grep + remove with zero risk of collateral damage.

### Step 1: Inject logs

Invoke a general-purpose agent with:

```
You are the runtime-logger agent for ticket <TICKET-ID>.

Read:
- .doer/tickets/<TICKET-ID>/ac.md
- .doer/tickets/<TICKET-ID>/plan.md
- git diff <base-branch>..HEAD → the full diff for this ticket

Scope of logging (file selection):
1. Every file in the diff for this ticket.
2. Every file that sits in the call path exercised by the ACs (dependencies,
   shared helpers, repositories, view models, etc.). Follow imports and
   call chains outward from the diff until you cover the full runtime flow
   the dev will exercise. Stop at framework/SDK boundaries.

What to log (in scope files):
- Entry of every function/method involved in the AC flow (log arguments).
- Every conditional branch: which branch was taken and why (key values).
- Every meaningful state change: "set X to Y".
- Every external boundary: API calls, DB reads/writes, IO, threads, coroutines.
- Every exception catch (even if re-thrown or logged elsewhere).
- Exit of every function (log return value or "void complete").

Format — ALWAYS this exact shape:
  println("DOER - <TICKET-ID> - <ClassName.fnName> - <message or key=value>")

Rules:
- Use println, NOT the app's logger. This is throwaway instrumentation,
  we want it to stand out and be trivially removable.
- Prefix `DOER - <TICKET-ID>` is MANDATORY on every log. No exceptions.
- Do NOT modify business logic, only add log statements.
- Do NOT remove or rewrite existing logs in the codebase.
- After adding logs, run the build to make sure nothing broke syntactically.

Write a summary to .doer/tickets/<TICKET-ID>/runtime-logs-added.md listing
each file touched and a one-line reason.
```

### Step 2: Temporary commit

Once the logger agent returns, commit the logs so they survive pause/resume and so the dev sees a clean working tree:

```bash
git add -A
git commit -m "doer(<TICKET-ID>): [TEMP] runtime debug logs — DO NOT MERGE"
```

Record the commit SHA in `metadata.json → stages.8.temp_log_commit_sha`. This SHA is what the cleanup step will revert.

### Step 3: Hand off to the dev

Narrate to the user:

```
Runtime logs injected across N files. Temporary commit: <sha>.

Now build and run the app:
  <repo-specific build/install command the orchestrator detected>

Exercise each AC manually. Logs will appear in logcat / console with the
prefix "DOER - <TICKET-ID>". Filter with:
  <repo-specific log filter command, e.g. `adb logcat | grep "DOER - <TICKET-ID>"`>

When you've exercised all ACs, paste the filtered log output here (or tell me
where to read it from) and say "ready" to analyze.
```

If the orchestrator cannot detect the build command, ask the dev once and persist it in `metadata.json → runtime_build_command` for future tickets.

### Step 4: Analyze the logs

When the dev provides the log output, invoke an analyzer agent:

```
You are the runtime-log analyzer for ticket <TICKET-ID>.

Read:
- .doer/tickets/<TICKET-ID>/ac.md
- .doer/tickets/<TICKET-ID>/plan.md
- The log excerpt provided by the dev (in .doer/tickets/<TICKET-ID>/runtime-log-output.txt)

For each AC, determine from the logs:
- Was the code path for this AC actually hit? (yes / no)
- Did the values at each decision point match the expected behavior?
- Were there unexpected errors, exceptions, or retries?
- Did any branch NOT get exercised that should have been?

Output findings in .doer/tickets/<TICKET-ID>/runtime-analysis.md with sections:
  ## AC-by-AC verdict
    AC-1: PASS | FAIL | NOT_EXERCISED — <evidence from logs>
  ## Anomalies
    - <anomaly, which log line, why it matters>
  ## Recommended next action
    One of:
      - APPROVE — all ACs pass, proceed to cleanup.
      - RETURN_TO_STAGE_4 — defects in implementation, <list>.
      - RETURN_TO_STAGE_3 — tests did not cover behavior that broke, <list>.
      - RETURN_TO_STAGE_2 — plan missed a flow, <list>.
      - NEED_MORE_DATA — logs insufficient, <what to exercise>.
```

Present the `runtime-analysis.md` to the dev and ask:

```
Analyzer recommends: <action>.
<short summary>

Apply this recommendation? [Y / explain / override]
```

Branches:
- **APPROVE** → proceed to Step 5 (cleanup).
- **RETURN_TO_STAGE_N** → cleanup logs first (Step 5), then jump back to stage N with the findings pre-loaded as BLOCKERs for the doer.
- **NEED_MORE_DATA** → keep logs, loop back to Step 3 (dev exercises more, pastes more logs).
- **Dev overrides** → honor the dev's choice, record the override reason.

### Step 5: Cleanup (no logs reach the final branch)

Strategy: `git revert` the temporary commit so the logs are removed AND the history records that they existed.

```bash
TEMP_SHA=<stages.8.temp_log_commit_sha>
git revert --no-edit $TEMP_SHA
git commit --amend -m "doer(<TICKET-ID>): remove runtime debug logs"
```

Verify cleanup:

```bash
if git grep -l "DOER - <TICKET-ID>" -- .; then
  echo "ERROR: Residual DOER logs found. Manual cleanup required."
  exit 1
fi
```

If residuals are found (shouldn't happen, but defensive), invoke the logger agent once more with: *"Remove every line matching `DOER - <TICKET-ID>`. Do not touch anything else."*

Narrate to user: *"Runtime logs removed. Final commit: <sha>. Proceeding to docs sync."*

### Step 6: Record outcome

Update `metadata.json → stages.8`:
```json
{
  "name": "runtime-verify",
  "status": "complete",
  "temp_log_commit_sha": "<sha>",
  "revert_commit_sha": "<sha>",
  "ac_verdicts": {"AC-1": "PASS", "AC-2": "PASS"},
  "returns_triggered": []  // or ["stage-4"] if the loop returned
}
```

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
   git commit -m "doer(<TICKET-ID>): sync documentation"
   ```

---

## Stage 10 — Wrapup (Lessons & Assumptions)

**Goal:** close the loop. Capture lessons. Validate assumptions.

1. Read `./.doer/knowledge/assumptions/<TICKET-ID>.md`. For each assumption, mark it VALIDATED, INVALIDATED (with reason), or UNVERIFIED.
2. Ask the user: "Any lesson to capture from this ticket? A lesson is something non-obvious you'd want future tickets to know. Reply with one or more, or `none`."
3. If the user provides lessons, for each one, the orchestrator writes a new file at `./.doer/knowledge/lessons/{slug}.md`:

   ```markdown
   ---
   slug: <short-kebab-case>
   captured_from: <TICKET-ID>
   captured_at: <ISO8601>
   when_it_applies: <short description of contexts where this lesson is relevant>
   ---

   ## What happened
   <short narrative>

   ## Why it matters
   <impact / consequence>

   ## Takeaway
   <actionable rule or heuristic>
   ```

4. Write `./.doer/tickets/<TICKET-ID>/wrapup.md`:

   ```markdown
   # <TICKET-ID> — Wrapup

   ## Assumptions
   - <assumption> → VALIDATED
   - <assumption> → INVALIDATED: <reason>

   ## Lessons captured
   - [lesson-slug] — <takeaway>

   ## Commits
   <list of SHAs from metadata.json>
   ```

5. **Generate performance report** at `./.doer/tickets/<TICKET-ID>/performance.md`.

   Data sources:
   - Timestamps from `metadata.json → stages.<N>.started_at` and `completed_at` (recorded by the orchestrator as each stage runs)
   - Iteration count and blockers resolved from `metadata.json → stages.<N>.convergence_loop`
   - Commits via `git log <base>..HEAD --oneline` and `git diff <base>..HEAD --shortstat`
   - Agent invocations from `metadata.json → agent_invocations` (incremented on every Agent tool call)
   - Test delta: count new/modified test files and current pass/fail via the repo's test command

   Report format:

   ```markdown
   # <TICKET-ID> — Performance Report

   ## Timing
   - Started:   <created_at>
   - Completed: <completed_at>
   - Wall clock: <end - start>
   - Active:    <sum of per-stage durations, excludes paused time>

   ## Stage breakdown
   | Stage | Status | Duration | Iterations | Blockers resolved |
   |-------|--------|----------|------------|-------------------|
   | 1 AC Confirm   | ✓ / imported | ... | — | — |
   | 2 Plan         | ... | ... | 2 | 3 |
   | ... |

   ## Code metrics
   - Commits:        <N>
   - Files changed:  <N> (<src> source, <tests> tests, <docs> docs)
   - Lines:          +<added> / -<removed>
   - Tests added:    <N>
   - Tests modified: <N>
   - Test status:    <passing>/<total> passing

   ## Agent invocations
   - <agent-name>:   <count>
   - ...

   ## Convergence stats
   - Loops converged iteration 1: <N>
   - Loops converged iteration 2+: <N>
   - Loops hit max iterations:    <N>
   - Average iterations per loop: <avg>
   ```

6. Update `metadata.json`: `status: "complete"`, `completed_at: <ISO8601>`.
7. Final commit:
   ```bash
   git add -A
   git commit -m "doer(<TICKET-ID>): wrapup"
   ```
8. Narrate: "Ticket <TICKET-ID> complete. {count} commits on branch `<branch-name>`. Performance report at `.doer/tickets/<TICKET-ID>/performance.md`. When you are ready, push and open a PR manually. `/doer` does not push or deploy."

---

## `/doer continue <TICKET-ID>`

1. Read `./.doer/tickets/<TICKET-ID>/metadata.json`.
2. If `status != "paused"` and `status != "in_progress"`, warn the user.
3. Check out the feature branch if not already on it:
   ```bash
   git checkout <branch-name>
   ```
4. Read the last stage's loop state (if any). If mid-loop, resume at the same iteration.
5. Narrate: "Resuming <TICKET-ID> at Stage {N} ({name}){, iteration {i}}. Continue? [Y/n]"
6. Proceed.

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

**Goal:** run stages that exist in the current skill but did NOT exist when the ticket was closed. Useful when the pipeline has been extended (new stages added) and you want to retroactively apply them to previously completed tickets.

**Scope:** only runs stages **missing by name** from the ticket's `metadata.json → stages`. Does NOT re-run stages that existed before but whose internal logic changed (those are out of scope — rerunning them would create an infinite catch-up treadmill).

### Step 1: Load ticket

1. Read `./.doer/tickets/<TICKET-ID>/metadata.json`.
2. If the ticket does not exist → error: "Ticket <TICKET-ID> not found."
3. If `status != "complete"` → error: "Ticket <TICKET-ID> is currently {status}. Use `/doer continue` instead of verify."

### Step 2: Compute missing stages (by name)

1. Extract `executed_stage_names`: all values of `stages.*.name` from the ticket metadata.
2. Extract `current_stage_names`: the stage name list from the skill's default metadata template (the `stages` block under the intake section of this SKILL.md — the authoritative list).
3. `missing = current_stage_names \ executed_stage_names` (set difference, preserving the order they appear in the current skill).
4. If `missing` is empty → narrate "Nothing to verify. Ticket <TICKET-ID> already ran all stages that the current skill defines." → stop.

### Step 3: Present missing stages, ask per stage

Present the list with a one-line description of each missing stage and ask for each:

```
Ticket <TICKET-ID> was closed with {executed_count} stages. Current skill has {current_count}.

Missing stages (not executed at close time):
  - 8 runtime-verify: On-device AC validation via temporary debug logs.
  - 11 security-audit: (example)

Which of these should I run retroactively?
```

Ask per missing stage, one at a time via `AskUserQuestion`: *"Run `<stage-name>` retroactively? [Y/n/skip-all]"*. Record the decision. `skip-all` aborts the remaining questions and proceeds only with what was already approved.

### Step 4: Checkout the ticket branch

Before running any retroactive stage:

```bash
git fetch --all
BRANCH="<metadata.branch>"
# If the branch still exists locally or remotely, check it out.
# If the branch was deleted after merge, check out the final commit SHA stored
# in metadata.commits[last] and warn the user we are operating in detached HEAD.
```

Narrate which state the dev is working against (live branch vs detached HEAD on merged commit).

### Step 5: Run each approved missing stage

For each approved stage, in the order it appears in the current skill:

1. Narrate: *"Running retroactive stage: <name>."*
2. Mark it in metadata BEFORE running so resume works:
   ```json
   "stages": {
     "<N>": {
       "name": "<stage-name>",
       "status": "retroactive_in_progress",
       "added_retroactively": true,
       "started_at": "<ISO8601>"
     }
   }
   ```
3. Execute the stage using the **current** skill's logic (the same sections dev would run in a normal flow). All artifacts, subagent calls, loops, and commits work exactly as in a normal ticket run.
4. On completion, update:
   ```json
   {
     "status": "complete",
     "added_retroactively": true,
     "retroactive_verdict": "<stage-specific outcome, e.g. APPROVED, RETURN_TO_STAGE_4>",
     "completed_at": "<ISO8601>"
   }
   ```
5. **If the stage's verdict is a RETURN_TO_STAGE_N or equivalent "reopen" signal:**
   - Set top-level `status: "in_progress"`.
   - Set `current_stage: N`.
   - Add a blocking condition explaining the retroactive reopen: `{"type": "retroactive-return", "from_stage": "<retroactive-stage-name>", "reason": "<analyzer-recommendation>"}`.
   - Narrate: *"Retroactive stage `<name>` returned `<verdict>`. Ticket reopened at Stage N. Run `/doer continue <TICKET-ID>` to proceed."*
   - Stop. Do NOT run the remaining retroactive stages — the dev needs to fix the earlier issue first.

### Step 6: Finalize (commit-last pattern)

**CRITICAL ordering rule:** the final commit MUST be the last filesystem write of the `/doer verify` run. Do NOT write to `metadata.json` (or anywhere else) after the final commit. If anything needs to be persisted, it happens BEFORE the commit. After the commit: narration only.

If all approved retroactive stages completed without reopening, execute these steps in strict order:

1. **Flush all pending metadata writes.** Consolidate every deferred update that accumulated during Step 5 into a single write:
   - Final `stages.<N>.completed_at` for each retroactive stage (if any stage deferred it)
   - Final `stages.<N>.status = "complete"` and `retroactive_verdict` per stage
   - Accumulated `agent_invocations` counters from Step 5
   - The new `verify_runs` entry:
     ```json
     "verify_runs": [
       {
         "verified_at": "<ISO8601 — compute ONCE, use this same value below>",
         "stages_added_retroactively": ["runtime-verify", "..."],
         "all_verdicts_approved": true
       }
     ]
     ```
     Keep `verify_runs` as an array so multiple runs accumulate (append, do not overwrite).

2. **Verify the working tree has changes** (defensive check):
   ```bash
   if git diff --quiet && git diff --cached --quiet; then
     echo "No changes to commit — retroactive stages produced no persisted state."
   fi
   ```

3. **Single atomic commit** containing everything from Step 1:
   ```bash
   git add -A
   git commit -m "doer(<TICKET-ID>): retroactive verify — <comma-separated stage names>"
   ```

4. **Verify nothing was left uncommitted** (defensive check for the bug this pattern prevents):
   ```bash
   if ! git diff --quiet || ! git diff --cached --quiet; then
     echo "WARNING: Uncommitted changes remain after verify finalization. This should never happen."
     git status --short
   fi
   ```
   If the warning fires, something wrote to disk after Step 3. Investigate.

5. **Narrate only — no more writes.** *"Verify complete. <N> stages added retroactively, all approved. Ticket <TICKET-ID> is up to date with the current skill."*

**What the orchestrator MUST NOT do after Step 3:**
- Do NOT update `current_stage` (the ticket is complete, stays complete)
- Do NOT update performance tracking (`agent_invocations`, timing — those belong to the verify run itself, flush them in Step 1)
- Do NOT write a final timestamp like `metadata.last_modified` (if you want such a field, write it in Step 1)
- Do NOT emit lessons or anything else that writes to disk. Verify is not a ticket-creation path, it should not touch knowledge/ files.

### Edge cases

- **Stage exists in metadata but with different name than current skill:** treat as not-missing (names match is the contract). If the dev genuinely renamed a stage and wants it re-run, they do that manually.
- **Ticket has stages the current skill does not:** that's fine, they stay. Verify is additive only.
- **Dev aborts mid-verify:** whatever was persisted stays. Next `/doer verify` recomputes missing stages and picks up where it left off.

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

## Locale override

The default locale for all user-facing prose is **English**. Three ways to override:

1. **Per-ticket flag:** invoke the skill with `--es` suffix (e.g. `/doer ABC-123 --es`).
2. **Inline directive:** write `locale: es` at any point during the conversation.
3. **Local preferences file:** if a file named `preferences.md` exists in the same directory as this SKILL.md, read it at the start of every `/doer` invocation (BEFORE asking any questions, BEFORE narrating). If it contains a line like `locale: <code>` (e.g. `locale: es`), treat that as the default locale for this installation. Per-ticket flags still override this.

When locale is not English, the orchestrator and every subagent it spawns MUST produce all user-facing narration, questions, confirmations, summaries, reports, and artifact prose in that language. File names, git commit messages, commands, JSON keys, code, and technical identifiers stay in English. Persist `"locale": "<code>"` in `metadata.json` so the preference survives pause/resume. When spawning any subagent, append to its prompt: "Produce all user-facing prose in <language>. Keep code, commands, file names, and JSON keys in English."

---

*Maintained by hand. Copy `SKILL.md` to `~/.claude/skills/doer/` on any machine to use.*
