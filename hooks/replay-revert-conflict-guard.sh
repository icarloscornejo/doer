#!/usr/bin/env bash
# PreToolUse guard for Bash: forbid completing a conflicted revert of a
# "[TEMP] REPLAY" commit by hand (skills/replay/SKILL.md, cleanup ON
# CONFLICT). Exact mirror of protolog-revert-conflict-guard.sh, matching
# "[TEMP] REPLAY" instead of "[TEMP] PROTOLOG" in the REVERT_HEAD subject.
# The two never cross-fire: a "[TEMP] REPLAY" revert does not match the
# protolog guard's "[TEMP] PROTOLOG" case and vice versa.
#
# Scoped to wk sessions only: inert unless a live session marker
# (./.doer/wk-session-<pid>.json) exists for the current process, see
# git-commit-no-verify-guard.sh for the full rationale.
set -euo pipefail

[ -f ".doer/wk-session-${PPID}.json" ] || exit 0

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"

case "$cmd" in
  *"git revert"*"--continue"*|*"git revert"*"--quit"*|*"git commit"*) ;;
  *) exit 0 ;;
esac

git_dir="$(git rev-parse --git-dir 2>/dev/null)" || exit 0
[ -f "$git_dir/REVERT_HEAD" ] || exit 0

subject="$(git log -1 --format=%s REVERT_HEAD 2>/dev/null || true)"
case "$subject" in
  *"[TEMP] REPLAY"*) ;;
  *) exit 0 ;;
esac

reason="wk: a revert of a [TEMP] REPLAY commit is in progress and must not be completed by hand (skills/replay/SKILL.md cleanup, ON CONFLICT). The only permitted action is 'git revert --abort', then the restore() fallback (hooks/replay-restore.py) for that commit's files only."
jq -n --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
exit 0
