# =====================================================================
# DOER-13: bounded suite output (lib/helpers/bounded.sh)
# =====================================================================
# Sourced from tests/helpers.sh, so it shares pass/fail/assert_eq and the
# counters. Every fixture is a fresh temp git repo; the helper runs in a
# subshell and its output lands in a file, so no trap or variable leaks into
# the harness. A missing helper just makes the assertions fail.
BOUNDED_SH="${REPO_ROOT}/lib/helpers/bounded.sh"
BF_N=0
BF_FAILS_REL=".doer/bounded-fails.txt"
BF_SUITE_CMD='cat "$1"; exit "$2"'

bf_new() { # fresh repo, empty input file, cwd = repo root
  BF_N=$((BF_N + 1))
  BF_D="$TMPDIR_TEST/bfcase$BF_N"
  mkdir -p "$BF_D"
  git -C "$BF_D" init -q
  BF_IN="$BF_D.in"
  : > "$BF_IN"
  BF_CWD=""
  BF_BASH=""
}
bf_go() { # run the helper by path (or via /bin/bash when BF_BASH is set), capture output and exit
  BF_OUTF="$BF_D.out"
  (
    cd "${BF_CWD:-$BF_D}" || exit 99
    if [ -n "$BF_BASH" ]; then /bin/bash "$BOUNDED_SH" "$@"; else "$BOUNDED_SH" "$@"; fi
  ) > "$BF_OUTF" 2>&1
  BF_EXIT=$?
  BF_OUT="$(cat "$BF_OUTF")"
}
bf_suite() { # <exit-code> [extra helper args before --]: replay BF_IN as the command output
  local code="$1"; shift
  bf_go run "$@" -- sh -c "$BF_SUITE_CMD" sh "$BF_IN" "$code"
}
bf_hdr() { printf '%s\n' "$BF_OUT" | grep -m1 -- "^$1"; }
bf_has() { # <desc> <fixed-string>
  if printf '%s\n' "$BF_OUT" | grep -qF -- "$2"; then pass "bounded: $1"; else fail "bounded: $1" "missing '$2'"; fi
}
bf_lacks() { # <desc> <fixed-string>
  if printf '%s\n' "$BF_OUT" | grep -qF -- "$2"; then fail "bounded: $1" "found '$2'"; else pass "bounded: $1"; fi
}
bf_eq() { assert_eq "bounded: $1" "$2" "$3"; }
bf_maxlen() { LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$BF_OUTF"; }
bf_size() { LC_ALL=C wc -c < "$BF_OUTF" | tr -d ' '; }
bf_le() { # <desc> <actual> <limit>
  if [ "$2" -le "$3" ] 2>/dev/null; then pass "bounded: $1"; else fail "bounded: $1" "$2 > $3"; fi
}
bf_order() { # <desc> <needle>...: first occurrences appear in increasing line order
  local desc="$1" previous=0 current needle ok=yes; shift
  for needle in "$@"; do
    current="$(printf '%s\n' "$BF_OUT" | grep -nF -m1 -- "$needle" | cut -d: -f1)"
    if [ -z "$current" ] || [ "$current" -le "$previous" ]; then ok=no; fi
    previous="${current:-0}"
  done
  assert_eq "bounded: $desc" "yes" "$ok"
}
bf_no_frag() { # <desc> <value>: no 3-char piece of the value survives anywhere in the output
  local value="$2" position piece leaked=""
  position=0
  while [ "$position" -le $((${#value} - 3)) ]; do
    piece="${value:$position:3}"
    if grep -qF -- "$piece" "$BF_OUTF"; then leaked="$leaked $piece"; fi
    position=$((position + 1))
  done
  assert_eq "bounded: $1" "" "$leaked"
}
bf_no_leftover() { # <desc>: no log or marker file stays under .doer (the fails file is separate)
  assert_eq "bounded: $1" "" "$(find "$BF_D/.doer" -type f ! -name bounded-fails.txt 2>/dev/null)"
}
bf_kill() { # <pid>: cleanup that ignores an empty pid (kill 0 would signal the whole harness group)
  case "$1" in ''|*[!0-9]*|0) return 0 ;; esac
  kill "$1" 2>/dev/null
  return 0
}
bf_gone() { # <pid>: poll up to 1 s for the process to disappear; an empty pid is reported as nopid
  local pid="$1" tries=0
  case "$pid" in ''|*[!0-9]*|0) echo nopid; return ;; esac
  while [ "$tries" -lt 10 ]; do
    kill -0 "$pid" 2>/dev/null || { echo gone; return; }
    sleep 0.1
    tries=$((tries + 1))
  done
  echo alive
}
bf_filler() { awk -v n="$1" 'BEGIN { for (i = 1; i <= n; i++) print "PASS  filler " i }' >> "$BF_IN"; }

# --- parse and syntax ---
bash -n "$BOUNDED_SH" 2>/dev/null && pass "bounded: bounded.sh parses" || fail "bounded: bounded.sh parses"
assert_eq "bounded: bounded.sh is executable" "yes" "$([ -x "$BOUNDED_SH" ] && echo yes || echo no)"

# --- statuses and helper exit codes ---
bf_new
printf 'PASS  a\nPASS  b\nPASS  c\n' > "$BF_IN"
bf_suite 0
bf_eq "ok: status line" "status: ok" "$(bf_hdr 'status: ')"
bf_eq "ok: exit line" "exit: 0" "$(bf_hdr 'exit: ')"
bf_eq "ok: helper exit 0" "0" "$BF_EXIT"
bf_eq "ok: counts line" "counts: passed=3 failed=0" "$(bf_hdr 'counts: ')"
bf_eq "ok: fails line" "fails: 0" "$(bf_hdr 'fails: ')"
bf_has "ok: starts with the fixed banner" "BOUNDED RUN"
bf_no_leftover "ok: no log left behind"

bf_new
printf 'some output\nmore output\n' > "$BF_IN"
bf_suite 0
bf_eq "ok without PASS or FAIL: status ok" "status: ok" "$(bf_hdr 'status: ')"
bf_eq "ok without PASS or FAIL: counts unparsed" "counts: unparsed" "$(bf_hdr 'counts: ')"

bf_new
seq 1 100 | awk '{ print "out-" $1 }' > "$BF_IN"
bf_suite 1
bf_eq "exit 1 without PASS or FAIL: status failed" "status: failed" "$(bf_hdr 'status: ')"
bf_eq "exit 1 without PASS or FAIL: helper exit 1" "1" "$BF_EXIT"
bf_eq "exit 1 without PASS or FAIL: fails unparsed" "fails: unparsed" "$(bf_hdr 'fails: ')"
bf_eq "exit 1 without PASS or FAIL: counts unparsed" "counts: unparsed" "$(bf_hdr 'counts: ')"
bf_eq "exit 1 without PASS or FAIL: lines total" "lines: 100" "$(bf_hdr 'lines: ')"
bf_has "unparsed failure: the 40-line tail starts at line 61" "out-61"
bf_lacks "unparsed failure: the tail stops before line 61" "out-60"
bf_has "unparsed failure: the tail ends at the last line" "out-100"

bf_new
printf 'PASS  a\nPASS  b\n' > "$BF_IN"
bf_suite 1
bf_eq "exit 1 with PASS only: status failed" "status: failed" "$(bf_hdr 'status: ')"
bf_eq "exit 1 with PASS only: fails unparsed" "fails: unparsed" "$(bf_hdr 'fails: ')"
bf_eq "exit 1 with PASS only: helper exit 1" "1" "$BF_EXIT"

bf_new
printf 'PASS  a\nFAIL  broken one\n' > "$BF_IN"
bf_suite 0
bf_eq "exit 0 with a FAIL line: status failed" "status: failed" "$(bf_hdr 'status: ')"
bf_eq "exit 0 with a FAIL line: exit line keeps 0" "exit: 0" "$(bf_hdr 'exit: ')"
bf_eq "exit 0 with a FAIL line: helper exit 1" "1" "$BF_EXIT"

bf_new
bf_go run -- sh -c 'nosuchcmd'
bf_eq "unknown command in sh -c: status failed" "status: failed" "$(bf_hdr 'status: ')"
bf_eq "unknown command in sh -c: exit 127" "exit: 127" "$(bf_hdr 'exit: ')"
bf_eq "unknown command in sh -c: helper exit 1" "1" "$BF_EXIT"

bf_new
bf_go run -- nosuchbinary_doer13
bf_eq "unknown binary: status error" "status: error" "$(bf_hdr 'status: ')"
bf_eq "unknown binary: helper exit 1" "1" "$BF_EXIT"
bf_has "unknown binary: the message is the tail content" "nosuchbinary_doer13"
bf_lacks "unknown binary: never reads as ok" "status: ok"

bf_new
BF_CWD="$TMPDIR_TEST"
mkdir -p "$TMPDIR_TEST/notarepo$BF_N"
BF_CWD="$TMPDIR_TEST/notarepo$BF_N"
bf_go run -- sh -c 'echo hi'
bf_eq "outside a git repo: helper exit 2" "2" "$BF_EXIT"

# --- failure extraction ---
bf_new
{ printf 'PASS  a\nFAIL  one-alpha\n  err-one\nPASS  mid\nFAIL  two-beta\n  err-two-a\n  err-two-b\n'; } > "$BF_IN"
bf_filler 60
bf_suite 1
bf_eq "all FAIL lines: fails count" "fails: 2" "$(bf_hdr 'fails: ')"
bf_eq "all FAIL lines: counts" "counts: passed=62 failed=2" "$(bf_hdr 'counts: ')"
bf_order "pair order is FAIL1, err1, FAIL2, err2" "FAIL  one-alpha" "  err-one" "FAIL  two-beta" "  err-two-a"
bf_has "second error line of the second failure" "  err-two-b"

bf_new
printf 'FAIL  stop-one\n  err-stop\nPASS  x\n  stray-after-pass\nFAIL  stop-two\nFAIL  stop-three\n  err-three\n' > "$BF_IN"
bf_filler 60
bf_suite 1
bf_lacks "window stops at the next PASS line" "stray-after-pass"
bf_order "window stops at the next FAIL line" "FAIL  stop-two" "FAIL  stop-three" "  err-three"

bf_new
printf 'FAIL  five-limit\n' > "$BF_IN"
awk 'BEGIN { for (i = 1; i <= 7; i++) print "    detail-" i }' >> "$BF_IN"
bf_filler 60
bf_suite 1
bf_has "error window returns the fifth line" "detail-5"
bf_lacks "error window stops at five lines" "detail-6"

bf_new
printf 'FAIL  tests/only_a_file.sh\n' > "$BF_IN"
bf_filler 60
bf_suite 1
bf_has "a FAIL line naming only a file returns that line" "FAIL  tests/only_a_file.sh"

bf_new
awk 'function rep(s, n,  r) { while (n-- > 0) r = r s; return r }
BEGIN { print "FAIL " rep("a", 480) "NAMEMID" rep("b", 510) }' > "$BF_IN"
bf_filler 60
bf_suite 1
bf_le "long FAIL line is cut to 400 chars" "$(printf '%s\n' "$BF_OUT" | grep '^FAIL ' | LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')" 400
bf_has "long FAIL line shows the cut marker" "...[+"
bf_lacks "long FAIL line loses its middle inline" "NAMEMID"
bf_eq "long FAIL line is complete in the fails file" "yes" "$(grep -q "NAMEMID" "$BF_D/$BF_FAILS_REL" && echo yes || echo no)"
bf_eq "fails file keeps the whole 1,000-char line" "1" "$(awk 'length($0) >= 1000' "$BF_D/$BF_FAILS_REL" | wc -l | tr -d ' ')"

bf_new
awk 'BEGIN { for (i = 1; i <= 30; i++) { printf "com.x.Suite > case%02d FAILED\n    java.lang.AssertionError gradle-err-%02d\n", i, i } }' > "$BF_IN"
bf_filler 60
printf 'FAILURE: Build failed with an exception.\n' >> "$BF_IN"
bf_suite 1
bf_eq "gradle: 30 FAILED lines counted, footer not counted" "fails: 30" "$(bf_hdr 'fails: ')"
bf_has "gradle: first error line returned" "gradle-err-01"
bf_has "gradle: last error line returned beyond the tail window" "gradle-err-30"
bf_has "gradle: FAILED suffix line returned" "com.x.Suite > case17 FAILED"

bf_new
printf '> Task :app:test FAILED\n' > "$BF_IN"
bf_suite 1
bf_eq "gradle Task FAILED line counts as a failure" "fails: 1" "$(bf_hdr 'fails: ')"

# --- output budget ---
bf_new
printf 'PASS  p1\nPASS  p2\nPASS  p3\nPASS  p4\nPASS  p5\n' > "$BF_IN"
awk 'function rep(s, n,  r) { while (n-- > 0) r = r s; return r }
BEGIN { for (i = 1; i <= 120; i++) { printf "FAIL  c%03d%s\n", i, rep("x", 30); printf "  e%03d_1_%s\n", i, rep("e", 51) } }' >> "$BF_IN"
bf_suite 1
bf_eq "120 FAILs fit with no cut signal" "fails: 120" "$(bf_hdr 'fails: ')"
bf_has "120 FAILs: the first error line is present" "e001_1_"
bf_has "120 FAILs: the last FAIL line is present" "FAIL  c120"
bf_has "120 FAILs: the middle error line is present" "e060_1_"
bf_le "120 FAILs: fixed part stays within 55 lines" "$(( $(printf '%s\n' "$BF_OUT" | wc -l) - 240 ))" 55
bf_no_leftover "120 FAILs: only the fails file stays under .doer"

bf_new
awk 'function rep(s, n,  r) { while (n-- > 0) r = r s; return r }
BEGIN { for (i = 1; i <= 200; i++) { printf "FAIL  c%03d%s\n", i, rep("x", 50); for (j = 1; j <= 5; j++) printf "  e%03d_%d_%s\n", i, j, rep("e", 111) } }' > "$BF_IN"
bf_suite 1
bf_eq "200 FAILs with errors: error lines omitted signal" "fails: 200 (showing 200, error lines omitted, full list in .doer/bounded-fails.txt (repository root))" "$(bf_hdr 'fails: ')"
bf_has "200 FAILs with errors: names still print" "FAIL  c001"
bf_lacks "200 FAILs with errors: early error lines are dropped inline" "e001_1_"
bf_eq "200 FAILs with errors: file holds every FAIL line" "200" "$(grep -c '^FAIL' "$BF_D/$BF_FAILS_REL")"
bf_eq "200 FAILs with errors: file holds every error line" "1000" "$(grep -c '^  e' "$BF_D/$BF_FAILS_REL")"
bf_le "200 FAILs with errors: total within the budget" "$(bf_size)" 27000

bf_new
DIR_PART="$(basename "$BF_D")"
printf 'FILESEC=Zp4Rq8Lw3Tn\nDIRPART=%s\n' "$DIR_PART" > "$BF_D/.env"
awk 'function rep(s, n,  r) { while (n-- > 0) r = r s; return r }
BEGIN { for (i = 1; i <= 2500; i++) { if (i == 2400) printf "FAIL  c%04d Zp4Rq8Lw3Tn %s\n", i, rep("x", 50); else printf "FAIL  c%04d%s\n", i, rep("x", 69) } }' > "$BF_IN"
bf_suite 1
bf_eq "2500 FAILs: cut signal with the count shown" "yes" "$(bf_hdr 'fails: ' | grep -qE '^fails: 2500 \(showing [0-9]+, full list in \.doer/bounded-fails\.txt \(repository root\)\)$' && echo yes || echo no)"
bf_eq "2500 FAILs: file holds all 2,500 FAIL lines" "2500" "$(grep -c '^FAIL' "$BF_D/$BF_FAILS_REL")"
bf_le "2500 FAILs: total within the budget" "$(bf_size)" 27000
bf_eq "2500 FAILs: env value absent from the fails file" "0" "$(grep -c 'Zp4Rq8Lw3Tn' "$BF_D/$BF_FAILS_REL")"
bf_eq "2500 FAILs: redaction marker present in the fails file" "yes" "$(grep -q 'REDACTED' "$BF_D/$BF_FAILS_REL" && echo yes || echo no)"
bf_lacks "2500 FAILs: env value absent from the output" "Zp4Rq8Lw3Tn"
bf_lacks "2500 FAILs: a value equal to a temp directory name never appears" "$DIR_PART"
# an ok run after a failing one removes the stale fails file
printf 'PASS  fine\n' > "$BF_IN"
bf_suite 0
bf_eq "ok run removes the earlier fails file" "no" "$([ -e "$BF_D/$BF_FAILS_REL" ] && echo yes || echo no)"

bf_new
awk 'function rep(s, n,  r) { while (n-- > 0) r = r s; return r }
BEGIN { for (i = 1; i <= 2500; i++) print "FAIL " rep("f", 995);
  for (i = 1; i <= 3; i++) print "Results: " rep("r", 990);
  for (i = 1; i <= 40; i++) print rep("t", 1000) }' > "$BF_IN"
bf_suite 1
bf_le "worst case: total output within 27,000 chars" "$(bf_size)" 27000
bf_le "worst case: no line above 400 chars" "$(bf_maxlen)" 400

bf_new
mkdir -p "$BF_D.outside"
printf 'OUTSIDE=outsidevalue1\n' > "$BF_D.outside/envfile"
ln -s "$BF_D.outside/envfile" "$BF_D/.env"
awk 'function rep(s, n,  r) { while (n-- > 0) r = r s; return r }
BEGIN { for (i = 1; i <= 15; i++) print "Results: " i " passed " rep("z", 300); print rep("q", 1000) }' > "$BF_IN"
bf_suite 1
bf_le "size: every line at most 200 chars without FAIL lines" "$(bf_maxlen)" 200
bf_le "size: at most 55 lines without FAIL lines" "$(printf '%s\n' "$BF_OUT" | wc -l | tr -d ' ')" 55
bf_le "size: total within the budget" "$(bf_size)" 27000

bf_new
head -c 1048576 /dev/zero | tr '\0' 'm' > "$BF_IN"
bf_suite 1
bf_le "1 MB single line: no printed line above 200 chars" "$(bf_maxlen)" 200
bf_le "1 MB single line: total within the budget" "$(bf_size)" 27000

bf_new
printf 'BINSECRET=binsecret99\n' > "$BF_D/.env"
{ printf 'a\000b binsecret99 \000\n'; printf 'FAIL  binfail\n'; head -c 3000 /dev/urandom; } > "$BF_IN"
bf_suite 0
bf_eq "binary output with exit 0 and a FAIL line: status failed" "status: failed" "$(bf_hdr 'status: ')"
bf_has "binary output: the FAIL line is present" "FAIL  binfail"
bf_eq "binary output: the env value is absent" "0" "$(LC_ALL=C grep -ac 'binsecret99' "$BF_OUTF")"
bf_le "binary output: total within the budget" "$(bf_size)" 27000

bf_new
head -c 200000 /dev/urandom > "$BF_IN"
bf_suite 1
bf_le "binary garbage: total within the budget" "$(bf_size)" 27000
bf_eq "binary garbage: status failed" "status: failed" "$(bf_hdr 'status: ')"

# --- results lines ---
bf_new
printf 'Results: 3 passed, 0 failed\nPASS  a\nResults: 4 passed, 1 failed\nResults: 5 passed, 0 failed\n' > "$BF_IN"
bf_suite 0
bf_has "results total sums every Results line" "results total: passed=12"
bf_has "results lines are echoed" "Results: 5 passed, 0 failed"

# --- timeout, signals, process groups ---
bf_new
PID_FILE="$BF_D.pid"
bf_go run --timeout 1 -- sh -c 'sleep 30 & echo $! > "$1"; wait' sh "$PID_FILE"
bf_eq "timeout: status timeout" "status: timeout" "$(bf_hdr 'status: ')"
bf_eq "timeout: helper exit 1" "1" "$BF_EXIT"
GRANDCHILD_PID="$(cat "$PID_FILE" 2>/dev/null)"
bf_eq "timeout: the grandchild is killed" "gone" "$(bf_gone "$GRANDCHILD_PID")"
bf_kill "$GRANDCHILD_PID"
bf_no_leftover "timeout: no log left behind"

bf_new
PID_FILE="$BF_D.pid"
( cd "$BF_D" && exec "$BOUNDED_SH" run --timeout 60 -- sh -c 'sleep 30 & echo $! > "$1"; wait' sh "$PID_FILE" ) > /dev/null 2>&1 &
HELPER_PID=$!
WAITED=0
while [ ! -s "$PID_FILE" ] && [ "$WAITED" -lt 50 ]; do sleep 0.1; WAITED=$((WAITED + 1)); done
sleep 0.3
kill -TERM "$HELPER_PID" 2>/dev/null
wait "$HELPER_PID" 2>/dev/null
GRANDCHILD_PID="$(cat "$PID_FILE" 2>/dev/null)"
bf_eq "SIGTERM to the helper kills the grandchild" "gone" "$(bf_gone "$GRANDCHILD_PID")"
bf_kill "$GRANDCHILD_PID"
bf_no_leftover "SIGTERM to the helper removes the log"

bf_new
SECONDS=0
CAPTURED="$( cd "$BF_D" && "$BOUNDED_SH" run --timeout 60 -- sh -c 'echo PASS  quick' 2>&1 )"
bf_le "clean run with a long timeout returns promptly through command substitution" "$SECONDS" 5
assert_eq "bounded: clean run through command substitution reports ok" "yes" "$(printf '%s\n' "$CAPTURED" | grep -q '^status: ok' && echo yes || echo no)"

bf_new
PID_FILE="$BF_D.pid"
bf_go run --timeout 60 -- sh -c 'sleep 30 >/dev/null 2>&1 & echo $! > "$1"' sh "$PID_FILE"
bf_eq "clean run with a backgrounded sleep: status ok" "status: ok" "$(bf_hdr 'status: ')"
BACKGROUND_PID="$(cat "$PID_FILE" 2>/dev/null)"
sleep 0.3
bf_eq "clean run leaves a backgrounded process alone" "yes" "$([ -n "$BACKGROUND_PID" ] && kill -0 "$BACKGROUND_PID" 2>/dev/null && echo yes || echo no)"
bf_kill "$BACKGROUND_PID"

# --- redaction ---
bf_new
{
  printf 'ENVTEST_TOKENISH=abcdef123456\nFLAG=1\nMODE=ok\nexport OTHERKEY=xyz789\nNODE_ENV=test\nMETACHAR=a.b*c+\n'
} > "$BF_D/.env"
{
  printf 'FAIL  t1 abcdef123456\n'
  printf 'echo xyz789 seen\nFLAG=1 echoed\nMODE=ok echoed\nval a.b*c+ end\nplain axc stays\n'
  printf 'password=hunter22\nAuthorization: Bearer abc.def\nBearer zzz.yyy\n'
  printf 'FAIL  my test case\nFAIL  config: token absent\nFAIL  four token sums\n'
} > "$BF_IN"
bf_suite 1
bf_lacks "env value from a KEY=value line is redacted" "abcdef123456"
bf_lacks "env value from an export line is redacted" "xyz789"
bf_lacks "short assignment FLAG=1 is redacted" "FLAG=1"
bf_lacks "short assignment MODE=ok is redacted" "MODE=ok"
bf_lacks "metachar value is redacted as a fixed string" "a.b*c+"
bf_has "a regex lookalike of the metachar value stays" "plain axc stays"
bf_lacks "password assignment pattern is redacted" "hunter22"
bf_lacks "authorization bearer pattern is redacted" "abc.def"
bf_lacks "bare bearer pattern is redacted" "zzz.yyy"
bf_has "redaction marker is used" "[REDACTED]"
bf_has "a long env value collides with test text as documented" "FAIL  my [REDACTED] case"
bf_has "test name with the word token and a space is unchanged" "FAIL  config: token absent"
bf_has "test name four token sums is unchanged" "FAIL  four token sums"
bf_eq "header exit line intact when FLAG=1 is in .env" "exit: 1" "$(bf_hdr 'exit: ')"
bf_eq "header fails line intact when FLAG=1 is in .env" "fails: 4" "$(bf_hdr 'fails: ')"

bf_new
printf 'FLAG=1\nLOG_LEVEL=error\n' > "$BF_D/.env"
printf 'PASS  a\nFLAG=1 echoed in an ok run\n' > "$BF_IN"
bf_suite 0
bf_eq "ok run: status line intact with a short env value" "status: ok" "$(bf_hdr 'status: ')"
bf_eq "ok run: exit line intact with a short env value" "exit: 0" "$(bf_hdr 'exit: ')"
bf_lacks "ok run: echoed FLAG=1 is redacted" "FLAG=1"
printf 'FAIL  x\nlevel error here\n' > "$BF_IN"
bf_suite 1
bf_eq "failed run: status line intact with LOG_LEVEL=error" "status: failed" "$(bf_hdr 'status: ')"
bf_lacks "failed run: echoed error value is redacted in log text" "level error here"
bf_go run -- nosuchbinary_doer13
bf_eq "error run: status line intact with LOG_LEVEL=error" "status: error" "$(bf_hdr 'status: ')"

bf_new
printf 'EXAMPLEKEY=examplevalue123\n' > "$BF_D/.env.example"
printf 'echo examplevalue123\n' > "$BF_IN"
bf_suite 0
bf_has ".env.example is not read" "examplevalue123"

bf_new
mkdir -p "$BF_D/pkg" "$BF_D/node_modules/dep" "$BF_D/a/b/c/d/e/f" "$BF_D/store" "$BF_D/linked"
printf 'PKGVAL=pkgsecretAA\n' > "$BF_D/pkg/.env"
printf 'NMVAL=nmsecretBB\n' > "$BF_D/node_modules/dep/.env"
printf 'DEEPVAL=deepsecretCC\n' > "$BF_D/a/b/c/d/e/f/.env"
printf 'LINKVAL=linksecretDD\n' > "$BF_D/store/realenv"
ln -s ../store/realenv "$BF_D/linked/.env"
mkdir -p "$BF_D/direnv/.env"
printf 'pkgsecretAA\nnmsecretBB\ndeepsecretCC\nlinksecretDD\n' > "$BF_IN"
bf_suite 0
bf_lacks "env nested one directory down is honored" "pkgsecretAA"
bf_lacks "env under node_modules is honored" "nmsecretBB"
bf_lacks "env deeper than four directories is honored" "deepsecretCC"
bf_lacks "in-tree symlinked env is redacted" "linksecretDD"
bf_lacks "a .env directory causes no skip notice" "env: skipped"
bf_eq "a .env directory does not break the run" "status: ok" "$(bf_hdr 'status: ')"

bf_new
mkdir -p "$BF_D.outside"
printf 'OUTSIDE=outsidevalue1\n' > "$BF_D.outside/envfile"
ln -s "$BF_D.outside/envfile" "$BF_D/.env"
printf 'PASS  a\n' > "$BF_IN"
bf_suite 0
bf_eq "out-of-tree env symlink is counted in the env line" "env: skipped 1 file(s) (outside worktree)" "$(bf_hdr 'env: ')"

bf_new
printf 'PASS  a\n' > "$BF_IN"
bf_suite 0
bf_lacks "no skip notice without skipped env files" "env: skipped"

bf_new
BF_ENV_VALUE="abcdefgh1"
MYCI_TOKEN=$BF_ENV_VALUE MYCI_NOTHING=zzzzzzzzz bf_go run -- sh -c 'echo "got abcdefgh1 and zzzzzzzzz"; echo FAIL  inherited; exit 1'
bf_lacks "inherited secret-named variable is redacted" "abcdefgh1"
bf_has "inherited non-matching name is not redacted" "zzzzzzzzz"
bf_eq "inherited redaction keeps the status line" "status: failed" "$(bf_hdr 'status: ')"
bf_new
MYCI_TOKEN=ab9de bf_go run -- sh -c 'echo "got ab9de"; exit 0'
bf_has "inherited secret value of 5 chars is not redacted" "got ab9de"

bf_new
printf 'STRADDLE=Q9W8Z7X6V5\n' > "$BF_D/.env"
awk 'function rep(s, n,  r) { while (n-- > 0) r = r s; return r }
BEGIN { print "FAIL " rep("a", 291) "Q9W8Z7X6V5" rep("b", 700) }' > "$BF_IN"
bf_filler 5
bf_suite 1
bf_no_frag "value straddling char 300 of a FAIL line leaves no fragment" "Q9W8Z7X6V5"
awk 'function rep(s, n,  r) { while (n-- > 0) r = r s; return r }
BEGIN { print rep("x", 196) "Q9W8Z7X6V5" rep("y", 300) }' > "$BF_IN"
bf_suite 1
bf_no_frag "value straddling char 200 of a tail line leaves no fragment" "Q9W8Z7X6V5"

# --- scope ---
bf_new
mkdir -p "$BF_D/pkg"
printf 'TOPVAL=topsecretEE\n' > "$BF_D/.env"
printf 'PKGVAL=pkgsecretFF\n' > "$BF_D/pkg/.env"
BF_CWD="$BF_D/pkg"
bf_go run -- sh -c 'pwd -P; echo topsecretEE pkgsecretFF; echo FAIL  scoped; exit 1'
PHYSICAL_PKG="$(cd "$BF_D/pkg" && pwd -P)"
bf_has "the command runs in the current subdirectory" "$PHYSICAL_PKG"
bf_lacks "toplevel env is honored from a subdirectory" "topsecretEE"
bf_lacks "subdirectory env is honored" "pkgsecretFF"
bf_eq "the fails file lives at the repository root" "yes" "$([ -e "$BF_D/$BF_FAILS_REL" ] && echo yes || echo no)"
bf_eq "no .doer directory is created in the subdirectory" "no" "$([ -e "$BF_D/pkg/.doer" ] && echo yes || echo no)"

bf_new
printf 'SLASHVAL=varpathsecretGG\n' > "$BF_D/.env"
printf 'varpathsecretGG\nPASS  a\n' > "$BF_IN"
bf_suite 0
bf_lacks "temp directory path form (symlinked var) still honors an in-tree env" "varpathsecretGG"
bf_lacks "temp directory path form adds no skip notice" "env: skipped"

# --- bash 3.2 reruns (the system shell on macOS) ---
if [ -x /bin/bash ]; then
  bf_new
  BF_BASH=1
  printf 'PASS  a\nFAIL  old-shell\n  old-err\n' > "$BF_IN"
  bf_filler 30
  bf_suite 1
  bf_eq "bash 3.2: no env file at all, status failed" "status: failed" "$(bf_hdr 'status: ')"
  bf_has "bash 3.2: FAIL line returned" "FAIL  old-shell"
  bf_has "bash 3.2: error line returned" "  old-err"
  printf 'PASS  a\n' > "$BF_IN"
  bf_suite 0
  bf_eq "bash 3.2: ok run" "status: ok" "$(bf_hdr 'status: ')"
  bf_go run -- nosuchbinary_doer13
  bf_eq "bash 3.2: unknown binary is status error" "status: error" "$(bf_hdr 'status: ')"
  printf 'ENVV=oldshellsecretHH\n' > "$BF_D/.env"
  printf 'oldshellsecretHH\n' > "$BF_IN"
  bf_suite 1
  bf_lacks "bash 3.2: env value redacted" "oldshellsecretHH"
  bf_go run --timeout 1 -- sh -c 'sleep 30 & echo $! > "$1"; wait' sh "$BF_D.pid"
  bf_eq "bash 3.2: timeout status" "status: timeout" "$(bf_hdr 'status: ')"
  bf_kill "$(cat "$BF_D.pid" 2>/dev/null)"
fi

cd "$JIRA_PROJECT_DIR" || exit 1
