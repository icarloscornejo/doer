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
| `/doer pause` | Persist current state and stop. |

**Stages cannot be skipped manually.** Every stage must run. The only way to skip stages is through Stage 1's pre-existing-work detection (see Stage 1 below). This is by design: the orchestrator decides which stages to skip, not the user.

**Implicit activation:** If the user writes natural language (e.g. "sigue", "continúa", "pausa aquí", "el plan se ve bien") and an active ticket exists in `./.doer/tickets/*/metadata.json` with `status == "in_progress"`, treat the message as a directive to the active orchestrator rather than a new query.

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
        ├── wrapup.md               # Captured lessons (Stage 9 output)
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
       "1": {"name": "ac-confirm",    "status": "pending"},
       "2": {"name": "plan",          "status": "pending", "loop": true},
       "3": {"name": "tests",         "status": "pending", "loop": true},
       "4": {"name": "code",          "status": "pending", "loop": true},
       "5": {"name": "reflect",       "status": "pending"},
       "6": {"name": "code-review",   "status": "pending", "loop": true},
       "7": {"name": "quality-gate",  "status": "pending"},
       "8": {"name": "docs-sync",     "status": "pending"},
       "9": {"name": "wrapup",        "status": "pending"}
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

Before each stage, narrate: "Starting Stage {N} — {name}. {one-sentence goal}."

Inside a doer/reviewer loop, narrate: "Iteration {i} of {max}: invoking {agent}... [wait] agent returned {status}, {total_findings} findings ({blockers} blockers)."

After each stage, narrate: "Stage {N} complete. Committed as `{sha}`. Continue to Stage {N+1}? [Y/n]"

If the user writes "pause", "stop", "para", "espera" at any point:
1. Persist current state to `metadata.json` (set `status: "paused"`).
2. Reply: "Paused at Stage {N} (iteration {i} if applicable). Resume with `/doer continue <TICKET-ID>`."
3. Stop.

---

## Doer/Reviewer Loop Pattern (Delta-Aware)

Stages 2, 3, 4, and 6 use this pattern. Max iterations: **5**.

### Findings severity

Reviewer returns findings in three buckets:

- **BLOCKER** — must be fixed before advancing. Loop continues.
- **SUGGESTION** — optional improvement. Shown to user, does not block.
- **INFO** — observational, no action needed.

Convergence = zero BLOCKERs remaining.

### Iteration 1 (clean-slate)

1. Invoke doer with the stage input.
2. Doer writes its artifact AND a `changelog.md` describing what it produced and why.
3. Invoke reviewer with the artifact. Reviewer produces findings categorized BLOCKER/SUGGESTION/INFO.
4. If zero BLOCKERs → converged. Exit loop. If SUGGESTIONs exist, present them to the user: "Optional improvements: {list}. Apply any? [numbers / n]".
5. If BLOCKERs > 0 → proceed to Iteration 2.

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
   - Instruction: "For each prior BLOCKER, mark it RESOLVED or STILL_OPEN. Scan areas the doer touched (per changelog) for new issues. Do NOT re-analyze untouched areas."
4. Reviewer output:
   ```json
   {
     "prior_blockers_resolved": ["id-1", "id-3"],
     "prior_blockers_still_open": ["id-2"],
     "new_blockers": [...],
     "suggestions": [...]
   }
   ```
5. Remaining BLOCKERs = still_open + new. If zero → converged. Otherwise → next iteration.

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
   - Run `git status --porcelain` → detect uncommitted changes
   - Run `git log --oneline <base-branch>..HEAD` → detect commits ahead of base
   - Run `git branch --show-current` → confirm which branch the user is on

   Present what was detected: "I see you are on branch `X` with Y uncommitted files and Z commits ahead of main. Is this the work you meant? [Y/n/explain]"

4. **Decide the entry point.** Based on what the user has:

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

Output findings as BLOCKER / SUGGESTION / INFO.
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

Output findings as BLOCKER / SUGGESTION / INFO.
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

Output findings as BLOCKER / SUGGESTION / INFO.
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

## Stage 8 — Docs Sync

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

## Stage 9 — Wrapup (Lessons & Assumptions)

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

5. Update `metadata.json`: `status: "complete"`, `completed_at: <ISO8601>`.
6. Final commit:
   ```bash
   git add -A
   git commit -m "doer(<TICKET-ID>): wrapup"
   ```
7. Narrate: "Ticket <TICKET-ID> complete. {count} commits on branch `<branch-name>`. When you are ready, push and open a PR manually. `/doer` does not push or deploy."

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

*Maintained by hand. Copy `SKILL.md` to `~/.claude/skills/doer/` on any machine to use.*
