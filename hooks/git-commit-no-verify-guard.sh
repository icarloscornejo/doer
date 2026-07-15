#!/usr/bin/env bash
# PreToolUse guard for Bash: deny any "git commit" that omits --no-verify.
#
# lib/principles.md #6: all commits use --no-verify, pre-commit hooks
# interrupt mid-stage without value (intermediate states may fail a hook
# while correct for the stage; the dev runs real checks manually before the
# PR). A plain "git commit" without the flag can get silently cancelled by
# a repo's pre-commit hook, which looks like a no-op failure if you are not
# watching for it. The skill files already say --no-verify everywhere, but
# a markdown instruction alone does not survive context drift across a long
# session, so this closes the gap at the tool-call level for every session
# that has this plugin installed, not just the one where it was written.
set -euo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"

case "$cmd" in
  *"git commit"*) ;;
  *) exit 0 ;;
esac

case "$cmd" in
  *"--no-verify"*|*"-n "*) exit 0 ;;
esac

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "wk: every git commit must use --no-verify (see lib/principles.md #6). A commit without it can be silently cancelled by a pre-commit hook. Retry with --no-verify."
  }
}'
exit 0
