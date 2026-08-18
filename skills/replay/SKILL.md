---
name: replay
description: >-
  Emulates a bug scenario at full fidelity directly in the app's own source, so it
  reproduces on a device in ANY environment regardless of actual backend content,
  feature flags, or A/B bucket. Invoke as "/wk:replay" (inject) or "/wk:replay
  cleanup". Not a proxy, not an OkHttp interceptor, not a mock server: forced data
  flows through the app's own parser and mappers, zero external setup. Two
  techniques, combinable, chosen with the dev: network response replay (a body
  captured in a Charles/HAR session, forced at the deserialization seam) and
  flag/kill-switch forcing (forced at the read site). Runs only after the real fix
  is committed, and before /wk:protologs when both are used together (e.g.
  /wk:bugfix Stage 6, which invokes this skill first). Standalone in any repo, no
  dependency on bugfix.json.
version: 7.7.0
user-invocable: true
allowed-tools: [Read, Edit, Grep, Glob, Bash, AskUserQuestion, Agent]
---

# replay

Emulates a bug scenario (a captured network response, an internal flag or kill
switch, or both) directly in the current branch's source, so the exact scenario
reproduces on a device without depending on the real backend, CMS, or A/B
assignment. Works standalone in any repo; `/wk:bugfix` Stage 6 invokes it before
`/wk:protologs`, but it has no dependency on bugfix's state file.

---

## How the tag works

Every injected log line carries the exact prefix `PROTOLOG_RESPONSE - ` (with
trailing space), deliberately different from `/wk:protologs`' own `PROTOLOG - ` tag
so the two never collide: `grep "PROTOLOG - "` does not match a
`PROTOLOG_RESPONSE - ` line and vice versa, so each skill's cleanup only ever
strips its own logs.

Filter on Android device:

```
adb logcat | grep "PROTOLOG_RESPONSE - "
```

Fallback: Android Studio Logcat with filter `PROTOLOG_RESPONSE - `.

---

## Injected code shape (the contract)

Every replay edit is wrapped in a sentinel block:

```kotlin
// REPLAY START <TAG>
// REPLAY-ORIG:    val orders = api.getOrders(id)
    val forcedRaw = REPLAY_RAW
    val forced: ApiResponse<List<OrderDto>> = gson.fromJson(forcedRaw, forcedType)
    println("PROTOLOG_RESPONSE - [${Thread.currentThread().name}] Repo.orders: replay entry, id=$id, flagX=$flagX")
    val orders = forced.data.map { it.toDomain() }
    println("PROTOLOG_RESPONSE - [${Thread.currentThread().name}] Repo.orders: replay applied, count=${orders.size}")
// REPLAY END <TAG>
```

`<TAG>` is the ticket KEY when known, or `standalone` when there is none. Rules,
in order of how often they matter:

1. **Every original line the block replaces gets a `REPLAY-ORIG:` line above it**,
   in the same block, carrying the original line **verbatim, including its own
   leading whitespace**, after the literal marker `// REPLAY-ORIG:` (or `#
   REPLAY-ORIG:` in a `#`-comment language; the marker text itself is what
   matters, not the comment syntax around it). This is what makes cleanup an
   exact, provable operation instead of a guess: "strip every block, keeping only
   the `REPLAY-ORIG:` payloads" reconstructs the file byte for byte.
2. **A purely additive block (nothing deleted at that point) carries NO
   `REPLAY-ORIG:` line at all.** Never emit an empty `REPLAY-ORIG:` line to mean
   "nothing to restore": an empty marker restores to an actual blank line, which
   is wrong when no line existed there before. Omit the line entirely.
3. **Exactly two `PROTOLOG_RESPONSE - ` logs per forced site**: one at entry (the
   discriminating inputs the branch depends on: ids, flags, bucket), one right
   after the forced value is produced (the payload or its key fields). Not
   protologs' density: protologs covers the rest of the slice when the dev wants
   it (see Step 9).
4. **Never nest a `REPLAY START` inside another open block.** Sequential blocks in
   the same file are fine; a `REPLAY START` while a previous block has not been
   closed with its `REPLAY END` is a structural violation and gets denied by the
   integrity guard.
5. **Never create a new file.** The sub-agent's own tool access does not enforce
   this (see Step 5), so it is enforced by both the agent's prompt and
   `hooks/replay-temp-commit-integrity-guard.sh`, which denies any new untracked
   source file in a `[TEMP] REPLAY` commit.

This contract is what makes `hooks/replay-restore.py` usable as BOTH the
integrity guard's check and cleanup's actual removal operation: they run the
exact same transformation, so a passing guard is a proof the fallback is safe,
not a hope.

---

## Mode: inject (default)

Activated when the user types `/wk:replay` with no arguments, or when `/wk:bugfix`
Stage 6 invokes this skill in inject mode.

### Step 0 - Session marker + technique

Run `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/session.sh" start replay` (idempotent, safe
even when `/wk:bugfix` already started its own marker for this session).

Then ask which technique the scenario needs. This is a closed set of 2-4 mutually
exclusive options, so per `lib/narration.md` it is an `AskUserQuestion`, not plain
chat:

- **Network response**: a captured Charles/HAR session drives the scenario.
- **Flags / kill switches**: no network evidence, but internal flags gate the
  buggy branch.
- **Both**: a content response and a flag need to agree (e.g. a p13n response
  gated by a flag).

The answer selects which of Steps 2-3 (network) and the flag-forcing path (folded
into Step 5's agent work, see "Flag / kill-switch forcing" below) actually run.

### Step 1 - Anchor the pre-replay state

```bash
PRE_REPLAY_SHA=$(git rev-parse HEAD)
git status --porcelain
```

Narrate `PRE_REPLAY_SHA`. This is the recovery anchor: `git checkout
<PRE_REPLAY_SHA> -- <files>` restores exactly, handles deletions (unlike a text
patch), needs no state file, and is recoverable on a later session as `<first
[TEMP] REPLAY sha>^` (`git log --format='%H %s' | grep '\[TEMP\] REPLAY'`, take the
oldest, then `^`). This is why replay does not depend on `bugfix.json`: the repo's
own history is the source of truth.

If the working tree is not clean, or HEAD looks like a `[TEMP]` commit rather than
a real fix, warn (do not block): *"The working tree isn't in the state I'd expect
after a committed fix. Replay will still work, but double check you're not about
to mix an uncommitted change into the forced-response commit."* An uncommitted fix
tangles with the forced code in one diff and turns cleanup from a clean revert
into a manual split.

### Step 2 - Locate the evidence (network technique only)

Reuse `~/Downloads/<KEY>/charles/` when `/wk:bugfix` already downloaded it for this
ticket. Otherwise ask (plain chat, open-ended) for the `.har`, or a `.chls` to
convert:

```bash
command -v makehar >/dev/null && makehar "<in.chls>" \
  || [ -x "/Applications/Charles.app/Contents/MacOS/Charles" ] \
     && /Applications/Charles.app/Contents/MacOS/Charles convert "<in.chls>" "<out.har>"
```

### Step 3 - Pick the endpoints

Parse the HAR with `python3`, listing method/status/size/url per entry. **Never
read a whole HAR into context**; HAR files are huge and most of it is irrelevant.

```python
import json, sys
har = json.load(open(sys.argv[1]))
for i, e in enumerate(har["log"]["entries"]):
    req, res = e["request"], e["response"]
    size = res["content"].get("size", -1)
    print(f"{i}: {req['method']} {res['status']} {size}B {req['url']}")
```

Present the numbered list in chat (plain chat: the candidate count is unbounded,
so it does not fit `AskUserQuestion`'s 4-option cap) and ask which entries drive
the scenario. For the chosen ones, print only a short head of the body plus its
key fields, never the full body at this stage; the full body is handled by script
in Step 4, never retyped through the model.

Validate each chosen body actually parses as JSON before continuing. HAR bodies
are often base64-encoded (`content.encoding == "base64"`) and Charles can truncate
large ones (`content.size != len(body)`); a truncated body throws at the seam and
looks exactly like an app bug, so catching it here saves a confusing round trip
later.

### Step 4 - Splice the payload by script, not by the model

A `python3` step, run directly (never through the sub-agent, so the payload never
enters model context at all):

1. Extract the exact body bytes for the chosen HAR entry (decoding base64 if
   needed).
2. **Scan for secrets and PII before anything else.** A captured HAR body
   routinely carries session cookies, bearer tokens, `Authorization` headers,
   emails, addresses, or payment fragments. This code is about to be written into
   a source file and committed; even though the commit is `[TEMP]` and never
   merged, it lands in local git history, and a careless `git push` publishes it.
   Flag candidates (header names `Authorization`/`Set-Cookie`/`Cookie`, JSON keys
   containing `token`/`session`/`password`/`secret`, email-shaped strings, long
   high-entropy tokens) and **stop for explicit dev approval** on what to redact
   before writing anything to disk. If a flagged value is one the scenario
   actually depends on, say so rather than silently redacting it into a repro
   that no longer reproduces.
3. Measure the byte size (`len(body.encode('utf-8'))`; treat this as a
   conservative estimate, not exact, since the JVM's real limit is 65535 bytes of
   *modified* UTF-8 where non-BMP characters cost more, hence the 30 KB threshold
   below rather than chasing exactness).
4. Substitute every `$` with `${'$'}` (Kotlin target only; irrelevant for other
   languages).
5. Emit the literal: under 30 KB, an inline `"""..."""` raw string; 30 KB or over,
   a chunked `listOf("...", "...").joinToString("")` (never `"a" + "b"`, the
   Kotlin IR backend constant-folds concatenated literals back into a single
   oversized constant; never `const val` either, since it is the literal itself,
   not the `const` modifier, that becomes the oversized constant-pool entry).
6. Write the emitted literal into the target source file at the location Step 5's
   agent identifies, as the value of `REPLAY_RAW` inside the block.

The model only ever sees: endpoint, size, a content hash, and which seam it lands
in. This is a token guardrail (retyping 30 KB of JSON is wasteful), a fidelity
guarantee (a model retyping it can silently corrupt a character and the repro
fails in a way that looks like a real bug), and a safety guardrail (redaction
happens before anything touches disk, not after).

### Step 5 - Delegate the seam search and injection (Agent tool, general-purpose)

The orchestrator does not search for the seam or write the block inline. Dispatch
an agent with the prompt below, filling in the `<...>` markers. The agent locates
the seam, decides the injection point, and returns a plan; Step 4's script (not
the agent) performs the actual payload splice once the agent has identified where
`REPLAY_RAW` goes and what surrounds it.

```
You are the replay-agent. Your job is to find the exact seam to force a value
into, and write the surrounding block, for the scenario described below. You do
NOT write the forced payload literal yourself; a deterministic script already
computed it and will splice it in at the location you identify. Your output tells
the orchestrator exactly where that splice goes and writes everything else.

== INVIOLABLE RULES (read first, apply to everything you write) ==

1. NEVER touch the transport layer (Retrofit interfaces, OkHttp, fetch, axios,
   requests, HttpClient, interceptors, mock servers). The injection point is
   always where the app takes an already-fetched raw response and starts turning
   it into typed models, or where a flag/kill-switch is READ, never where the
   network call itself happens.
2. NEVER delete a line without preserving it. Every original line your block
   replaces gets a `REPLAY-ORIG:` line directly above it, in the same comment
   syntax as the file, carrying that line VERBATIM including its own leading
   whitespace. A purely additive block (nothing replaced) carries NO
   `REPLAY-ORIG:` line at all; never emit an empty one.
3. NEVER nest a `REPLAY START` inside an still-open block. Sequential blocks in
   the same file are fine.
4. NEVER create a new file. If a payload seems too awkward to splice into the
   identified seam, say so and pick a different (still-correct) seam; do not
   reach for an asset/resource file as an escape hatch.
5. EXACTLY two `PROTOLOG_RESPONSE - ` logs per forced site: one at entry (the
   discriminating inputs the branch depends on), one right after the value is
   produced (the payload or its key fields). Never more, per this skill's
   contract (this is deliberately NOT `/wk:protologs`' density).
6. Reuse the app's OWN configured parser instance (the one wired into
   `addConverterFactory(...)` or equivalent), never a fresh default one: naming
   strategy, custom adapters, and `ignoreUnknownKeys`-equivalent settings all
   change what a fresh instance would parse differently from the real app.

== SELF-CHECK BEFORE RETURNING (mandatory) ==

Before returning, run this yourself against every file you touched:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/hooks/replay-restore.py" check <file> <(git show HEAD:<file>)
```

Exit 0 means the file is clean (every change is inside a properly-formed block,
with `REPLAY-ORIG:` accounting for every deleted line). Non-zero: exit 1 means a
real change slipped outside a block (fix it: move it inside, or add the missing
`REPLAY-ORIG:` line); exit 2 means unbalanced or nested markers (fix the markers).
Repeat until every touched file passes, before you compile or return.

== SCENARIO ==
Technique: <network response | flags/kill switches | both, from Step 0>
Ticket / tag: <KEY or "standalone">
<For network technique: endpoint(s) chosen in Step 3, method, url, and the exact
byte size Step 4 computed for each (not the body itself).>
<For flag technique: the flag name(s)/key(s) the dev named, and the branch they
need to force.>

== SEAM RANKING (network technique) ==

Force the LAST representation that is still bytes/string/untyped, never the typed
object. In order:

  A2. A raw-string variable already produced by manual parsing (code that does
      something like `response.body()!!.string()` and hand-parses from there).
      Highest fidelity, one-line change: force the string variable itself.
  A.  The deserialization boundary: the first caller of the api method, forced
      with the app's own parser and the exact same generic type (including any
      envelope: `ApiResponse<T>`, `Response<T>`, etc). This is the default target.
  B.  Mapper input: a hand-built DTO fed into `.toDomain()` or equivalent. Use
      only when the response type cannot be reliably reconstructed for A.
  C.  Transport / interceptor / mock server. FORBIDDEN, not a fallback.
  D.  A function's already-mapped return value. AVOID: if the call site looks
      like `api.getOrders(id).data.map { it.toDomain() }`, forcing the outer
      expression's result silently degrades to this and skips the mapper. The
      forced value must be fed through the SAME trailing pipeline the real code
      uses, reproduced inside the block.

== FINDING THE SEAM (network technique, in order, stop at the first unambiguous hit) ==

1. Static path-segment grep on the HAR URL's last static segments (fails when a
   version prefix lives in a builder, when paths are built from concatenated
   constants, or on GraphQL).
2. Annotation-scoped grep (`@GET(`, `@POST(`, Ktor `url(`, `axios.get<`, etc):
   kills the common-word noise of step 1.
3. Path-constant indirection: `const val ORDERS_PATH = "..."`, then its users.
4. Response-shape grep, the RELIABLE FALLBACK when 1-3 are ambiguous: take 2-3
   UNUSUAL keys from the response body (skip generic ones like `id`/`status`) and
   grep serialization annotations (`@SerializedName("deliverySlotId")`,
   `@SerialName`, `@Json(name = ...)`). Lands directly on the DTO; immune to every
   URL-construction failure mode. Run this automatically whenever 1-3 are
   ambiguous, don't wait to be told.
5. GraphQL / generated clients: the URL is worthless (always `/graphql`); use the
   request body's `operationName`, or an OpenAPI `operationId`.

Then walk UP from the api method/DTO to its call sites. **More than one call site
is a blocker, not a detail**: report all of them and which one you chose and why,
since a shared api method may or may not reach the flow under test.

== FINDING THE READ SITE (flag/kill-switch technique) ==

Force at the READ site (the call that takes the key and returns a value consumed
by a branch), NEVER at the definition/registry site (enum declarations,
`setDefaults`, `buildConfigField`), where a remote value would override the local
default anyway. Common shapes: `remoteConfig.getBoolean(...)`, `.boolVariation(`,
`isFeatureEnabled(`, `BuildConfig.FLAG_*`, an app's own `FeatureFlags.isEnabled(`
wrapper, or a Kotlin delegated property `by flag("...")`.

With MULTIPLE read sites and no shared wrapper: enumerate all of them and report
the blast radius before touching anything; a half-forced flag produces an
inconsistent app state that reads as a brand-new bug, not the one under test.
With a shared wrapper, force inside it keyed to the specific flag so the blast
radius stays one flag, not all of them.

== PARSER SNIPPETS (network technique, detect which the repo actually uses) ==

Grep `addConverterFactory(`, `Moshi.Builder(`, `GsonBuilder(`, `Json {` to
identify the library, then reuse the app's own configured instance if one is
reachable from the injection site; only fall back to a fresh default instance
when none is reachable, and say so in your report.

Gson:
```kotlin
val forcedType = object : com.google.gson.reflect.TypeToken<ApiResponse<List<OrderDto>>>() {}.type
val forced: ApiResponse<List<OrderDto>> = gson.fromJson(REPLAY_RAW, forcedType)
```

Moshi:
```kotlin
val forced: ApiResponse<List<OrderDto>> = moshi.adapter<ApiResponse<List<OrderDto>>>().fromJson(REPLAY_RAW)!!
```

kotlinx.serialization:
```kotlin
val forced: ApiResponse<List<OrderDto>> = json.decodeFromString(REPLAY_RAW)
```

Non-Kotlin stacks: TS/zod `Schema.parse(JSON.parse(RAW))`; Python pydantic
`Model.model_validate_json(RAW)`; Swift `decoder.decode(T.self, from: Data(RAW.utf8))`;
Go `json.Unmarshal([]byte(RAW), &v)`. Force the string/bytes variable feeding the
parser, same principle as Kotlin's A2/A.

== ENVIRONMENT-SCOPED IDENTIFIERS ==

Any id in the captured body that is environment-scoped (context ids, sids, system
ids, CMS rule ids) will not exist in the target environment. Hardcoding it makes
the override SILENTLY DO NOTHING: the app requests context X, the forced response
answers for context Y, no match fires, and it looks like it worked while having
zero effect. Default to rewriting the relevant id fields dynamically against
whatever the app actually requests at runtime (read the request parameters at the
injection site, splice them into the forced body before parsing). Flag it in your
report if you had to hardcode one instead, and why. When a content response and a
personalization response are forced together, they must agree on the same id:
pin the content side, derive the p13n side from it.

== OUTPUT (JSON only, no summary file) ==

{
  "seam_technique": "A2 | A | B | flag-read-site",
  "files_touched": [{"path": "...", "reason": "<one line>", "fidelity_note": "<which layers this traverses: deserializer / envelope unwrap / DTO-to-Entity / DB round trip / DTO-to-Domain, and which it skips>"}],
  "call_sites_found": <int, for the chosen api method/flag>,
  "call_site_ambiguity": "<null, or which flow you picked and why>",
  "env_scoped_ids": [{"field": "...", "handling": "dynamic | hardcoded", "reason": "<if hardcoded, why>"}],
  "flag_blast_radius": [{"site": "file:function", "forced": true or false, "reason": "<if left untouched, why>"}],
  "self_check": "clean, or what Check found and you fixed",
  "splice_points": [{"path": "...", "marker": "<a unique string the orchestrator's script will replace with the emitted REPLAY_RAW literal>"}]
}
```

### Step 6 - Integrity backstop

The orchestrator independently re-runs the same check, once, no edits, no loop:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/hooks/replay-restore.py" check <file> <(git show HEAD:<file>)
```

Any non-zero exit stops here; do not commit, do not fix, do not loop. Narrate the
offending file and the exact diagnostic; the dev fixes by hand with the Edit tool
or asks for a new round.

### Step 7 - Single-pass compile

Batch every touched module into ONE invocation, same discipline as
`/wk:protologs`: detect module type (Android modules `compileDebugKotlin`,
java-library `compileKotlin`), export `JAVA_HOME` from Android Studio's JBR when
unset, never `--no-daemon`. On failure, report the errors and stop; no retry, no
self-correction.

### Step 8 - Commit

```bash
git add -A && git commit --no-verify -m "[TEMP] REPLAY <TAG>: <what is forced> (round <N>). DO NOT MERGE"
```

`<TAG>` is the ticket KEY when known, `standalone` otherwise; keep the grep
anchors (`REPLAY START`, `[TEMP] REPLAY`) KEY-independent so cleanup works either
way. `<N>` starts at 1 and increments each time inject runs again on this branch
without an intervening cleanup (same round semantics as `/wk:protologs`; `git log
--oneline --grep '\[TEMP\] REPLAY'` tells you the current count). Never push.

### Step 9 - Hand off

Print the exact log lines to look for, in order, and **state plainly what a false
positive would look like for this scenario** (a forced response can make the
screen look correct through a different code path than the one under test; a
hardcoded environment-scoped id can make the override silently do nothing while
looking like it worked). Report:

- The fidelity ledger per file (`fidelity_note` from Step 5's JSON): which layers
  the forced value traversed and which it skipped.
- Which environment-scoped ids were substituted dynamically versus hardcoded.
- Which flag read sites were left untouched, if the flag technique had more than
  one site.
- Filter command: `adb logcat | grep "PROTOLOG_RESPONSE - "` (fallback: Android
  Studio Logcat, same filter).
- Reminder: *"When you're done testing, run `/wk:replay cleanup` to remove
  everything without a trace. If you also need `/wk:protologs` to verify the rest
  of the flow, run replay's cleanup only once protologs cleanup is done too,
  topmost commit first."*

---

## Mode: cleanup (`/wk:replay cleanup`)

Activated when the user types `/wk:replay cleanup`, or when the invoking skill
reaches its cleanup step.

### Step 1 - Session marker

Run `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/session.sh" start replay` (idempotent).
Required even on a fresh session, since `$PPID` changes between sessions and
every guard is gated on a live marker; skipping this leaves the revert-conflict
guard inert precisely when it matters.

### Step 2 - Enumerate [TEMP] REPLAY commits

```bash
git log --format='%H %s' HEAD | grep '\[TEMP\] REPLAY'
```

Found: go to Step 3 (revert path). None found: narrate *"No [TEMP] REPLAY commits
found; falling back to text-match cleanup."* and go to Step 3-fallback.

### Step 3 - Revert path

Revert each `[TEMP] REPLAY` commit, most recent first, with the auto-abort
wrapper:

```bash
git revert --no-edit <sha> || { git revert --abort 2>/dev/null; echo "CONFLICT: <sha>"; }
```

**ON CONFLICT (mandatory, no exceptions), identical rule to `/wk:protologs`:**
FORBIDDEN to resolve by hand, run `git revert --continue`/`--quit`, or `git
commit` while a revert is in progress. The wrapper above has already run `git
revert --abort`; the only permitted path is confirming the abort took
(`git rev-parse -q --verify REVERT_HEAD` prints nothing), continuing with the
remaining reverts, then running Step 3-fallback for that commit's files only. A
`PreToolUse` hook (`hooks/replay-revert-conflict-guard.sh`) denies
`--continue`/`--quit`/`git commit` while `REVERT_HEAD` points at a `[TEMP] REPLAY`
commit, as a backstop.

### Step 3-fallback - restore() (only when no [TEMP] REPLAY commit applies)

```bash
git grep -l "REPLAY START" 2>/dev/null
grep -rl "REPLAY START" . --include="*.kt" --include="*.java" \
  --include="*.swift" --include="*.ts" --include="*.tsx" \
  --include="*.js" --include="*.py" --include="*.go" \
  --include="*.rs" --include="*.rb" 2>/dev/null
```

Deduplicate. None found: narrate *"No REPLAY blocks found in the repo. The code
is already clean."* and stop. For each found file:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/hooks/replay-restore.py" strip "<file>" > "<file>.replay-restored"
mv "<file>.replay-restored" "<file>"
```

This is the SAME transformation the integrity guard checked before the commit
landed (see "Injected code shape"), so it is exact by construction: a nonzero
exit from `replay-restore.py` (unbalanced or nested markers) means STOP and fix
that file by hand with the Edit tool rather than force a partial strip; do not
guess with `sed`.

**Any site the inject-time agent marked revert-only** (Step 5's JSON, when an
additive/restorable block was genuinely impossible for that seam) skips the
fallback entirely: if no `[TEMP] REPLAY` commit survives to revert it, stop and
tell the dev this file needs a manual look, rather than applying a fallback known
not to be safe there.

Narrate the processed files.

### Step 4 - Verify complete cleanup

```bash
git rev-parse -q --verify REVERT_HEAD && echo "REVERT IN PROGRESS" || true
git status --porcelain | grep -E '^(UU|AA|DD|AU|UA|DU|UD)' || true
```

Either printing anything: STOP, do not verify, do not report success; narrate the
in-flight revert, abort it, return to Step 3's ON CONFLICT block.

```bash
git grep -n "REPLAY START\|REPLAY END\|REPLAY-ORIG:\|PROTOLOG_RESPONSE - " 2>/dev/null || true
```

Empty: narrate *"No trace of REPLAY blocks or `PROTOLOG_RESPONSE - ` remains."*
Non-empty: show which, do not delete automatically, ask the dev to review by hand.

### Step 5 - Mandatory compile verification

Same discipline as inject Step 7 and as `/wk:protologs` cleanup: never report
success without this. Detect affected modules from the reverted commits' files
(or, on the fallback path, from Step 5's `files_touched`), one batched
invocation. Compiles clean: narrate success. Fails: narrate the exact error and
STOP, do not report cleanup as done, do not auto-retry; hand the error to the dev.

### Step 6 - Release the session marker (standalone only)

If this cleanup ran standalone (`/wk:replay cleanup` typed directly), run
`"${CLAUDE_PLUGIN_ROOT}/lib/helpers/session.sh" stop`. If `/wk:bugfix` Stage 6
invoked it, skip: Stage 6 owns the marker's lifecycle and releases it at its own
close.

---

## General narration rules

- Begin each action with a short line describing what is being done, in the
  operating locale (`lib/narration.md`); artifacts (commit messages, code
  comments, this skill's own JSON contracts) stay English regardless.
- Never use em dashes in any response.
- Build or git errors are always narrated; never silenced.
- This skill's only commits are its own `[TEMP] REPLAY` commits (inject) and
  their reverts (cleanup). It never commits or pushes business logic, and never
  pushes to a remote.
- Payload bodies never pass through model context (Step 4); only endpoint
  metadata, sizes, and hashes do.
