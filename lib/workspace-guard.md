# Workspace Guard + Per-Ticket Lock

Idempotent check that prevents `.doer/` (including `.doer/config.json`, the per-project Jira config) from ever being committed in this clone, plus a lightweight lock against two sessions racing on the same ticket. A dead session's lock (recorded process gone, same host) is stolen immediately; a live one blocks for up to 30 minutes. MUST run inline (actual Bash execution, not a reference) at every ticket-scoped entry point: intake (after creating the branch), resume, `cleanup-history`. `/wk:setup` and `/wk:jira <url>` also run steps 1-3 (the exclude rule) before writing `config.json`; they skip step 4, the per-ticket lock, since they are not ticket-scoped.

Step 4 also writes the session marker (`"${CLAUDE_PLUGIN_ROOT}/lib/helpers/session.sh" start doer` or `start bugfix`, per the invoking skill). This plugin's PreToolUse guards (`git-commit-no-verify-guard.sh`, the protolog guards, and the replay guards) are inert without a live marker, so a normal Claude Code session with the plugin installed but no wk skill active is never affected by them.

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

# 4. Per-ticket lock: fresh lock from another LIVE session -> stop.
#    Dead (recorded claude pid gone, same host) or stale (>30 min) -> steal.
#    $PPID is the session's long-lived claude process; $$ is this transient
#    shell and must NOT be recorded (it dies right after this command).
if [ -f "$TICKET_DIR/lock.json" ]; then
  TOUCHED=$(jq -r '.touched_at // 0' "$TICKET_DIR/lock.json" 2>/dev/null)
  LOCK_PID=$(jq -r '.pid // empty' "$TICKET_DIR/lock.json" 2>/dev/null)
  LOCK_HOST=$(jq -r '.host // empty' "$TICKET_DIR/lock.json" 2>/dev/null)
  AGE=$(( $(date +%s) - ${TOUCHED:-0} ))
  ALIVE=1
  if [ -n "$LOCK_PID" ] && [ "$LOCK_HOST" = "$(hostname)" ]; then
    case "$(ps -o comm= -p "$LOCK_PID" 2>/dev/null)" in
      *claude*) ;;   # recorded pid is alive and still a claude process
      *) ALIVE=0 ;;  # gone, or recycled into an unrelated process
    esac
  fi
  if [ "$ALIVE" -eq 1 ] && [ "$AGE" -lt 1800 ]; then
    echo "LOCKED: another session touched <TICKET-ID> ${AGE}s ago and its process is still alive (or is on another host, where liveness can't be checked). Close it or wait for the lock to expire (30 min)."
    exit 1
  fi
fi
mkdir -p "$TICKET_DIR"
printf '{"pid": %d, "host": "%s", "touched_at": %d}\n' "$PPID" "$(hostname)" "$(date +%s)" > "$TICKET_DIR/lock.json"

# 5. Session marker (activates this plugin's PreToolUse guards for this session only)
"${CLAUDE_PLUGIN_ROOT}/lib/helpers/session.sh" start <SKILL>   # <SKILL> = doer | bugfix
```

- If `TRACKED` is non-empty, ask the user once per ticket: 1) commit `git rm -r --cached .doer/` on this branch, 2) skip and clean manually later, 3) untrack silently (stage but do not commit). Default 3.
- On `LOCKED`, stop the run and surface the message verbatim. No retry, no prompt, and NEVER delete or rewrite `lock.json` manually to bypass it: the liveness check above already steals every objectively dead lock, so a surviving `LOCKED` means the other session is (or may be) alive, even if the dev believes otherwise. The user closes the other session and re-invokes; the steal then happens on its own.
- The lock releases at wrapup (`rm -f "$TICKET_DIR/lock.json"`) or ages out after 30 minutes on a crash. The session marker releases at wrapup too (`session.sh stop`); a crash leaves it inert (see `lib/helpers/session.sh`, pruned on the next `start` in this repo).
- For scrubbing historical `.doer/` content from earlier commits, use `/doer cleanup-history <TICKET-ID>` (out of scope for the Guard).
