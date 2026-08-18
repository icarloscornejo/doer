#!/usr/bin/env bash
# PreToolUse guard for Bash: before any "[TEMP] REPLAY" commit, verify every
# touched source file obeys the restore-equality invariant from
# skills/replay/SKILL.md ("Injected code shape"): stripping every REPLAY
# START..END block (via hooks/replay-restore.py, the SAME script cleanup's
# fallback uses to actually remove them) must reproduce the parent content
# byte for byte.
#
# This is deliberately NOT protologs' Check A/B (no added line outside a
# tagged line). Replay REPLACES expressions by design, so its diffs contain
# deletions; a protolog-style additive-only check would pass on a block that
# silently dropped the original code, and cleanup's "no trace remains" text
# check would then pass on a mutilated file. Restore-equality catches
# deletions, unbalanced/nested markers, and any added line outside a block,
# all with a single check, and proves the fallback is safe because the
# fallback IS this same transformation (see replay-restore.py).
#
# Scoped to wk sessions only: inert unless a live session marker
# (./.doer/wk-session-<pid>.json) exists for the current process, see
# git-commit-no-verify-guard.sh for the full rationale.
#
# 7.7.0: this guard reads the union of the index, the working tree diff
# against HEAD, and untracked files, not `git diff --cached` alone, because
# `hooks/protolog-temp-commit-integrity-guard.sh` shipped that exact bug: as
# a PreToolUse hook it runs BEFORE `git add -A` executes, so `--cached`
# alone sees an empty, HEAD-equal index on the real "git add -A && git
# commit ..." invocation shape and silently allows anything through.
# Verified empirically before this guard was written; the protolog guard
# carries the same fix in this release.
set -euo pipefail

[ -f ".doer/wk-session-${PPID}.json" ] || exit 0

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"

case "$cmd" in
  *"git commit"*"[TEMP] REPLAY"*) ;;
  *) exit 0 ;;
esac

RESTORE="$(dirname "$0")/replay-restore.py"
fail=""

# R3: the commit message must carry DO NOT MERGE.
case "$cmd" in
  *"DO NOT MERGE"*) ;;
  *) fail="${fail}
[R3] commit message is missing the required \"DO NOT MERGE\" marker." ;;
esac

files="$( { git diff --cached --name-only 2>/dev/null; git diff HEAD --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort -u)"

TMP_PARENT="$(mktemp)"
TMP_ERR="$(mktemp)"
trap 'rm -f "$TMP_PARENT" "$TMP_ERR"' EXIT

while IFS= read -r file; do
  [ -z "$file" ] && continue
  case "$file" in
    *.kt|*.kts|*.java|*.swift|*.ts|*.tsx|*.js|*.py|*.go|*.rs|*.rb) ;;
    *) continue ;;
  esac
  [ -f "$file" ] || continue

  if git cat-file -e "HEAD:${file}" 2>/dev/null; then
    # R1: restore-equality against the parent blob.
    git show "HEAD:${file}" > "$TMP_PARENT" 2>/dev/null || true
    if ! python3 "$RESTORE" check "$file" "$TMP_PARENT" 2>"$TMP_ERR"; then
      reason_detail="$(cat "$TMP_ERR" 2>/dev/null || true)"
      fail="${fail}
[R1] ${file}: restore-equality failed. ${reason_detail}"
    fi
  else
    # R2: a brand new source file has no parent blob to restore against,
    # and the skill's contract is edit-in-place only (no new asset/payload
    # files), so any new source file in a [TEMP] REPLAY commit is forbidden
    # outright, regardless of its own content.
    fail="${fail}
[R2] ${file}: new source file introduced by a [TEMP] REPLAY commit. Replay never creates new files (skills/replay/SKILL.md); splice the payload into an existing file instead."
  fi
done <<< "$files"

if [ -n "$fail" ]; then
  reason="wk: replay integrity check failed before [TEMP] commit (skills/replay/SKILL.md).${fail}

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
