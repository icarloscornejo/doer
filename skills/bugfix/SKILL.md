---
name: bugfix
description: >-
  End-to-end bug triage from a Jira ticket. Invoke as "/wk:bugfix <jira-url-or-key>"
  (e.g. /wk:bugfix PDE-2779 or a full browse URL). Pulls the ticket (title,
  description, comments), downloads every Charles session (.chls) attached or
  mentioned in text, converts them to .har, distills the signals, asks for entry
  points, then investigates in plan mode to reach a verdict. A real app bug gets
  planned, fixed, and verified on device with /wk:protologs; a bug that is not
  the app's fault (API / CMS / backend / data / env) produces a mini-spike ready
  to post to Jira. Use /wk:doer for planned feature/refactor tickets instead.
version: 7.0.0
user-invocable: true
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, AskUserQuestion, WebFetch, EnterPlanMode, ExitPlanMode, Skill, Agent]
---

# /wk:bugfix - bug triage pipeline

A deterministic pipeline: **Jira ticket → ordered context → investigation (plan mode) → verdict → fix-or-spike**.

- **Best run in opusplan.** Stages 0-3 and 5-6 are mechanical. Stage 4 uses `EnterPlanMode` so the investigation runs on the strongest model; execution drops back on `ExitPlanMode`. The skill cannot force the session model; at the top of Stage 4 it reminds the user.
- **Single source of truth:** one lean `bugfix.json` per ticket. Heavy raw data (full description, comments, HAR bodies) lives in files on disk and is read **on demand only**, never inlined into the JSON.
- **Jira access** goes through `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/jira.sh"`, configured **per-project** at `./.doer/config.json` (git-excluded), via `/wk:setup` or `/wk:jira <url>`. The token is full-env: `$JIRA_PAT` by default, or whatever `jira_token_env` names; never persisted. If `jira.sh config` reports missing `base_url` or `token_present: false`, run the auto-detect pass (candidate env var NAMEs only, never values; see `/wk:setup`'s `SKILL.md`) before giving up and pointing the user at `/wk:setup`.

## Storage layout (hybrid)

```
./.doer/tickets/<KEY>/          # control state (Workspace Guard keeps it out of git)
├── bugfix.json                 # LEAN control file: state + signals + evidence + plan
├── ticket.md                   # raw description + comments (read on demand only)
└── lock.json

~/Downloads/<KEY>/              # heavy artifacts, easy to inspect manually
├── charles/                    # <name>.chls + <name>.har
├── screenshots/                # <name>.png
└── spike.md                    # only when verdict = not_app_bug
```

### `bugfix.json` schema

```json
{
  "ticket_id": "PDE-2779",
  "title": "<summary>",
  "url": "<source_url from jira.sh>",
  "status": "in_progress",
  "current_stage": 0,
  "verdict": null,
  "artifacts_dir": "/Users/<user>/Downloads/PDE-2779",
  "signals": {
    "repro": ["1- ...", "2- ..."],
    "expected": "...", "actual": "...", "env": "qa4",
    "related_tickets": ["PDE-2680"],
    "technical": ["BO-6x3Srun...", "isP13NEnabled"]
  },
  "attachments": [
    {"filename": "x.chls", "kind": "charles", "source": "attachment", "jira_url": "...",
     "path": "charles/x.chls", "har": "charles/x.har", "done": false, "converted": false}
  ],
  "evidence": [],
  "entry_points": [],
  "plan": null,
  "stages": {"0": "pending", "1": "pending", "2": "pending", "3": "pending", "4": "pending", "5": "pending", "6": "pending"},
  "notes": []
}
```

**Rule:** after each stage, update `bugfix.json` (`current_stage`, `stages[n]="complete"`, the fields that stage owns). Keep it lean; raw text goes to `ticket.md`, network dumps stay as `.har`.

## Stage 0 - Init & Resume

1. Parse the ticket **KEY** from the argument (full URL or bare key; regex `[A-Z]+-\d+`).
2. If `./.doer/tickets/<KEY>/bugfix.json` exists → **resume**: read it, announce `current_stage`, jump to the next incomplete stage. Never redo work flagged `done`.
3. Otherwise run the **Workspace Guard + lock** inline (`lib/workspace-guard.md`), then create the folders and the initial `bugfix.json` (`status=in_progress`, `current_stage=0`, all stages pending, `artifacts_dir` set):
   ```bash
   mkdir -p "$HOME/Downloads/<KEY>/charles" "$HOME/Downloads/<KEY>/screenshots" ".doer/tickets/<KEY>"
   ```
4. Verify Jira access: `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/jira.sh" config`. On missing `base_url` or absent token, run the auto-detect pass (env var NAME candidates only, via `env | grep -iE 'JIRA.*(PAT|TOKEN)'` and project memory, never values); if nothing resolves, stop and point the user at `/wk:setup`.

## Stage 1 - Ingest Jira (informational, no pause)

1. Fetch: `jira.sh fetch <KEY>` → lean JSON (title, status, description, comments, attachments, source_url).
2. Write **`ticket.md`** in `.doer/tickets/<KEY>/`: summary, type/status/priority, description verbatim, every comment (author · date · body). The ONLY place raw text lives.
3. Distill into `signals{}`: `repro` (numbered steps), `expected`, `actual`, `env`, `related_tickets` (`[A-Z]+-\d+` mentions), `technical` (endpoint ids, context ids, flag/function names).
4. Build `attachments[]`: every fetched attachment (kind = `charles` for `.chls`, `screenshot` for images, else `other`) plus every `.chls` filename mentioned in text (`[^name.chls]`) cross-referenced to its attachment URL (`source: "mentioned"`).
5. Recap one line (title, attachment count, Charles sessions detected) and continue. Mark stage 1 complete.

## Stage 2 - Download & Convert

Skip with a note if `attachments[]` has no `.chls` and no screenshots (`stages.2 = "complete"`, note `"no attachments"`).

1. Download every `.chls` and image via `jira.sh download <url> <local-path>` into `~/Downloads/<KEY>/charles/` and `screenshots/` (dedupe by filename; ASCII-safe local names, original name kept in the JSON). A `.chls` mentioned in text with no matching attachment cannot be downloaded; log it in `notes` and continue.
2. Convert each `.chls` → `.har`, auto-detecting the converter:
   ```bash
   command -v makehar >/dev/null && makehar "<in.chls>" \
     || [ -x "/Applications/Charles.app/Contents/MacOS/Charles" ] \
        && /Applications/Charles.app/Contents/MacOS/Charles convert "<in.chls>" "<out.har>"
   ```
   Neither available → note it, keep the `.chls` for manual conversion, continue (the investigation can still work from ticket text + screenshots).
3. Set `done` / `converted` per attachment. Mark stage 2 complete.

## Stage 3 - Entry Points

One `AskUserQuestion`: does the user have entry points (files / classes / modules / feature area) to focus the investigation? Offer the area inferred from `signals` (if any) and "search the codebase yourself". Save into `entry_points[]` (paths, or the literal `"search"`). Mark stage 3 complete.

## Stage 4 - Investigation, Analysis & Verdict (plan mode)

1. Remind: *"Stage 4 runs in plan mode; for the deepest analysis, make sure you're on opusplan."*
2. `EnterPlanMode`, then **read `analyze.md`** (this skill's directory) and follow it: HAR digest → `evidence[]`, screenshot reading, code correlation at `entry_points`, root cause per `lib/debugging.md`, the `app_bug` vs `not_app_bug` verdict criteria, and the `plan{}` shape.
3. Present **root cause + verdict + plan**; on approval `ExitPlanMode` and persist `verdict` + `plan` into `bugfix.json`. Mark stage 4 complete.

## Stage 5 - Execute

Branch on `verdict`:

### `app_bug`

Implement `plan.steps` (edit the files, add the tests). Follow repo conventions and `lib/debugging.md` (no fix without root cause). Run the relevant module tests / build. Record what changed in `notes`. Mark stage 5 complete → Stage 6.

### `not_app_bug`

1. Read `templates/mini-spike.md` (this skill's directory) and write `~/Downloads/<KEY>/spike.md` in Jira wiki markup, filled from `signals`, `evidence`, the root cause, and `plan.spike_owner`.
2. Iterate with the user on content and formatting; rewrite `spike.md` each round.
3. When satisfied, **ask** whether to post it as a Jira comment. Only on explicit yes:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/lib/helpers/jira.sh" comment <KEY> "$HOME/Downloads/<KEY>/spike.md"
   ```
   Mark `status=complete`. **A spike does not go to device; stop here.**

## Stage 6 - Verify on device (`app_bug` only)

1. Invoke `wk:protologs` (Skill tool, inject mode) to instrument the entire flow, from the `entry_points` upward if the flow starts earlier. If the logging scope is unclear, ask the user how far up/down to instrument first.
2. The user runs the build on device; confirm the logs show the expected flow and the fix behaves.
3. Invoke `wk:protologs cleanup`; verify no `PROTOLOG` trace remains.
4. Set `status=complete`, `completed_at`, release the lock (`rm -f .doer/tickets/<KEY>/lock.json`), mark stage 6 complete.

## Notes

- Keep `bugfix.json` lean at all times; this is a token-cost guardrail.
- On resume, trust the `done`/`converted`/stage flags; never redo completed work.
- Every external or irreversible action (posting to Jira) requires an explicit user yes.
- Narration, turn boundaries, and locale follow `lib/narration.md`.
