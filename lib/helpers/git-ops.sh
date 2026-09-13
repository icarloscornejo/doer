#!/usr/bin/env bash
# wk plugin: git operations that rewrite history or revert commits. Every
# command here is destructive or semi-destructive. squash and scrub-history
# always create a backup ref before touching anything, and print it BEFORE
# the risky part runs, so it stays communicated even if the rewrite itself
# fails partway through. For read-only inspection, see git-checks.sh.

set -eu

usage() {
  cat >&2 <<EOF
Usage: git-ops.sh <command> [args...]

Commands:
  squash <base> <ticket> <doer|bugfix>        Collapse commits since <base> into
                                                one; the commit message is read
                                                from stdin.
  scrub-history <base> <ticket> <doer|bugfix>  Strip .doer/ from history since
                                                <base>. Rewrites SHAs; caller
                                                confirms with the dev first.
  revert-temp <PROTOLOG|REPLAY>                Revert every "[TEMP] <TAG>"
                                                commit, most recent first,
                                                auto-aborting on conflict.
  restore-phantoms <base>                      git restore every clean phantom
                                                file (dirty but not part of the
                                                diff vs <base>); prints the
                                                ones left dirty for review.
EOF
  exit 2
}

[ $# -ge 1 ] || usage
CMD="$1"; shift

case "$CMD" in
  squash)
    [ $# -ge 3 ] || usage
    BASE="$1"; TICKET="$2"; KIND="$3"
    [ -z "$(git status --porcelain 2>/dev/null)" ] \
      || { echo "git-ops.sh squash: working tree is dirty, refusing" >&2; exit 1; }
    git merge-base --is-ancestor "$BASE" HEAD \
      || { echo "git-ops.sh squash: <base> is not an ancestor of HEAD, refusing" >&2; exit 1; }
    COUNT="$(git rev-list --count "$BASE"..HEAD)"
    if [ "$COUNT" -le 1 ]; then
      echo "SKIP: 1 commit"
      exit 0
    fi
    MSG="$(cat)"
    REF="refs/${KIND}-backup/${TICKET}-pre-squash-$(date +%s)"
    git update-ref "$REF" HEAD
    echo "BACKUP $REF"
    git reset --soft "$BASE"
    printf '%s' "$MSG" | git commit --no-verify -F -
    FINAL_COUNT="$(git rev-list --count "$BASE"..HEAD)"
    [ "$FINAL_COUNT" -eq 1 ] \
      || { echo "git-ops.sh squash: expected 1 commit after squash, got $FINAL_COUNT" >&2; exit 1; }
    ;;

  scrub-history)
    [ $# -ge 3 ] || usage
    BASE="$1"; TICKET="$2"; KIND="$3"
    REF="refs/${KIND}-backup/${TICKET}-pre-cleanup-$(date +%s)"
    git update-ref "$REF" HEAD
    echo "BACKUP $REF"
    BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    export FILTER_BRANCH_SQUELCH_WARNING=1
    git filter-branch -f --index-filter 'git rm -r --cached --ignore-unmatch .doer/' \
      --prune-empty "${BASE}..HEAD"
    git update-ref -d "refs/original/refs/heads/${BRANCH}" 2>/dev/null || true
    REMAINING="$(git log --format=%H --diff-filter=ACMR -- '.doer/*' "${BASE}..HEAD" 2>/dev/null)"
    [ -z "$REMAINING" ] \
      || { echo "git-ops.sh scrub-history: .doer/ still present after filter-branch" >&2; exit 1; }
    ;;

  revert-temp)
    [ $# -ge 1 ] || usage
    TAG="$1"
    SHAS="$(git log --format='%H %s' HEAD 2>/dev/null | grep "\[TEMP\] $TAG" | awk '{print $1}' || true)"
    if [ -z "$SHAS" ]; then
      echo "NONE"
      exit 0
    fi
    HAD_CONFLICT=0
    for sha in $SHAS; do
      if git revert --no-edit "$sha" >/dev/null 2>&1; then
        echo "REVERTED $sha"
      else
        git revert --abort 2>/dev/null || true
        if git rev-parse -q --verify REVERT_HEAD >/dev/null 2>&1; then
          echo "git-ops.sh revert-temp: REVERT_HEAD still set after abort for $sha, stop" >&2
          exit 2
        fi
        FILES="$(git show --name-only --format= "$sha" 2>/dev/null | tr '\n' ' ')"
        echo "CONFLICT $sha $FILES"
        HAD_CONFLICT=1
      fi
    done
    exit $HAD_CONFLICT
    ;;

  restore-phantoms)
    [ $# -ge 1 ] || usage
    BASE="$1"
    DIRTY="$({ git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null; } | sed '/^$/d' | sort -u)"
    INTENDED="$(git diff "$BASE"...HEAD --name-only 2>/dev/null | sed '/^$/d' | sort -u)"
    PHANTOMS="$(comm -23 <(printf '%s\n' "$DIRTY") <(printf '%s\n' "$INTENDED") 2>/dev/null | sed '/^$/d')"
    [ -n "$PHANTOMS" ] || exit 0
    while IFS= read -r f; do
      if git diff --quiet -- "$f" 2>/dev/null; then
        git restore -- "$f"
      else
        echo "$f"
      fi
    done <<< "$PHANTOMS"
    ;;

  *)
    usage
    ;;
esac
