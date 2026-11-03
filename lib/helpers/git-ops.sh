#!/usr/bin/env bash
# wk plugin: git operations that rewrite history or revert commits. Every
# command here is destructive or semi-destructive. squash and scrub-history
# always create a backup ref before touching anything, and print it BEFORE
# the risky part runs, so it stays communicated even if the rewrite itself
# fails partway through. For read-only inspection, see git-checks.sh.
#
# Exit codes: 0 done, 1 refused for a stated reason (dirty tree, base is not an
# ancestor, conflicts, a leftover after the rewrite), 2 an unusable <base> or a
# git error. A git error is never read as an empty result: every git command
# whose output or status decides something is captured or checked, and the few
# places that stay open on purpose carry a "fail-open ok" comment saying why.

set -eu

# The caller's environment must not change what a pathspec means.
unset GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS

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
                                                Refuses (exit 1, no BACKUP line)
                                                when the working tree is dirty.
  revert-temp <PROTOLOG|REPLAY>                Revert every "[TEMP] <TAG>"
                                                commit, most recent first,
                                                auto-aborting on conflict.
                                                Refuses (exit 2) when a revert
                                                is already in progress.
  restore-phantoms <base>                      git restore every clean phantom
                                                file (dirty but not part of the
                                                diff vs <base>); prints the
                                                ones left dirty for review.

Exit: 0 done, 1 refused for a stated reason, 2 unusable <base> or git error.
EOF
  exit 2
}

[ $# -ge 1 ] || usage
CMD="$1"; shift

# A git failure is never an empty result: callers capture git output first,
# then parse it, and stop here when git itself failed.
fail_git() { echo "git-ops.sh $CMD: git failed" >&2; exit 2; }

# fail_after_backup <what>: a git step failed after the backup ref was printed.
fail_after_backup() {
  echo "git-ops.sh $CMD: git $1 failed; the backup is $BACKUP_REF (rollback: git reset --hard $BACKUP_REF)" >&2
  exit 2
}

# require_base <base>: the base must resolve to a commit that shares history with HEAD.
require_base() {
  COMMIT_RC=0
  git rev-parse --verify -q "${1}^{commit}" >/dev/null 2>&1 || COMMIT_RC=$?
  SHARED_RC=0
  git merge-base "$1" HEAD >/dev/null 2>&1 || SHARED_RC=$?
  if [ "$COMMIT_RC" -ne 0 ] || [ "$SHARED_RC" -ne 0 ]; then
    echo "git-ops.sh $CMD: unusable base '$1'" >&2
    exit 2
  fi
}

# top_level: every path below is root-relative, so work from the repo root.
top_level() {
  TOP="$(git rev-parse --show-toplevel)" || fail_git
  cd "$TOP" || fail_git
}

# require_clean_tree: refuse (exit 1) on any change, exit 2 when git cannot say.
require_clean_tree() {
  STATUS_TEXT="$(git status --porcelain)" || fail_git
  [ -z "$STATUS_TEXT" ] \
    || { echo "git-ops.sh $CMD: working tree is dirty, refusing" >&2; exit 1; }
}

# The platform's own attribution guidance nudges the model to append a
# Co-Authored-By trailer to every commit; the dev never wants that on a
# squash. git accepts whitespace before the trailer's colon, so match that
# too, not just the exact "key:" form.
# fail-open ok: grep -v exits 1 when nothing is left; this is not a git command.
strip_coauthor() { grep -viE '^co-authored-by[[:space:]]*:' || true; }
has_coauthor()   { grep -qiE '^co-authored-by[[:space:]]*:'; }

case "$CMD" in
  squash)
    [ $# -ge 3 ] || usage
    BASE="$1"; TICKET="$2"; KIND="$3"
    require_base "$BASE"
    require_clean_tree
    # 0 = ancestor, 1 = not an ancestor (refuse), anything else = git error.
    ANCESTOR_RC=0
    git merge-base --is-ancestor "$BASE" HEAD || ANCESTOR_RC=$?
    case "$ANCESTOR_RC" in
      0) ;;
      1) echo "git-ops.sh squash: <base> is not an ancestor of HEAD, refusing" >&2; exit 1 ;;
      *) fail_git ;;
    esac
    MSG="$(cat)"
    HAD_TRAILER=0
    printf '%s\n' "$MSG" | has_coauthor && HAD_TRAILER=1
    STRIPPED_MSG="$(printf '%s\n' "$MSG" | strip_coauthor)"
    CLEAN_MSG="$(printf '%s\n' "$STRIPPED_MSG" | git stripspace)" || fail_git
    [ -n "$CLEAN_MSG" ] \
      || { echo "git-ops.sh squash: empty commit message after stripping" >&2; exit 1; }
    [ "$HAD_TRAILER" -eq 0 ] || echo "STRIPPED Co-Authored-By trailer"
    COUNT="$(git rev-list --count "$BASE"..HEAD)" || fail_git
    if [ "$COUNT" -eq 0 ]; then
      echo "SKIP: 1 commit"
      exit 0
    fi
    if [ "$COUNT" -eq 1 ]; then
      LAST_MSG="$(git log -1 --format=%B)" || fail_git
      if printf '%s\n' "$LAST_MSG" | has_coauthor; then
        BACKUP_REF="refs/${KIND}-backup/${TICKET}-pre-squash-$(date +%s)"
        git update-ref "$BACKUP_REF" HEAD || fail_git
        echo "BACKUP $BACKUP_REF"
        LAST_STRIPPED="$(printf '%s\n' "$LAST_MSG" | strip_coauthor)"
        AMEND_MSG="$(printf '%s\n' "$LAST_STRIPPED" | git stripspace)" || fail_after_backup stripspace
        printf '%s\n' "$AMEND_MSG" | git commit --amend --no-verify -F - || fail_after_backup "commit --amend"
        echo "STRIPPED Co-Authored-By trailer"
        AMENDED_MSG="$(git log -1 --format=%B)" || fail_after_backup log
        printf '%s\n' "$AMENDED_MSG" | has_coauthor \
          && { echo "git-ops.sh squash: Co-Authored-By trailer survived the commit" >&2; exit 1; }
      fi
      echo "SKIP: 1 commit"
      exit 0
    fi
    BACKUP_REF="refs/${KIND}-backup/${TICKET}-pre-squash-$(date +%s)"
    git update-ref "$BACKUP_REF" HEAD || fail_git
    echo "BACKUP $BACKUP_REF"
    git reset --soft "$BASE" || fail_after_backup reset
    printf '%s' "$CLEAN_MSG" | git commit --no-verify -F - || fail_after_backup commit
    SQUASHED_MSG="$(git log -1 --format=%B)" || fail_after_backup log
    printf '%s\n' "$SQUASHED_MSG" | has_coauthor \
      && { echo "git-ops.sh squash: Co-Authored-By trailer survived the commit" >&2; exit 1; }
    FINAL_COUNT="$(git rev-list --count "$BASE"..HEAD)" || fail_after_backup rev-list
    [ "$FINAL_COUNT" -eq 1 ] \
      || { echo "git-ops.sh squash: expected 1 commit after squash, got $FINAL_COUNT" >&2; exit 1; }
    ;;

  scrub-history)
    [ $# -ge 3 ] || usage
    BASE="$1"; TICKET="$2"; KIND="$3"
    require_base "$BASE"
    # Nothing uncommitted may be at risk: refuse before the backup ref exists.
    require_clean_tree
    BACKUP_REF="refs/${KIND}-backup/${TICKET}-pre-cleanup-$(date +%s)"
    git update-ref "$BACKUP_REF" HEAD || fail_git
    echo "BACKUP $BACKUP_REF"
    BRANCH="$(git rev-parse --abbrev-ref HEAD)" || fail_after_backup rev-parse
    export FILTER_BRANCH_SQUELCH_WARNING=1
    git filter-branch -f --index-filter 'git rm -r --cached --ignore-unmatch .doer/' \
      --prune-empty "${BASE}..HEAD" || fail_after_backup filter-branch
    # fail-open ok: only drops the refs/original backup git leaves behind, which may not exist.
    git update-ref -d "refs/original/refs/heads/${BRANCH}" 2>/dev/null || true
    # The range comes before "--" (after it git reads it as a path), and a git
    # failure here must not read as "verified clean".
    REMAINING="$(git log --no-color --format=%H --diff-filter=ACMR "${BASE}..HEAD" -- '.doer/*')" \
      || fail_after_backup log
    [ -z "$REMAINING" ] \
      || { echo "git-ops.sh scrub-history: .doer/ still present after filter-branch" >&2; exit 1; }
    ;;

  revert-temp)
    [ $# -ge 1 ] || usage
    TAG="$1"
    # A revert the dev started is not ours to abort: refuse while one is in progress.
    PENDING_RC=0
    git rev-parse -q --verify REVERT_HEAD >/dev/null 2>&1 || PENDING_RC=$?
    case "$PENDING_RC" in
      0) echo "git-ops.sh revert-temp: a revert is already in progress, resolve or abort it first" >&2; exit 2 ;;
      1) ;;
      *) fail_git ;;
    esac
    LOG_TEXT="$(git log --format='%H %s' HEAD)" || fail_git
    SHAS="$(printf '%s\n' "$LOG_TEXT" | grep "\[TEMP\] $TAG" | awk '{print $1}')" || true  # fail-open ok: grep exits 1 when no commit matches
    if [ -z "$SHAS" ]; then
      echo "NONE"
      exit 0
    fi
    HAD_CONFLICT=0
    for sha in $SHAS; do
      if git revert --no-edit "$sha" >/dev/null 2>&1; then
        echo "REVERTED $sha"
      else
        # A failed revert is a conflict only when it left REVERT_HEAD behind.
        CONFLICT_RC=0
        git rev-parse -q --verify REVERT_HEAD >/dev/null 2>&1 || CONFLICT_RC=$?
        case "$CONFLICT_RC" in
          0) ;;
          1) echo "git-ops.sh revert-temp: git revert failed for $sha without a conflict" >&2; exit 2 ;;
          *) fail_git ;;
        esac
        # fail-open ok: whether the abort worked is decided by the REVERT_HEAD check right after it.
        git revert --abort >/dev/null 2>&1 || true
        AFTER_RC=0
        git rev-parse -q --verify REVERT_HEAD >/dev/null 2>&1 || AFTER_RC=$?
        case "$AFTER_RC" in
          0) echo "git-ops.sh revert-temp: REVERT_HEAD still set after abort for $sha, stop" >&2; exit 2 ;;
          1) ;;
          *) fail_git ;;
        esac
        FILES_TEXT="$(git show --name-only --format= "$sha")" || fail_git
        FILES="$(printf '%s\n' "$FILES_TEXT" | tr '\n' ' ')"
        echo "CONFLICT $sha $FILES"
        HAD_CONFLICT=1
      fi
    done
    exit $HAD_CONFLICT
    ;;

  restore-phantoms)
    [ $# -ge 1 ] || usage
    BASE="$1"
    top_level
    require_base "$BASE"
    # Phase 1 changes nothing: capture everything, classify every phantom.
    WORK_FILES="$(git diff --name-only)" || fail_git
    INDEX_FILES="$(git diff --cached --name-only)" || fail_git
    RANGE_FILES="$(git diff "$BASE"...HEAD --name-only)" || fail_git
    DIRTY="$(printf '%s\n%s\n' "$WORK_FILES" "$INDEX_FILES" | sed '/^$/d' | sort -u)"
    INTENDED="$(printf '%s\n' "$RANGE_FILES" | sed '/^$/d' | sort -u)"
    PHANTOMS="$(comm -23 <(printf '%s\n' "$DIRTY") <(printf '%s\n' "$INTENDED") | sed '/^$/d')"
    [ -n "$PHANTOMS" ] || exit 0
    CLEAN=()
    DIRTY_LIST=()
    while IFS= read -r f; do
      # git diff --quiet: 0 = no unstaged change, 1 = changed, anything else = git failed.
      QUIET_RC=0
      git diff --quiet -- ":(literal)$f" || QUIET_RC=$?
      case "$QUIET_RC" in
        0) CLEAN+=("$f") ;;
        1) DIRTY_LIST+=("$f") ;;
        *) fail_git ;;
      esac
    done <<< "$PHANTOMS"
    # Phase 2: revalidate right before the one restore, then restore in a single call.
    if [ "${#CLEAN[@]}" -gt 0 ]; then
      RESTORE_ARGS=()
      for f in "${CLEAN[@]}"; do
        QUIET_RC=0
        git diff --quiet -- ":(literal)$f" || QUIET_RC=$?
        case "$QUIET_RC" in
          0) RESTORE_ARGS+=(":(literal)$f") ;;
          1) echo "git-ops.sh restore-phantoms: $f changed while it was being classified, nothing restored" >&2; exit 2 ;;
          *) fail_git ;;
        esac
      done
      git restore -- "${RESTORE_ARGS[@]}" \
        || { echo "git-ops.sh restore-phantoms: git restore failed, nothing else was touched" >&2; exit 2; }
    fi
    if [ "${#DIRTY_LIST[@]}" -gt 0 ]; then
      printf '%s\n' "${DIRTY_LIST[@]}"
    fi
    ;;

  *)
    usage
    ;;
esac
