# Intake (when ticket does NOT exist)

This file runs when `/doer <TICKET-ID>` is invoked and `./.doer/tickets/<TICKET-ID>/metadata.json` does NOT exist. Locale resolution has already happened in the entry-point dispatch (see SKILL.md).

## Step 0. Auto-fetch detection (tracker connectivity)

This step detects whether the dev has tracker connectivity configured and offers to fetch ticket data automatically. Doer does NOT configure anything; it only detects what is already available.

### Step 0A. Check ticket ID shape

Check whether `<TICKET-ID>` matches a known tracker pattern:
- Jira/Linear: `^[A-Z][A-Z0-9_]+-[0-9]+$`
- GitHub Issues: `^#?[0-9]+$` or `^[A-Za-z0-9_./-]+#[0-9]+$`

If no match, skip Step 0 entirely and proceed to Step 1 (manual flow).

### Step 0B. Detection cascade

Run detection in priority order. Stop at the first successful detection.

**Priority 1: MCP tools.** Check your available tool list for tool names containing `jira`, `atlassian`, `linear`, `get_issue`, `get-issue`. If a matching MCP tool that can fetch issue details is found, record: `method = "mcp"`, `tool_name = "<matched tool name>"`.

**Priority 2-3: Environment variables.** Run:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/lib/helpers/tracker-detect.sh" resolve "<TICKET-ID>"
```
Parse the JSON output. If `tracker != "unknown"` and `method != "none"`, record the detection.

If `tracker == "ambiguous"` (both Jira and Linear env vars are set), ask the dev via `AskUserQuestion`:
```
Question: Both Jira and Linear credentials are configured. Which tracker is <TICKET-ID> from?
Options:
  - Jira
  - Linear
```

**Priority 4: Nothing found.** Skip Step 0 entirely. Proceed to Step 1 (manual flow) with no interruption or narration about the failed detection. Do NOT tell the dev that auto-fetch was attempted and failed.

### Step 0C. Offer auto-fetch

If connectivity was detected, ask the dev via `AskUserQuestion`:

```
Question: I detected <tracker> access via <method_desc>. Want me to fetch <TICKET-ID> data automatically?
Options:
  - Yes, fetch it (Recommended)
  - No, I will paste manually
```

Where `<method_desc>` is:
- MCP: `"MCP tool '<tool_name>'"`
- wk_env: `"WK_JIRA_* environment variables"` (or WK_LINEAR_*)
- common_env: `"JIRA_* environment variables"` (or LINEAR_*)
- gh_cli: `"GitHub CLI (gh)"`

If the dev says "No" or uses the auto "Other" to decline, proceed to Step 1 (manual flow) with no further auto-fetch mentions.

### Step 0D. Fetch and pre-populate

If the dev says "Yes":

**For MCP method:** Use the detected MCP tool to fetch the issue. Parse the response for title, description/body, status, and labels. The exact tool invocation depends on the MCP tool's parameter schema.

**For env var methods (wk_env, common_env) and gh_cli:** Run:
```bash
RESULT=$(bash "${CLAUDE_PLUGIN_ROOT}/lib/helpers/tracker-fetch.sh" <tracker> "<TICKET-ID>" --var-prefix <wk|common>)
```

Check the `.error` field:
```bash
FETCH_ERROR=$(printf '%s' "$RESULT" | jq -r '.error // empty')
```

If `.error` is non-null, narrate: `"Fetch failed: <error>. Falling back to manual flow."` and proceed to Step 1.

On success:

1. Extract ACs from the body using the existing helper:
```bash
TMPBODY=$(mktemp)
printf '%s' "$BODY" > "$TMPBODY"
RAW_ACS=$(bash "${CLAUDE_PLUGIN_ROOT}/skills/load/lib/extract-acs.sh" "$TMPBODY")
rm -f "$TMPBODY"
[ -z "$RAW_ACS" ] && RAW_ACS="derive"
```

2. Store fetched data in local memory (not yet persisted to metadata.json; that happens at Step 3):
   - `fetched_title` = `.title`
   - `fetched_description` = `.body`
   - `fetched_raw_acs` = extracted ACs or `"derive"`
   - `fetched_labels` = `.labels` (joined as comma-separated string)
   - `fetched_status` = `.status`
   - `fetched_source_url` = `.source_url`

3. Build the `intake.tracker` provenance object:
```json
{
  "kind": "<jira|linear|gh>",
  "source_id": "<TICKET-ID as typed>",
  "source_url": "<fetched_source_url>",
  "imported_at": "<ISO8601>"
}
```

4. Derive a suggested branch name from the fetched title:
```bash
SLUG=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\{2,\}/-/g' | sed 's/^-//;s/-$//' | cut -c1-50)
SUGGESTED_BRANCH="${TICKET_ID}-${SLUG}"
```

### Step 0E. Modified question flow (auto-fetch path)

When auto-fetch succeeded, the intake questions change as described in the table below. After completing these modified questions, skip to Step 2 (testing strategy inference).

| # | Original question | Auto-fetch behavior |
|---|-------------------|---------------------|
| Q1 | "What is the title of `<TICKET-ID>`?" | **SKIP.** Narrate: `"Title (from tracker): <fetched_title>"` |
| Q2 | "Paste the full description of the ticket." | **SKIP.** Narrate: `"Description fetched from tracker (<N> chars)."` |
| Q3 | "Does the ticket already have acceptance criteria?" | **SKIP.** If `fetched_raw_acs != "derive"`: narrate `"ACs extracted from tracker description."` If `fetched_raw_acs == "derive"`: narrate `"No AC section found in tracker description; will derive in Stage 1."` |
| Q4 | "Any extra context?" | **ASK (plain chat),** pre-filled: `"Fetched context: labels: <X, Y>; status: <Z>. Any additional context? Type 'skip' if the fetched context is sufficient."` If the dev types `skip`, use the fetched context string only. Otherwise append the dev's response. |
| Q5 | "What branch should this ticket use?" | **ASK (`AskUserQuestion`)** with `SUGGESTED_BRANCH` derived from fetched title. Options: `Use current branch (<current>)` / `Use suggested name (<SUGGESTED_BRANCH>)`. |
| Q6 | "Have you already done any work on this ticket?" | **ALWAYS ASK.** Cannot be auto-detected. Unchanged from manual flow. |

When auto-fetch was NOT used (dev declined or nothing detected), the full manual question flow in Step 1 runs unchanged.

---

## Step 1. Ask intake questions

Ask **one at a time**. Do not batch. Questions 1, 2, and 4 expect open free-text answers (a title, a pasted description, extra context), so ask them as plain-chat questions and read the dev's reply. Questions 3, 5, and 6 are choices, so they use `AskUserQuestion` (the tool auto-appends a free-text "Other"; do NOT add one by hand). See the mechanism rule in `${CLAUDE_PLUGIN_ROOT}/lib/narration.md`.

| # | Question | How to ask |
|---|----------|-----------|
| 1 | "What is the title of `<TICKET-ID>`?" | plain chat |
| 2 | "Paste the full description of the ticket." | plain chat |
| 3 | "Does the ticket already have acceptance criteria?" | `AskUserQuestion`, two options: `Yes, I'll paste them` / `No, derive in Stage 1`. On `Yes`, ask a plain-chat follow-up to paste the ACs and store them in `raw_acs`. On `No`, set `raw_acs = "derive"`. The dev can also paste ACs directly through the auto "Other". |
| 4 | "Any extra context? (related issues, prior decisions, links, constraints). Type `skip` if none." | plain chat |
| 5 | "What branch should this ticket use?" | `AskUserQuestion`, two options: `Use current branch (<current branch name>)` / `Use suggested name (<suggested>)`. Resolve the current branch with `git rev-parse --abbrev-ref HEAD`; derive `<suggested>` from the ticket id and title (e.g. `feature/<TICKET-ID>-<kebab-title>`). The auto "Other" lets the dev type a custom name. |
| 6 | "Have you already done any work on this ticket before invoking `/doer`?" | `AskUserQuestion`, two options: `Yes` / `No` |

**Only if question 6 was answered `Yes`**, ask the four follow-ups one at a time as plain-chat questions (each captures free-text detail: a path, a summary, or pass/fail state, so a structured prompt does not fit):

| # | Question | Notes |
|---|----------|-------|
| 6a | "Do you have a written plan (mental or in a file)? If so, paste it or give the path." | If yes, capture summary or path |
| 6b | "Did you write tests already? If so, give the file paths and pass/fail status." | If yes, capture file paths and pass/fail status |
| 6c | "Did you write implementation code? If so, give the file paths and commit/staged/uncommitted state." | If yes, capture file paths and commit/staged/uncommitted state |
| 6d | "Did you update any documentation? If so, give the file paths." | If yes, capture file paths |

Persist all answers under `metadata.intake.prior_work`. If question 6 was `No`, write `prior_work: { "exists": false, "plan": null, "tests": null, "code": null, "docs": null }` and skip the follow-ups.

## Step 2. Infer testing strategy, then ask ONE confirmation

After all six intake questions are answered (and the prior-work follow-ups if applicable), but BEFORE initializing `metadata.json`, the orchestrator infers `testing_strategy.mode` (no question, orchestrator decides) and presents the inference in a single `AskUserQuestion` for confirmation.

### Step 2A. Infer `testing_strategy.mode` (no question)

Read `metadata.intake.title`, `metadata.intake.description`, and `metadata.intake.raw_acs`. Apply the following signal rules; each matched signal contributes to its bucket. Persist the matched signal IDs into `signals[]`.

**Signals for `direct`:**
- Title contains an update-class verb (`update`, `change`, `edit`, `rename`, `fix`, `tweak`) AND a small-thing noun (`label`, `copy`, `string`, `constant`, `config`, `default`, `placeholder`, `typo`, `text`, `value`); both anywhere in the title (not contiguous). Signal ID: `direct.title.verb_noun`.
- Title contains any of the contiguous compounds: `rename`, `update label`, `change label`, `update copy`, `fix typo`, `update string`, `update constant`, `update config`, `update default`, `update placeholder`. Signal ID: `direct.title.compound`.
- Description has no ACs (`raw_acs == "derive"` or empty) AND no conditional-logic language (no `if`, no `when`, no `should`). Signal ID: `direct.no_acs_no_logic`.
- Description length < 300 chars AND no Given/When/Then language. Signal ID: `direct.short_description`.
- Description matches `change X to Y` or `update X from Y to Z` patterns. Signal ID: `direct.change_x_to_y`.
- Title contains: `mapper`, `transformer`, `util`, `utility`, `extension`, `helper`, `parser`, `calculator`, `converter`, `validator`. Signal ID: `direct.technical_unit_title`.
- Ticket is a refactor with no behavior change. Signal ID: `direct.refactor_no_behavior`.
- Description or context references integrating with an SDK or library whose internal mechanism is not documented in the ticket or known from existing codebase patterns (e.g., the ticket says "hide feature X" but the SDK's method for hiding is unknown). Signal ID: `direct.sdk_unknown_mechanism`.

**Signals for `bdd`:**
- Title or description contains user-story language: `as a user`, `should see`, `should be able to`, `when user`, `given`, `when`, `then`. Signal ID: `bdd.user_story_language`.
- Raw ACs are written in Given/When/Then format (case-insensitive `GIVEN`/`WHEN`/`THEN` markers). Signal ID: `bdd.gwt_in_acs`.
- Description suggests an observable behavior change from a user or QA perspective. Signal ID: `bdd.observable_behavior`.
- Description suggests a bug reported by QA or a user (not a dev-internal issue). Signal ID: `bdd.bug_user_reported`.
- Description involves analytics instrumentation with AC (events, STag, GA4, SOT). Signal ID: `bdd.analytics_with_ac`.
- Description involves a flow with multiple states or actors. Signal ID: `bdd.flow_multi_state`.

**Decision logic:**
- Count signals per mode. Highest count wins.
- Tie between `direct` and `bdd` → `bdd` wins (safer default for coverage).
- If no signals match at all → default to `bdd`.

Persist a draft of `testing_strategy = { mode, rationale, signals }` to local memory (NOT to disk yet; the dev still has to confirm in step 2B).

### Step 2B. Confirmation

Present the inference in ONE `AskUserQuestion` block:

```
Question: Doer inferred the following for this ticket. Confirm or override?

Testing strategy: <DIRECT | BDD> (<one-sentence rationale>)
  Signals: <comma-separated list of matched signal IDs>

Options:
  - Y: accept
  - change strategy:<direct|bdd>: override testing strategy
```

Acceptance rules:
- `Y` → accept; persist `testing_strategy` as inferred; `overridden_by_dev = false`.
- `change strategy:<value>` → override `testing_strategy.mode` to the given value; set `testing_strategy.overridden_by_dev = true`. Re-narrate the final state for the dev (one short summary line) before proceeding.

After confirmation, persist:
- `metadata.testing_strategy = { mode, rationale, signals, overridden_by_dev }`

**Once set, `testing_strategy.mode` does not change for the remainder of the ticket.**

## Step 3. Initialize metadata.json

(intake fields + chosen mode are embedded; see `${CLAUDE_PLUGIN_ROOT}/lib/memory-paths.md` for the full schema):

```json
{
  "ticket_id": "<TICKET-ID>",
  "title": "<title>",
  "branch": "<branch-name>",
  "status": "in_progress",
  "current_stage": 1,
  "skill_version": "<read from frontmatter at intake time, e.g. 6.3.1>",
  "testing_strategy": {
    "mode": "<direct | bdd chosen in step 2>",
    "rationale": "<one-sentence rationale>",
    "signals": ["<signal-id>", "..."],
    "overridden_by_dev": false
  },
  "created_at": "<ISO8601>",
  "completed_at": null,
  "intake": {
    "description": "<full description from intake or auto-fetched>",
    "raw_acs": "<pasted ACs, extracted ACs, or 'derive'>",
    "context": "<extra context or 'none'>",
    "prior_work": {
      "exists": false, "plan": null, "tests": null, "code": null, "docs": null
    },
    "tracker": null
  },
  "stages": {
    "1": {"name": "ac-confirm",     "status": "pending"},
    "2": {"name": "plan",           "status": "pending"},
    "3": {"name": "tests",          "status": "pending"},
    "4": {"name": "code",           "status": "pending"},
    "5": {"name": "code-review",    "status": "pending"},
    "6": {"name": "quality-gate",   "status": "pending"},
    "7": {"name": "runtime-verify", "status": "pending"},
    "8": {"name": "docs-sync",      "status": "pending"},
    "9": {"name": "wrapup",         "status": "pending"}
  },
  "changelog": [],
  "code_review": [],
  "blocking_conditions": [],
  "commits": [],
  "workspace_guard": null,
  "session_ids": [],
  "session_ids_source": null
}
```

**`intake.tracker` (auto-fetch only):** When Step 0 auto-fetch was used, set `intake.tracker` to the provenance object built in Step 0D. When the manual flow was used (Step 0 skipped or dev declined), leave `intake.tracker` as `null`.

### Session ID capture (intake)

Immediately after writing `metadata.json`, capture the current session ID and append it:

```bash
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
SOURCE="env:CLAUDE_CODE_SESSION_ID"
if [ -z "$SESSION_ID" ]; then
  # Fallback: read most-recent sessionId value from the project JSONL directory.
  PROJ_SLUG="$(pwd | sed 's|/|-|g')"
  CLAUDE_CFG="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
  LATEST_JSONL="$(ls -t "${CLAUDE_CFG}/projects/${PROJ_SLUG}"/*.jsonl 2>/dev/null | grep -v 'agent-acompact' | head -1 || true)"
  if [ -n "$LATEST_JSONL" ]; then
    SESSION_ID="$(grep -o '"sessionId":"[^"]*"' "$LATEST_JSONL" 2>/dev/null | head -1 | sed 's|"sessionId":"||;s|"||g' || true)"
  fi
  SOURCE="jsonl_fallback"
fi
if [ -n "$SESSION_ID" ]; then
  jq --arg s "$SESSION_ID" --arg src "$SOURCE" \
    '.session_ids = [$s] | .session_ids_source = $src' \
    ".doer/tickets/<TICKET-ID>/metadata.json" \
    > ".doer/tickets/<TICKET-ID>/metadata.json.tmp" \
    && mv ".doer/tickets/<TICKET-ID>/metadata.json.tmp" ".doer/tickets/<TICKET-ID>/metadata.json"
fi
```
Narrate: "Session ID captured ($SOURCE)." If both env and fallback are empty, narrate: "Session ID not available; transcript cost reconciliation will be skipped at wrapup." and continue.

The remaining top-level fields (`ac`, `plan`, `assumptions_validation`, `lessons_captured`, `summary`, `performance`, etc.) are populated by their owning stages and start absent.

### Per-stage `verified_with` rule

When a stage transitions to `status: "complete"` (or `"skipped"`, or `"imported"`), the orchestrator MUST also write `verified_with: "<current SKILL frontmatter version>"` on that stage. Example after Stage 2 finishes under SKILL 6.3.1:
```json
"2": {"name": "plan", "status": "complete", "verified_with": "6.3.1", "completed_at": "...", ...}
```
This is the only mechanism that lets the auto-reverify check (see `${CLAUDE_PLUGIN_ROOT}/lib/migrations.md`) know which stages to spot-check after a SKILL upgrade.

## Step 4. Create the feature branch

If the dev chose `Use current branch` in Step 1 question 5, the branch already exists and is checked out: skip `git checkout -b` and keep working on it. Otherwise create it:

```bash
git checkout -b "<branch-name>"
```

If the branch already exists (local or remote), ask via `AskUserQuestion`:
```
Question: Branch `<branch-name>` already exists. How do you want to proceed?

Options:
  - Check out existing: continue on the existing branch
  - Pick a different name: I will ask for a new branch name
```
On "Pick a different name", ask for the new name as a plain-chat free-text question, then retry the checkout.

## Step 5. Workspace setup

Run the **Workspace Guard** per `${CLAUDE_PLUGIN_ROOT}/lib/workspace-guard.md`. This is MANDATORY before Stage 1.

## Step 6. Narrate and proceed

Narrate to the user: *"Ticket <TICKET-ID> initialized on branch `<branch-name>`. `.doer/` is gitignored locally, your team will never see these files. Starting Stage 1: AC Confirm."*

Run the Stage Finalization Checklist (`${CLAUDE_PLUGIN_ROOT}/lib/stage-checklist.md`) is not required at intake (no stage transitioned). Proceed to Stage 1: Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/01-ac-confirm.md` and ONLY that file.
