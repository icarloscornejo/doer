#!/usr/bin/env bash
# wk plugin: run a command (normally a repo's test suite) and print a bounded,
# redacted summary instead of its raw output, so the orchestrator's context is
# not flooded by tens of KB of passing tests.
#
# Usage: bounded.sh run [--timeout SECONDS] -- <command...>
#   Production form: bounded.sh run --timeout 540 -- sh -c '<command>'
#   The command runs in the CURRENT directory (like stage-checks.sh pre-review);
#   the git toplevel is only the read boundary for .env files and the home of
#   the temporary log and of .doer/bounded-fails.txt.
#
# Output (header lines are built here and never redacted; everything taken from
# the command's output is redacted as a whole line BEFORE any cut):
#   BOUNDED RUN / status: ok|failed|timeout|error / exit: <code or none> /
#   lines: <n> / counts: passed=<n> failed=<n> or unparsed / fails: <n> or
#   unparsed (or the two cut forms naming .doer/bounded-fails.txt) / up to 3
#   "results:" lines + "results total: passed=<sum>" / "env: skipped <n>
#   file(s) (outside worktree)" when n > 0 / FAIL section / raw tail.
#   FAIL line: ^FAIL(ED)? or ends in " FAILED"; each is followed by up to 5
#   non-blank non-PASS/FAIL lines (the window stops at the next PASS or FAIL).
#   Budget: total <= 27,000 chars, FAIL section <= 16,000, header/results/tail
#   lines cut at 200, FAIL and error lines at 400 (300 head + 70 tail joined by
#   " ...[+N]... "). .doer/bounded-fails.txt keeps every FAIL line and its
#   error lines uncut (redacted only) whenever fails > 0.
#
# Status: ok only when exit 0 and zero FAIL lines. Exit 0 with FAIL lines, or a
# non-zero exit, is failed. timeout is decided by a marker the watchdog writes.
# error means the command could not be executed (never green).
# Exit codes: 0 only for ok, 1 for any other status, 2 when it cannot start.
#
# Redaction: values (3+ chars) and "KEY=value" texts from every .env* file in
# the worktree (only .git is skipped; the walk costs time in big trees), as
# fixed strings; values of inherited env vars named like a secret (6+ chars);
# keyword=value and bearer patterns. Arbitrary secrets in other files or under
# other names cannot be detected, and a non-secret value that collides with
# test text shows as [REDACTED]. If redaction fails nothing from the log is
# printed and the status is error.
#
# Known limits and assumptions: SIGKILL of this helper runs no trap, so the
# suite (its own process group) keeps running. Harness assumptions: the Bash
# tool cuts very large output, so the 27,000 budget sits under it; the Bash
# tool maximum timeout is 600000 ms, so the default --timeout is 540.
# bash 3.2 compatible (the macOS system shell).

set -u

usage() {
  echo "Usage: bounded.sh run [--timeout SECONDS] -- <command...>" >&2
  exit 2
}

[ "${1:-}" = "run" ] || usage
shift
TIMEOUT=540
if [ "${1:-}" = "--timeout" ]; then
  [ $# -ge 2 ] || usage
  TIMEOUT="$2"
  shift 2
fi
case "$TIMEOUT" in ''|*[!0-9]*|0) echo "bounded.sh: --timeout needs a positive integer" >&2; exit 2 ;; esac
[ "${1:-}" = "--" ] || usage
shift
[ $# -ge 1 ] || usage
command -v perl >/dev/null 2>&1 || { echo "bounded.sh requires perl" >&2; exit 2; }
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "bounded.sh: not inside a git repository" >&2; exit 2; }
TOP="$(cd "$TOP" && pwd -P)"
mkdir -p "$TOP/.doer" || { echo "bounded.sh: cannot create $TOP/.doer" >&2; exit 2; }
WORK="$(mktemp -d "$TOP/.doer/bounded-run.XXXXXX")" || { echo "bounded.sh: cannot create a temp dir" >&2; exit 2; }
FAILS_REL=".doer/bounded-fails.txt"
FAILS_FILE="$TOP/$FAILS_REL"
rm -f "$FAILS_FILE"

LOG="$WORK/log"
MARK="$WORK/timeout"
CHILD=""
WATCHDOG=""
KILL_GROUP=0

# TERM, then KILL if the group is still there after about 2 s.
kill_group() {
  local tries=0
  kill -s TERM -- "-$CHILD" 2>/dev/null
  while kill -0 -- "-$CHILD" 2>/dev/null && [ "$tries" -lt 20 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  kill -s KILL -- "-$CHILD" 2>/dev/null
  return 0
}
cleanup() {
  # pkill first: the watchdog only acts when its sleep ends normally
  if [ -n "$WATCHDOG" ]; then
    pkill -P "$WATCHDOG" 2>/dev/null
    kill "$WATCHDOG" 2>/dev/null
  fi
  if [ "$KILL_GROUP" = 1 ] && [ -n "$CHILD" ]; then kill_group; fi
  rm -rf "$WORK"
}
on_signal() { KILL_GROUP=1; exit "$1"; }
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

RC=""
STATUS=""
if ! command -v "$1" >/dev/null 2>&1; then
  printf 'bounded.sh: cannot execute %s: command not found\n' "$1" > "$LOG"
  STATUS="error"
else
  # setpgrp gives the suite its own group so one signal reaches its grandchildren;
  # a failed exec exits 127 instead of reading as success
  perl -e 'setpgrp(0,0); exec { $ARGV[0] } @ARGV or exit 127' -- "$@" > "$LOG" 2>&1 &
  CHILD=$!
  ( sleep "$TIMEOUT" && { : > "$MARK"; kill -s TERM -- "-$CHILD"; sleep 2; kill -s KILL -- "-$CHILD"; } ) > /dev/null 2>&1 &
  WATCHDOG=$!
  { wait "$CHILD"; RC=$?; } 2>/dev/null
  if [ -e "$MARK" ]; then STATUS="timeout"; KILL_GROUP=1; kill_group; fi
fi

# Everything below handles the command's text, byte-safe and locale-independent.
export LC_ALL=C

SECRETS="$WORK/secrets"
CLEAN="$WORK/clean"
tr -d '\000' < "$LOG" > "$CLEAN"

build_secrets() {
  local name value found skipped path
  : > "$WORK/envfiles"
  found="$(find "$TOP" -name .git -prune -o -name '.env*' \( -type f -o -type l \) -print 2>/dev/null \
    | perl -MCwd=realpath -e '$top = shift; while (<STDIN>) { chomp; next if /\.(example|sample|template)$/; $r = realpath($_); if (defined $r && -f $r && index($r, "$top/") == 0) { print "OK\t$r\n" } else { print "SKIP\n" } }' "$TOP")" || return 1
  skipped="$(printf '%s\n' "$found" | grep -c '^SKIP')"
  ENV_SKIPPED="${skipped:-0}"
  {
    printf '%s\n' "$found" | grep '^OK' | cut -f2- | while IFS= read -r path; do cat -- "$path"; echo; done \
      | awk '{
          line = $0; sub(/\r$/, "", line); sub(/^[ \t]+/, "", line)
          if (line ~ /^#/) next
          sub(/^export[ \t]+/, "", line)
          eq = index(line, "="); if (eq < 2) next
          key = substr(line, 1, eq - 1); if (key !~ /^[A-Za-z_][A-Za-z0-9_]*$/) next
          value = substr(line, eq + 1); n = length(value)
          if (n >= 2 && substr(value, 1, 1) == substr(value, n, 1) && (substr(value, 1, 1) == "\"" || substr(value, 1, 1) == "\047")) value = substr(value, 2, n - 2)
          if (value == "") next
          print key "=" value
          if (length(value) >= 3) print value
        }'
    shopt -s nocasematch
    for name in $(compgen -e); do
      case "$name" in *[!A-Za-z0-9_]*) continue ;; esac
      [[ $name =~ (TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|API_?KEY|PRIVATE_?KEY|_PAT$|_KEY$) ]] || continue
      value="${!name}"
      [ "${#value}" -ge 6 ] || continue
      case "$value" in *$'\n'*) continue ;; esac
      printf '%s\n' "$value"
    done
    shopt -u nocasematch
  } | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2- | awk '!seen[$0]++' > "$SECRETS"
}

# shellcheck disable=SC2016  # awk program text
AWK_LIB='
function load_secrets(  line) { nsec = 0; while ((getline line < SECF) > 0) sec[++nsec] = line; close(SECF) }
function fixed(s, pat,   out, i, n) {
  n = length(pat); out = ""
  while ((i = index(s, pat)) > 0) { out = out substr(s, 1, i - 1) "[REDACTED]"; s = substr(s, i + n) }
  return out s
}
function rx(s, re,   low, out) {
  out = ""; low = tolower(s)
  while (match(low, re)) {
    out = out substr(s, 1, RSTART - 1) "[REDACTED]"
    s = substr(s, RSTART + RLENGTH); low = substr(low, RSTART + RLENGTH)
  }
  return out s
}
function redact(s,   i) {
  for (i = 1; i <= nsec; i++) if (length(sec[i]) > 0) s = fixed(s, sec[i])
  s = rx(s, "(token|secret|password|passwd|api[_-]?key|authorization)[=:][^ \t\r\n]+")
  return rx(s, "bearer[ \t\r\n]+[^ \t\r\n]+")
}
function cut(s, lim) { return length(s) > lim ? substr(s, 1, lim) : s }
function cut400(s,   n) {
  n = length(s); if (n <= 400) return s
  return substr(s, 1, 300) " ...[+" (n - 370) "]... " substr(s, n - 69)
}
'
# shellcheck disable=SC2016
AWK_SCAN='
BEGIN { load_secrets(); FB = 16000 }
{
  line = $0
  if (line ~ /^FAIL(ED)?$/ || line ~ /^FAIL(ED)?[[:space:]:]/ || line ~ / FAILED$/) kind = 1
  else if (line ~ /^PASS$/ || line ~ /^PASS[[:space:]:]/ || line ~ / PASSED$/) kind = 2
  else kind = 0
  if (line ~ /^Results:/) {
    r1 = r2; r2 = r3; r3 = line; nres++
    if (match(line, /[0-9]+ passed/)) { rsum += substr(line, RSTART, RLENGTH - 7) + 0; rseen = 1 }
  }
  if (kind == 1) {
    failed++; win = 5; cur = 0
    red = redact(line); print red > FAILFILE
    if (!over) {
      nm = cut400(red); sz = length(nm) + 1
      if (names + sz > FB) over = 1
      else { k++; name[k] = nm; names += sz; witherr += sz; cur = k }
    }
  } else if (kind == 2) { passed++; win = 0 }
  else if (win > 0 && line ~ /[^[:space:]]/) {
    win--; red = redact(line); print red > FAILFILE
    if (cur > 0) { ec = cut400(red); nerr[cur]++; err[cur, nerr[cur]] = ec; witherr += length(ec) + 1 }
  }
}
END {
  full = (!over && witherr <= FB) ? 1 : 0
  for (i = 1; i <= k; i++) {
    print name[i] > SECTFILE
    if (full) for (j = 1; j <= nerr[i]; j++) print err[i, j] > SECTFILE
  }
  if (nres >= 3) print "results: " cut(redact(r1), 191) > RESFILE
  if (nres >= 2) print "results: " cut(redact(r2), 191) > RESFILE
  if (nres >= 1) print "results: " cut(redact(r3), 191) > RESFILE
  print "lines=" NR; print "passed=" passed + 0; print "failed=" failed + 0
  print "shown=" k + 0; print "full=" full; print "rsum=" (rseen ? rsum : "")
}
'

ENV_SKIPPED=0
REDACTION_OK=1
SECTION="$WORK/section"
RESULTS="$WORK/results"
STATS="$WORK/stats"
TAIL_OUT="$WORK/tail"
: > "$SECTION"; : > "$RESULTS"
build_secrets || REDACTION_OK=0
LINES_N=0; PASSED=0; FAILED=0; SHOWN=0; FULL=0; RSUM=""
if [ "$REDACTION_OK" = 1 ]; then
  awk -v SECF="$SECRETS" -v FAILFILE="$FAILS_FILE" -v SECTFILE="$SECTION" -v RESFILE="$RESULTS" \
    "$AWK_LIB$AWK_SCAN" "$CLEAN" > "$STATS" || REDACTION_OK=0
fi
if [ "$REDACTION_OK" = 1 ]; then
  while IFS== read -r key value; do
    case "$key" in
      lines) LINES_N="$value" ;; passed) PASSED="$value" ;; failed) FAILED="$value" ;;
      shown) SHOWN="$value" ;; full) FULL="$value" ;; rsum) RSUM="$value" ;;
    esac
  done < "$STATS"
fi

if [ "$REDACTION_OK" = 0 ]; then
  rm -f "$FAILS_FILE"
  echo "BOUNDED RUN"
  echo "status: error"
  echo "exit: ${RC:-none}"
  echo "bounded.sh: redaction failed, the command output is withheld"
  exit 1
fi

if [ "$STATUS" = "" ]; then
  if [ "$RC" = 0 ] && [ "$FAILED" = 0 ]; then STATUS="ok"; else STATUS="failed"; fi
fi
TAIL_LINES=20
if { [ "$STATUS" = failed ] || [ "$STATUS" = timeout ]; } && [ "$FAILED" = 0 ]; then TAIL_LINES=40; fi
tail -n "$TAIL_LINES" "$CLEAN" | awk -v SECF="$SECRETS" "$AWK_LIB"'BEGIN { load_secrets() } { print cut(redact($0), 200) }' > "$TAIL_OUT" || {
  rm -f "$FAILS_FILE"
  printf 'BOUNDED RUN\nstatus: error\nexit: %s\nbounded.sh: redaction failed, the command output is withheld\n' "${RC:-none}"
  exit 1
}

hdr() { printf '%s\n' "${1:0:200}"; }
echo "BOUNDED RUN"
hdr "status: $STATUS"
if [ "$STATUS" = timeout ] || [ "$STATUS" = error ]; then hdr "exit: none"; else hdr "exit: $RC"; fi
hdr "lines: $LINES_N"
if [ $((PASSED + FAILED)) -eq 0 ]; then hdr "counts: unparsed"; else hdr "counts: passed=$PASSED failed=$FAILED"; fi
CUT_TAIL="full list in $FAILS_REL (repository root))"
if [ "$FAILED" -gt 0 ]; then
  if [ "$FULL" = 1 ]; then hdr "fails: $FAILED"
  elif [ "$SHOWN" = "$FAILED" ]; then hdr "fails: $FAILED (showing $FAILED, error lines omitted, $CUT_TAIL"
  else hdr "fails: $FAILED (showing $SHOWN, $CUT_TAIL"; fi
elif [ "$STATUS" = ok ]; then hdr "fails: 0"
else hdr "fails: unparsed"; fi
cat "$RESULTS"
if [ -n "$RSUM" ]; then hdr "results total: passed=$RSUM"; fi
if [ "$ENV_SKIPPED" -gt 0 ]; then hdr "env: skipped $ENV_SKIPPED file(s) (outside worktree)"; fi
cat "$SECTION"
hdr "tail (last $TAIL_LINES lines)"
cat "$TAIL_OUT"
[ "$STATUS" = ok ]
