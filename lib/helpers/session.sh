#!/usr/bin/env bash
# wk plugin: per-repo session marker helper.
# Spec: lib/state.md, lib/workspace-guard.md.
#
# Storage: ./.doer/wk-session-<pid>.json (per-clone, excluded via
# .git/info/exclude, never committed).
#
# Every PreToolUse guard shipped by this plugin (git-commit-no-verify-guard.sh,
# protolog-temp-commit-integrity-guard.sh, protolog-revert-conflict-guard.sh,
# replay-temp-commit-integrity-guard.sh, replay-revert-conflict-guard.sh)
# checks for a live marker before doing anything else, so a normal Claude Code
# session with the plugin installed but no wk skill running is never affected.
# $PPID is the long-lived claude process for the session (same pid the hook
# sees as its own $PPID, since the hook runs as a child of the same process
# that issued the Bash tool call); $$ is this transient shell and must not be
# recorded.

set -eu

usage() {
  cat >&2 <<EOF
Usage: session.sh <command> [args...]

Commands:
  start <skill>   Write ./.doer/wk-session-\$PPID.json ({"pid","host","skill","touched_at"}),
                  ensuring .doer/ is git-excluded first. Also prunes markers whose pid
                  is no longer a live claude process on this host.
  stop            Remove ./.doer/wk-session-\$PPID.json for the current session.
  active          Exit 0 if any live marker exists in this repo, exit 1 otherwise.

Notes:
  - Requires jq.
  - All writes are atomic (write to .tmp then mv).
EOF
  exit 2
}

[ $# -ge 1 ] || usage

if ! command -v jq >/dev/null 2>&1; then
  echo "session.sh requires jq" >&2
  exit 2
fi

ensure_exclude() {
  mkdir -p .git/info
  [ -f .git/info/exclude ] || touch .git/info/exclude
  grep -qxF '.doer/' .git/info/exclude || echo '.doer/' >> .git/info/exclude
}

is_live_claude_pid() {
  local pid="$1" host="$2"
  [ "$host" = "$(hostname)" ] || return 1
  case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
    *claude*) return 0 ;;
    *) return 1 ;;
  esac
}

prune_dead_markers() {
  local f pid host
  for f in .doer/wk-session-*.json; do
    [ -e "$f" ] || continue
    pid="$(jq -r '.pid // empty' "$f" 2>/dev/null || true)"
    host="$(jq -r '.host // empty' "$f" 2>/dev/null || true)"
    [ -n "$pid" ] && [ -n "$host" ] || { rm -f "$f"; continue; }
    is_live_claude_pid "$pid" "$host" || rm -f "$f"
  done
}

CMD="$1"
shift

case "$CMD" in
  start)
    [ $# -ge 1 ] || { echo "start requires <skill>" >&2; exit 2; }
    SKILL="$1"
    ensure_exclude
    mkdir -p .doer
    prune_dead_markers
    TMP=".doer/wk-session-${PPID}.json.tmp"
    OUT=".doer/wk-session-${PPID}.json"
    jq -n --arg skill "$SKILL" --arg host "$(hostname)" --argjson pid "$PPID" --argjson t "$(date +%s)" \
      '{pid: $pid, host: $host, skill: $skill, touched_at: $t}' > "$TMP"
    mv "$TMP" "$OUT"
    ;;

  stop)
    rm -f ".doer/wk-session-${PPID}.json"
    ;;

  active)
    prune_dead_markers 2>/dev/null || true
    ls .doer/wk-session-*.json >/dev/null 2>&1
    ;;

  *)
    usage
    ;;
esac
