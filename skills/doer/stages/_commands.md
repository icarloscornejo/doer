# Doer Commands

Auxiliary commands beyond the main `/doer <TICKET-ID>` entry point.

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

No mutation. Read-only.

---

## `/doer list`

List every directory under `./.doer/tickets/`, one line each:

```
ABC-123   [in_progress]  Stage 4 (code)         fix-login-timeout
ABC-119   [complete]                            add-redis-cache
ABC-110   [in_progress]  Stage 2 (plan)         refactor-auth  (last touched 3d ago)
```

Read-only.

---

## `/doer locale <code>`

Sets the global operating locale for this Claude Code config. The orchestrator runs:

```bash
"${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh" set-locale "<code>"
```

The helper writes `.locale = "<code>"` into `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json` (creating the file and parent directory if missing). After persisting, the orchestrator narrates a confirmation IN the new locale (e.g. *"Locale set to es. All chat from now on in Spanish."* or *"Locale fijado a es. Toda la conversación de aquí en adelante en español."*).

This setting is global to the Claude Code config (claude-tm vs claude-sephora vs claude-personal each have their own `$CLAUDE_CONFIG_DIR` and therefore their own preferences file). It survives plugin uninstall, install, and version upgrades. It is NOT per-ticket; switching locale affects the next chat output across all tickets.

The command is valid at any time, with or without an active ticket. There is no `--global` flag because the global file is the only locale source.

---

## `/doer verify <TICKET-ID>`

**Two purposes:**

1. **Missing-stage verify (original):** run stages that exist in the current SKILL but did NOT exist in `metadata.stages` when the ticket closed. Additive.
2. **Forced reverify (escape hatch):** force the spot-check pass on stages whose `verified_with` is current but the dev wants to re-validate anyway. Useful for debug or when the dev suspects something despite version match.

The auto-reverify path inside the Migration Check (Phase 2) already handles 99% of cases automatically. This command is only needed when:
- A ticket is `complete` and the dev declined the auto-reverify prompt earlier but now wants it.
- The dev wants to force a fresh spot-check even though the SKILL version matches.

### Step 1: Load + Guard

1. Read `metadata.json`. Error if not found.
2. Error if `status != "complete"` (use `/doer <TICKET-ID>` instead to resume).
3. **Workspace Guard. RUN INLINE, do NOT just reference it.** These exact bash commands MUST execute before step 2. Same block as the resume flow:

   ```bash
   GUARD_OK=$(jq -r '.workspace_guard // empty' .doer/tickets/<TICKET-ID>/metadata.json 2>/dev/null)
   EXCLUDE_HAS_DOER=$(grep -qxF '.doer/' .git/info/exclude 2>/dev/null && echo yes || echo no)
   if [ "$GUARD_OK" = "ok" ] && [ "$EXCLUDE_HAS_DOER" = "yes" ]; then
     echo "Workspace Guard: already satisfied (skipping)."
   else
     mkdir -p .git/info
     [ -f .git/info/exclude ] || touch .git/info/exclude
     grep -qxF '.doer/' .git/info/exclude || echo '.doer/' >> .git/info/exclude

     mkdir -p .doer && touch .doer/.guard-test
     STATUS=$(git status --porcelain .doer/.guard-test 2>/dev/null)
     rm -f .doer/.guard-test
     if [ -n "$STATUS" ]; then
       echo "ERROR: .doer/ exclude rule did not take effect. Investigate before proceeding."
       exit 1
     fi

     TRACKED=$(git ls-files .doer/ 2>/dev/null | head -1)
     # If TRACKED non-empty, surface the 3-option prompt (see lib/workspace-guard.md, default option 3).

     # Migration Check (see lib/migrations.md), then mark workspace_guard = "ok".
     echo "Workspace Guard: applied."
   fi
   ```

   Self-check: `.git/info/exclude` contains `.doer/` AND `metadata.workspace_guard == "ok"`. STOP if either fails.

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
3. Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/0<N>-<name>.md` and execute the stage's logic (same subagent calls, loops, commits as a normal run).
4. On completion, update metadata: `status: "complete"`, `added_retroactively: true`, `retroactive_verdict: <APPROVED | RETURN_TO_STAGE_N | ...>`, `completed_at`.
5. **If verdict is RETURN_TO_STAGE_N (reopen signal):**
   - Set top-level `status: "in_progress"`, `current_stage: N`.
   - Add blocking condition: `{"type": "retroactive-return", "from_stage": "<name>", "reason": "..."}`.
   - Narrate: *"Retroactive `<name>` returned <verdict>. Ticket reopened at Stage N. Run `/doer <TICKET-ID>` to proceed."*
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

No commit needed (`metadata.json` is in `.doer/`, gitignored). Per-stage commits during Step 5 already captured any real code changes.

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

3. **Workspace Guard. RUN INLINE, do NOT just reference it.** These exact bash commands MUST execute before step 4:

   ```bash
   GUARD_OK=$(jq -r '.workspace_guard // empty' .doer/tickets/<TICKET-ID>/metadata.json 2>/dev/null)
   EXCLUDE_HAS_DOER=$(grep -qxF '.doer/' .git/info/exclude 2>/dev/null && echo yes || echo no)
   if [ "$GUARD_OK" = "ok" ] && [ "$EXCLUDE_HAS_DOER" = "yes" ]; then
     echo "Workspace Guard: already satisfied (skipping)."
   else
     mkdir -p .git/info
     [ -f .git/info/exclude ] || touch .git/info/exclude
     grep -qxF '.doer/' .git/info/exclude || echo '.doer/' >> .git/info/exclude

     mkdir -p .doer && touch .doer/.guard-test
     STATUS=$(git status --porcelain .doer/.guard-test 2>/dev/null)
     rm -f .doer/.guard-test
     if [ -n "$STATUS" ]; then
       echo "ERROR: .doer/ exclude rule did not take effect. Investigate before proceeding."
       exit 1
     fi

     TRACKED=$(git ls-files .doer/ 2>/dev/null | head -1)
     # If TRACKED non-empty, surface the 3-option prompt (see lib/workspace-guard.md, default option 3).

     echo "Workspace Guard: applied."
   fi
   ```

4. Run the same logic as Stage 9 step 5 (PR-ready history cleanup):
   ```bash
   DIRTY=$(git log --format=%H --diff-filter=ACMR -- '.doer/*' "<base>..HEAD" 2>/dev/null)
   ```
   If empty → narrate *"Nothing to clean, branch already free of .doer/ content."* and exit.

   Otherwise, confirm with the user (this command is invoked manually so the dev should explicitly approve), then:
   ```bash
   git update-ref "refs/doer-backup/<TICKET-ID>-pre-cleanup-$(date +%s)" HEAD
   git filter-branch -f --index-filter 'git rm -r --cached --ignore-unmatch .doer/' --prune-empty "<base>..HEAD"
   git update-ref -d refs/original/refs/heads/<branch-name> 2>/dev/null || true
   ```
   Verify `git log --diff-filter=ACMR -- '.doer/*' "<base>..HEAD"` is empty. Tell the user the backup ref name (rollback: `git reset --hard <ref>`).

5. Narrate the result. Do NOT commit anything new. This command is purely a history rewrite.

### Safety

- Always creates a backup ref under `refs/doer-backup/<TICKET-ID>-pre-cleanup-<timestamp>` before rewriting. Tell the user the ref name; they can `git reset --hard <ref>` to roll back.
- Refuses to run if the branch has been pushed AND has commits other people may have based work on. Detect via `git rev-list --count HEAD@{u}..HEAD` and `git rev-list --count HEAD..HEAD@{u}` if upstream is set; warn if the upstream tracking suggests rewrite would be disruptive.
