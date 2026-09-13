#!/usr/bin/env bash
# wk plugin: read-only git inspection helpers, one process per subcommand.
# Every command here only reads repo state; nothing here writes a commit,
# ref, or file (except phantoms/classify-diff/etc printing to stdout). For
# operations that rewrite history or revert commits, see git-ops.sh.

set -eu

usage() {
  cat >&2 <<EOF
Usage: git-checks.sh <command> [args...]

Commands:
  base-candidates                 {"current","candidates":[...]} branch names
  diff-files <base>               Union of changed files (tree+index+vs base)
  secrets <base>                  Lines added since <base> that look like a credential
  ac-leak <base>                  Added lines (excluding .doer/**) leaking an AC-N label
  squash-gate <base>               REPLAY/PROTOLOG markers still in the diff vs <base>
  trace <PROTOLOG|REPLAY>         Tracked + untracked lines still carrying the tag
  revert-in-progress              Whether a git revert is currently unresolved
  phantoms <base>                 Dirty files not explained by the diff vs <base>
  classify-diff <base>            "runtime" or "non-runtime" (path heuristic only)
  temp-rounds <PROTOLOG|REPLAY>   Count of "[TEMP] <TAG>" commits in history
  doer-history <base>             Commits since <base> that touch .doer/*
  pr-templates                    Known PR/MR template paths found in the repo

Exit: base-candidates/diff-files/phantoms/classify-diff/temp-rounds/
doer-history/pr-templates always exit 0 (an empty result is a valid answer).
secrets/ac-leak/squash-gate/trace/revert-in-progress exit 1 when they find
something, so callers can branch on the exit code alone.
EOF
  exit 2
}

[ $# -ge 1 ] || usage
command -v jq >/dev/null 2>&1 || { echo "git-checks.sh requires jq" >&2; exit 2; }

CMD="$1"; shift

case "$CMD" in
  base-candidates)
    # Only branches that actually exist locally, in priority order (upstream,
    # then develop/main/master), excluding the current branch and duplicates.
    CURRENT="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    UPSTREAM="${UPSTREAM#*/}"
    CANDS=""
    for b in "$UPSTREAM" develop main master; do
      [ -n "$b" ] || continue
      [ "$b" = "$CURRENT" ] && continue
      git show-ref --quiet "refs/heads/$b" 2>/dev/null && CANDS="${CANDS}${b}
"
    done
    CANDS="$(printf '%s' "$CANDS" | awk '!seen[$0]++')"
    jq -n --arg cur "$CURRENT" --arg cands "$CANDS" \
      '{current: $cur, candidates: (if $cands == "" then [] else ($cands | split("\n")) end)}'
    ;;

  diff-files)
    [ $# -ge 1 ] || usage
    BASE="$1"
    { git diff "$BASE"...HEAD --name-only 2>/dev/null
      git diff --name-only 2>/dev/null
      git diff --cached --name-only 2>/dev/null
    } | sed '/^$/d' | sort -u
    ;;

  secrets)
    [ $# -ge 1 ] || usage
    BASE="$1"
    MATCHES="$(git diff "$BASE"..HEAD 2>/dev/null \
      | grep -nEi '(api[_-]?key|secret|token|password|bearer|aws_)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{8,}' \
      || true)"
    [ -z "$MATCHES" ] && exit 0
    printf '%s\n' "$MATCHES"
    exit 1
    ;;

  ac-leak)
    [ $# -ge 1 ] || usage
    BASE="$1"
    MATCHES="$(git diff "$BASE"..HEAD -- . ':(exclude).doer/**' 2>/dev/null \
      | grep -E '^\+' | grep -E '\bAC-[0-9]+\b' || true)"
    [ -z "$MATCHES" ] && exit 0
    printf '%s\n' "$MATCHES"
    exit 1
    ;;

  squash-gate)
    [ $# -ge 1 ] || usage
    BASE="$1"
    MATCHES="$(git diff "$BASE"..HEAD 2>/dev/null \
      | grep -nE 'REPLAY START|REPLAY END|REPLAY-ORIG:|PROTOLOG_RESPONSE - |PROTOLOG - ' || true)"
    [ -z "$MATCHES" ] && exit 0
    printf '%s\n' "$MATCHES"
    exit 1
    ;;

  trace)
    [ $# -ge 1 ] || usage
    TAG="$1"
    case "$TAG" in
      PROTOLOG) PAT='PROTOLOG - ' ;;
      REPLAY) PAT='REPLAY START|REPLAY END|REPLAY-ORIG:|PROTOLOG_RESPONSE - ' ;;
      *) echo "git-checks.sh trace: unknown tag '$TAG' (want PROTOLOG or REPLAY)" >&2; exit 2 ;;
    esac
    TRACKED="$(git grep -nE "$PAT" 2>/dev/null || true)"
    # grep -rn over "." always prefixes matches with "./", unlike git grep;
    # strip it so the same tracked file's two results collapse under sort -u
    # instead of surviving as look-alike duplicates.
    UNTRACKED="$(grep -rnE "$PAT" . --include="*.kt" --include="*.java" \
      --include="*.swift" --include="*.ts" --include="*.tsx" \
      --include="*.js" --include="*.py" --include="*.go" \
      --include="*.rs" --include="*.rb" 2>/dev/null | sed 's|^\./||' || true)"
    OUT="$(printf '%s\n%s\n' "$TRACKED" "$UNTRACKED" | sed '/^$/d' | sort -u)"
    [ -z "$OUT" ] && exit 0
    printf '%s\n' "$OUT"
    exit 1
    ;;

  revert-in-progress)
    HEAD_MARK="$(git rev-parse -q --verify REVERT_HEAD 2>/dev/null || true)"
    CONFLICTS="$(git status --porcelain 2>/dev/null | grep -E '^(UU|AA|DD|AU|UA|DU|UD)' || true)"
    [ -z "$HEAD_MARK" ] && [ -z "$CONFLICTS" ] && exit 0
    [ -n "$HEAD_MARK" ] && echo "REVERT IN PROGRESS"
    [ -n "$CONFLICTS" ] && printf '%s\n' "$CONFLICTS"
    exit 1
    ;;

  phantoms)
    [ $# -ge 1 ] || usage
    BASE="$1"
    DIRTY="$({ git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null; } | sed '/^$/d' | sort -u)"
    INTENDED="$(git diff "$BASE"...HEAD --name-only 2>/dev/null | sed '/^$/d' | sort -u)"
    PHANTOMS="$(comm -23 <(printf '%s\n' "$DIRTY") <(printf '%s\n' "$INTENDED") 2>/dev/null | sed '/^$/d')"
    if [ -z "$PHANTOMS" ]; then
      echo '[]'
      exit 0
    fi
    ENTRIES=()
    while IFS= read -r f; do
      if git diff --quiet -- "$f" 2>/dev/null; then
        ENTRIES+=("$(jq -n --arg p "$f" '{path: $p, clean: true}')")
      else
        ENTRIES+=("$(jq -n --arg p "$f" '{path: $p, clean: false}')")
      fi
    done <<< "$PHANTOMS"
    printf '%s\n' "${ENTRIES[@]}" | jq -s '.'
    ;;

  classify-diff)
    # ponytail: path heuristic, never a skip decision
    [ $# -ge 1 ] || usage
    BASE="$1"
    FILES="$(git diff "$BASE"...HEAD --name-only 2>/dev/null)"
    if [ -z "$FILES" ]; then echo "non-runtime"; exit 0; fi
    while IFS= read -r f; do
      case "$f" in
        *.md|docs/*|.github/*|.gitlab*|*.lock|*lockfile*|*.lock.json) ;;
        *) echo "runtime"; exit 0 ;;
      esac
    done <<< "$FILES"
    echo "non-runtime"
    ;;

  temp-rounds)
    # ponytail: counts [TEMP] commits across all history, not just since the
    # last cleanup; matches the current prose behavior verbatim.
    [ $# -ge 1 ] || usage
    TAG="$1"
    git log --oneline --grep "\[TEMP\] $TAG" 2>/dev/null | wc -l | tr -d ' '
    ;;

  doer-history)
    [ $# -ge 1 ] || usage
    BASE="$1"
    git log --format=%H --diff-filter=ACMR -- '.doer/*' "$BASE..HEAD" 2>/dev/null
    ;;

  pr-templates)
    shopt -s nullglob
    MATCHES=(.github/PULL_REQUEST_TEMPLATE* .gitlab/merge_request_templates/* PULL_REQUEST_TEMPLATE*)
    shopt -u nullglob
    [ ${#MATCHES[@]} -gt 0 ] && printf '%s\n' "${MATCHES[@]}"
    exit 0
    ;;

  *)
    usage
    ;;
esac
