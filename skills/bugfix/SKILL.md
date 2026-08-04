---
name: bugfix
description: >-
  End-to-end bug triage from a Jira ticket. Invoke as "/wk:bugfix <jira-url-or-key>"
  (e.g. /wk:bugfix PDE-2779 or a full browse URL). Pulls the ticket (title,
  description, comments), downloads every Charles session (.chls) attached or
  mentioned in text, converts them to .har, distills the signals, digests the
  evidence, asks for entry points, then investigates in plan mode (read-only,
  code correlation and verdict only) to reach a verdict. A real app bug gets
  planned, fixed, and verified on device with /wk:protologs; a bug that is not
  the app's fault (API / CMS / backend / data / env) produces a mini-spike ready
  to post to Jira. Use /wk:doer for planned feature/refactor tickets instead.
version: 7.5.0
user-invocable: true
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, AskUserQuestion, WebFetch, EnterPlanMode, ExitPlanMode, Skill, Agent]
---

# /wk:bugfix - bug triage pipeline

A deterministic pipeline: **Jira ticket → ordered context → investigation (plan mode) → verdict → fix-or-spike**.

- **Best run in opusplan.** Stages 0-3 and 5-6 are mechanical. Stage 4 uses `EnterPlanMode` so the investigation runs on the strongest model; execution drops back on `ExitPlanMode`. The skill cannot force the session model; at the top of Stage 4 it reminds the user. Everything that needs `Bash` (downloads, `.chls` conversion, HAR parsing) runs before Stage 4, in Stages 0-3, since plan mode does not inherit the session's own permission mode: a `Bash` call inside `EnterPlanMode` prompts for approval on every single invocation, turning the investigation into a click-through instead of a one-shot. Stage 4 only ever uses `Read`/`Grep`/`Glob` on the already-gathered evidence and the codebase.
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
  "entry_points_topic": null,
  "plan": null,
  "commit_message": null, "pr_description": null,
  "stages": {"0": "pending", "1": "pending", "2": "pending", "3": "pending", "4": "pending", "5": "pending", "6": "pending"},
  "notes": []
}
```

`entry_points[]` can arrive pre-populated from `./.doer/entry-points.json` (per-repo store, see `lib/state.md` and Stage 3 Step 2 below), not just from the dev typing them fresh. `entry_points_topic` holds the matched/chosen topic key from that store when applicable (`null` when `entry_points` is `"search"` or came from an ad hoc answer with no stored topic); Stage 5/6 close uses it to offer refining the stored entry.

**Rule:** after each stage, update `bugfix.json` in ONE `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/metadata.sh" write "<KEY>" '<filter>' --file bugfix.json` call (`current_stage`, `stages[n]="complete"`, the fields that stage owns, all in the same jq filter). Never `Write`/`Edit` `bugfix.json` directly, and never split one stage's close into two writes: see `lib/state.md`, "Writing metadata.json" (applies equally to `bugfix.json`), for why. Keep it lean; raw text goes to `ticket.md`, network dumps stay as `.har`.

## Stage 0 - Init & Resume

1. Parse the ticket **KEY** from the argument (full URL or bare key; regex `[A-Z]+-\d+`).
2. If `./.doer/tickets/<KEY>/bugfix.json` exists → **resume**: read it, announce `current_stage`, jump to the next incomplete stage. Never redo work flagged `done`.
3. Otherwise run the **Workspace Guard + lock** inline (`lib/workspace-guard.md`), then create the folders and the initial `bugfix.json` (`status=in_progress`, `current_stage=0`, all stages pending, `artifacts_dir` set):
   ```bash
   mkdir -p "$HOME/Downloads/<KEY>/charles" "$HOME/Downloads/<KEY>/screenshots" ".doer/tickets/<KEY>"
   echo '<full JSON document>' | "${CLAUDE_PLUGIN_ROOT}/lib/helpers/metadata.sh" init "<KEY>" --file bugfix.json
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

## Stage 3 - Evidence Digest & Entry Points

Runs entirely outside plan mode, since it is the stage that does the actual `Bash`-heavy parsing.

1. **HAR evidence digest** (skip with a note if `attachments[]` has no converted `.har` and no screenshots; `evidence` stays `[]`). For each converted `.har`, extract ONLY the requests that matter, filter by `signals.technical` (endpoint ids, BO/context ids, flag names). Never read a whole HAR into context; they are huge.

   ```bash
   python3 - "<charles/name.har>" "<term1>" "<term2>" <<'PY'
   import json,sys
   har=json.load(open(sys.argv[1])); terms=[t.lower() for t in sys.argv[2:]]
   for e in har["log"]["entries"]:
       req=e["request"]; url=req["url"]
       blob=(url+" "+(e.get("response",{}).get("content",{}).get("text","") or "")).lower()
       if any(t in blob for t in terms):
           print(req["method"], e["response"]["status"], url[:160])
   PY
   ```

   Refine iteratively: grep response bodies for the specific identifiers (e.g. a context id present in one session and absent in another; a flag value; a status code). Distill each finding into a **one-line** entry in `evidence[]`:

   ```json
   {"session": "repro",  "finding": "context=6x3Srun... never appears as a p13n request (0 calls)"}
   {"session": "fixed",  "finding": "context=6x3Srun... fires x6 (logout+login, en-US/en-CA/fr-CA)"}
   ```

   Prefer a comparative shape when the ticket has a repro vs fixed/working session, the delta between sessions is usually the whole story. Read screenshots only if they add signal the HARs and text don't (UI state, error copy, toggle states); fold anything relevant into `evidence[]` the same way.

2. **Entry points**, in three steps:

   **2a. Recover before asking.** Run `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/entrypoints.sh" match <terms>` with `signals.technical` terms plus keywords from `title`. For each hit, validate every path with `test -f`: a path that no longer exists gets narrated plainly (`"<path> from the '<topic>' entry point no longer exists, was it moved/renamed?"`) and the dev is offered to fix or drop it right there, in the same turn. This replaces MAJOR-version pruning (what `wk:doer`'s lessons pool uses): an entry point does not go stale because the skill got a version bump, it goes stale because the file moved. Surviving paths become the **recommended** option in the `AskUserQuestion` below, shown with their `topic` and `captured_from` so the dev knows where they came from.

      No hits → fall back to the current behavior: offer the area inferred from `signals`/`evidence` and "search the codebase yourself".

   **2b. Ask.** One `AskUserQuestion` offering: the recovered paths (if any, recommended), the inferred area, and "search the codebase yourself". Save the answer into `entry_points[]` (paths, or the literal `"search"`).

      Then, only when the answer is real paths (never on `"search"`), a **second, conditional** question about persisting it, one case at a time:
      - **No stored entry for this topic** and the dev gave real paths: ask whether to save it as a standing rule for future tickets on `<proposed topic>` (options: *save* / *just this ticket*; the tool's "Other" is the edit-the-topic path). On save → `entrypoints.sh save --topic <t> --paths <p> --keywords <k> --from <KEY>`; set `entry_points_topic` to `<t>`.
      - **Stored entry exists and the dev accepted its paths as-is:** ask nothing. Just `entrypoints.sh save --topic <t> --paths <same paths> --from <KEY>` (a no-op merge that appends `<KEY>` to `captured_from`, confirming the entry without friction) and set `entry_points_topic` to `<t>`.
      - **Stored entry exists and the dev gave additional or different paths:** ask what to do, showing the current stored count (options: *merge the new ones in* / *replace* / *leave the stored entry as-is*). Apply via `entrypoints.sh save --topic <t> --paths <p> --from <KEY> [--mode replace]`, or skip the write on "leave as-is"; set `entry_points_topic` to `<t>` whenever a write happened.

   **2c. Refinement hook for later.** Stage 5/6 close checks whether Stage 4's root cause lives in a file that was NOT in the `entry_points_topic` entry's stored `paths`; if so it offers, once, adding it (see Stage 5/6).

3. **Persist.** ONE `metadata.sh write` sets `evidence[]`, `entry_points[]`, `entry_points_topic`, and `stages.3 = "complete"` together.

## Stage 4 - Investigation, Analysis & Verdict (plan mode)

1. Remind: *"Stage 4 runs in plan mode; for the deepest analysis, make sure you're on opusplan."*
2. `EnterPlanMode`, then **read `analyze.md`** (this skill's directory) and follow it: code correlation at `entry_points` using the `evidence[]` already gathered in Stage 3, root cause per `lib/debugging.md`, the `app_bug` vs `not_app_bug` verdict criteria, and the `plan{}` shape. Read-only tools only (`Read`/`Grep`/`Glob`); no `Bash`, the evidence is already on disk in `bugfix.json`.
3. Present **root cause + verdict + plan**; on approval `ExitPlanMode`, then persist per `analyze.md`'s Confirm step (one batched `metadata.sh write`: `verdict` + `plan` + stage 4 complete).

## Stage 5 - Execute

Branch on `verdict`:

### `app_bug`

Tests first, TDD order, driven by `plan.tests` from Stage 4:

1. Write every test in `plan.tests.bug` and `plan.tests.regression`. Run them: `tests.bug` entries **must fail** (they exercise the not-yet-fixed defect); `tests.regression` entries **must pass** (they lock the sibling behaviors that already work today). A `bug` test that already passes means the root cause is wrong, go back to `lib/debugging.md`, do not proceed. A `regression` test that already fails is a distinct pre-existing bug, narrate it and let the dev decide before continuing.
2. Commit the tests:
   ```bash
   git add -A && git commit --no-verify -m "<KEY>: <subject>"
   ```
3. Implement `plan.steps`. Follow repo conventions and `lib/debugging.md` (no fix without root cause).
4. Run the full relevant suite: everything green, `bug` and `regression` tests together. Green regressions after the fix are the evidence nothing sibling broke; a regression going red means the fix broke that sibling, fix it before advancing, never weaken the test to make it pass.
5. Commit the fix, separate from the tests commit:
   ```bash
   git add -A && git commit --no-verify -m "<KEY>: <subject>"
   ```

Record what changed in `notes`.

Both commits land before Stage 6 runs (working messages; the PR-ready message is chosen in Stage 6). They must stay separate from anything Stage 6 adds. `wk:protologs`' `[TEMP]` commit mechanism (Step 4.6) assumes the fix underneath it is already committed, so its diff contains only PROTOLOG lines and cleanup's revert is a clean no-op. An uncommitted fix gets tangled with the injected logs in the same working-tree diff and has to be split apart by hand afterward.

Mark stage 5 complete → Stage 6.

### `not_app_bug`

1. Read `templates/mini-spike.md` (this skill's directory) and write `~/Downloads/<KEY>/spike.md` in Jira wiki markup, filled from `signals`, `evidence`, the root cause, and `plan.spike_owner`.
2. Iterate with the user on content and formatting; rewrite `spike.md` each round.
3. **Entry-points refinement (2c).** If `entry_points_topic` is set and the root cause in `plan.root_cause` names a file not already in that topic's stored `paths`, ask once whether to add it (`entrypoints.sh save --topic <entry_points_topic> --paths <existing+new> --from <KEY>`). Skip silently when `entry_points_topic` is `null`, or the root-cause file is already covered.
4. When satisfied, **ask** whether to post it as a Jira comment. Only on explicit yes:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/lib/helpers/jira.sh" comment <KEY> "$HOME/Downloads/<KEY>/spike.md"
   ```
   Mark `status=complete`, release the lock (`rm -f .doer/tickets/<KEY>/lock.json`) and the
   session marker (`"${CLAUDE_PLUGIN_ROOT}/lib/helpers/session.sh" stop`). **A spike does not
   go to device; stop here.**

## Stage 6 - Verify on device & Deliver (`app_bug` only)

1. Invoke `wk:protologs` (Skill tool, inject mode), passing `entry_points[]` from `bugfix.json` as the user-specified entry points (protologs' Step 2.5 will not re-ask). This instruments the entire flow from those entry points, upward if the flow starts earlier. If the logging scope is unclear, ask the user how far up/down to instrument first.
2. The user runs the build on device; confirm the logs show the expected flow and the fix behaves.
3. Invoke `wk:protologs cleanup`; verify no `PROTOLOG` trace remains.
4. **Entry-points refinement (2c).** If `entry_points_topic` is set and `plan.root_cause` names a file not already in that topic's stored `paths`, ask once whether to add it (`entrypoints.sh save --topic <entry_points_topic> --paths <existing+new> --from <KEY>`). Skip silently when `entry_points_topic` is `null`, or the root-cause file is already covered.
5. **Recommended commit message.** Draft THREE candidates, each `<KEY>: <Subject ≤72 chars>` with the subject starting uppercase, specific to the actual change, in plain business language. Each candidate takes a genuinely different angle (the user-visible symptom fixed, the component changed, the root cause addressed), not rewordings of the same sentence. Validate all three before presenting (Core Principle 10):
   ```bash
   printf '%s\n' "<candidate-1>" "<candidate-2>" "<candidate-3>" \
     | grep -nE '\bAC-[0-9]+\b|\bPROTOLOG\b|\bDOER\b|\bdoer\('
   ```
   A match means an internal label leaked; rewrite that candidate and re-validate, never present a matching draft. Present the three candidates in the chat as plain text, numbered 1-3, each in its own fenced code block. Drafts NEVER go inside `AskUserQuestion`, only the selection does. Ask via `AskUserQuestion` with short labels (`Option 1` / `Option 2` / `Option 3`), marking the strongest `(Recommended)`; the tool's auto-appended "Other" is the edit path, and a plain-chat reply (`1`, `2`, `3`, `edit: <text>`) is equally valid. Re-run the grep on any edited text before accepting it. Hold the chosen message for step 8's single write.
6. **Offer to squash now** (`AskUserQuestion`: `Yes` / `No, I'll squash manually`). Cleanup leaves a `[TEMP]`/revert pair per logging round sitting on top of the Stage 5 fix commit; protologs' own cleanup step explicitly defers this collapse to the invoking skill (`skills/protologs/SKILL.md`, cleanup Step 2). On yes: skip if only 1 commit since `<base>` (same base branch confirmed in protologs inject Step 1); otherwise back up (`git update-ref refs/bugfix-backup/<KEY>-pre-squash-$(date +%s) HEAD`), then `git reset --soft <base> && git commit --no-verify -m "<chosen message>"`, verify exactly 1 commit remains, narrate the backup ref (rollback: `git reset --hard <ref>`).
7. **PR description.** Auto-detect a template (`.github/PULL_REQUEST_TEMPLATE*`, `.gitlab/merge_request_templates/`, repo root). One found → use it; several → ask which; none → ask the dev to paste one, or reply `default` (Summary / Changes / How to test / Verification / Notes) or `skip`. Dispatch a PR-description writer Agent (read budget 0; inline `title`, `signals` (`repro`/`expected`/`actual`/`env`), the root cause and steps from `plan`, `notes`, and a one-line on-device verification outcome from step 2). Rules for the output: fill every template section (`> N/A for this ticket.` where not applicable), preserve headings and directives verbatim, terse prose + bullets, no em-dashes, no internal labels (no `PROTOLOG`, no stage names, no verdict jargon like `app_bug`). Validate with the same grep as step 5 before presenting; scrub or regenerate on a match. Present wrapped in a four-backtick fence (four backticks on their own line before and after) so the description's own markdown, including any triple-backtick blocks inside it, renders literally in chat and copies verbatim. Then ask a plain-chat question ("keep it as is, or want changes?") and **end the turn there** (`lib/narration.md` turn boundary 4); never `AskUserQuestion` for this. Persisting `pr_description` or running step 8 before the dev's reply is prohibited. On requested changes, rewrite, re-validate with the same grep, re-present, and ask again, as many rounds as needed. Only an explicit ok (or `skip`) unlocks step 8; on `skip`, hold the literal `"skipped"` for step 8's write.
8. **Close.** Precondition: step 7 has the dev's explicit approval (or `"skipped"`); if not, this step does not run. ONE `"${CLAUDE_PLUGIN_ROOT}/lib/helpers/metadata.sh" write ... --file bugfix.json` call setting `status=complete`, `completed_at`, `commit_message` (step 5's choice), `pr_description` (step 7's approved result, or `"skipped"`), and `stages.6="complete"`. Release the lock (`rm -f .doer/tickets/<KEY>/lock.json`) and the session marker (`"${CLAUDE_PLUGIN_ROOT}/lib/helpers/session.sh" stop`).

## Notes

- Keep `bugfix.json` lean at all times; this is a token-cost guardrail.
- On resume, trust the `done`/`converted`/stage flags; never redo completed work.
- Every external or irreversible action (posting to Jira) requires an explicit user yes.
- Narration, turn boundaries, and locale follow `lib/narration.md`.
