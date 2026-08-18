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
#
# 7.7.0 fix: this guard was fail-open on its only real invocation shape,
# `git add -A && git commit --no-verify -m "[TEMP] PROTOLOG ..."`
# (skills/protologs/SKILL.md Step 4.6). As a PreToolUse hook it runs BEFORE
# that command executes, so at hook time `git add -A` has not happened yet;
# reading only `git diff --cached` therefore saw an empty (HEAD-equal) index
# and iterated zero files every time, silently allowing anything through.
# Verified empirically in a scratch repo: a deliberate Check A violation was
# permitted under the real "git add -A && git commit" shape and only denied
# when the file was staged by hand first, which is not how the skill invokes
# it. Reading the union of the index, the working tree diff against HEAD,
# and untracked files closes this regardless of whether the caller stages
# before or as part of the same compound command.
set -euo pipefail

[ -f ".doer/wk-session-${PPID}.json" ] || exit 0

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"

case "$cmd" in
  *"git commit"*"[TEMP] PROTOLOG"*) ;;
  *) exit 0 ;;
esac

fail=""

files="$( { git diff --cached --name-only 2>/dev/null; git diff HEAD --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort -u)"

while IFS= read -r file; do
  [ -z "$file" ] && continue
  case "$file" in
    *.kt|*.kts|*.java|*.swift|*.ts|*.tsx|*.js|*.py|*.go|*.rs|*.rb) ;;
    *) continue ;;
  esac
  [ -f "$file" ] || continue

  # Diff against HEAD (not --cached alone): correct whether the file is
  # staged, unstaged, or a mix of both at hook time.
  filediff="$(git diff HEAD -- "$file" 2>/dev/null || true)"
  if [ -z "$filediff" ]; then
    # New untracked file: there is no HEAD blob to diff against. Every line
    # in it counts as an addition for Check A purposes.
    filediff="$(awk '{print "+"$0}' "$file" 2>/dev/null || true)"
  fi

  # Check A (non-PROTOLOG additions): any added line that is not a PROTOLOG
  # line means the logger-agent changed real code (forbidden refactor).
  checkA="$(printf '%s\n' "$filediff" | grep '^+' | grep -v '^+++' | grep -v 'PROTOLOG - ' || true)"
  if [ -n "$checkA" ]; then
    fail="${fail}
[Check A] ${file}: non-PROTOLOG lines added (forbidden refactor):
${checkA}"
  fi

  # Check B (PROTOLOG mixed with business logic on one physical line): a
  # PROTOLOG line that is not a bare println/print/etc call or a bare
  # ".also { println(...) }" continuation means the injection glued a log
  # onto real code; deleting it by text match would delete the logic too.
  checkB="$(printf '%s\n' "$filediff" | grep '^+' | grep -v '^+++' | grep 'PROTOLOG - ' \
    | grep -vE '^\+[[:space:]]*(\.also \{ )?(println|print|console\.log|System\.out\.println|fmt\.Println|puts|println!)' || true)"
  if [ -n "$checkB" ]; then
    fail="${fail}
[Check B] ${file}: PROTOLOG mixed with business logic on one line:
${checkB}"
  fi
done <<< "$files"

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
