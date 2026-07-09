---
name: protologs
description: >-
  Injects temporary debug logs (tag PROTOLOG) into the vertical slice of the
  current diff to verify runtime behavior on device. Two modes:
  - /wk:protologs          -> injects logs (asks to confirm base branch),
    commits them as a [TEMP] commit so multiple rounds of logs and any
    fixes requested in between stay individually trackable.
  - /wk:protologs cleanup  -> reverts every [TEMP] commit (sed removal is
    only a fallback), leaving the code identical to its original state, and
    verifies no trace remains. Also invoked by /wk:doer Stage 4 and
    /wk:bugfix Stage 6 for on-device runtime verification.
version: 7.1.0
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

Combine and deduplicate the three lists. If the result is empty, narrate:
*"No changes between the current branch and `<BASE>`. Nothing to instrument."*
and stop without touching any files.

Show the file list to the user and confirm via `AskUserQuestion`:
*"I will instrument the vertical slice of these N files vs `<BASE>`. Continue?"*

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
with the tag "PROTOLOG - " to the vertical slice of the change described below.

PHILOSOPHY: MORE IS BETTER. When in doubt between adding or skipping a log,
ADD IT. The goal is coverage saturation so that any behavioral issue can be
diagnosed on device.

== Full diff ==
<output of `git diff <BASE>...HEAD` + `git diff` + `git diff --cached`>

== Files to instrument ==
<file list from Step 2>

== SLICE SCOPE ==

Do not limit yourself to the diff. Trace the COMPLETE vertical slice in BOTH
directions:

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

Read every file needed to trace the slice. There is no file limit; completeness
is the stopping criterion. Follow calls all the way to the real entry point
(ViewModel, Fragment, Composable, BroadcastReceiver, WorkManager, etc.). Do not
stop at the first layer you see.

Stop ONLY at the boundary of third-party frameworks/SDKs/libraries (log the
call into them and the result they return, but do not descend into their code).

== MANDATORY MINIMUM-DENSITY CHECKLIST ==

For EVERY function in the slice (not just the changed ones), you MUST log:

  [ ] Entry to the function with ALL relevant arguments (name=value)
  [ ] Exit of the function (value returned or "returning void")
  [ ] Every conditional branch taken (if/else/when/guard) with the condition and its value
  [ ] Every collection: its size BEFORE and AFTER operating on it
  [ ] Every nullable: whether it is null or non-null at the point of use
  [ ] Every call to an in-slice function: what is called and with what args
  [ ] Every state change (StateFlow.emit, LiveData.value=, MutableState, etc.)
  [ ] Every suspension point in coroutines (before AND after each suspend fun call)
  [ ] Every catch/exception: exception type and message
  [ ] Every Result/Either/sealed class: which variant was received
  [ ] Every flow collect/map/filter: the value going in and the value coming out

== MANDATORY KOTLIN PATTERNS ==

For Kotlin specifically, in addition to the checklist above:

  Message format - include the current thread name in EVERY log line:
    println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: description key=value")
  When coroutine debug mode is on, the thread name shows as `main @coroutine#N`,
  which is invaluable for tracing async flows. One println per site, no refactor.

  Coroutines - log before AND after each suspend fun call:
    println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: calling suspendFoo(arg=$arg)")
    val result = suspendFoo(arg)
    println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: suspendFoo returned=$result")

  StateFlow/SharedFlow - log on every emit:
    println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: emitting state=${newState}")
    _state.emit(newState)

  When exhaustive - log each branch with the matched value:
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

  Lists/collections - log before operating:
    println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: list.size=${list.size}, isEmpty=${list.isEmpty()}")

  Nullable - log inside each ?.let and ?: run:
    val x = maybeNull?.let {
        println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: maybeNull is non-null, value=$it")
        it.process()
    } ?: run {
        println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: maybeNull is NULL, using fallback")
        fallback()
    }

  Data classes - log with toString() if <= 6 properties, or field by field if larger:
    println("PROTOLOG - [${Thread.currentThread().name}] ClassName.fn: model=$model")

  Result/sealed class - log each variant:
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

== VALID LINE SHAPES (only these two exist) ==

Every PROTOLOG line occupies its own full line, with nothing else on it, so that
deleting it (by text match on "PROTOLOG - ") leaves the surrounding code exactly
as it was:

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
one physical line; deleting it by text match deletes the logic with it. This is
exactly the bug that broke a `when` block and two constructor calls in a real
incident. The `.also {}` ALWAYS goes on its own line below.

== DO NOT RULES (critical for perfect cleanup) ==

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
   standalone `.also {}` form from VALID LINE SHAPES above, never inline it):
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

Every modified file must be such that deleting all lines containing "PROTOLOG - "
restores it to a syntactically identical state to its exact prior state.

A "gap" is a slice hop where it is TECHNICALLY IMPOSSIBLE to add a log without
violating the rules above (not merely difficult or inconvenient). The bar for
declaring a gap is high: exhaust all nearby alternatives first.

== MANDATORY COMPILE VERIFICATION ==

After injecting all logs, compile/typecheck ONLY the parts of the project that
contain files you modified. Do NOT return the JSON until everything you touched
compiles cleanly. Detect the project type and use the narrowest check available:

  Gradle (build.gradle[.kts] present):
    derive the module per touched file (replace `/` with `:` from the repo root
    up to the directory containing build.gradle, prefixed with `:`;
    e.g. feature/home/data/... -> :feature:home:data) and run:
      ./gradlew :<module>:compileDebugKotlin 2>&1 | tail -60
    (if JAVA_HOME is unset and Android Studio exists, export
     JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home")
  Xcode / SwiftPM:  xcodebuild build (scheme of the touched target) or swift build
  TypeScript:       tsc --noEmit (or the repo's typecheck script)
  Python:           python -m py_compile <touched files>
  Go / Rust:        go build ./... | cargo check
  Anything else:    the repo's documented build/typecheck command

If the check fails:
1. Read the exact error (file + line number + message).
2. Fix ONLY the PROTOLOG line that caused it -- never touch business logic.
3. Re-compile that same module.
4. Repeat until it is green.

Common PROTOLOG mistakes to check before compiling:
- .size on a String (use .length instead)
- .isSuccessful / .code() / .body() on non-Retrofit types (use .toString())
- ?. on a non-nullable receiver
- String interpolation calling a method not available on that type

Only after every touched module compiles cleanly, return the JSON.

Return ONLY this JSON (do not write any summary file):

{
  "files_touched": [{"path": "...", "reason": "<one line>", "log_count": <int>}],
  "files_read": <int: total source files read>,
  "total_logs_injected": <int>,
  "slice_coverage": {
    "<change-id>": {
      "entry": "<file:function where the flow starts>",
      "boundary": "<file:function at the external boundary, or null>",
      "observable_result": "<file:function where the visible result is produced>",
      "hops_covered": <int>,
      "gaps": ["<hop that COULD NOT be instrumented (technically impossible) and why>"]
    }
  }
}
```

### Step 4.5 - Detect forbidden refactors (mandatory, before compiling)

The agent sometimes violates DO NOT RULE #2: it converts expression functions to block
functions, creates intermediate variables only to print their value, or adds empty
`else {}` blocks. These structural changes do NOT contain `PROTOLOG - `, so they survive
the `sed` cleanup and corrupt the code. This check catches them before compilation.

After the agent returns its JSON but BEFORE compiling, the orchestrator (NOT the agent)
runs TWO checks for every file in `files_touched`:

**Check A (non-PROTOLOG additions):**

```bash
git diff -- "<file>" | grep "^+" | grep -v "^+++" | grep -v "PROTOLOG - "
```

- **Empty output**: the file is clean, only `PROTOLOG - ` lines were added. Continue.
- **Non-empty output**: the agent added non-PROTOLOG lines (forbidden refactors). Do NOT
  compile. Narrate the offending lines. Revert them with the Edit tool (examples:
  `else -> { Unit }` back to `else -> Unit`; expression functions restored to their
  original form; intermediate variables eliminated). Re-run the check until it passes.
  Only then compile.

**Check B (PROTOLOG mixed with business logic on the same line, DO NOT RULE #5):**

```bash
git diff -- "<file>" | grep "^+" | grep -v "^+++" | grep "PROTOLOG - " \
  | grep -vE '^\+[[:space:]]*(\.also \{ )?(println|print|console\.log|System\.out\.println|fmt\.Println|puts|println!)'
```

A line only survives this filter if it contains `PROTOLOG - ` but is NOT a bare
`println(...)` / `print(...)` / etc. or a bare `.also { println(...) }` continuation
line. Non-empty output means the injection put PROTOLOG on the same physical line as
real code (e.g. `X -> Y.also { println("PROTOLOG - ...") }` inline, or `).also {
println(...) }` glued to a closing paren). Do NOT compile. Move the `.also {}` (or the
println) to its own line per VALID LINE SHAPES, re-run BOTH checks until they pass, only
then compile. This is the exact failure mode that broke a `when` block and two
constructor calls in a real incident; Check A alone missed it because the offending
line does contain `PROTOLOG - `.

Skip both checks for any file present in `/tmp/protolog-workdir-<branch>.patch` (it had
uncommitted changes before the injection, so the agent's additions cannot be cleanly
distinguished from the pre-existing ones).

### Step 4.6 - Commit this round as [TEMP]

Once both Step 4.5 checks pass and the touched modules compile clean, commit the round:

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
- If there are `gaps` in any coverage, show them FIRST:
  *"Gaps (uninstrumented hops): [gap]. That part of the slice will be blind."*
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

### Step 6 - Optional re-verification build

The agent already compiled every touched module as part of the injection step and
auto-fixed any PROTOLOG syntax errors before returning. This step is an optional
extra pass you can offer to the user for peace of mind.

Offer via `AskUserQuestion`: *"The agent already compiled and verified the injected
logs. Do you want a second compile pass to double-check? (takes ~1-2 min)"*

If they accept, detect the affected modules from `files_touched` and run:

```bash
# same per-project-type check as the injection step, e.g. for Gradle:
./gradlew :<module>:compileDebugKotlin --stacktrace 2>&1 | tail -40
```

If it fails despite the agent's self-fix, narrate the error and offer the user to
revert with the backup patch.

---

## Mode: cleanup (`/wk:protologs cleanup`)

Activated when the user types `/wk:protologs cleanup`, or when the invoking skill reaches its cleanup step.

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

Revert each `[TEMP]` commit found in Step 1, most recent first:

```bash
git revert --no-edit <sha>
```

Fixes the dev requested mid-verification live in separate, non-`[TEMP]` commits and are
untouched by these reverts. If a revert conflicts (rare: a fix touched the same lines as
a log), run `git revert --abort` and fall through to Step 2-fallback for the affected
files only. Collapsing each `[TEMP]`/revert pair out of history is left to the wrapup
squash (doer) or to the dev directly (standalone); cleanup's job is just to remove the
logs, not to rewrite history.

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
on the fallback path, from `files_touched` in the original inject JSON) and run the same
per-project-type check as inject Step 4's compile verification, e.g. for Gradle:

```bash
./gradlew :<module>:compileDebugKotlin --stacktrace 2>&1 | tail -40
```

- Compiles clean -> narrate *"Working tree is clean of PROTOLOG and compiles clean."*
- Fails -> narrate the exact error, do NOT report cleanup as done, fix the offending
  file (fallback path: re-check for an embedded PROTOLOG line the first pass missed;
  revert path: this should not happen since Step 4.6 already required a clean compile
  before committing) and re-run this step until it passes.

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
