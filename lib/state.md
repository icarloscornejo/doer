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
{"jira_base_url": "https://jira.example.com", "jira_token_env": "JIRA_PROD_PAT", "jira_auth_email": null}
```

Read and written only through `lib/helpers/jira.sh` (`set-url`, `set-token-env`, `set-auth-email`, `config`). Per-project: different repos can point at different Jira instances. `jira_token_env` names the environment variable holding the token (default `JIRA_PAT` if absent); the token itself is never persisted, only its env var's name. `jira_auth_email` is optional and switches auth from Bearer (Jira Server/DC) to HTTP Basic `email:token` (required for Atlassian Cloud, `*.atlassian.net`). Set up guided via `/wk:setup`, or one-shot via `/wk:jira <url>`.

## metadata.json (doer ticket)

```json
{
  "ticket_id": "ABC-123",
  "title": "<title>",
  "branch": "<feature branch>",
  "status": "in_progress | complete",
  "current_stage": 1,
  "skill_version": "7.2.0",
  "created_at": "<ISO8601>", "completed_at": null,
  "intake": {"description": "...", "raw_acs": "... | derive", "context": "...",
              "prior_work": {"exists": false}, "tracker": null},
  "ac": {"in_scope": ["AC-1: ..."], "out_of_scope": [], "open_questions_resolved": [],
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
  "summary": null, "commit_message": null, "pr_description": null
}
```

Stage statuses: `pending | in_progress | complete | skipped | imported`. `ac`, `plan`, and later fields start absent and are written by their owning stage. `last_green_sha` is always the full 40-char `git rev-parse HEAD` output (string-equality comparisons break on abbreviation).

## Writing metadata.json (and bugfix.json)

ALWAYS through `lib/helpers/metadata.sh` (`init` to create, `write` to update), NEVER via direct `Edit`/`Write` tool calls on the file, and NEVER more than once per logical stage transition. Applies equally to `bugfix.json` (`metadata.sh ... --file bugfix.json`). Batch every field of one transition (stage status, `completed_at`, the stage's payload, `current_stage` advance) into a SINGLE jq filter and call `write` exactly once; a correction after a successful write is a NEW write, never a retry of the same transition.

Rationale: `.doer/` is a hidden directory, and rapid successive rewrites of the same file from an automated process is a known trigger for corporate EDR ransomware heuristics, which can lock the file at the OS level (observed: macOS `com.apple.provenance` tag + EPERM on all further access, including read, rename, and even creating a new file with the same name — but not other files in the same directory). This is unrelated to and unfixable via git/filesystem permissions. `metadata.sh write` uses tmp-file + atomic `mv` (a single `rename()` syscall, never an in-place rewrite) precisely to minimize this risk.

If `metadata.sh` reports a `write` failure (exit 2, mv failed):
1. STOP. Do not retry the same write.
2. Do NOT attempt to self-heal via `mv`, `xattr`, `chflags`, or `rm` on the locked file from inside the session — these are exactly the operations that can escalate or fail to resolve an EDR lock, and in the worst case make it look more suspicious, not less.
3. Narrate the failure plainly and tell the dev: this is very likely an OS/EDR lock unrelated to the ticket's code. They can check Console.app (filter `endpointsecurity`) around the failure timestamp, or simply wait — these locks are usually time-boxed — and ask you to retry `metadata.sh write` later.
4. Continue reporting stage results in chat even if the write is blocked; the code/tests are the source of truth, metadata.json is bookkeeping.

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
