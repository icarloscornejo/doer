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
version: 2.2.0
user-invocable: true
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, AskUserQuestion, Agent]
---

# Doer — Ticket Execution Orchestrator

User-facing orchestrator for executing a single ticket end-to-end on a feature branch. Runs 9 sequential stages with doer/reviewer convergence loops. Narrates every action so the user can pause at any point. State persists on disk so work can be resumed across sessions.

**Scope:** one ticket, one branch, end-to-end implementation up to (but not including) PR and deploy.

**Out of scope:** PRD creation, architecture design, ticket creation, pull request assembly, CI, deployment. By design.

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
   - Stages whose only output is `.doer/` (1 AC, 2 Plan, 9 Wrapup) SKIP the commit entirely. Stages with real code (3 Tests, 4 Code, 5 Review, 7 Runtime, 8 Docs) commit code only.
   - Stage 7 (Runtime Verify) temp commit + revert still works because it touches real source files, not `.doer/`.

---

## Versioning & Migrations

The SKILL frontmatter declares the current version (SemVer: MAJOR.MINOR.PATCH).

| Bump | When | Migration block? |
|------|------|------------------|
| **MAJOR** | Structural change (renames/removes stages, changes metadata shape, removes/renames artifact files) | REQUIRED |
| **MINOR** | Adds capability OR changes the format of persistent files (plan.md, changelog.md, ac.md, etc.) | REQUIRED if any persistent file format changed; optional otherwise |
| **PATCH** | Bug fix to orchestrator behavior, doc edit, no file format change | None |

**Rule of thumb:** if a bump changes how an existing artifact file is shaped, **register a migration block**. Tickets in flight should never be stuck reading verbose old formats just because they were created before the optimization. Token-cost reductions are real wins; auto-applying them keeps every ticket on the latest cheapest format.

Each ticket persists `skill_version` in `metadata.json` at intake. On every entry point (`continue`, `verify`, any stage execution), the orchestrator runs the **Migration Check** below.

### Migration Check (auto, silent)

Runs as part of the Workspace Guard sequence (right after the exclude check, before any stage logic). Behavior:

1. Read `metadata.skill_version` (default `"1.0.0"` if missing — pre-versioning era).
2. Read current SKILL frontmatter `version`.
3. If equal → no-op.
4. If ticket version < current version → walk every migration block below in chronological order. For each block whose `from` matches the ticket's current version: apply it, then bump `metadata.skill_version` to the block's `to`. Continue until the ticket's version equals the current SKILL version.
5. If the ticket version is behind the SKILL but no migration block matches the gap (e.g. a PATCH bump): silently bump `metadata.skill_version` to current. No file changes.
6. **Always auto-apply silently.** Do NOT ask the user. Narrate ONE summary line at the end IF any migration block actually executed: *"Migrated ticket X.Y.Z → A.B.C: N file changes."* If only a silent version-bump happened (case 5), narrate nothing.

### Migration: From 1.x → 2.0.0

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

# 5. Orphaned files — leave on disk as historical (do NOT delete):
#    reflect.md, runtime-logs-added.md, runtime-log-output.txt, performance.md
#    The new pipeline doesn't reference them; they're inert.

# 6. Set metadata.skill_version = "2.0.0"
```

**Repository-level cleanup** (orchestrator does this once per repo if needed):
- Lessons in `.doer/knowledge/lessons/` already migrated by Workspace Guard step 5 (existing rule).

### Migration: From 2.0.0 → 2.1.0

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
  #    information from the original — only the shape changes.
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

MINOR bump that changes orchestrator BEHAVIOR only — no file changes:
- An entire loop iteration (doer + reviewer + AUTO_FIX) now runs in a single turn. Previously each Agent call was its own turn. Fixes broken auto-resume in VS Code/IDE plugins.
- `/doer pause` removed. State persists after every Agent return; abandoning the session = pausing.

**Per-ticket changes:** none. Just bump `metadata.skill_version` to "2.2.0". The orchestrator's NEW behavior takes effect on the next iteration.

```bash
# 1. Set metadata.skill_version = "2.2.0"
# That's it. No file rewrites, no structural changes.
```

The `metadata.status` field continues to use `"in_progress"` and `"complete"`. The `"paused"` value, if present from old tickets, is treated as equivalent to `"in_progress"` (resume-able). New tickets never write `"paused"`.

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

**There is no `/doer pause`.** State persists automatically after every Agent return. To stop, just close the session or write `stop` / `wait` / `para`. To resume, `/doer continue <TICKET-ID>` from any future session.

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
        ├── metadata.json           # workflow state + raw intake (title, description, type, raw_acs, raw_context)
        ├── ac.md                   # confirmed ACs (Stage 1)
        ├── plan.md                 # implementation plan (Stage 2)
        ├── changelog.md            # doer's "what + why" log, accumulated across stages
        ├── wrapup.md               # lessons summary + performance report (Stage 9, final stage)
        └── review/
            ├── plan-review.md      # ONE file per stage, sections per iteration
            ├── tests-review.md
            └── code-review.md
```

**Per ticket: 6 fixed files + 3 review files (only when those stages have loops).** Reflect, runtime-logs-added, runtime-log-output, performance, ticket are all gone (rolled into other artifacts or dropped as low-value).

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

3. **No `ticket.md` file** — the raw intake lives directly inside `metadata.json` as a `raw` block (see step 4). One less file, no duplication.

4. Initialize `metadata.json` (raw intake is embedded — no separate `ticket.md`):

   ```json
   {
     "ticket_id": "<TICKET-ID>",
     "title": "<title>",
     "type": "<type>",
     "branch": "<branch-name>",
     "status": "in_progress",
     "current_stage": 1,
     "skill_version": "<read from frontmatter at intake time, e.g. 2.0.0>",
     "created_at": "<ISO8601>",
     "raw": {
       "description": "<full description from intake>",
       "raw_acs": "<pasted ACs or 'derive'>",
       "context": "<extra context or 'none'>"
     },
     "stages": {
       "1": {"name": "ac-confirm",     "status": "pending"},
       "2": {"name": "plan",           "status": "pending", "loop": true},
       "3": {"name": "tests",          "status": "pending", "loop": true},
       "4": {"name": "code",           "status": "pending", "loop": true},
       "5": {"name": "code-review",    "status": "pending", "loop": true},
       "6": {"name": "quality-gate",   "status": "pending"},
       "7": {"name": "runtime-verify", "status": "pending"},
       "8": {"name": "docs-sync",      "status": "pending"},
       "9": {"name": "wrapup",         "status": "pending"}
     },
     "blocking_conditions": [],
     "commits": []
   }
   ```

   **Pipeline is now 9 stages** (Stage 5 Reflect was removed — its self-review value was marginal vs the formal Stage 5 Code Review). All stages renumbered accordingly.

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
           # Conflict — ask user once per file: overwrite | keep both (rename) | skip
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

6. **Migration Check.** If a ticket is active, run the **Migration Check** (see Versioning & Migrations). Auto-applies any pending migration silently. Idempotent — once at current version, no-op.

7. **Mark satisfied:** if a ticket is active, write `metadata.workspace_guard = "ok"`. (No-op if no active ticket — next ticket-scoped invocation sets it.)

For deep cleanup of historical `.doer/` content from earlier commits on the feature branch, use `/doer cleanup-history <TICKET-ID>` — out of scope for the Guard.

---

## Narration Protocol

**Per-stage narration:**
- Before: `"Starting Stage {N} — {name}. {one-sentence goal}."` + write `stages.<N>.started_at`.
- After: write `stages.<N>.completed_at` + `"Stage {N} complete. Committed as {sha}. Continuing to Stage {N+1}..."` then END TURN.
- Inside loop: `"Iteration {i}/{max}: invoking {agent}... agent returned {status}, {findings} findings ({blockers} blockers)."`

### Turn boundaries — granularity is the WHOLE iteration

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
| Between iteration N and N+1 | **NO — END TURN** |
| Between stages | **NO — END TURN** |
| Between subagent and a major file write that informs the next subagent | YES |

**MUST rules:**

1. End the turn at every stage boundary. Narrate "Stage N complete. Continuing to Stage N+1..." then STOP.
2. End the turn between iterations of the same loop. Narrate iteration result, then STOP.
3. **Never bundle multiple stages or multiple loop iterations in one turn.** One stage = one or more turns. One iteration = one turn. Never collapse iterations.
4. **If an Agent call inside an iteration returns an error**, end the turn before invoking anything else. Surface the error to the user; do not silently retry the next subagent.

**Self-check before every response:** *"Am I about to start a new iteration or a new stage?"* If yes — STOP, narrate where you ended, do not start the new unit.

### SUGGESTIONs never pause

Zero BLOCKERs = converged. SUGGESTIONs are appended to the stage's single review file (e.g. `review/plan-review.md`) under the iteration's section. Orchestrator narrates `"Converged with N SUGGESTIONs logged. Continuing."` then auto-proceeds (next stage, in a new turn).

### Interrupt detection — and the auto-resume rule

At any turn boundary, the user's next message is interpreted as:

| User message contains... | Interpretation |
|--------------------------|----------------|
| `stop`, `wait`, `hold on`, `para`, or a clear halt signal | **HALT** — narrate "Stopping. Run `/doer continue <TICKET-ID>` to resume." Stop. State already persisted in metadata. |
| **Anything else** (including empty, `ok`, `sí`, `dale`, `continue`, `y`, an unrelated comment, a question about the work) | **RESUME** — read `metadata.json`, do the next pending action without further prompting |

**MUST NOT** ask the user "continuar?" / "Continue? [Y/n]" between iterations or stages. Continuation is implicit.

**MUST NOT** require the user to type `/doer continue <TICKET-ID>` to advance work in flight. `/doer continue` is for resuming **across sessions**, not for nudging the next step. Within a session, any non-halt message advances.

**State persistence:** all progress (current iteration, BLOCKERs found, files written, etc.) is persisted to `metadata.json` after every Agent return. Closing the session at any point preserves state — the next `/doer continue <TICKET-ID>` resumes intact. There is no separate "pause" command needed; abandoning the session = pausing.

**To stop mid-Agent (the Agent is already running):** terminal users can use `Ctrl+C` in the parent shell or `Esc` if their client supports it. The orchestrator cannot be interrupted mid-Agent from inside.

### Performance counters (consumed by Stage 9 wrapup)

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

### Review file (ONE per stage, sections per iteration)

Each stage with a loop has **a single review file** at `review/{stage}-review.md` (e.g. `review/plan-review.md`, `review/tests-review.md`, `review/code-review.md`). NEVER create per-iteration files like `plan-review-1.md`. The single file accumulates iteration sections:

```markdown
# {Stage} Review — <TICKET-ID>

## Iteration 1
- BLOCKERs: <list with IDs>
- AUTO_FIXes applied: <list>
- SUGGESTIONs: <list>
- Verdict: needs_revision

## Iteration 2
- Prior BLOCKERs resolved: <ids>
- Prior BLOCKERs still open: <ids>
- New BLOCKERs: <list>
- AUTO_FIXes applied: <list>
- SUGGESTIONs: <list>
- Verdict: converged
```

Append on each iteration. The reviewer reads only the most recent iteration's section + the prior BLOCKERs (passed in the prompt). Old SUGGESTIONs stay logged for the user but are NOT re-analyzed.

### Changelog file (compact, append-only)

Each ticket has a single `changelog.md`. Every doer + AUTO_FIX pass APPENDs a section. NEVER rewrite or compress prior sections. Format MANDATORY:

```markdown
## Iteration N — <stage> (<initial | fixes>)
- Decision/Output: <one line, terse>
- Decision/Output: <one line>
- Fix #<blocker-id>: <what changed + why> (only on iter 2+)
- AutoFix #<id>: <mechanical change> (when AUTO_FIXes applied)
```

Bullets only. No prose paragraphs. The reviewer reads this to understand what the doer just did — terse means cheap to read AND cheap to write.

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

1. Read `metadata.json` — `title`, `type`, `raw.description`, `raw.raw_acs`, `raw.context` come from the intake.
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
| Plan + tests + complete code | 5 (code-review) | 2, 3, 4 |

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
- ./.doer/tickets/<TICKET-ID>/metadata.json (raw.* for intake context)
- ./.doer/tickets/<TICKET-ID>/ac.md
- <doer-skill-dir>/lessons/*.md (global — apply those whose scope matches)
- ./.doer/knowledge/assumptions/<TICKET-ID>.md

Explore the codebase to understand structure relevant to this ticket.

Produce ./.doer/tickets/<TICKET-ID>/plan.md using the COMPACT format below.
Use bullets and tables. No prose paragraphs. Be terse — the plan will be
read multiple times by other agents (token cost matters).

```markdown
# <TICKET-ID> Plan

## Files
| Path | Change | Reason |
|------|--------|--------|
| ... | new/edit/delete | one-line why |

## Steps
1. <verb> <thing> — `<file>:<line-range>`
2. ...

## Tests
- <test name> covers <AC-N>
- ...

## Risks
- <risk> → <mitigation>

## Assumptions
- <new assumption> (also append to assumptions/<TICKET-ID>.md)
```

Also append to changelog.md (compact format — one section per iteration):

```markdown
## Iteration 1 — Plan (initial)
- Decision: <X> because <Y>
- Decision: ...
```

Do NOT write code. Do NOT run tests. Plan only.
```

### Plan reviewer prompt (skeleton)

```
Read plan.md, ac.md, changelog.md, and metadata.json (raw.* for original intake).

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
Read ac.md, plan.md (and metadata.json `raw.*` for context).

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
Read ac.md, plan.md, and the tests added in Stage 3 (metadata.json `raw.*` if needed).

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

## Stage 5 — Code Review (Doer/Reviewer Loop, External Review)

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

## Stage 6 — Quality Gate (Validation, Not Loop)

**Goal:** fast sanity check. No agents. Just run tests.

1. Run the full test suite (detect the command from the repo — `npm test`, `pytest`, `go test ./...`, etc. If unclear, ask user).
2. If any test fails:
   - Narrate the failures.
   - Ask: "Tests failing: {list}. Options: 1) Return to Stage 4 to fix, 2) Return to Stage 6 to re-review, 3) Pause for manual fix. Which?"
3. If all tests pass, write the log to `.doer/tickets/<TICKET-ID>/test-log.txt` for the dev's reference (lives on disk only — gitignored, no commit).
4. Narrate "Quality gate passed: <N>/<N> tests green. Continuing." and proceed.

---

## Stage 7 — Runtime Verify (Live Debug Logs, Temporary)

**Goal:** verify on-device behavior against ACs via dense temporary debug logs. Logs NEVER reach the final branch.

**Skip:** ask once: *"Does this ticket produce runtime behavior worth exercising on device? [Y/n]"*. If `n`, mark `stages.7.status = "skipped"` and proceed to Stage 8.

**Log format (exact):** `println("DOER - <TICKET-ID> - <ClassName.fnName> - <msg or key=value>")`. The prefix is unique to this ticket — nothing else in the codebase matches.

### Step 1: Inject logs

Invoke a general-purpose agent:

```
You are the runtime-logger agent for ticket <TICKET-ID>.

Read: .doer/tickets/<TICKET-ID>/ac.md, plan.md, and `git diff <base>..HEAD`.

Scope: every file in the diff PLUS every file in the call path the ACs
exercise (deps, helpers, repositories, view models). Follow imports
outward from the diff. Stop at framework/SDK boundaries.

Log: function entry (args), conditional branches (which + why), state
changes, external boundaries (API/DB/IO/threads/coroutines), exception
catches, function exit (return or void).

Format MANDATORY: println("DOER - <TICKET-ID> - <ClassName.fnName> - <msg>")

Rules: use println (not app logger), never modify business logic, never
touch existing logs, run the build after to verify syntax.

Return a JSON list of files touched + one-line reason each. Do NOT
write a summary file — the orchestrator narrates it inline.
```

### Step 2: Temporary commit

```bash
git add -A
git commit --no-verify -m "doer(<TICKET-ID>): [TEMP] runtime debug logs — DO NOT MERGE"
```

Commit is identified later by its unique message prefix.

### Step 3: Hand off to dev

Narrate the file list inline + build/filter commands:
```
Runtime logs injected across N files: <list>.
Build & run: <build command — detect or ask once, persist as metadata.runtime_build_command>
Exercise each AC, filter with: <e.g. adb logcat | grep "DOER - <TICKET-ID>">
Paste filtered output here when ready.
```

### Step 4: Analyze logs

When the dev pastes the log output, pass it **directly in the prompt** to the analyzer (no intermediate `runtime-log-output.txt` — the logs may be huge, no point persisting them):

```
You are the runtime-log analyzer for ticket <TICKET-ID>.

Read: ac.md, plan.md.

Log excerpt from the dev's session:
<<<
{paste the user's log output here verbatim}
>>>

For each AC: was the code path hit? Did values match expected? Any
unexpected errors? Any branch that should have been exercised but wasn't?

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

if git grep -l "DOER - <TICKET-ID>" -- .; then
  echo "ERROR: Residual DOER logs found"; exit 1
fi
```

If residuals: re-invoke logger with *"Remove every line matching `DOER - <TICKET-ID>`. Touch nothing else."*

### Step 6: Record outcome

Persist to `metadata.json → stages.7`:
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
   git commit --no-verify -m "doer(<TICKET-ID>): sync documentation"
   ```

---

## Stage 9 — Wrapup (Lessons + Assumptions + Performance)

**Goal:** capture lessons, validate assumptions, write a single `wrapup.md` (lessons + assumptions + performance, no separate file), clean `.doer/` from branch history.

1. **Validate assumptions.** Read `.doer/knowledge/assumptions/<TICKET-ID>.md`. Mark each VALIDATED, INVALIDATED (reason), or UNVERIFIED.

2. **Capture lessons.** Ask: *"Any lesson worth saving for future tickets? Reply with one or more, or `none`."* For each, write to the GLOBAL pool at `<doer-skill-dir>/lessons/{slug}.md` (NOT under `.doer/`). Format:
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

3. **Write `wrapup.md`** — single consolidated file with everything. Pull data from `metadata.json` (stage timestamps, agent_invocations, convergence_loop), `git log/diff` (commits/LOC), and the repo test command (pass/fail):
   ```markdown
   # <TICKET-ID> — Wrapup

   ## Assumptions
   - <item> → VALIDATED | INVALIDATED: <reason> | UNVERIFIED

   ## Lessons captured
   - [<slug>] — <one-line takeaway>

   ## Commits
   <SHA list>

   ## Performance
   - Timing: started <X>, completed <Y>, wall clock <Z>, active <W> (excludes paused)
   - Stages: | N | name | status | duration | iterations | BLOCKERs resolved |
   - Code: <commits> commits, <files> files (<src> src / <tests> tests / <docs> docs), +<add>/-<rem> LOC, <X/Y> tests passing
   - Agents: <agent>: <count>, ...
   - Convergence: iter1 <a>, iter2+ <b>, max-iter <c>, avg <d>
   ```

4. **Update `metadata.json`:** `status: "complete"`, `completed_at: <ISO8601>`.

5. **PR-ready history cleanup** — remove `.doer/` from prior commits on the feature branch:
   ```bash
   DIRTY=$(git log --format=%H --diff-filter=ACMR -- '.doer/*' "<base>..HEAD" 2>/dev/null)
   ```
   If empty → skip to step 6. Otherwise confirm with user (destructive, changes SHAs). On approval:
   ```bash
   git update-ref "refs/doer-backup/<TICKET-ID>-pre-cleanup-$(date +%s)" HEAD
   git filter-branch -f --index-filter 'git rm -r --cached --ignore-unmatch .doer/' --prune-empty "<base>..HEAD"
   git update-ref -d refs/original/refs/heads/<branch-name> 2>/dev/null || true
   ```
   Verify `git log --diff-filter=ACMR -- '.doer/*' "<base>..HEAD"` is empty. Tell user the backup ref (rollback: `git reset --hard <ref>`). On decline: narrate *"Skipping history cleanup. Run /doer cleanup-history later."*

6. **Final commit** (only if uncommitted real changes — wrapup itself has none since it only writes to `.doer/`):
   ```bash
   if ! git diff --quiet || ! git diff --cached --quiet; then
     git add -A
     git commit --no-verify -m "doer(<TICKET-ID>): wrapup"
   fi
   ```

7. Narrate: *"Ticket <TICKET-ID> complete. {N} commits on `<branch>` (post-cleanup). Wrapup: .doer/tickets/<TICKET-ID>/wrapup.md. Run your pre-commit checks, then push and open the PR manually."*

---

## `/doer continue <TICKET-ID>`

1. Read `./.doer/tickets/<TICKET-ID>/metadata.json`.
2. If `status == "complete"`, warn the user (use `/doer verify` for closed tickets, not `continue`).
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
ABC-110   [in_progress]  Stage 2 (plan)         refactor-auth  (last touched 3d ago)
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
- **User says `stop` / `wait` / `para`:** state is already persisted after each Agent return. Narrate the current position and stop. Resume via `/doer continue <TICKET-ID>` later.

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
