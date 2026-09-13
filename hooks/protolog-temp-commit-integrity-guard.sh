#!/usr/bin/env bash
# PreToolUse guard for Bash: before any "[TEMP] PROTOLOG" commit, re-run
# skills/protologs/SKILL.md Step 4.5 Check A/B against every staged source
# file, deterministically, instead of trusting the orchestrator to have
# actually run them. Both checks are now one call to
# hooks/protolog-restore.py check <post> <parent>: exit 1 is Check A (some
# non-PROTOLOG content differs from the parent, catching both additions AND
# deletions, unlike the old line-added-only diff grep), exit 2 is Check B
# (a PROTOLOG line is embedded with business logic or otherwise malformed).
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

HERE="$(cd "$(dirname "$0")" && pwd)"
RESTORE="$HERE/protolog-restore.py"
tmp_parent="$(mktemp)"
trap 'rm -f "$tmp_parent"' EXIT

files="$( { git diff --cached --name-only 2>/dev/null; git diff HEAD --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort -u)"

while IFS= read -r file; do
  [ -z "$file" ] && continue
  case "$file" in
    *.kt|*.kts|*.java|*.swift|*.ts|*.tsx|*.js|*.py|*.go|*.rs|*.rb) ;;
    *) continue ;;
  esac
  [ -f "$file" ] || continue

  # Parent image at HEAD; empty for a new untracked file (there is no HEAD
  # blob), which is what makes "check" require the whole new file to be
  # nothing but PROTOLOG lines.
  git show "HEAD:${file}" > "$tmp_parent" 2>/dev/null || : > "$tmp_parent"

  # `if` here, not a bare `check_err=$(...)`: under set -e a failing command
  # substitution used as a plain statement aborts the script immediately,
  # before the exit code could ever be read back out of it.
  if check_err="$(python3 "$RESTORE" check "$file" "$tmp_parent" 2>&1)"; then
    check_exit=0
  else
    check_exit=$?
  fi

  case "$check_exit" in
    0) ;;
    1)
      fail="${fail}
[Check A] ${file}: non-PROTOLOG change (restore-equality mismatch):
${check_err}"
      ;;
    2)
      fail="${fail}
[Check B] ${file}: PROTOLOG line embedded with business logic or malformed:
${check_err}"
      ;;
    *)
      fail="${fail}
[protolog-restore.py] ${file}: unexpected error (exit ${check_exit}):
${check_err}"
      ;;
  esac
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
