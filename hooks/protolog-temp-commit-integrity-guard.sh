#!/usr/bin/env bash
# PreToolUse guard for Bash: before any "[TEMP] PROTOLOG" commit, re-run
# skills/protologs/SKILL.md Step 4.5 Check A/B against every staged source
# file, deterministically, instead of trusting the orchestrator to have
# actually run them.
#
# Real incident: the logger-agent violated the "no refactor" rules in 5
# files (expression->block conversions, an empty init {}, a println split
# across lines, a when block rewrapped) and the checks that exist precisely
# to catch this were never run before the [TEMP] commit landed. Deleting
# only the PROTOLOG-tagged lines afterward did not restore the files:
# dangling empty blocks, broken syntax, restructured control flow. A
# markdown "MUST run this" instruction does not survive a long session; this
# closes the gap at the tool-call level, the same way
# git-commit-no-verify-guard.sh does for principles.md #6.
#
# Scoped to wk sessions only: inert unless a live session marker
# (./.doer/wk-session-<pid>.json) exists for the current process, see
# git-commit-no-verify-guard.sh for the full rationale.
set -euo pipefail

[ -f ".doer/wk-session-${PPID}.json" ] || exit 0

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"

case "$cmd" in
  *"git commit"*"[TEMP] PROTOLOG"*) ;;
  *) exit 0 ;;
esac

fail=""

while IFS= read -r file; do
  [ -z "$file" ] && continue
  case "$file" in
    *.kt|*.kts|*.java|*.swift|*.ts|*.tsx|*.js|*.py|*.go|*.rs|*.rb) ;;
    *) continue ;;
  esac
  [ -f "$file" ] || continue

  # Check A (non-PROTOLOG additions): any added line that is not a PROTOLOG
  # line means the logger-agent changed real code (forbidden refactor).
  checkA="$(git diff --cached -- "$file" | grep '^+' | grep -v '^+++' | grep -v 'PROTOLOG - ' || true)"
  if [ -n "$checkA" ]; then
    fail="${fail}
[Check A] ${file}: non-PROTOLOG lines added (forbidden refactor):
${checkA}"
  fi

  # Check B (PROTOLOG mixed with business logic on one physical line): a
  # PROTOLOG line that is not a bare println/print/etc call or a bare
  # ".also { println(...) }" continuation means the injection glued a log
  # onto real code; deleting it by text match would delete the logic too.
  checkB="$(git diff --cached -- "$file" | grep '^+' | grep -v '^+++' | grep 'PROTOLOG - ' \
    | grep -vE '^\+[[:space:]]*(\.also \{ )?(println|print|console\.log|System\.out\.println|fmt\.Println|puts|println!)' || true)"
  if [ -n "$checkB" ]; then
    fail="${fail}
[Check B] ${file}: PROTOLOG mixed with business logic on one line:
${checkB}"
  fi
done <<< "$(git diff --cached --name-only)"

if [ -n "$fail" ]; then
  reason="wk: protolog integrity check failed before [TEMP] commit (skills/protologs/SKILL.md Step 4.5).${fail}

Fix these files with the Edit tool (never sed-delete blind), re-stage, and retry the commit."
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

exit 0
