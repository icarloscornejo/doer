#!/usr/bin/env bash
# wk plugin: single source of truth for Core Principle 10's forbidden-vocabulary
# regex (internal orchestration labels that must never reach team-facing
# artifacts). See lib/principles.md #10.
#
# Reads each <file> given, or stdin if none given. Prints one line per match
# as <file|stdin>:<line>:<text>. Exit 0 clean, 1 if any match found.
#
# Scope: TEXT artifacts only (commit message candidates, PR descriptions).
# Never run this against a code diff: \bC-[0-9]+\b and \bQ-[0-9]+\b are common
# in real code (constants, question IDs) and would false-positive there. For
# diffs, use git-checks.sh ac-leak instead.

set -eu

PATTERN='\bAC-[0-9]+\b|\bO-[0-9]+\b|\bC-[0-9]+\b|\bOOS-[0-9]+\b|\bQ-[0-9]+\b|\bR[0-9]+-F[0-9]+\b|PROTOLOG|\bREPLAY\b|\bDOER\b|\bdoer\('
# PROTOLOG has no trailing \b on purpose: it must also catch PROTOLOG_RESPONSE
# ("_" is a word character, so \b would not match right after "G").

if [ $# -eq 0 ]; then
  OUT="$(grep -nE "$PATTERN" - 2>/dev/null | sed 's/^/stdin:/' || true)"
else
  OUT="$(grep -nHE "$PATTERN" "$@" 2>/dev/null || true)"
fi

if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT"
  exit 1
fi
exit 0
