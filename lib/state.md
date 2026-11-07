# State: Schemas and Layout

Single source of truth for on-disk state. Control state is lean JSON; raw text and heavy artifacts live in files read on demand, never inlined into the JSON.

## Layout

```
${CLAUDE_PLUGIN_ROOT}/                 # plugin install (cross-project)
├── skills/{doer,bugfix,protologs,replay}/
├── lib/                               # protocols + helpers
└── lessons/{slug}.md                  # GLOBAL lessons pool, cross-project

${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/
└── preferences.json                   # locale only (personal, same in every repo); survives plugin upgrades

./.doer/                               # per-repo, excluded via .git/info/exclude
├── config.json                       # per-project Jira config (schema below)
├── entry-points.json                 # per-repo bugfix entry-point map (schema below)
├── wk-session-{pid}.json             # session marker (lib/helpers/session.sh), scopes PreToolUse guards
└── tickets/{TICKET-ID}/
    ├── metadata.json                  # doer tickets (schema below)
    ├── bugfix.json                    # bugfix tickets (schema in skills/bugfix/SKILL.md)
    ├── ticket.md                      # bugfix only: raw Jira description + comments
    ├── ac-draft.json                  # Stage 1 scratch (skills/doer/stages/01-ac.md), deleted at Step 6
    └── lock.json                      # per-ticket lock (workspace-guard.md)

~/Downloads/{TICKET-ID}/               # bugfix only: heavy artifacts
├── charles/  *.chls + *.har
└── screenshots/
```

## preferences.json

```json
{"locale": "es"}
```

Read and written only through `lib/helpers/preferences.sh`. Global and personal: the same locale applies whichever repo you're in.

## .doer/wk-session-{pid}.json

```json
{"pid": 12345, "host": "example.local", "skill": "doer", "touched_at": 1737100000}
```

Read and written only through `lib/helpers/session.sh` (`start <skill>`, `stop`). One file
per live wk session in this repo, named by the session's long-lived claude process pid
(`$PPID` as seen by the session, same value the hook sees as its own `$PPID`). This
plugin's PreToolUse guards (`hooks/*.sh`) check for a live marker before doing anything
else, so a normal Claude Code session with the plugin installed but no wk skill active is
never affected by them. Written by `lib/workspace-guard.md` step 4 (doer/bugfix) and by
`skills/protologs/SKILL.md` (standalone); released at each skill's wrapup, or pruned on
the next `start` in this repo if the process died without cleaning up.

## .doer/config.json

```json
{"jira_base_url": "https://jira.example.com", "jira_token_env": "JIRA_PROD_PAT", "jira_auth_email": null}
```

Read and written only through `lib/helpers/jira.sh` (`set-url`, `set-token-env`, `set-auth-email`, `config`). Per-project: different repos can point at different Jira instances. `jira_token_env` names the environment variable holding the token (default `JIRA_PAT` if absent); the token itself is never persisted, only its env var's name. `jira_auth_email` is optional and switches auth from Bearer (Jira Server/DC) to HTTP Basic `email:token` (required for Atlassian Cloud, `*.atlassian.net`). Set up guided via `/wk:setup`, or one-shot via `/wk:jira <url>`.

## .doer/entry-points.json

```json
{
  "version": 1,
  "entries": [
    {
      "topic": "home page offer banner",
      "keywords": ["offer banner", "hpmktg", "promotionlist", "home"],
      "paths": ["app/.../GetHomeUseCaseImpl.kt", "app/.../GetTransformedBeautyOffersContentUseCaseImpl.kt"],
      "note": "seccion CMS-driven, arrancar por el use case",
      "captured_from": ["PDE-2917"],
      "updated_at": "<ISO8601>"
    }
  ]
}
```

Read and written only through `lib/helpers/entrypoints.sh` (`match`, `list`, `save`, `forget`). Per-repo, used by `skills/bugfix/SKILL.md` Stage 3 to recover and offer known investigation entry points for a topic the dev has already mapped in a previous ticket. `captured_from` accumulates the ticket keys that confirmed or extended the entry; a path is validated (`test -f`) at recovery time and dropped/flagged if it no longer exists, since staleness here means the file moved or was renamed, not that the skill's pipeline shape changed.

This is a **different mechanism** from the cross-project lessons pool (`${CLAUDE_PLUGIN_ROOT}/lessons/{slug}.md`): a lesson is narrative (`What happened / Why it matters / Takeaway`) and applies across any repo; an entry point is a structured topic-to-file-path mapping that is only ever valid in this exact checkout, so it lives per-repo in `.doer/`, not in the plugin install.

## metadata.json (doer ticket)

```json
{
  "ticket_id": "ABC-123",
  "title": "<title>",
  "branch": "<feature branch>",
  "status": "in_progress | complete",
  "current_stage": 1,
  "skill_version": "7.2.5",
  "created_at": "<ISO8601>", "completed_at": null,
  "intake": {"description": "...", "raw_acs": "... | derive", "context": "...",
              "prior_work": {"exists": false}, "tracker": null},
  "ac": {"in_scope": ["AC-1: ..."], "candidates": [], "out_of_scope": [], "open_questions_resolved": [],
          "merged": [], "source_map": [], "discarded_intake_items": [],
          "applicable_lessons": [], "self_review": {"ran": true, "rounds": 1, "findings": [],
          "dev_accepted": [], "dev_rejected": []}},
  "plan": {"files": [], "steps": [], "tests": [], "risks": [], "assumptions": []},
  "stages": {
    "1": {"name": "ac",     "status": "pending"},
    "2": {"name": "plan",   "status": "pending"},
    "3": {"name": "build",  "status": "pending"},
    "4": {"name": "verify", "status": "pending"},
    "5": {"name": "wrapup", "status": "pending"}
  },
  "changelog": [], "code_review": [],
  "test_command": null, "lint_command": null, "typecheck_command": null,
  "runtime_build_command": null,
  "last_green_sha": null, "last_green_test_command": null,
  "assumptions_validation": [], "lessons_captured": [],
  "no_pr": false,
  "summary": null, "commit_message": null, "pr_description": null,
  "cost_sessions": [{"id": "<session id>", "ts": "<ISO8601>", "usd": 4.2}],
  "cost": null
}
```

Cost tracking (`lib/helpers/cost.sh`): `cost_sessions` lists the sessions that worked the ticket, each with the last counter reading `usd` (or `null`) and `reset: true` when a later reading went lower. It exists only on tickets created with `init --track-cost`; every `metadata.sh write` on such a ticket folds a sample of the current session into the same write. `cost` is written once at close by `cost.sh record`, and it is measured from the session transcripts, not from counters: tokens per model, deduplicated by `message.id` across every registered session (registration order, the closing session last, decides which session a copied message belongs to), priced with `lib/cost-rates.json` (the only price table: one entry per model with input, output, cache read, 5m and 1h cache write rates, the date the rates were taken and their source URL; a model matches its key exactly or with a `-YYYYMMDD` suffix; Haiku 5.5 has a long-prompt tier; Opus 5.5, 5 and 4.8 have a fast-mode multiplier). Fields: `status` (`known | partial | unknown`), `total_usd`, `reason`, `scope` (always `"whole sessions; may include non-ticket work in them"`), token totals, per-session figures, `by_model` (tokens and usd per model), `unpriced_models`, `compactions` (`count` and `estimated_usd`), `rates` (`taken_on`, `source`), `reported_usd`, `by_stage` (per stage: the four token counts, `usd` for its events, `compaction_usd` for the compactions whose timestamp falls in its window, and `unpriced_models`; or `null` with `by_stage_reason`), `unassigned_usd` (events and compactions in no stage window; `null` with `by_stage`), where `usd` plus `compaction_usd` over all stages plus `unassigned_usd` equals `total_usd`, and the three dollar fields are `null` whenever `total_usd` is (tokens still show) and `recorded_at`. `partial` means some model, fast-mode call or search fee was not priced: its tokens are counted, `total_usd` covers the rest and `unpriced_models` names the cause; `unknown` means no total (no tracking, a session without a transcript, an unreadable rate table). Compaction calls are billed but are not messages in the transcript; each `compact_boundary` is estimated from its `compactMetadata` (input `preTokens` as a cache read when the previous request of the thread is within the threshold of its cache tier, else as a cache write of that tier: a previous request that wrote 1-hour tokens means `compaction.cold_after_seconds_1h` and the 1-hour write rate, any other means `compaction.cold_after_seconds` and the 5-minute write rate; output taken as `postTokens`, so the real output can be underestimated) and `total_usd` includes that estimate, with `compactions.estimated_usd` showing how much of it is an estimate. `reported_usd` is the sum of the counters the status line and multi-instance persisted (`null` unless every session has one that did not go backwards): an optional cross-check, never the source of `total_usd` or `status`. Sessions are counted whole, so a session shared by two tickets counts in each; tickets created before 7.13.0 record `unknown`.

Inherited versus own context (additive fields). Context of a request is input + cache read + cache creation. A real main request is not from a subagent file or a sidechain line, has non-zero usage and a model other than `<synthetic>`. A line is sidechain when its file lives under a `subagents/` directory or it has `isSidechain: true`. `cost.sessions[].entry_context_tokens` is E, the context of the session's first real main request strictly after its registration `ts`; `null` when `ts` is empty or unparseable (no known baseline: all its cache reads are own) or when the session has no real main request after `ts`. The baseline B of a request is E, or `min(E, postTokens)` after a main-thread compaction that came after E's request. A request's `own = max(0, cache_read - B)` and the rest is inherited; sidechain cache reads are all own, and main requests at or before a parseable `ts` are all inherited and are not counted as requests. Each `by_stage` entry adds `requests`, `context_entry`, `context_exit`, `growth_tokens` (sum of per-session growths, `null` when no real main request), `inherited_cache_read_tokens`, `own_cache_read_tokens` (the two sum to `cache_read_tokens`) and `own_cache_read_usd` (own reads at each event's cache-read rate, long-prompt tier included, skipping unpriced events; `null` whenever `usd` is). `context_entry` and `context_exit` are `null` when more than one session has real main requests in the window. Stage 5 ends at a parseable `stages.5.completed_at`, else at the time `record` runs.

Post-hoc measurement of a finished ticket: `cd <scratch dir holding a copy of .doer/tickets/<ID>/metadata.json> && env -u CLAUDE_CODE_SESSION_ID cost.sh record <ID>`. Without `env -u`, `record` adds the invoking session to the sessions it reads and its requests land in Stage 5 and `total_usd`; the copy keeps the real ticket untouched. Work a registered session does after close falls in no stage (`unassigned_usd`), so compare per-stage figures. Limits: E can include work the session did between `/doer` start and `enter`, and the first request after `enter` already includes SKILL.md and 01-ac.md. The fresh-session ceiling is E of a measured fresh `/doer` run times 1.25: the first measured fresh `/doer` run (7.16.0 development, started from a cross-session prompt) had E = 73,632 tokens, so the ceiling is 92,000 tokens; a baseline above it is rejected as not fresh.

Reading a stored record: `cost.sh summary <ID> [--file F]` prints a short text of the `cost` already stored in the ticket metadata (it never recomputes anything and never changes the ticket). A known or partial record prints `status: <status>`, `total: $<usd>` and, when `by_stage` is an object, one line per stage in numeric order: `stage <N>: $<usd>, inherited <X.X>M, own <X.X>M cache read, own cache read $<usd>` (dollars with two decimals, tokens in millions with one decimal, `n/a` for a missing number). A `by_stage` of `null` prints only the status and total. A ticket with no `cost`, an `unknown` record (its `reason`, newlines flattened to spaces), a missing ticket file or one that is not exactly one JSON document prints a single `cost: <reason>` line. Like the other cost subcommands it always exits 0.

`no_pr` (since 7.18.0): `true` when the ticket was started with `--no-pr` (a branch that merges straight to the base branch). It is set once at creation and the field is absent on older tickets, where absent means `false`, the PR flow. In no-PR mode Stage 5 writes `pr_description = "skipped"` (so the Stage 5 required fields below still validate) and closes with a merge-and-push line; the squash is unchanged. `bugfix.json` carries the same field.

Stage statuses: `pending | in_progress | complete | skipped | imported`. `ac`, `plan`, and later fields start absent and are written by their owning stage. `last_green_sha` is always the full 40-char `git rev-parse HEAD` output (string-equality comparisons break on abbreviation). Stage 1 can also persist `metadata.ac` in a deliberately INCOMPLETE state, with `stages.1.status = "in_progress"` and a `metadata.ac.pause_reason` set (`01-ac.md`, "Pausing Stage 1"): an obligation the dev's own edits left uncovered still needs a disposition, and only the dev can supply one. This is the same "leave the stage `in_progress` for a later resume" pattern `lib/loop.md` uses for the Stage 3 loop; `stages.1.status = "complete"` is reserved for a draft that passed the deterministic integrity pass in full.

Optional `test_weakening_justifications`: an array of `{path, line_text, reason}` (trimmed removed line text, non-blank reason) written only by the Stage 3 orchestrator after the dev gives an explicit reason. `stage-checks.sh pre-review` downgrades a `weakened-tests` removed-assertion BLOCKER to INFO by count per `(path, line_text)`. Exit 2 means the base is unusable or git failed: stop and report it, never read it as an empty or clean result.

Since 7.9.0, each `ac.source_map` row also carries `origins` (the ticket bullet(s) it came from, with section), `added_by` (which self-review finding or dev edit introduced it, if not from Step 5), and `fidelity` (how well the landed AC restates it). Tickets created before 7.9.0 have `source_map` rows without these fields; `01-ac.md`'s Present renders them with Section `unknown` and Fidelity `unreviewed`, which counts as needing attention.

## Writing metadata.json (and bugfix.json)

ALWAYS through `lib/helpers/metadata.sh` (`init` to create, `write` to update), NEVER via direct `Edit`/`Write` tool calls on the file, and NEVER more than once per logical stage transition. Applies equally to `bugfix.json` (`metadata.sh ... --file bugfix.json`). Batch every field of one transition (stage status, `completed_at`, the stage's payload, `current_stage` advance) into a SINGLE jq filter and call `write` exactly once; a correction after a successful write is a NEW write, never a retry of the same transition.

Rationale: `.doer/` is a hidden directory, and rapid successive rewrites of the same file from an automated process is a known trigger for corporate EDR ransomware heuristics, which can lock the file at the OS level (observed: macOS `com.apple.provenance` tag + EPERM on all further access, including read, rename, and even creating a new file with the same name — but not other files in the same directory). This is unrelated to and unfixable via git/filesystem permissions. `metadata.sh write` uses tmp-file + atomic `mv` (a single `rename()` syscall, never an in-place rewrite) precisely to minimize this risk.

If `metadata.sh` reports a `write` failure (exit 2, mv failed):
1. STOP. Do not retry the same write.
2. Do NOT attempt to self-heal via `mv`, `xattr`, `chflags`, or `rm` on the locked file from inside the session — these are exactly the operations that can escalate or fail to resolve an EDR lock, and in the worst case make it look more suspicious, not less.
3. Narrate the failure plainly and tell the dev: this is very likely an OS/EDR lock unrelated to the ticket's code. They can check Console.app (filter `endpointsecurity`) around the failure timestamp, or simply wait — these locks are usually time-boxed — and ask you to retry `metadata.sh write` later.
4. Continue reporting stage results in chat even if the write is blocked; the code/tests are the source of truth, metadata.json is bookkeeping.

## Required fields before marking a stage `complete`

Deterministic presence check (no LLM), implemented by `metadata.sh write --require <stage>:<complete|skipped>` (validates the transformed document before swapping) and standalone by `metadata.sh check-required <stage> <complete|skipped> [<file>|-]`. If a field is missing, back-fill it from the best available source (git log timestamp, current time) and write again as a NEW transition, narrating the correction; only then does the status land.

| Stage | Required when `complete` | Required when `skipped` |
|---|---|---|
| 1 ac | `completed_at`, `metadata.ac` populated | n/a |
| 2 plan | `completed_at`, `metadata.plan` populated | n/a |
| 3 build | `completed_at`, `iterations`, `loop_outcome`, `metadata.last_green_sha` | n/a (never skipped) |
| 4 verify | `completed_at`, `ac_verdicts`, `recommendation`, `evidence`, `anomalies`, `rationale`; see "Stage 4 payload" below | `skipped_reason`, `skipped_acknowledged_by = "dev"` |
| 5 wrapup | `completed_at`, `metadata.summary`, `metadata.commit_message`, `metadata.pr_description` (or `"skipped"`), `metadata.cost` (an object with a `status`) | n/a |

### Stage 4 payload

`stages.4` on complete: `ac_verdicts` (`PASS|FAIL|NOT_EXERCISED` per in-scope AC), `recommendation` (the analyzer's value, verbatim: `APPROVE|RETURN_TO_BUILD|NEED_MORE_DATA`), `evidence` (non-blank string per PASS/FAIL AC), `anomalies` (array, may be empty), `rationale`, plus when needed `accepted_not_exercised` (`[{ac, reason}]`, one entry with a non-blank reason per NOT_EXERCISED AC) and `override` (`{reason}`, required unless the recommendation is `APPROVE`). `null` counts as absent for the last two. All text is already redacted (`<redacted>` for credential-looking or personal values).

Free text (evidence, anomalies, rationale, acceptance and override reasons) reaches the write only through `--slurpfile` from `.doer/tickets/<ID>/stage4-payload.json`, never as a literal in the filter or the shell command; the file is deleted only after the write succeeds. When `--require` refuses on evidence or acceptance, never back-fill a placeholder (exception to the generic back-fill advice above): re-dispatch the analyzer on the pasted logs, or ask the dev again.

When the ticket itself transitions to `complete`: `completed_at` set, `summary` non-empty, lock file removed.
