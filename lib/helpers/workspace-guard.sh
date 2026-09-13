#!/usr/bin/env bash
# wk plugin: Workspace Guard + per-ticket lock. Spec: lib/workspace-guard.md.
#
# MUST be invoked as the Bash tool's entire command: a bare statement, never
# wrapped in $(...), a subshell, or chained after another command with &&.
# $PPID must stay the long-lived claude process for this session (same
# invariant session.sh itself depends on); acquire/release hand off to
# session.sh via exec at the end specifically so session.sh inherits that
# exact $PPID instead of seeing workspace-guard.sh's own pid as its parent.

set -eu

usage() {
  cat >&2 <<EOF
Usage: workspace-guard.sh <command> [args...]

Commands:
  acquire <TICKET-ID> <doer|bugfix>   Steps 1-5: exclude rule, verify it took,
                                       detect already-tracked .doer/ files,
                                       per-ticket lock (steal dead/stale locks,
                                       refresh a same-session lock), then
                                       exec session.sh start <skill>.
                                       stdout "TRACKED <path>" when .doer/ has
                                       tracked files (the caller asks the dev
                                       what to do); nothing on a clean tree.
                                       "LOCKED ..." verbatim with exit 1 if
                                       another live session holds the lock.
  acquire --no-lock                   Steps 1-3 only (setup/jira: not
                                       ticket-scoped, no lock, no session
                                       marker). Exit 1 if the exclude rule
                                       does not take effect.
  release <TICKET-ID>                 rm -f lock.json, then exec session.sh stop.
EOF
  exit 2
}

[ $# -ge 1 ] || usage
command -v jq >/dev/null 2>&1 || { echo "workspace-guard.sh requires jq" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"

ensure_exclude() {
  mkdir -p .git/info
  [ -f .git/info/exclude ] || touch .git/info/exclude
  grep -qxF '.doer/' .git/info/exclude || echo '.doer/' >> .git/info/exclude
}

# Steps 1-3: exclude rule, verify it took effect, report already-tracked
# .doer/ files. Exits 1 if the exclude rule is not effective. Prints
# "TRACKED <path>" (one file, the first found) if any are tracked.
run_steps_1_to_3() {
  ensure_exclude
  mkdir -p .doer && touch .doer/.guard-test
  STATUS="$(git status --porcelain .doer/.guard-test 2>/dev/null)"
  rm -f .doer/.guard-test
  if [ -n "$STATUS" ]; then
    echo "ERROR: .doer/ exclude rule not effective. Investigate (global gitignore override?) before proceeding." >&2
    exit 1
  fi
  TRACKED="$(git ls-files .doer/ 2>/dev/null | head -1)"
  # An `if` here, not `[ -n "$TRACKED" ] && echo ...`: with $TRACKED empty
  # (the normal case) that `&&` chain's own exit status is 1, which is NOT an
  # error, but is indistinguishable from one to `set -e` when it is the last
  # command in this function, aborting the caller before it ever reaches its
  # own `exit 0`.
  if [ -n "$TRACKED" ]; then
    echo "TRACKED $TRACKED"
  fi
}

CMD="$1"; shift

case "$CMD" in
  acquire)
    [ $# -ge 1 ] || usage
    if [ "$1" = "--no-lock" ]; then
      run_steps_1_to_3
      exit 0
    fi
    [ $# -ge 2 ] || usage
    TICKET_ID="$1"; SKILL="$2"
    TICKET_DIR=".doer/tickets/${TICKET_ID}"

    run_steps_1_to_3

    # Step 4: per-ticket lock. $PPID is the session's long-lived claude
    # process; $$ is this transient shell and must NOT be recorded (it dies
    # right after this command).
    if [ -f "$TICKET_DIR/lock.json" ]; then
      TOUCHED="$(jq -r '.touched_at // 0' "$TICKET_DIR/lock.json" 2>/dev/null)"
      LOCK_PID="$(jq -r '.pid // empty' "$TICKET_DIR/lock.json" 2>/dev/null)"
      LOCK_HOST="$(jq -r '.host // empty' "$TICKET_DIR/lock.json" 2>/dev/null)"
      AGE=$(( $(date +%s) - ${TOUCHED:-0} ))
      # Same-session resume: the lock is our own, from earlier in this same
      # live process. Never block on it, just refresh below.
      if [ "$LOCK_PID" != "$PPID" ] || [ "$LOCK_HOST" != "$(hostname)" ]; then
        ALIVE=1
        if [ -n "$LOCK_PID" ] && [ "$LOCK_HOST" = "$(hostname)" ]; then
          case "$(ps -o comm= -p "$LOCK_PID" 2>/dev/null)" in
            *claude*) ;;   # recorded pid is alive and still a claude process
            *) ALIVE=0 ;;  # gone, or recycled into an unrelated process
          esac
        fi
        if [ "$ALIVE" -eq 1 ] && [ "$AGE" -lt 1800 ]; then
          echo "LOCKED: another session touched ${TICKET_ID} ${AGE}s ago and its process is still alive (or is on another host, where liveness can't be checked). Close it or wait for the lock to expire (30 min)."
          exit 1
        fi
      fi
    fi
    mkdir -p "$TICKET_DIR"
    printf '{"pid": %d, "host": "%s", "touched_at": %d}\n' "$PPID" "$(hostname)" "$(date +%s)" > "$TICKET_DIR/lock.json"

    # Step 5: session marker, same $PPID as above (exec, not a subprocess).
    exec "$HERE/session.sh" start "$SKILL"
    ;;

  release)
    [ $# -ge 1 ] || usage
    TICKET_ID="$1"
    rm -f ".doer/tickets/${TICKET_ID}/lock.json"
    exec "$HERE/session.sh" stop
    ;;

  *)
    usage
    ;;
esac
