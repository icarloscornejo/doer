# Stage 7. Runtime Verify (Live Debug Logs, Temporary)

**Goal:** verify on-device behavior against ACs via dense temporary debug logs. Logs NEVER reach the final branch.

## Always ask (Stage 7 is NEVER auto-skipped)

**Stage 7 MUST be explicitly approved or skipped by the dev.** The orchestrator MUST NOT skip Stage 7 silently under any circumstance, including when the diff is 100% docs/config and no runtime code was touched. Silent auto-skip is forbidden because it produces false-positive skips that hide real verification gaps.

Classify the diff first to inform the default suggestion (this is for UX only, NOT a skip decision):

```bash
git diff --name-only <base>..HEAD
```

Classify each path:
- **Non-runtime:** `*.md`, files under `docs/`, `README*`, `CHANGELOG*`, `*.yml`/`*.yaml`/`*.json` config, `*.env.example`, `.github/`, `.gitlab-ci.yml`, `package.json` (only version/dep edits), `build.gradle` (only version/dep edits).
- **Runtime:** anything else (source code, real config that the app reads at runtime, migrations, etc.).

Then ALWAYS ask via `AskUserQuestion`. The classification picks the default suggestion but does NOT bypass the prompt:

**Case A. All paths are non-runtime:**
```
Question: Stage 7 is runtime verification on device. The diff in this ticket is
100% non-runtime (docs/config only). There is likely nothing to exercise on
device. How do you want to proceed?

Options:
  - Skip Stage 7 (recommended): mark as skipped with reason "no runtime code in diff"
  - Run Stage 7 anyway: I will inject debug logs and you exercise on device
```

**Case B. At least one path is runtime:**
```
Question: Stage 7 is runtime verification on device. The diff touches runtime
code. Do you want to exercise the ACs on a real device/simulator now?

Options:
  - Run Stage 7 (recommended): I will inject debug logs and walk you through
  - Skip Stage 7: mark as skipped, you take responsibility for runtime correctness
```

In BOTH cases, the dev's choice is recorded:

- **If skipped:**
  ```json
  metadata.stages.7.status = "skipped"
  metadata.stages.7.skipped_reason = "<dev's chosen reason or default text from the option>"
  metadata.stages.7.skipped_acknowledged_by = "dev"
  narrate: "Stage 7 skipped at dev's request: <reason>. Continuing to Stage 8."
  ```
  Run the Stage Finalization Checklist and proceed: Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/08-docs-sync.md` and ONLY that file.
- **If run:** proceed to Step 1 (Inject logs) below.

**Why no silent auto-skip:** even on a doc-only diff, the dev may have manually changed runtime behavior outside the doer flow (e.g. a hotfix on another branch that got merged in), or the classification heuristic may misjudge a file (e.g. a YAML that the app actually reads at runtime). Asking always is cheap (one prompt) and prevents Claude from quietly dropping the only on-device verification step.

## Log format (language-aware)

The orchestrator instructs the logger agent to use the language's basic stdout/console output (NOT the app's logger framework). The format is:

```
<basic-stdout-of-the-language>("DOER - <message>")
```

| Language | Output | Example |
|----------|--------|---------|
| Kotlin / Scala | `println(...)` | `println("DOER - LoginViewModel.onSubmit validating credentials")` |
| Java | `System.out.println(...)` | `System.out.println("DOER - AuthService refreshing token")` |
| Swift | `print(...)` | `print("DOER - LoginVC tapped submit button")` |
| TypeScript / JavaScript | `console.log(...)` | `console.log("DOER - useAuth state=loading")` |
| Python | `print(...)` | `print("DOER - login_handler validating user")` |
| Go | `fmt.Println(...)` | `fmt.Println("DOER - HandleLogin received request")` |
| Rust | `println!(...)` | `println!("DOER - validate_login start")` |
| Ruby | `puts(...)` | `puts "DOER - LoginController#create called"` |

**Rules for the message:**
- ALWAYS prefix with `DOER - ` (with the trailing space). The grep tag for cleanup.
- The message itself must include enough context to identify origin (class name, function name, key=value pairs as needed). The agent decides how much context.
- Single ticket active in runtime-verify at a time. Concurrent runtime-verify on multiple tickets is not supported (the grep tag `DOER - ` would mix them).

## Step 1: Inject logs

MUST invoke a general-purpose runtime-logger sub-agent via the Agent tool. The orchestrator MUST NOT inject the debug logs inline:

```
You are the runtime-logger agent for ticket <TICKET-ID>.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump>

== metadata.plan ==
<JSON dump>

== Diff ==
<output of `git diff <base>..HEAD`>

Scope: every file in the diff PLUS every file in the call path the ACs
exercise (deps, helpers, repositories, view models). Follow imports
outward from the diff. Stop at framework/SDK boundaries.

Read budget: every file in the diff (mandatory; you must read all of them)
PLUS up to 5 additional source files for call-path exploration. The +5 caps
exploration, not diff reads. If a BLOCKER genuinely requires more than 5
extra files, note the extra reads in your output and proceed.

Log: function entry (args), conditional branches (which + why), state
changes, external boundaries (API/DB/IO/threads/coroutines), exception
catches, function exit (return or void).

Format MANDATORY: <basic stdout for the file's language>("DOER - <message>")

The "basic stdout" varies per language. Detect by file extension:
- .kt / .kts / .scala  ->  println(...)
- .java                ->  System.out.println(...)
- .swift               ->  print(...)
- .ts / .tsx / .js / .jsx / .mjs  ->  console.log(...)
- .py                  ->  print(...)
- .go                  ->  fmt.Println(...)   (import "fmt" if missing)
- .rs                  ->  println!(...)
- .rb                  ->  puts ...
Default for any other: pick the language's most basic stdout/console output.
NEVER use the app's logger framework (Timber, log4j, structlog, winston, etc.).

The message must:
- Start with literal `DOER - ` (with the trailing space). This is the grep tag.
- Include enough context to identify origin (class name, fn name, key=value).
- Be concise. One line per call site.

Rules: never modify business logic, never touch existing logs, run the
build after to verify syntax.

DO NOT (these survive cleanup and pollute the PR):
- Create a variable solely to print its value. Inline the expression.
    Wrong:  val endpoint = if (x) "a" else "b"; println("DOER - ... endpoint=$endpoint")
    Right:  println("DOER - ... endpoint=${if (x) "a" else "b"}")
- Refactor existing code to enable logging. Do not split returns,
  chains, or expressions just to capture an intermediate value.
    Wrong:  val r = foo(); println("DOER - ... $r"); return r
    Right:  println("DOER - ... calling foo"); return foo()    (or skip this log)
- Add helpers, factories, or any function that is not a print/log line.
  The logger's only job is to add stdout calls. Anything else is out of scope.

Return a JSON list of files touched + one-line reason each. Do NOT
write a summary file, the orchestrator narrates it inline.
```

## Step 2: Temporary commit

```bash
git add -A
git commit --no-verify -m "doer(<TICKET-ID>): [TEMP] runtime debug logs. DO NOT MERGE"
```

Commit is identified later by its unique message prefix.

## Step 3: Hand off to dev

Narrate the file list inline + build/filter commands. **Project-aware filter suggestion**: detect the project type from the diff's file extensions and offer the simplest filter as the primary recommendation, with native OS log streams as fallback for release builds.

| Project type | Primary filter (simplest) | Fallback (release builds, no Metro/dev server) |
|---|---|---|
| React Native (`.tsx`/`.jsx` in diff) | Metro bundler stdout: pipe `pnpm run bundle:ios` (or equivalent) through `grep "DOER - "` | iOS: `xcrun simctl spawn booted log stream --predicate 'eventMessage CONTAINS "DOER - "'` / Android: `adb logcat \| grep "DOER - "` |
| Native iOS (`.swift` in diff) | `xcrun simctl spawn booted log stream --predicate 'eventMessage CONTAINS "DOER - "'` | Xcode console |
| Native Android (`.kt`/`.java` in diff) | `adb logcat \| grep "DOER - "` | Android Studio Logcat |
| Web (`.ts`/`.js` not in RN tree) | Browser DevTools console | Node test runner stdout |
| Backend (Python, Go, Rust, Ruby, Java server) | Process stdout / `tail -f` of the run command | Container logs / journald |

Use the table to pick the filter. If unclear, offer the top two options and let the dev pick.

```
Runtime logs injected across N files: <list>.
Build & run: <build command, detect or ask once, persist as metadata.runtime_build_command>
Exercise each AC, filter with: <primary filter from the table for this project type>
                       (fallback: <fallback filter from the table>)
Paste filtered output here when ready.
```

## Step 4: Analyze logs

When the dev pastes the log output, MUST invoke a runtime-log analyzer sub-agent via the Agent tool, passing the log output **directly in the prompt** (no intermediate `runtime-log-output.txt`, the logs may be huge, no point persisting them). The orchestrator MUST NOT analyze the logs inline:

```
You are the runtime-log analyzer for ticket <TICKET-ID>.

The orchestrator has inlined these below:

== metadata.ac ==
<JSON dump>

== metadata.plan ==
<JSON dump>

Log excerpt from the dev's session:
<<<
{paste the user's log output here verbatim}
>>>

For each AC: was the code path hit? Did values match expected? Any
unexpected errors? Any branch that should have been exercised but wasn't?

Read budget: 0 source files. You receive metadata.ac, metadata.plan, and the
log paste inline. Do NOT read code. Your job is pure analysis on the inputs.

Return JSON:
{
  "ac_verdicts": {"AC-1": "PASS|FAIL|NOT_EXERCISED", ...},
  "evidence": {"AC-1": "<which log lines support the verdict>", ...},
  "anomalies": [...],
  "recommendation": "APPROVE | RETURN_TO_STAGE_2 | RETURN_TO_STAGE_3 | RETURN_TO_STAGE_4 | NEED_MORE_DATA",
  "rationale": "<one paragraph>"
}
```

Present the recommendation to dev: *"Analyzer recommends: <action>. <rationale>. Apply? [Y / explain / override]"*

Branches:
- **APPROVE** → Step 5
- **RETURN_TO_STAGE_N** → cleanup first, then jump back to N with findings as BLOCKERs
- **NEED_MORE_DATA** → keep logs, loop back to Step 3
- **Override** → honor dev's choice, record reason

## Step 5: Cleanup

```bash
TEMP_SHA=$(git log --grep="^doer(<TICKET-ID>): \[TEMP\] runtime debug logs" --format="%H" | head -n1)
[ -z "$TEMP_SHA" ] && { echo "ERROR: temp commit not found"; exit 1; }

git revert --no-edit "$TEMP_SHA"
git commit --no-verify --amend -m "doer(<TICKET-ID>): remove runtime debug logs"

# 5a. Tag check, zero printlns with the DOER tag must remain.
if git grep -l "DOER - " -- .; then
  echo "ERROR: Residual DOER logs found"; exit 1
fi

# 5b. Out-of-temp-commit drift check, anything that was changed by
# the temp commit but is no longer present in the revert means a debug
# artifact was added in a different commit and survived the revert.
TEMP_FILES=$(git show --pretty=format: --name-only "$TEMP_SHA" | sort -u)
DRIFT=$(for f in $TEMP_FILES; do
  if [ -f "$f" ] && ! git diff "$TEMP_SHA^" -- "$f" | grep -q .; then continue; fi
  # Compare file vs base for changes that don't match the temp commit's reverse:
  diff <(git show "$TEMP_SHA":"$f" 2>/dev/null) <(cat "$f" 2>/dev/null) > /dev/null 2>&1 || echo "$f"
done)
# Heuristic check: variables introduced and never referenced, helper
# functions added without callers, single-expression returns split into
# val + return. These often slip past the tag grep. The orchestrator
# MUST diff <base>..HEAD on every file the temp commit touched and
# scan for these patterns:
echo "Reviewing files touched by temp commit for non-log debug artifacts..."
for f in $TEMP_FILES; do
  CURRENT_DIFF=$(git diff <base>..HEAD -- "$f")
  if [ -n "$CURRENT_DIFF" ]; then
    echo "WARNING: $f still has changes after revert, likely a debug helper or refactor not in the temp commit."
    echo "Inspect manually:  git diff <base>..HEAD -- $f"
  fi
done
```

If residuals or drift detected:
- Tag residuals: re-invoke logger with *"Remove every line matching `DOER - `. Touch nothing else."*
- Drift residuals: invoke a general-purpose agent with the diff and the instruction *"This file was touched during runtime-verify. Remove any change that was added solely to enable debug logging, variables that captured a value just to print it, expressions split into val+return, helper functions with no real callers. Keep only the changes that belong to the ticket's actual implementation per `metadata.plan` (inlined in this prompt: <JSON dump>)."*

After the agent completes, amend onto the previous commit:
```bash
git add -A
git commit --no-verify --amend --no-edit
```

See `${CLAUDE_PLUGIN_ROOT}/lib/debugging.md` for additional drift-handling guidance.

## Step 6: Record outcome

Persist to `metadata.stages.7`:
```json
{
  "name": "runtime-verify",
  "status": "complete",
  "ac_verdicts": {"AC-1": "PASS", ...},
  "returns_triggered": [],
  "completed_at": "<ISO8601>"
}
```
No SHAs persisted (git history IS the source of truth). No commit needed (`.doer/` gitignored).

Run the Stage Finalization Checklist (`${CLAUDE_PLUGIN_ROOT}/lib/stage-checklist.md`) before transitioning. Auto-proceed: Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/08-docs-sync.md` and ONLY that file.
