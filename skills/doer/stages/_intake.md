# Intake (when ticket does NOT exist)

This file runs when `/doer <TICKET-ID>` is invoked and `./.doer/tickets/<TICKET-ID>/metadata.json` does NOT exist. Locale resolution has already happened in the entry-point dispatch (see SKILL.md).

## Step 1. Ask intake questions

Ask the following questions **one at a time** via `AskUserQuestion`. Do not batch.

| # | Question |
|---|----------|
| 1 | "What is the title of `<TICKET-ID>`?" |
| 2 | "Paste the full description of the ticket." |
| 3 | "Does the ticket already have acceptance criteria? If yes, paste them. If no, type `derive` and we'll build them together in Stage 1." |
| 4 | "Any extra context? (related issues, prior decisions, links, constraints). Type `skip` if none." |
| 5 | "What name should the feature branch use? (e.g. `feature/fix-login-timeout`)" |
| 6 | "Have you already done any work on this ticket before invoking `/doer`? [y/N]" |

**Only if question 6 was answered `y`**, ask the four follow-ups one at a time (also via `AskUserQuestion`):

| # | Question | Notes |
|---|----------|-------|
| 6a | "Do you have a written plan (mental or in a file)?" | If yes, capture summary or path |
| 6b | "Did you write tests already?" | If yes, capture file paths and pass/fail status |
| 6c | "Did you write implementation code?" | If yes, capture file paths and commit/staged/uncommitted state |
| 6d | "Did you update any documentation?" | If yes, capture file paths |

Persist all answers under `metadata.intake.prior_work`. If question 6 was `N`, write `prior_work: { "exists": false, "plan": null, "tests": null, "code": null, "docs": null }` and skip the follow-ups.

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
    "description": "<full description from intake>",
    "raw_acs": "<pasted ACs or 'derive'>",
    "context": "<extra context or 'none'>",
    "prior_work": {
      "exists": false, "plan": null, "tests": null, "code": null, "docs": null
    }
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

```bash
git checkout -b "<branch-name>"
```

If the branch already exists (local or remote), ask:
"Branch `<branch-name>` already exists. Options: 1) Check out existing, 2) Pick a different name. Which?"

## Step 5. Workspace setup

Run the **Workspace Guard** per `${CLAUDE_PLUGIN_ROOT}/lib/workspace-guard.md`. This is MANDATORY before Stage 1.

## Step 6. Narrate and proceed

Narrate to the user: *"Ticket <TICKET-ID> initialized on branch `<branch-name>`. `.doer/` is gitignored locally, your team will never see these files. Starting Stage 1: AC Confirm."*

Run the Stage Finalization Checklist (`${CLAUDE_PLUGIN_ROOT}/lib/stage-checklist.md`) is not required at intake (no stage transitioned). Proceed to Stage 1: Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/01-ac-confirm.md` and ONLY that file.
