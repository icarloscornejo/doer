#!/usr/bin/env bash
# PreToolUse guard for Bash: forbid completing a conflicted revert of a
# "[TEMP] PROTOLOG" commit by hand (skills/protologs/SKILL.md, cleanup Step 2
# ON CONFLICT). Real incident: an agent hand-resolved the conflict and ran
# `git revert --continue`; the end state was correct but reached via an
# unverified mechanism (Step 3b skips reconciliation on the revert path
# because it assumes reverts are exact by construction). A markdown "MUST
# abort" instruction does not survive a conflict that looks trivial to
# resolve, so this closes the gap at the tool-call level, the same way
# protolog-temp-commit-integrity-guard.sh does for Step 4.5.
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
  *"[TEMP] PROTOLOG"*) ;;
  *) exit 0 ;;
esac

reason="wk: a revert of a [TEMP] PROTOLOG commit is in progress and must not be completed by hand (skills/protologs/SKILL.md cleanup Step 2, ON CONFLICT). The only permitted action is 'git revert --abort', then Step 2-fallback (sed) for that commit's files only."
jq -n --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
exit 0
