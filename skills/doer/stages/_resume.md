# Resume Flow

Entered when `/doer <TICKET-ID>` finds existing `./.doer/tickets/<TICKET-ID>/metadata.json`. The dev did NOT have to type a separate "continue" command, the orchestrator detected the existing ticket and switched modes automatically.

## Steps

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

7. **Append current session ID to `metadata.session_ids`.** Best-effort; do not block resume on failure.
   ```bash
   SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
   SOURCE="env:CLAUDE_CODE_SESSION_ID"
   if [ -z "$SESSION_ID" ]; then
     PROJ_SLUG="$(pwd | sed 's|/|-|g')"
     CLAUDE_CFG="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
     LATEST_JSONL="$(ls -t "${CLAUDE_CFG}/projects/${PROJ_SLUG}"/*.jsonl 2>/dev/null | grep -v 'agent-acompact' | head -1 || true)"
     if [ -n "$LATEST_JSONL" ]; then
       SESSION_ID="$(grep -o '"sessionId":"[^"]*"' "$LATEST_JSONL" 2>/dev/null | head -1 | sed 's|"sessionId":"||;s|"||g' || true)"
     fi
     SOURCE="jsonl_fallback"
   fi
   if [ -n "$SESSION_ID" ]; then
     # Append only if not already present in the array.
     ALREADY=$(jq -r --arg s "$SESSION_ID" '.session_ids // [] | map(select(. == $s)) | length' \
       ".doer/tickets/<TICKET-ID>/metadata.json" 2>/dev/null || echo 0)
     if [ "$ALREADY" = "0" ]; then
       jq --arg s "$SESSION_ID" '.session_ids = ((.session_ids // []) + [$s])' \
         ".doer/tickets/<TICKET-ID>/metadata.json" \
         > ".doer/tickets/<TICKET-ID>/metadata.json.tmp" \
         && mv ".doer/tickets/<TICKET-ID>/metadata.json.tmp" ".doer/tickets/<TICKET-ID>/metadata.json"
     fi
   fi
   ```

8. Narrate: *"Resuming <TICKET-ID> at Stage {N} ({name}){, iteration {i}}{, status: {status}}."* Then proceed (the user invoked `/doer <TICKET-ID>` on an existing ticket, so resume is the implicit intent, do NOT ask for further confirmation).

9. Proceed: Read the file at `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/0<N>-<name>.md` for the current stage and ONLY that file.
