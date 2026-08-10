---
name: protologs
description: >-
  Injects temporary debug logs (tag PROTOLOG) into the vertical slice of the
  current diff to verify runtime behavior on device. Two modes:
  - /wk:protologs          -> injects logs (asks to confirm base branch and,
    optionally, the entry point / root point where the flow starts), commits
    them as a [TEMP] commit so multiple rounds of logs and any fixes
    requested in between stay individually trackable.
  - /wk:protologs cleanup  -> reverts every [TEMP] commit (sed removal is
    only a fallback), leaving the code identical to its original state, and
    verifies no trace remains. Also invoked by /wk:doer Stage 4 and
    /wk:bugfix Stage 6 for on-device runtime verification.
version: 7.6.0
user-invocable: true
allowed-tools: [Read, Edit, Grep, Glob, Bash, AskUserQuestion, Agent]
---

# protologs

Injects / cleans runtime logs on the current branch. Works standalone in any
repo; `/wk:doer` (Stage 4) and `/wk:bugfix` (Stage 6) invoke it for their
runtime verification, but it has no dependency on their state files.

---

## How the tag works

Every injected line carries the exact prefix `PROTOLOG - ` (with trailing space).
That tag is the only footprint left by the skill; deleting it is enough to fully
restore the files.

Filter on Android device:

```
adb logcat | grep "PROTOLOG - "
```

Fallback: Android Studio Logcat with filter `PROTOLOG - `.

---

## Mode: inject (default)

Activated when the user types `/wk:protologs` with no arguments, or when `/wk:doer` Stage 4 / `/wk:bugfix` Stage 6 invokes this skill in inject mode.

Before Step 1, run `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/session.sh" start protologs`. This activates this plugin's PreToolUse guards for the session (they are inert otherwise, see `lib/workspace-guard.md`). Safe to run even when `/wk:doer`/`/wk:bugfix` already started their own marker for this session; it is idempotent per session pid.

### Step 1 - Confirm base branch

Run the following commands (none fails fatally if the ref does not exist):

```bash
# candidate 1: upstream tracking of current branch
git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null | sed 's|origin/||'

# candidate 2: if develop exists
git show-ref --quiet refs/heads/develop 2>/dev/null && echo "develop"

# candidate 3: if main exists
git show-ref --quiet refs/heads/main 2>/dev/null && echo "main"

# candidate 4: if master exists
git show-ref --quiet refs/heads/master 2>/dev/null && echo "master"

# current branch (to show the user)
git rev-parse --abbrev-ref HEAD
```

Deduplicate candidates, removing the current branch (it cannot be its own base).
Show the found candidates via `AskUserQuestion` with available options plus
"Other branch / type it yourself". If they choose "Other", ask a second free-text
`AskUserQuestion`. The chosen branch is used as `<BASE>` for the rest of the flow.

### Step 2 - Compute the diff

```bash
# changed files (staged + unstaged + diff vs base)
git diff <BASE>...HEAD --name-only
git diff --name-only          # unstaged
git diff --cached --name-only # staged but not yet committed
```

Combine and deduplicate the three lists into `<DIFF_FILES>`. Do not stop yet
if this is empty; Step 2.5 decides whether an empty diff is fatal.

### Step 2.5 - Confirm entry point (root point)

Per `lib/narration.md`, the answer here is open free text, so this is a
**plain-chat question**, not `AskUserQuestion`.

If `/wk:doer` Stage 4 or `/wk:bugfix` Stage 6 invoked this skill and already
supplied entry points (bugfix's `entry_points[]`, or the AC/flow context from
doer's plan), skip this question entirely and use what was supplied.

Otherwise ask in chat: *"Where does the flow you want to verify start? Give
me entry points (file paths, class/function names, or a short flow
description, e.g. `HomeFragment.onResume` or "the checkout button tap").
Multiple are fine. Reply `derive` (or leave it empty) to let me infer the
entry point from the diff instead."*

- If the user gives entry points, store them verbatim as `<ENTRY_POINTS>` for
  Step 4. They are an anchor that complements the diff, not a replacement for
  it: `<DIFF_FILES>` is still used.
- If the user says `derive` (or gives nothing), set `<ENTRY_POINTS>` to
  `none - derive the entry point from the diff` and proceed exactly as
  before.
- If `<DIFF_FILES>` is empty AND `<ENTRY_POINTS>` is also
  `none - derive the entry point from the diff`, narrate:
  *"No changes between the current branch and `<BASE>`, and no entry point
  given. Nothing to instrument."* and stop without touching any files.
- If `<DIFF_FILES>` is empty but explicit entry points were given, do not
  stop; proceed to instrument the slice starting from those entry points
  alone.

Show the file list (`<DIFF_FILES>`, may be empty when entry points carry the
slice) and any `<ENTRY_POINTS>` to the user and confirm via `AskUserQuestion`:
*"I will instrument the vertical slice of these N files vs `<BASE>`[, anchored
at <ENTRY_POINTS>]. Continue?"*

### Step 3 - Safety backup in /tmp

Before the agent modifies anything, capture the full pre-inject state. The committed
patch alone misses uncommitted work, so save the working tree and index too:

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD | tr '/' '-')
git diff <BASE>...HEAD        > /tmp/protolog-committed-${BRANCH}.patch
git diff HEAD                 > /tmp/protolog-workdir-${BRANCH}.patch
git diff --cached             > /tmp/protolog-staged-${BRANCH}.patch
```

Narrate all three patch paths. `/tmp/protolog-workdir-${BRANCH}.patch` is the source
of truth for the pre-inject state: it captures every staged and unstaged change vs HEAD.

If cleanup fails for any reason, the user can restore the pre-inject state by resetting
tracked files to HEAD and reapplying the working-tree patch:

```bash
git checkout -- .
git apply /tmp/protolog-workdir-<branch>.patch
```

The committed and staged patches are kept as references for the committed changes and
the index snapshot respectively.

### Step 4 - Inject logs via agent

MUST invoke a general-purpose agent using the Agent tool. The orchestrator
does NOT inject logs inline.

Agent prompt (fill in the `<...>` markers):

```
You are the logger-agent. Your ONLY function is to add temporary debug lines
with the tag "PROTOLOG - " to a targeted diagnostic slice of the change
described below.

== INVIOLABLE RULES (read first, apply to every line you write) ==

VALID LINE SHAPES (only these two exist). Every PROTOLOG line occupies its own
full line, with nothing else on it, so that deleting it (by text match on
"PROTOLOG - ") leaves the surrounding code exactly as it was:

1. A standalone print call: `println("PROTOLOG - <message>")`.
2. A standalone `.also { println("PROTOLOG - <message>") }` continuing the
   expression on the PREVIOUS line (Kotlin/Swift allow a leading-dot
   continuation). This is the sanctioned way to log a return value, a `when`
   branch result, or a constructor call WITHOUT refactoring anything: deleting
   the line leaves the original expression syntactically complete.
   ```kotlin
   // when branch:
   FeatureEntity.HandlerType.PROMOTION_LIST_FOR_YOU -> PROMOTION_LIST_FOR_YOU
       .also { println("PROTOLOG - [${Thread.currentThread().name}] FeaturesMapper: branch PROMOTION_LIST_FOR_YOU") }

   // return / constructor:
   return PromotionList.Item(
       ...
   )
       .also { println("PROTOLOG - [${Thread.currentThread().name}] PromotionListMapper: exit value=$it") }
   ```
   Never write the `.also { println(...) }` on the SAME line as the code it is
   attached to (e.g. `X -> Y.also { println(...) }` or `).also { println(...) }`
   glued to a closing paren). That mixes a PROTOLOG line with business logic on
   one physical line; deleting it by text match deletes the logic with it. This
   is exactly the bug that broke a `when` block and two constructor calls in a
   real incident. The `.also {}` ALWAYS goes on its own line below.

FORBIDDEN:
1. Creating a variable ONLY to print its value.
   BAD:  val endpoint = if (x) "a" else "b"
         println("PROTOLOG - endpoint=$endpoint")
   GOOD: println("PROTOLOG - endpoint=${if (x) "a" else "b"}")

2. Refactoring existing code to enable a log. Do not split returns, method chains,
   or long expressions. If a log would require a refactor, find the NEAREST
   previous or subsequent point where you CAN log without changing logic.
   NEVER skip that slice node entirely.
   BAD:  val r = foo()
         println("PROTOLOG - result=$r")
         return r
   GOOD: println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: about to call foo")
         return foo()
   ALSO GOOD (when the returned/emitted value itself needs logging, use the
   standalone `.also {}` form above, never inline it):
   BAD:  return foo().also { println("PROTOLOG - result=$it") }
   GOOD: return foo()
             .also { println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: result=$it") }

3. Adding helpers, factories, or any extra function. The only permitted change
   is println/print/console.log lines (standalone or standalone `.also {}`).

4. Modifying existing business logic, imports, or comments.

5. Mixing a PROTOLOG line with business logic on the same physical line. Every
   `.also { println("PROTOLOG - ...") }` is on its own line (see VALID LINE
   SHAPES). Never `X -> Y.also { ... }`, never a println joined by `;` to real
   code, never a println hanging off the line that closes a constructor call.

Every modified file must be such that deleting all lines containing
"PROTOLOG - " restores it to a syntactically identical state to its exact
prior state. When a log would require breaking one of these rules, log at the
NEAREST legal point instead; never skip the slice node in silence and never
bend a rule to fit it in.

A "gap" is a slice hop where it is TECHNICALLY IMPOSSIBLE to add a log without
violating the rules above (not merely difficult or inconvenient). The bar for
declaring a gap is high: exhaust all nearby alternatives first. This is
distinct from a hop skipped by the hop budget below (see SLICE SCOPE):
report each under its own `reason` in `slice_coverage.gaps`.

== SELF-CHECK BEFORE RETURNING (mandatory, before compiling) ==

Before you compile and before you return the JSON, run these two checks
yourself against every file you touched, and fix anything they catch. A
structural violation can compile clean and only break later at cleanup time,
so catching it here (not after the orchestrator's own backstop) is what keeps
a round mergeable.

Check A (non-PROTOLOG additions):
```bash
git diff -- "<file>" | grep "^+" | grep -v "^+++" | grep -v "PROTOLOG - "
```
Empty output means the file is clean. Non-empty means you added a non-PROTOLOG
line (a forbidden refactor, FORBIDDEN #2): revert it with the Edit tool and
re-run the check.

Check B (PROTOLOG mixed with business logic on the same line, FORBIDDEN #5):
```bash
git diff -- "<file>" | grep "^+" | grep -v "^+++" | grep "PROTOLOG - " \
  | grep -vE '^\+[[:space:]]*(\.also \{ )?(println|print|console\.log|System\.out\.println|fmt\.Println|puts|println!)'
```
Empty output means every PROTOLOG line is a bare standalone call or a bare
`.also {}` continuation. Non-empty means a line got glued to real code: move
it to its own line per VALID LINE SHAPES and re-run both checks.

Repeat both checks until they pass, on every touched file, before moving on
to compilation. Report the outcome in the JSON's `self_check` field: `"clean"`
if both passed with nothing to fix, or the list of what you found and
corrected.

== Full diff ==
<output of `git diff <BASE>...HEAD` + `git diff` + `git diff --cached`>

== Files to instrument ==
<file list from Step 2, <DIFF_FILES>>

== USER-SPECIFIED ENTRY POINTS (authoritative) ==
<ENTRY_POINTS from Step 2.5, or "none - derive the entry point from the diff">

When entry points are given, they are the ROOT of the slice: start tracing
there and follow the flow downward through the diff to the boundary. Do NOT
substitute a different entry point you infer on your own; if the given entry
point does not reach the diff, log both paths and report it as a gap.

== SLICE SCOPE (hop budget, not exhaustive) ==

Trace the vertical slice in BOTH directions, but under a budget:

  ENTRY POINT    the action that triggers the flow (tap, click, call, event,
                 scheduled job, etc.)
       | downward through every function/method the call passes through,
       | following from the diff UPWARD to the entry point AND DOWNWARD
       | to the boundary.
  BOUNDARY       the point where the process touches the outside world: network
                 call, DB query, file system, IPC, coroutine handoff.
       | back up through the return path
  OBSERVABLE     the visible result: UI rendered, state emitted,
  RESULT         HTTP response, record persisted, event fired.

UPWARD budget: at most 3 hops from the function the diff touches up to the
entry point. If USER-SPECIFIED ENTRY POINTS were given above, ignore the hop
count and start there instead, since the entry point is authoritative and may
sit further than 3 hops away.

DOWNWARD: stop at the first external boundary (network, DB, filesystem, IPC)
or at the boundary of a third-party framework/SDK/library. Log the call into
it and the result it returns; do not descend into its code.

Any hop that falls outside the upward budget is NOT a gap under the technical-
impossibility bar above: it is a scope cut. Report it in `slice_coverage.gaps`
with `"reason": "hop budget"` and the file:function where you stopped, so the
orchestrator can offer the dev an extra round anchored there. Do not silently
skip it without reporting.

== DENSITY (one level for the whole slice) ==

MANDATORY, for every function in the slice:

  [ ] Entry to the function with the relevant arguments (name=value)
  [ ] Exit of the function (value returned or "returning void")
  [ ] Every branch actually taken (if/else/when/guard), with the condition and its value
  [ ] Every catch/exception: exception type and message

CONDITIONAL, only when the value sits on the data path being verified (it
flows from or to the diff or the entry point, not incidental local state):

  [ ] Collection size before/after an operation on it
  [ ] Whether a nullable is null or non-null at the point of use
  [ ] Before AND after a suspend fun call
  [ ] A StateFlow/SharedFlow/LiveData emission
  [ ] Which Result/Either/sealed class variant was received
  [ ] The value going into and coming out of a flow collect/map/filter

When a value is not on that path, do not log it. This is a change in kind
from "log everything you can": skip anything off the verified path even if it
would be easy to add.

== KOTLIN LINE FORMS ==

Use these forms wherever the DENSITY section above calls for a log. This is
format, not an independent list of things to log.

  Message format - include the current thread name in EVERY log line:
    println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: description key=value")
  When coroutine debug mode is on, the thread name shows as `main @coroutine#N`,
  which is invaluable for tracing async flows. One println per site, no refactor.

  Coroutines - log before AND after each suspend fun call (when on the verified path):
    println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: calling suspendFoo(arg=$arg)")
    val result = suspendFoo(arg)
    println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: suspendFoo returned=$result")

  StateFlow/SharedFlow - when logging an emission:
    println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: emitting state=${newState}")
    _state.emit(newState)

  When branch (mandatory, per DENSITY) - log each branch actually taken with the matched value:
    when (x) {
        is Foo -> {
            println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: when branch=Foo, x=$x")
            ...
        }
        is Bar -> {
            println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: when branch=Bar, x=$x")
            ...
        }
    }

  Lists/collections - when logging a size, before operating:
    println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: list.size=${list.size}, isEmpty=${list.isEmpty()}")

  Nullable - when logging null/non-null, inside each ?.let and ?: run:
    val x = maybeNull?.let {
        println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: maybeNull is non-null, value=$it")
        it.process()
    } ?: run {
        println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: maybeNull is NULL, using fallback")
        fallback()
    }

  Data classes - when logging one, use toString() if <= 6 properties, or field by field if larger:
    println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: model=$model")

  Result/sealed class (mandatory when on the verified path, per DENSITY) - log each variant:
    result.fold(
        onSuccess = {
            println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: result=Success, data=$it")
        },
        onFailure = {
            println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: result=Failure, error=$it")
        }
    )

== MANDATORY FORMAT PER FILE TYPE ==

Detect the language by file extension and use EXACTLY:

  .kt / .kts   ->  println("PROTOLOG - <message>")
  .java        ->  System.out.println("PROTOLOG - <message>")
  .swift       ->  print("PROTOLOG - <message>")
  .ts/.tsx/.js ->  console.log("PROTOLOG - <message>")
  .py          ->  print("PROTOLOG - <message>")
  .go          ->  fmt.Println("PROTOLOG - <message>")
  .rs          ->  println!("PROTOLOG - <message>");
  .rb          ->  puts "PROTOLOG - <message>"

The message MUST start with the literal "PROTOLOG - " (with trailing space).
Standard message format: `[thread] ClassName.functionName: description key=value key2=value2`
One println per call site. Values go inside the string via interpolation.

NEVER use the app's logging framework (Timber, log4j, structlog, winston,
direct Logcat, etc.). Use ONLY the language's basic stdout.

== SINGLE-PASS COMPILE VERIFICATION (exactly 1 compile, no retries) ==

After injecting ALL logs across ALL files, run EXACTLY ONE compile/typecheck pass
that batches every touched module/target into a SINGLE invocation, so the
JVM/daemon cold-start cost is paid once this round, never once per file or per
fix. Do NOT attempt to fix and recompile if it fails; see below. Detect the
project type and use the narrowest batched check available:

  Gradle (build.gradle[.kts] present):
    derive the module per touched file (replace `/` with `:` from the repo root
    up to the directory containing build.gradle, prefixed with `:`; e.g.
    feature/home/data/... -> :feature:home:data), deduplicate the module list,
    and compile ALL of them in ONE gradle invocation (never one command per
    module, never one command per file):
      ./gradlew :modA:compileDebugKotlin :modB:compileDebugKotlin 2>&1 | tail -80
    Never pass `--no-daemon`; the Gradle daemon must persist so only the first
    compile of the whole session pays Kotlin daemon/dependency-resolution
    cold-start, not each round.
    (if JAVA_HOME is unset and Android Studio exists, export
     JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home")
  Xcode / SwiftPM:  xcodebuild build (scheme of the touched target) or swift build
  TypeScript:       tsc --noEmit (or the repo's typecheck script)
  Python:           python -m py_compile <touched files>
  Go / Rust:        go build ./... | cargo check
  Anything else:    the repo's documented build/typecheck command

Common PROTOLOG mistakes to avoid while writing lines (there is no recompile to
catch these after the fact, so get them right the first time):
- .size on a String (use .length instead)
- .isSuccessful / .code() / .body() on non-Retrofit types (use .toString())
- ?. on a non-nullable receiver
- String interpolation calling a method not available on that type

If the pass fails, do NOT fix and recompile. Read every error in the output
(file + line + message) and return the JSON with them listed under a top-level
`"compile_errors"` key instead. The orchestrator surfaces them to the user, who
decides whether to fix manually or ask for a new round, rather than the agent
spending another compile trying to self-correct.

Return the JSON immediately after this single pass, whether it came back green
or with errors captured in `compile_errors`.

Return ONLY this JSON (do not write any summary file):

{
  "files_touched": [{"path": "...", "reason": "<one line>", "log_count": <int>}],
  "files_read": <int: total source files read>,
  "total_logs_injected": <int>,
  "self_check": "clean, or the list of what Check A/B found and you corrected",
  "slice_coverage": {
    "<change-id>": {
      "entry": "<file:function where the flow starts>",
      "boundary": "<file:function at the external boundary, or null>",
      "observable_result": "<file:function where the visible result is produced>",
      "hops_covered": <int>,
      "gaps": [{"hop": "<file:function>", "reason": "technically impossible | hop budget", "detail": "<why>"}]
    }
  },
  "compile_errors": ["<file:line: message, only present if red after the single pass>"]
}
```

Omit `compile_errors` entirely (not an empty array) when the pass came back green.

### Step 4.5 - Integrity backstop before commit

The agent already ran Check A and Check B on itself (SELF-CHECK BEFORE RETURNING, in
the Step 4 prompt) before it ever compiled. This step is the orchestrator's own,
independent pass of the same two checks against the agent's committed diff, run
exactly once, so the commit gate does not rely solely on the agent's self-report.
It is a backstop, not a place to fix things: unlike the pre-7.6.0 version of this
step, it does NOT edit files, does NOT loop, and does NOT run before the agent's
compile (the agent already compiled inside Step 4; running this "before compiling"
was never actually possible and is why this step is now titled a backstop instead).

The orchestrator runs TWO checks for every file in `files_touched`:

**Check A (non-PROTOLOG additions):**

```bash
git diff -- "<file>" | grep "^+" | grep -v "^+++" | grep -v "PROTOLOG - "
```

Non-empty output means non-PROTOLOG lines were added (a forbidden refactor: expression
functions converted to block functions, an intermediate variable created only to print
its value, an empty `else {}` added, etc).

**Check B (PROTOLOG mixed with business logic on the same line, FORBIDDEN #5):**

```bash
git diff -- "<file>" | grep "^+" | grep -v "^+++" | grep "PROTOLOG - " \
  | grep -vE '^\+[[:space:]]*(\.also \{ )?(println|print|console\.log|System\.out\.println|fmt\.Println|puts|println!)'
```

Non-empty output means a PROTOLOG line got glued to real code (e.g. `X -> Y.also {
println("PROTOLOG - ...") }` inline, or `).also { println(...) }` glued to a closing
paren). This is the exact failure mode that broke a `when` block and two constructor
calls in a real incident; Check A alone missed it because the offending line does
contain `PROTOLOG - `.

Skip both checks for any file present in `/tmp/protolog-workdir-<branch>.patch` (it had
uncommitted changes before the injection, so the agent's additions cannot be cleanly
distinguished from the pre-existing ones).

**Either check non-empty, or the agent's JSON carries `compile_errors`:** STOP. Do NOT
commit, do NOT fix, do NOT recompile. Narrate the offending lines (side by side with
the agent's own `self_check` field: a `self_check: "clean"` alongside a backstop
failure here is a broken contract worth calling out on its own, not just the failure
itself). The dev decides: fix by hand with the Edit tool, ask for a new round, or
restore from `/tmp/protolog-workdir-<branch>.patch` (Step 3).

### Step 4.6 - Commit this round as [TEMP]

Once both Step 4.5 checks pass and the agent's JSON has no `compile_errors` key,
commit the round:

```bash
git add -A && git commit --no-verify -m "[TEMP] PROTOLOG debug logs (round <N>). DO NOT MERGE"
```

`<N>` starts at 1 and increments each time inject mode runs again on the same branch
without an intervening cleanup (the dev asking for more logs after reviewing the first
batch is the common case: `git log --oneline --grep '\[TEMP\] PROTOLOG'` tells you the
current count). This is what makes cleanup a plain revert instead of a text-matching
sed pass, and what keeps a fix the dev asks for mid-verification cleanly separated from
the logs: a `[TEMP]` commit contains ONLY PROTOLOG lines, never a fix. If the dev asks
for a fix while logs are live, that fix is committed separately (its own message,
no `[TEMP]` tag, never mixed into a logging commit) before or after the next round of
logs, whichever order the dev requests it in.

### Step 5 - Narrate result

After the agent returns:

- Show coverage summary: `total_logs_injected` logs across N files.
- If `<ENTRY_POINTS>` were given in Step 2.5, echo them back next to each
  slice's `entry`: *"Entry point you gave: `<ENTRY_POINTS>`. Agent anchored
  at: `<slice_coverage.entry>`."* A mismatch is not necessarily wrong (the
  agent may have found the exact function inside the file/class you named),
  but flag it if the two look unrelated.
- If there are `gaps` in any coverage, split them by `reason` and show BOTH groups:
  - `technically impossible`: *"Gaps (uninstrumented hops): [gap]. That part of the
    slice will be blind."*
  - `hop budget`: *"Cut by the hop budget: [hop] at [file:function]. Not blind by
    necessity, just not covered by default."* For these, ask via `AskUserQuestion`:
    *"I cut N hops here due to the hop budget. Want me to instrument any of them
    too?"* If the dev picks one or more, invoke `wk:protologs` again (inject mode)
    with those hops passed as the entry point, same as any `NEED_MORE_DATA` round:
    it lands as `[TEMP]` commit round N+1 via Step 4.6, on top of the current round.
- List `files_touched` with `reason` and `log_count` per file.
- Show filter commands:
  ```
  # Basic
  adb logcat | grep "PROTOLOG - "

  # With timestamps and level
  adb logcat -v time | grep "PROTOLOG - "

  # Only System.out (excludes other tags)
  adb logcat System.out:D *:S | grep "PROTOLOG - "
  ```
  (Fallback: Android Studio Logcat with filter `PROTOLOG - `)
- Remind at the end:
  *"When you are done testing, run `/wk:protologs cleanup` to remove everything without a trace."*

---

## Mode: cleanup (`/wk:protologs cleanup`)

Activated when the user types `/wk:protologs cleanup`, or when the invoking skill reaches its cleanup step.

Before Step 1, run `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/session.sh" start protologs` (same idempotent call as inject; covers the case where cleanup runs in a separate invocation from inject, e.g. a fresh session).

The primary path is reverting the `[TEMP]` commits made during inject (Step 4.6). This
is exact by construction: a `[TEMP]` commit contains only PROTOLOG lines, so reverting
it removes exactly those lines and nothing else, regardless of how many rounds of logs
or interleaved fixes happened in between. The `sed` text-match pass is only a fallback
for sessions where no `[TEMP]` commit exists (interrupted inject, pre-7.1.0 session).

### Step 1 - Enumerate [TEMP] commits

```bash
git log --format='%H %s' HEAD | grep '\[TEMP\] PROTOLOG'
```

If one or more are found, go to Step 2 (revert path). If none are found, narrate
*"No [TEMP] PROTOLOG commits found; falling back to text-match cleanup."* and go to
Step 2-fallback.

### Step 2 - Revert path

Revert each `[TEMP]` commit found in Step 1, most recent first. Always use the auto-abort
wrapper below so a conflict never leaves the repo sitting in a half-resolved revert:

```bash
git revert --no-edit <sha> || { git revert --abort 2>/dev/null; echo "CONFLICT: <sha>"; }
```

Fixes the dev requested mid-verification live in separate, non-`[TEMP]` commits and are
untouched by these reverts.

**ON CONFLICT (mandatory, no exceptions):**

If a revert conflicts (rare: a fix touched the same lines as a log), the wrapper above has
already run `git revert --abort`. From that point on:

FORBIDDEN:
1. Resolving the conflict by hand (editing the conflicted file, `git add` on it).
2. Running `git revert --continue` or `git revert --quit`.
3. Running `git commit` while a revert is still in progress.
   BAD:  fix the conflict markers with the Edit tool, `git add`, `git revert --continue`
   GOOD: confirm the abort took, then run Step 2-fallback for that commit's files only

The ONLY permitted path: confirm the abort took (`git rev-parse -q --verify REVERT_HEAD`
prints nothing), keep reverting the remaining `[TEMP]` commits with the same wrapper, then
run Step 2-fallback for the files touched by the conflicted commit only
(`git show --name-only --format= <sha>`). Step 3b is mandatory for those files, exactly as
for any other fallback-cleaned file.

Why this is absolute even when the conflict looks trivial to resolve: cleanup's guarantee
rests on exactly two verified mechanisms, a revert is exact by construction (a `[TEMP]`
commit contains only PROTOLOG lines), or the sed fallback carries its own checks (embedded-
line grep, Step 3b phantom reconciliation, Step 5 compile gate). A hand-resolved revert is
a third, unverified mechanism: its content is whatever was typed, yet Step 3b then skips
reconciliation because it assumes the revert path was exact. In a real incident an agent
hand-resolved a conflicting revert and ran `git revert --continue`; the end state happened
to be correct, but nothing in the flow verified it. Any command that completes the revert
with hand-chosen content is the same violation, whatever it is spelled as. A PreToolUse
hook (`hooks/protolog-revert-conflict-guard.sh`) also denies `--continue`/`--quit`/`git
commit` while `REVERT_HEAD` points at a `[TEMP] PROTOLOG` commit, as a backstop.

Collapsing each `[TEMP]`/revert pair out of history is left to the wrapup squash (doer) or
to the dev directly (standalone); cleanup's job is just to remove the logs, not to rewrite
history.

### Step 2-fallback - Text-match removal (only when no [TEMP] commit applies)

```bash
# tracked files
git grep -l "PROTOLOG - " 2>/dev/null

# untracked or new files (just in case)
grep -rl "PROTOLOG - " . --include="*.kt" --include="*.java" \
  --include="*.swift" --include="*.ts" --include="*.tsx" \
  --include="*.js" --include="*.py" --include="*.go" \
  --include="*.rs" --include="*.rb" 2>/dev/null
```

Deduplicate. If no file has the tag, narrate:
*"No lines with `PROTOLOG - ` found in the repo. The code is already clean."*
and stop.

For each found file, first check for embedded (non-standalone) PROTOLOG lines, since a
blind `sed` delete on those corrupts the file (the exact incident this rule prevents):

```bash
grep -n "PROTOLOG - " "<file>" \
  | grep -vE '^[0-9]+:[[:space:]]*(\.also \{ )?(println|print|console\.log|System\.out\.println|fmt\.Println|puts|println!)'
```

- No matches: every PROTOLOG line is standalone. Remove with:
  ```bash
  sed -i '' '/PROTOLOG - /d' "<file>"   # macOS / BSD
  sed -i '/PROTOLOG - /d' "<file>"      # Linux, if the above fails
  ```
- Matches found: these are `.also { println("PROTOLOG - ...") }` lines glued to real
  code (should not happen under the 7.1.0 inject rules, but a manual edit or an older
  session can still produce one). Strip only the PROTOLOG suffix, keep the line:
  ```bash
  sed -i '' -E 's/\.also \{ println\("PROTOLOG - [^"]*"\) \}//g' "<file>"   # macOS / BSD
  sed -i -E 's/\.also \{ println\("PROTOLOG - [^"]*"\) \}//g' "<file>"      # Linux
  ```
  Then re-run the grep above on that file to confirm no PROTOLOG trace and no broken
  syntax (e.g. a dangling `.also {` fragment); if the pattern does not match cleanly,
  stop and fix that file with the Edit tool by hand instead of guessing with sed.

Narrate the processed files.

### Step 3 - Verify complete cleanup

Mandatory regardless of which path (revert or fallback) was used. This is the check
that was skipped in the real incident: cleanup was reported as done without confirming
the result actually compiles.

Before anything else, confirm no revert is still in progress. A live revert here means
Step 2's ON CONFLICT rule was not followed:

```bash
git rev-parse -q --verify REVERT_HEAD && echo "REVERT IN PROGRESS" || true
git status --porcelain | grep -E '^(UU|AA|DD|AU|UA|DU|UD)' || true
```

If either prints anything, STOP: do not verify, do not report cleanup as done. Narrate
that a revert is in flight, run `git revert --abort`, and return to Step 2's ON CONFLICT
block.

```bash
git grep -n "PROTOLOG - " 2>/dev/null || true
grep -rn "PROTOLOG - " . --include="*.kt" --include="*.java" \
  --include="*.swift" --include="*.ts" --include="*.tsx" \
  --include="*.js" --include="*.py" --include="*.go" \
  --include="*.rs" --include="*.rb" 2>/dev/null || true
```

- If empty -> narrate: *"No trace of `PROTOLOG - ` remains. Proceeding to restore phantom files."*
- If lines still exist -> narrate which ones, do NOT delete them automatically;
  ask the user to review them manually before continuing.

### Step 3b - Restore files outside the original diff

**This step is mandatory when the fallback (Step 2-fallback) ran.** When the revert
path (Step 2) ran, the reverted `[TEMP]` commit already restored exactly the files it
touched, so there is nothing left to reconcile; skip straight to Step 4. Only the sed
fallback needs this reconciliation, because the logger-agent intentionally instruments
files outside the branch diff (callers, use cases, repositories) and `sed` has no
concept of "this file's changes came from one commit".

**Determine `<BASE>`**: run the same auto-detection as inject Step 1 (upstream
tracking -> develop -> main -> master). If multiple candidates are found, show them
to the user via `AskUserQuestion` and let them pick one. The chosen branch is
`<BASE>` for the rest of this step.

```bash
# 1. Files currently dirty in the working tree
git diff --name-only
git diff --cached --name-only

# 2. Files that are part of the branch's intended changes
git diff <BASE>...HEAD --name-only
```

Cross-reference: any file that appears in (1) but NOT in (2) is a **phantom** -- it
was clean before the logger agent touched it. Restore is **conditional**: the logs go,
but any correction the user made to a phantom during testing must be kept.

For each phantom, after `sed` (Step 2) already removed its PROTOLOG lines, check whether
anything besides PROTOLOG changed:

```bash
git diff --quiet -- "<phantom>"
```

- **Exit 0** (no diff vs HEAD): the file is clean, the agent only added PROTOLOG lines and
  they are now gone. Run `git restore <phantom>` (a no-op that also clears the working
  tree of any residue).
- **Exit 1** (diff exists): the file has non-PROTOLOG changes. These may be corrections the
  user made or refactors from the agent that survived. Do NOT restore automatically. Show
  `git diff -- <phantom>` and ask the user: *"This file has changes after cleanup. Keep or
  discard?"* Only run `git restore <phantom>` if they choose to discard.

After processing every phantom, re-run:

```bash
git diff --name-only
```

Narrate each file restored and each file kept per the user's choice. Never force-restore a
phantom with non-PROTOLOG changes without the user's explicit confirmation.

### Step 4 - Final working-tree confirmation

Run a last sanity check and narrate the result:

```bash
git status --short
```

- If the only modified files are those from `git diff <BASE>...HEAD --name-only`
  (the branch's intended changes, minus their PROTOLOG lines) -> narrate:
  *"Working tree is clean of PROTOLOG. Only your intended branch changes remain."*
- If unexpected files still appear -> show them and ask the user to decide.

### Step 5 - Mandatory compile verification before reporting success

**Never narrate the working tree as clean without running this step.** Reporting
cleanup success without validating the result is exactly what let the earlier incident
(corrupted `when` block, unclosed constructor calls) go unnoticed until the next build.

Detect the affected modules from the files touched by the reverted `[TEMP]` commits (or,
on the fallback path, from `files_touched` in the original inject JSON), deduplicate them,
and run the same batched, single-pass check as inject's compile verification (see
Step 4), one gradle invocation covering every affected module, e.g.:

```bash
./gradlew :modA:compileDebugKotlin :modB:compileDebugKotlin --stacktrace 2>&1 | tail -60
```

- Compiles clean -> narrate *"Working tree is clean of PROTOLOG and compiles clean."*
- Fails -> narrate the exact error and STOP. Do NOT report cleanup as done and do NOT
  recompile automatically (fallback path: this likely means an embedded PROTOLOG line
  the first pass missed; revert path: this should not happen since Step 4.6 already
  required a clean compile before committing, so treat it as noteworthy). Hand the
  error off to the user to decide the fix rather than looping recompiles -- this
  mirrors inject's single-pass cap.

### Step 6 - Release the session marker (standalone only)

If this cleanup run was invoked directly (`/wk:protologs cleanup` typed by the user),
run `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/session.sh" stop`. If it was invoked by `/wk:doer`
Stage 4 or `/wk:bugfix` Stage 6, skip this: those skills own the marker's lifecycle and
release it themselves at their own wrapup, since the parent session is still active after
this cleanup step returns.

---

## General narration rules

- Begin each action with a short English line describing what is being done.
- Never use em dashes in any response.
- Build or git errors are always narrated; never silenced.
- This skill's only commits are its own `[TEMP]` PROTOLOG commits (inject) and their
  reverts (cleanup). It never commits or pushes business logic, and it never pushes
  anything to a remote. Any real fix the dev asks for mid-verification is committed
  separately by whichever workflow owns that change (doer's Stage 3/4 loop, or the dev
  directly when the skill runs standalone).
