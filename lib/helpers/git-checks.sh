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
  squash-gate <base>              file: line of every REPLAY/PROTOLOG marker ADDED since <base>
                                  (context lines, hunk headers and removed lines never count)
  trace <PROTOLOG|REPLAY>         Tracked + untracked lines still carrying the tag
  revert-in-progress              Whether a git revert is currently unresolved
  phantoms <base>                 Dirty files not explained by the diff vs <base>
  classify-diff <base>            "runtime" or "non-runtime" (path heuristic only)
  temp-rounds <PROTOLOG|REPLAY>   Count of "[TEMP] <TAG>" commits in history
  doer-history <base>             Commits since <base> that touch .doer/*
  pr-templates                    Known PR/MR template paths found in the repo
  weakened-tests <base>           TSV kind/file/line/text/deficit: removed or commented-out
                                  assertions, newly disabled tests, block-commented
                                  assertions, deleted tests (exit 2 on an unusable base)

Exit: base-candidates/pr-templates always exit 0 (an empty result is a valid answer: they
only list suggestions). diff-files/phantoms/classify-diff/temp-rounds/doer-history exit 0
with their result. secrets/ac-leak/squash-gate/trace/revert-in-progress/weakened-tests exit 1
when they find something, so callers can branch on the exit code alone.
Every command that takes a <base>, plus trace/revert-in-progress/temp-rounds, exits 2 on an
unusable base or a git error, never 0: an empty result must not hide a failed check.
EOF
  exit 2
}

[ $# -ge 1 ] || usage
command -v jq >/dev/null 2>&1 || { echo "git-checks.sh requires jq" >&2; exit 2; }

CMD="$1"; shift

# Pinned so the user's diff.* / color.* config can never change what a check parses.
GIT_FLAGS=(-c core.quotePath=false)
DIFF_FLAGS=(diff --no-ext-diff --no-textconv --no-color --src-prefix=a/ --dst-prefix=b/)

# A git failure is never an empty result: callers capture git output first,
# then parse it, and stop here when git itself failed.
fail_git() { echo "git-checks.sh $CMD: git failed" >&2; exit 2; }

# require_base <base>: the base must resolve to a commit that shares history with HEAD.
require_base() {
  if ! { git rev-parse --verify -q "${1}^{commit}" >/dev/null 2>&1 \
         && git merge-base "$1" HEAD >/dev/null 2>&1; }; then
    echo "git-checks.sh $CMD: unusable base '$1'" >&2
    exit 2
  fi
}

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
    require_base "$BASE"
    RANGE_FILES="$(git diff "$BASE"...HEAD --name-only)" || fail_git
    WORK_FILES="$(git diff --name-only)" || fail_git
    INDEX_FILES="$(git diff --cached --name-only)" || fail_git
    printf '%s\n%s\n%s\n' "$RANGE_FILES" "$WORK_FILES" "$INDEX_FILES" | sed '/^$/d' | sort -u
    ;;

  secrets)
    [ $# -ge 1 ] || usage
    BASE="$1"
    require_base "$BASE"
    DIFF_TEXT="$(git "${GIT_FLAGS[@]}" "${DIFF_FLAGS[@]}" "$BASE"..HEAD)" || fail_git
    MATCHES="$(printf '%s\n' "$DIFF_TEXT" \
      | grep -nEi '(api[_-]?key|secret|token|password|bearer|aws_)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{8,}' \
      || true)"
    [ -z "$MATCHES" ] && exit 0
    printf '%s\n' "$MATCHES"
    exit 1
    ;;

  ac-leak)
    [ $# -ge 1 ] || usage
    BASE="$1"
    require_base "$BASE"
    DIFF_TEXT="$(git "${GIT_FLAGS[@]}" "${DIFF_FLAGS[@]}" "$BASE"..HEAD -- . ':(exclude).doer/**')" || fail_git
    MATCHES="$(printf '%s\n' "$DIFF_TEXT" | grep -E '^\+' | grep -E '\bAC-[0-9]+\b' || true)"
    [ -z "$MATCHES" ] && exit 0
    printf '%s\n' "$MATCHES"
    exit 1
    ;;

  squash-gate)
    [ $# -ge 1 ] || usage
    BASE="$1"
    require_base "$BASE"
    DIFF_TEXT="$(git "${GIT_FLAGS[@]}" "${DIFF_FLAGS[@]}" "$BASE"..HEAD)" || fail_git
    # Only lines ADDED by the branch count. A header line (+++) is recognised only
    # before the first @@ of a file, so an added line that itself starts with "++"
    # is content; context lines, hunk headers (@@ ... @@ <function context>) and
    # removed lines are never searched.
    MATCHES="$(printf '%s\n' "$DIFF_TEXT" | awk '
      /^diff --git / { in_hunk = 0; path = ""; next }
      !in_hunk && /^\+\+\+ / { path = substr($0, 7); sub(/\t.*$/, "", path); next }
      /^@@/ { in_hunk = 1; next }
      in_hunk && /^\+/ {
        added = substr($0, 2)
        if (added ~ /REPLAY START|REPLAY END|REPLAY-ORIG:|PROTOLOG_RESPONSE - |PROTOLOG - /) print path ": " added
      }')"
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
    # git grep: exit 1 = no match; anything above 1 (or not a repo) is a failed check.
    TRACKED_RC=0
    TRACKED="$(git grep -nE "$PAT")" || TRACKED_RC=$?
    [ "$TRACKED_RC" -le 1 ] || fail_git
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
    STATUS_TEXT="$(git status --porcelain)" || fail_git
    CONFLICTS="$(printf '%s\n' "$STATUS_TEXT" | grep -E '^(UU|AA|DD|AU|UA|DU|UD)' || true)"
    [ -z "$HEAD_MARK" ] && [ -z "$CONFLICTS" ] && exit 0
    [ -n "$HEAD_MARK" ] && echo "REVERT IN PROGRESS"
    [ -n "$CONFLICTS" ] && printf '%s\n' "$CONFLICTS"
    exit 1
    ;;

  phantoms)
    [ $# -ge 1 ] || usage
    BASE="$1"
    require_base "$BASE"
    WORK_FILES="$(git diff --name-only)" || fail_git
    INDEX_FILES="$(git diff --cached --name-only)" || fail_git
    RANGE_FILES="$(git diff "$BASE"...HEAD --name-only)" || fail_git
    DIRTY="$(printf '%s\n%s\n' "$WORK_FILES" "$INDEX_FILES" | sed '/^$/d' | sort -u)"
    INTENDED="$(printf '%s\n' "$RANGE_FILES" | sed '/^$/d' | sort -u)"
    PHANTOMS="$(comm -23 <(printf '%s\n' "$DIRTY") <(printf '%s\n' "$INTENDED") | sed '/^$/d')"
    if [ -z "$PHANTOMS" ]; then
      echo '[]'
      exit 0
    fi
    ENTRIES=()
    while IFS= read -r f; do
      # git diff --quiet: 0 = no unstaged change, 1 = changed, anything else = git failed.
      QUIET_RC=0
      git diff --quiet -- "$f" || QUIET_RC=$?
      case "$QUIET_RC" in
        0) ENTRIES+=("$(jq -n --arg p "$f" '{path: $p, clean: true}')") ;;
        1) ENTRIES+=("$(jq -n --arg p "$f" '{path: $p, clean: false}')") ;;
        *) fail_git ;;
      esac
    done <<< "$PHANTOMS"
    printf '%s\n' "${ENTRIES[@]}" | jq -s '.'
    ;;

  classify-diff)
    # ponytail: path heuristic, never a skip decision
    [ $# -ge 1 ] || usage
    BASE="$1"
    require_base "$BASE"
    FILES="$(git diff "$BASE"...HEAD --name-only)" || fail_git
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
    TEMP_LOG="$(git log --oneline --no-color --grep "\[TEMP\] $TAG")" || fail_git
    printf '%s\n' "$TEMP_LOG" | sed '/^$/d' | wc -l | tr -d ' '
    ;;

  doer-history)
    [ $# -ge 1 ] || usage
    BASE="$1"
    require_base "$BASE"
    # The range comes before "--": after it git reads it as a path and lists
    # every .doer commit in the whole history.
    DOER_LOG="$(git log --no-color --format=%H --diff-filter=ACMR "$BASE..HEAD" -- '.doer/*')" || fail_git
    [ -z "$DOER_LOG" ] || printf '%s\n' "$DOER_LOG"
    ;;

  pr-templates)
    shopt -s nullglob
    MATCHES=(.github/PULL_REQUEST_TEMPLATE* .gitlab/merge_request_templates/* PULL_REQUEST_TEMPLATE*)
    shopt -u nullglob
    [ ${#MATCHES[@]} -gt 0 ] && printf '%s\n' "${MATCHES[@]}"
    exit 0
    ;;

  weakened-tests)
    # ponytail: regex heuristics, so exotic frameworks and semantic weakening
    # (a strong assertion swapped for a weak one) stay with the reviewer.
    # Extend the name lists in the awk BEGIN block for new frameworks.
    # ponytail: known ceilings: bare Python `assert x == y` without parentheses is not
    # matched, triple-quote wrapping is not seen, openers not at line start are missed,
    # and the global multiset cancel can hide a swap between unrelated test files.
    [ $# -ge 1 ] || usage
    BASE="$1"
    require_base "$BASE"
    # Flags are pinned so user diff.* config can never change the result.
    GIT_FLAGS=(-c core.quotePath=false -c diff.renames=true)
    DIFF_FLAGS=(diff --no-ext-diff --no-textconv --no-color -M --src-prefix=a/ --dst-prefix=b/)
    RANGE=("$BASE...HEAD" -- . ':(exclude).doer/**')
    # One stream: name-status tokens (one per line), a separator, then the diff.
    # Captured first so a git failure exits 2 instead of feeding awk empty input.
    NAME_STATUS="$(git "${GIT_FLAGS[@]}" "${DIFF_FLAGS[@]}" --name-status -z "${RANGE[@]}" | tr '\0' '\n'; exit "${PIPESTATUS[0]}")" || {
      echo "git-checks.sh weakened-tests: git diff failed" >&2; exit 2; }
    DIFF_BODY="$(git "${GIT_FLAGS[@]}" "${DIFF_FLAGS[@]}" -U0 "${RANGE[@]}")" || {
      echo "git-checks.sh weakened-tests: git diff failed" >&2; exit 2; }
    MATCHES="$({
      printf '%s\n' "$NAME_STATUS"
      echo '@@@@SPLIT'
      printf '%s\n' "$DIFF_BODY"
    } | awk '
      BEGIN {
        NB = "[^A-Za-z0-9_]"
        AREG = "(^|" NB ")(assert[A-Za-z0-9_]*|assert\\.[A-Za-z]+|expect[A-Za-z0-9_]*|verify[A-Za-z0-9_]*|coVerify[A-Za-z0-9_]*|XCTAssert[A-Za-z0-9_]*|#expect|#require)(<[^>]*>)?!?[ ]*[({]"
        DB = "(^|[^A-Za-z0-9_$.])"
        D_ANN = "@(Ignore|Disabled)(" NB "|$)"
        D_X = DB "(xit|xdescribe|xtest)\\("
        D_SKIP = DB "(it|test|describe|context|suite)(\\.(describe|concurrent|serial|parallel))*\\.skip[(.]"
        D_THIS = DB "this\\.skip\\("
        D_XCT = DB "XCTSkip(If|Unless)?(" NB "|$)"
      }
      function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
      function shq(s) { gsub(/\047/, "\047\\\047\047", s); return "\047" s "\047" }
      function out(kind, f, l, t, d) { gsub(/\t/, " ", t); printf "%s\t%s\t%s\t%s\t%s\n", kind, f, l, t, d }
      function istest(p) {
        if (p !~ /\.(kt|java|swift|ts|tsx|js|jsx|py|go)$/) return 0
        if (p ~ /(^|\/)(test|tests|__tests__|spec|specs)\//) return 1
        if (p ~ /(Test|Tests|Spec|IT)\.(kt|java|swift|ts|tsx|js|jsx)$/) return 1
        if (p ~ /\.(test|spec)\.(ts|tsx|js|jsx)$/) return 1
        if (p ~ /(^|\/)test_[^\/]*\.py$/ || p ~ /_test\.py$/ || p ~ /_test\.go$/) return 1
        return 0
      }
      function iscomment(t, p) {
        if (t ~ /^(\/\/|\/\*|\*)/) return 1
        if (t ~ /^#([ \t]|$)/) return 1
        return (p ~ /\.(py|sh)$/ && t ~ /^#/)
      }
      function isassert(t, p) { return !iscomment(t, p) && t ~ AREG }
      function isdis(t, p) {
        if (iscomment(t, p)) return 0
        if (t ~ D_ANN || t ~ D_X || t ~ D_SKIP || t ~ D_THIS || t ~ D_XCT) return 1
        return (p ~ /\.swift$/ && t ~ /\.disabled\(/ && (t ~ /@Test\(/ || t ~ /@Suite\(/))
      }
      function hpath(s) { sub(/\t.*$/, "", s); return (s == "/dev/null") ? s : substr(s, 3) }
      function removed(ln, body,   t, f) {
        f = key
        if (!istest(f)) return
        t = trim(body)
        if (isdis(t, f)) mk[t]++
        if (st[f] == "D") return
        if (isassert(t, f)) { nrm++; rf[nrm] = f; rt[nrm] = t; rl[nrm] = ln; remAT[t]++ }
      }
      function added(ln, body,   t, f) {
        f = key
        if (st[f] == "D" || !istest(f)) return
        t = trim(body)
        addedAt[f, ln] = 1
        if (isassert(t, f)) { nad++; af[nad] = f; atx[nad] = t; addAT[t]++ }
        if (isdis(t, f)) { ndis++; df[ndis] = f; dt[ndis] = t; dl[ndis] = ln }
        if (t ~ /^\/\*/ && t !~ /^\/\*\*/ && t !~ /\*\//) { nb++; bf[nb] = f; bl[nb] = ln; bt[nb] = t }
      }
      # True when pre-existing assertion lines sit between the opener and its closer in HEAD.
      function wraps(f, start,   cmd, raw, n, found) {
        cmd = "git show HEAD:" shq(f) " 2>/dev/null"
        while ((cmd | getline raw) > 0) {
          n++
          if (n <= start) continue
          if (isassert(trim(raw), f) && !((f, n) in addedAt)) found = 1
          if (index(raw, "*/")) break
        }
        close(cmd)
        return found
      }
      phase == 0 {
        if ($0 == "@@@@SPLIT") { phase = 1; next }
        if (pend == 0) { stat = $0; pend = (stat ~ /^[RC]/) ? 2 : 1; np = 0; next }
        pth[++np] = $0
        if (--pend == 0) {
          if (stat == "D") { st[pth[1]] = "D"; dels[++nd] = pth[1] }
          else if (stat ~ /^R/) { ron[++nren] = pth[1]; rnn[nren] = pth[2] }
        }
        next
      }
      ro > 0 || rn > 0 {
        c = substr($0, 1, 1)
        if (c == "-") { ro--; removed(oldno++, substr($0, 2)) }
        else if (c == "+") { rn--; added(newno++, substr($0, 2)) }
        next
      }
      /^diff --git / { key = ""; oldp = ""; next }
      /^--- / { oldp = hpath(substr($0, 5)); next }
      /^\+\+\+ / { newp = hpath(substr($0, 5)); key = (newp == "/dev/null") ? oldp : newp; next }
      /^@@ / {
        split($2, o, ","); split($3, n, ",")
        oldno = substr(o[1], 2) + 0; ro = (o[2] == "") ? 1 : o[2] + 0
        newno = substr(n[1], 2) + 0; rn = (n[2] == "") ? 1 : n[2] + 0
        next
      }
      END {
        for (i = 1; i <= nd; i++) if (istest(dels[i])) out("deleted-test", dels[i], 0, "test file deleted", 0)
        for (i = 1; i <= nren; i++)
          if (istest(ron[i]) && !istest(rnn[i])) out("deleted-test", ron[i], 0, "test file renamed to a non-test path", 0)
        # Cancel identical removed/added assertions anywhere in the diff (moves, splits).
        for (t in remAT) { cr[t] = (remAT[t] < addAT[t]) ? remAT[t] : addAT[t]; ca[t] = cr[t] }
        for (i = 1; i <= nrm; i++) {
          if (cr[rt[i]] > 0) { cr[rt[i]]--; keep[i] = 0 } else { keep[i] = 1; left[rf[i]]++ }
        }
        for (j = 1; j <= nad; j++) { if (ca[atx[j]] > 0) ca[atx[j]]--; else gain[af[j]]++ }
        for (i = 1; i <= nrm; i++) {
          deficit = left[rf[i]] - gain[rf[i]]
          if (keep[i] && deficit > 0) out("removed-assertion", rf[i], rl[i], rt[i], deficit)
        }
        for (k = 1; k <= ndis; k++) {
          if (mk[dt[k]] > 0) mk[dt[k]]--; else out("disabled", df[k], dl[k], dt[k], 0)
        }
        for (k = 1; k <= nb; k++) if (wraps(bf[k], bl[k])) { okb[k] = 1; cntb[bf[k]]++ }
        for (k = 1; k <= nb; k++) if (okb[k]) out("block-commented", bf[k], bl[k], bt[k], cntb[bf[k]])
      }
    ')"
    [ -z "$MATCHES" ] && exit 0
    printf '%s\n' "$MATCHES"
    exit 1
    ;;

  *)
    usage
    ;;
esac
