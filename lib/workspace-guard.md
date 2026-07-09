# Workspace Guard + Per-Ticket Lock

Idempotent check that prevents `.doer/` (including `.doer/config.json`, the per-project Jira config) from ever being committed in this clone, plus a lightweight lock against two sessions racing on the same ticket. MUST run inline (actual Bash execution, not a reference) at every ticket-scoped entry point: intake (after creating the branch), resume, `cleanup-history`. `/wk:setup` and `/wk:jira <url>` also run steps 1-3 (the exclude rule) before writing `config.json`; they skip step 4, the per-ticket lock, since they are not ticket-scoped.

```bash
TICKET_DIR=".doer/tickets/<TICKET-ID>"

# 1. Ensure the exclude rule exists (per-clone, never committed; team sees nothing)
mkdir -p .git/info
[ -f .git/info/exclude ] || touch .git/info/exclude
grep -qxF '.doer/' .git/info/exclude || echo '.doer/' >> .git/info/exclude

# 2. Verify it takes effect
mkdir -p .doer && touch .doer/.guard-test
STATUS=$(git status --porcelain .doer/.guard-test 2>/dev/null)
rm -f .doer/.guard-test
[ -n "$STATUS" ] && { echo "ERROR: .doer/ exclude rule not effective. Investigate (global gitignore override?) before proceeding."; exit 1; }

# 3. Detect already-tracked .doer/ files
TRACKED=$(git ls-files .doer/ 2>/dev/null | head -1)

# 4. Per-ticket lock: fresh lock from another session -> stop; stale (>30 min) -> steal
if [ -f "$TICKET_DIR/lock.json" ]; then
  TOUCHED=$(jq -r '.touched_at // 0' "$TICKET_DIR/lock.json" 2>/dev/null)
  AGE=$(( $(date +%s) - ${TOUCHED:-0} ))
  [ "$AGE" -lt 1800 ] && { echo "LOCKED: another session touched <TICKET-ID> ${AGE}s ago. Close it or wait for the lock to expire (30 min)."; exit 1; }
fi
mkdir -p "$TICKET_DIR"
printf '{"pid": %d, "host": "%s", "touched_at": %d}\n' "$$" "$(hostname)" "$(date +%s)" > "$TICKET_DIR/lock.json"
```

- If `TRACKED` is non-empty, ask the user once per ticket: 1) commit `git rm -r --cached .doer/` on this branch, 2) skip and clean manually later, 3) untrack silently (stage but do not commit). Default 3.
- On `LOCKED`, stop the run and surface the message verbatim. No retry, no prompt; the user closes the other session and re-invokes.
- The lock releases at wrapup (`rm -f "$TICKET_DIR/lock.json"`) or ages out after 30 minutes on a crash.
- For scrubbing historical `.doer/` content from earlier commits, use `/doer cleanup-history <TICKET-ID>` (out of scope for the Guard).
