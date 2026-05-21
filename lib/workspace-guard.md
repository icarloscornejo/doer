# Workspace Guard

Status: protocol shared by all skills in the `wk` plugin.


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

5. **Migrate stale per-repo lessons → global pool.** Idempotent. The per-repo lessons location was deprecated in favor of `${CLAUDE_PLUGIN_ROOT}/lessons/` (global, cross-project). Old tickets still have files at `./.doer/knowledge/lessons/` from before the change. Migrate them so the user keeps a single global pool.

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

6. **Migration Check.** If a ticket is active, run the **Migration Check** (see `${CLAUDE_PLUGIN_ROOT}/lib/migrations.md`). Auto-applies any pending migration silently. Idempotent, once at current version, no-op.

7. **Acquire per-ticket lock** (only when a ticket is active). Run:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/lib/helpers/lock.sh acquire "<TICKET-ID>"
   ```
   If exit is non-zero, the orchestrator MUST stop the run. Surface the helper's stderr message verbatim. Do NOT prompt the user, do NOT retry. The user resolves the conflict (close the other session) and re-invokes `/wk:doer`.

   The protocol is documented in `${CLAUDE_PLUGIN_ROOT}/lib/lock.md`. The lock file lives at `./.doer/tickets/<TICKET-ID>/lock.json`.

8. **Mark satisfied:** if a ticket is active, write `metadata.workspace_guard = "ok"`. (No-op if no active ticket, next ticket-scoped invocation sets it.)

For deep cleanup of historical `.doer/` content from earlier commits on the feature branch, use `/doer cleanup-history <TICKET-ID>`, out of scope for the Guard.

