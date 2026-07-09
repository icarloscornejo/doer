# State: Schemas and Layout

Single source of truth for on-disk state. Control state is lean JSON; raw text and heavy artifacts live in files read on demand, never inlined into the JSON.

## Layout

```
${CLAUDE_PLUGIN_ROOT}/                 # plugin install (cross-project)
├── skills/{doer,bugfix,protologs}/
├── lib/                               # protocols + helpers
└── lessons/{slug}.md                  # GLOBAL lessons pool, cross-project

${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/
└── preferences.json                   # locale only (personal, same in every repo); survives plugin upgrades

./.doer/                               # per-repo, excluded via .git/info/exclude
├── config.json                       # per-project Jira config (schema below)
└── tickets/{TICKET-ID}/
    ├── metadata.json                  # doer tickets (schema below)
    ├── bugfix.json                    # bugfix tickets (schema in skills/bugfix/SKILL.md)
    ├── ticket.md                      # bugfix only: raw Jira description + comments
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

## .doer/config.json

```json
{"jira_base_url": "https://jira.example.com", "jira_token_env": "JIRA_PROD_PAT"}
```

Read and written only through `lib/helpers/jira.sh` (`set-url`, `set-token-env`, `config`). Per-project: different repos can point at different Jira instances. `jira_token_env` names the environment variable holding the bearer token (default `JIRA_PAT` if absent); the token itself is never persisted, only its env var's name. Set up guided via `/wk:setup`, or one-shot via `/wk:jira <url>`.

## metadata.json (doer ticket)

```json
{
  "ticket_id": "ABC-123",
  "title": "<title>",
  "branch": "<feature branch>",
  "status": "in_progress | complete",
  "current_stage": 1,
  "skill_version": "7.0.0",
  "created_at": "<ISO8601>", "completed_at": null,
  "intake": {"description": "...", "raw_acs": "... | derive", "context": "...",
              "prior_work": {"exists": false}, "tracker": null},
  "ac": {"in_scope": ["AC-1: ..."], "out_of_scope": [], "open_questions_resolved": [],
          "applicable_lessons": []},
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
  "summary": null, "commit_message": null, "pr_description": null
}
```

Stage statuses: `pending | in_progress | complete | skipped | imported`. `ac`, `plan`, and later fields start absent and are written by their owning stage. `last_green_sha` is always the full 40-char `git rev-parse HEAD` output (string-equality comparisons break on abbreviation).

## Required fields before marking a stage `complete`

Deterministic presence check (no LLM). If a field is missing, back-fill it from the best available source (git log timestamp, current time) and narrate; only then write the status.

| Stage | Required when `complete` | Required when `skipped` |
|---|---|---|
| 1 ac | `completed_at`, `metadata.ac` populated | n/a |
| 2 plan | `completed_at`, `metadata.plan` populated | n/a |
| 3 build | `completed_at`, `iterations`, `loop_outcome`, `metadata.last_green_sha` | n/a (never skipped) |
| 4 verify | `completed_at`, `ac_verdicts` | `skipped_reason`, `skipped_acknowledged_by = "dev"` |
| 5 wrapup | `completed_at`, `metadata.summary`, `metadata.commit_message`, `metadata.pr_description` (or `"skipped"`) | n/a |

When the ticket itself transitions to `complete`: `completed_at` set, `summary` non-empty, lock file removed.
