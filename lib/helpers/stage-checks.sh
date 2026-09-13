#!/usr/bin/env bash
# wk plugin: deterministic stage-close gates for doer Stage 2 (plan) and
# Stage 3 (build pre-review). Both are explicitly documented as "no LLM"
# checks in their stage file; this is their one implementation.

set -eu

usage() {
  cat >&2 <<EOF
Usage: stage-checks.sh <cmd> <TICKET-ID> [args...]

Commands:
  plan <TICKET-ID> [--plan <file>]
      Reads the proposed plan object from stdin (or --plan <file>: the plan
      is not persisted yet at this point in Stage 2, so there is nothing in
      metadata.json to validate against; this checks exactly what is about
      to be written). Reads metadata.ac.in_scope from
      ./.doer/tickets/<TICKET-ID>/metadata.json.
      Prints {"files_missing":[],"files_unexpected":[],"ac_uncovered":[],
      "assumptions":[{"id","result":"pass|fail|skipped","risk"}]}.
      Exit 0 when the three lists are empty and no assumption is both
      "fail" and "high" risk; exit 1 otherwise.

  pre-review <TICKET-ID> <base>
      Prints {"blockers":[{"kind":"tests|lint|typecheck|scope|secrets|ac-leak",
      "detail"}],"info":[...],"missing":["lint_command",...]}.
      Runs metadata.test_command / lint_command / typecheck_command (never
      autodetects: that stays a judgment call for the caller); composes
      git-checks.sh secrets and ac-leak; compares the diff's file list
      against plan.files[].path. Exit 0 with zero blockers, 1 otherwise.
EOF
  exit 2
}

[ $# -ge 2 ] || usage
command -v jq >/dev/null 2>&1 || { echo "stage-checks.sh requires jq" >&2; exit 2; }

CMD="$1"; shift
TICKET_ID="$1"; shift
TARGET="./.doer/tickets/${TICKET_ID}/metadata.json"
HERE="$(cd "$(dirname "$0")" && pwd)"

# run_with_timeout <seconds> <shell-command-string>
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$1" sh -c "$2"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$1" sh -c "$2"
  else
    perl -e 'alarm shift(@ARGV); exec "sh", "-c", shift(@ARGV)' "$1" "$2"
  fi
}

case "$CMD" in
  plan)
    PLAN_FILE="-"
    if [ "${1:-}" = "--plan" ]; then
      [ $# -ge 2 ] || usage
      PLAN_FILE="$2"
    fi
    [ -f "$TARGET" ] || { echo "stage-checks.sh: $TARGET does not exist" >&2; exit 2; }
    if [ "$PLAN_FILE" = "-" ]; then
      PLAN_JSON="$(cat)"
    else
      [ -f "$PLAN_FILE" ] || { echo "stage-checks.sh: plan file not found: $PLAN_FILE" >&2; exit 2; }
      PLAN_JSON="$(cat "$PLAN_FILE")"
    fi
    printf '%s' "$PLAN_JSON" | jq . > /dev/null || { echo "stage-checks.sh: plan is not valid JSON" >&2; exit 2; }

    # Files: every "edit"|"delete" path exists; every "new" path does not.
    # One compact JSON object per line, not @tsv: bash's `read` treats tab as
    # "IFS whitespace" and collapses consecutive delimiters REGARDLESS of what
    # IFS is set to, so an empty field (a null .check, below) silently shifts
    # every field after it. jq -c sidesteps that class of bug entirely.
    FILES_MISSING="[]"
    FILES_UNEXPECTED="[]"
    while IFS= read -r ROW; do
      [ -n "$ROW" ] || continue
      PLAN_PATH="$(printf '%s' "$ROW" | jq -r '.path')"
      CHANGE="$(printf '%s' "$ROW" | jq -r '.change')"
      case "$CHANGE" in
        edit|delete)
          [ -e "$PLAN_PATH" ] || FILES_MISSING="$(printf '%s' "$FILES_MISSING" | jq --arg p "$PLAN_PATH" '. + [$p]')"
          ;;
        new)
          [ ! -e "$PLAN_PATH" ] || FILES_UNEXPECTED="$(printf '%s' "$FILES_UNEXPECTED" | jq --arg p "$PLAN_PATH" '. + [$p]')"
          ;;
      esac
    done < <(printf '%s' "$PLAN_JSON" | jq -c '(.files // [])[]')

    # Coverage: every AC-N in metadata.ac.in_scope appears in some tests[].covers.
    IN_SCOPE_ACS="$(jq -r '(.ac.in_scope // [])[] | capture("^(?<id>AC-[0-9]+)").id' "$TARGET" 2>/dev/null || true)"
    COVERED_ACS="$(printf '%s' "$PLAN_JSON" | jq -r '[(.tests // [])[].covers[]?] | unique[]' 2>/dev/null || true)"
    AC_UNCOVERED="[]"
    if [ -n "$IN_SCOPE_ACS" ]; then
      while IFS= read -r AC; do
        [ -n "$AC" ] || continue
        printf '%s\n' "$COVERED_ACS" | grep -qFx "$AC" || AC_UNCOVERED="$(printf '%s' "$AC_UNCOVERED" | jq --arg a "$AC" '. + [$a]')"
      done <<< "$IN_SCOPE_ACS"
    fi

    # Assumptions: run every non-null check from the repo root, 10s timeout each.
    ASSUMPTIONS="[]"
    while IFS= read -r ROW; do
      [ -n "$ROW" ] || continue
      AID="$(printf '%s' "$ROW" | jq -r '.id')"
      CHECK="$(printf '%s' "$ROW" | jq -r '.check // ""')"
      RISK="$(printf '%s' "$ROW" | jq -r '.risk')"
      if [ -z "$CHECK" ]; then
        ASSUMPTIONS="$(printf '%s' "$ASSUMPTIONS" | jq --arg id "$AID" --arg risk "$RISK" '. + [{id: $id, result: "skipped", risk: $risk}]')"
        continue
      fi
      if run_with_timeout 10 "$CHECK" >/dev/null 2>&1; then
        RESULT="pass"
      else
        RESULT="fail"
      fi
      ASSUMPTIONS="$(printf '%s' "$ASSUMPTIONS" | jq --arg id "$AID" --arg r "$RESULT" --arg risk "$RISK" '. + [{id: $id, result: $r, risk: $risk}]')"
    done < <(printf '%s' "$PLAN_JSON" | jq -c '(.assumptions // [])[]')

    RESULT_JSON="$(jq -n --argjson fm "$FILES_MISSING" --argjson fu "$FILES_UNEXPECTED" \
      --argjson au "$AC_UNCOVERED" --argjson asm "$ASSUMPTIONS" \
      '{files_missing: $fm, files_unexpected: $fu, ac_uncovered: $au, assumptions: $asm}')"
    printf '%s\n' "$RESULT_JSON"

    HIGH_FAIL="$(printf '%s' "$RESULT_JSON" | jq '[.assumptions[] | select(.result == "fail" and .risk == "high")] | length')"
    EMPTY_OK="$(printf '%s' "$RESULT_JSON" | jq '(.files_missing | length) == 0 and (.files_unexpected | length) == 0 and (.ac_uncovered | length) == 0')"
    [ "$EMPTY_OK" = "true" ] && [ "$HIGH_FAIL" -eq 0 ]
    ;;

  pre-review)
    [ $# -ge 1 ] || usage
    BASE="$1"
    [ -f "$TARGET" ] || { echo "stage-checks.sh: $TARGET does not exist" >&2; exit 2; }

    BLOCKERS="[]"
    INFO="[]"
    MISSING="[]"

    TEST_CMD="$(jq -r '.test_command // empty' "$TARGET")"
    if [ -z "$TEST_CMD" ]; then
      MISSING="$(printf '%s' "$MISSING" | jq '. + ["test_command"]')"
    elif ! sh -c "$TEST_CMD" >/dev/null 2>&1; then
      BLOCKERS="$(printf '%s' "$BLOCKERS" | jq '. + [{kind: "tests", detail: "test command failed"}]')"
    fi

    LINT_CMD="$(jq -r '.lint_command // empty' "$TARGET")"
    if [ -z "$LINT_CMD" ]; then
      MISSING="$(printf '%s' "$MISSING" | jq '. + ["lint_command"]')"
    elif ! sh -c "$LINT_CMD" >/dev/null 2>&1; then
      BLOCKERS="$(printf '%s' "$BLOCKERS" | jq '. + [{kind: "lint", detail: "lint command failed"}]')"
    fi

    TYPECHECK_CMD="$(jq -r '.typecheck_command // empty' "$TARGET")"
    if [ -z "$TYPECHECK_CMD" ]; then
      MISSING="$(printf '%s' "$MISSING" | jq '. + ["typecheck_command"]')"
    elif ! sh -c "$TYPECHECK_CMD" >/dev/null 2>&1; then
      BLOCKERS="$(printf '%s' "$BLOCKERS" | jq '. + [{kind: "typecheck", detail: "typecheck command failed"}]')"
    fi

    DIFF_FILES="$(git diff "$BASE"...HEAD --name-only -- . ':(exclude).doer/**' 2>/dev/null)"
    PLAN_FILES="$(jq -r '(.plan.files // [])[].path' "$TARGET" 2>/dev/null || true)"
    if [ -n "$PLAN_FILES" ]; then
      while IFS= read -r PF; do
        [ -n "$PF" ] || continue
        printf '%s\n' "$DIFF_FILES" | grep -qFx "$PF" \
          || BLOCKERS="$(printf '%s' "$BLOCKERS" | jq --arg p "$PF" '. + [{kind: "scope", detail: ("plan file not touched: " + $p)}]')"
      done <<< "$PLAN_FILES"
    fi
    if [ -n "$DIFF_FILES" ]; then
      while IFS= read -r DF; do
        [ -n "$DF" ] || continue
        printf '%s\n' "$PLAN_FILES" | grep -qFx "$DF" \
          || INFO="$(printf '%s' "$INFO" | jq --arg p "$DF" '. + [{kind: "scope", detail: ("touched outside the plan: " + $p)}]')"
      done <<< "$DIFF_FILES"
    fi

    SECRETS_OUT="$("$HERE/git-checks.sh" secrets "$BASE" 2>/dev/null)" || true
    if [ -n "$SECRETS_OUT" ]; then
      BLOCKERS="$(printf '%s' "$BLOCKERS" | jq --arg d "$SECRETS_OUT" '. + [{kind: "secrets", detail: $d}]')"
    fi

    ACLEAK_OUT="$("$HERE/git-checks.sh" ac-leak "$BASE" 2>/dev/null)" || true
    if [ -n "$ACLEAK_OUT" ]; then
      BLOCKERS="$(printf '%s' "$BLOCKERS" | jq --arg d "$ACLEAK_OUT" '. + [{kind: "ac-leak", detail: $d}]')"
    fi

    RESULT_JSON="$(jq -n --argjson b "$BLOCKERS" --argjson i "$INFO" --argjson m "$MISSING" \
      '{blockers: $b, info: $i, missing: $m}')"
    printf '%s\n' "$RESULT_JSON"
    [ "$(printf '%s' "$BLOCKERS" | jq 'length')" -eq 0 ]
    ;;

  *)
    usage
    ;;
esac
