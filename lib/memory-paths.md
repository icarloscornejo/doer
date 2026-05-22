# Knowledge & State Layout

Status: protocol shared by all skills in the `wk` plugin.

This document is the single source of truth for `metadata.json` schema, per-ticket file layout, and the global `lessons/` location. Skills MUST consult this file when reading or writing any persistent state.

## Layout

All state lives under `./.doer/` in the current working directory (scoped to the target repo).

**Lessons are GLOBAL**: they live next to the plugin install (so all repos share the same accumulated knowledge). **Everything else is per-ticket and lives in a single `metadata.json` per ticket.** No markdown sidecars, no scratch files, no per-stage review files.

```
${CLAUDE_PLUGIN_ROOT}/             # plugin install root (e.g. ~/.claude/plugins/cache/wk/wk/<version>/)
├── skills/doer/SKILL.md
├── lib/                           # shared protocols (this file lives here)
└── lessons/                       # GLOBAL, cross-project, gitignored
    └── {slug}.md

${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/   # PER-CLAUDE-CONFIG, lives outside the versioned plugin cache
└── preferences.json               # locale + opt-in flags. Survives plugin uninstall/install/upgrade.

./.doer/                           # per-repo (in CWD), gitignored via .git/info/exclude
└── tickets/
    └── {TICKET-ID}/
        └── metadata.json          # SINGLE file per ticket: state + intake + ac + plan + changelog + code_review + assumptions + wrapup
```

**Why `preferences.json` lives outside `${CLAUDE_PLUGIN_ROOT}`:** the plugin cache is versioned (e.g. `cache/wk/wk/6.2.0/`), so any preference stored next to `SKILL.md` is wiped on every `uninstall + install` cycle. The global preferences file lives next to the active Claude Code config dir (`$CLAUDE_CONFIG_DIR`, falls back to `~/.claude`), which is stable across plugin upgrades and distinct per Claude install (claude-tm vs claude-sephora vs claude-personal each have their own `$CLAUDE_CONFIG_DIR`, so their preferences are isolated). Shape:

```json
{
  "locale": "es",
  "stage4_per_task_gate": false,
  "stage4_parallel_subagents": false,
  "stage5_advisor_personas": []
}
```

All reads and writes go through `${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh`. There is no `metadata.locale` field on tickets; the global file is the only locale source.

**Per ticket: 1 file (`metadata.json`).** Everything (ac, plan, changelog, code review history, assumptions, lessons captured, summary, performance) lives as structured fields inside `metadata.json`. One source of truth, no drift, no file-coordination cost. Sub-agents receive the relevant slices of metadata inlined in their prompts; they do not read sidecar files.

### `metadata.json` schema (v6.0.0)

```json
{
  "ticket_id": "<ID>",
  "title": "<title>",
  "branch": "<branch>",
  "status": "in_progress | complete",
  "current_stage": 1,
  "skill_version": "6.0.0",
  "testing_strategy": {
    "mode": "direct | bdd",
    "rationale": "<one sentence explaining why this mode was chosen>",
    "signals": ["<signal-id>", "..."],
    "overridden_by_dev": false
  },
  "created_at": "<ISO8601>",
  "completed_at": null,

  "intake": {
    "description": "<full pasted description>",
    "raw_acs": "<full pasted ACs or 'derive'>",
    "context": "<extra context or 'none'>",
    "prior_work": { "exists": false, "plan": null, "tests": null, "code": null, "docs": null }
  },

  "ac": {
    "in_scope": ["AC-1: ...", "AC-2: ..."],
    "out_of_scope": ["..."],
    "open_questions_resolved": [{"question": "...", "answer": "..."}],
    "applicable_lessons": ["<lesson-slug>"]
  },

  "plan": {
    "files": [{"path": "...", "change": "edit | new | delete", "reason": "..."}],
    "steps": [{"order": 1, "verb": "...", "what": "...", "where": "<file>:<line-range>", "parallel_group": "<optional string id; steps sharing the same id are independent and may dispatch in parallel when preferences.sh get-flag stage4_parallel_subagents returns true>"}],
    "tests": [{"name": "...", "covers": ["AC-N"], "what": "..."}],
    "risks": [{"risk": "...", "mitigation": "..."}],
    "assumptions": ["..."]
  },

  "stages": {
    "1": {"name": "ac-confirm",     "status": "pending | in_progress | complete | skipped | imported | blocked | retroactive_in_progress", "verified_with": "6.0.0", "completed_at": "<ISO8601>"},
    "2": {"name": "plan",           "status": "...", "verified_with": "6.0.0", "retry_used": false},
    "3": {"name": "tests",          "status": "pending | in_progress | complete | deferred | skipped | imported | blocked", "verified_with": "6.0.0", "retry_used": false, "testing_strategy_mode": "direct | bdd"},
    "4": {"name": "code",           "status": "...", "verified_with": "6.0.0", "iterations": 0, "loop_outcome": "converged | accepted_with_residuals", "pre_stage4_sha": "<full-40-char-SHA>", "per_task_gate": {"enabled": false, "decisions": [{"step_order": 1, "decision": "accepted | edited_manual | edited_via_writer | rejected | skipped | auto_accepted_empty", "at": "<ISO8601>", "edit_instructions": "<optional, only for edited_via_writer>"}]}, "parallel_subagents": {"enabled": false, "groups": [{"id": "<parallel_group id, or 'serial-<order>' for ungrouped steps>", "step_orders": [1, 2], "dispatched": "parallel | serialized_due_to_overlap | serial_singleton", "started_at": "<ISO8601>", "completed_at": "<ISO8601>", "errored_step_orders": []}]}},
    "5": {"name": "code-review",    "status": "...", "verified_with": "6.0.0", "iterations": 0, "loop_outcome": "..."},
    "6": {"name": "quality-gate",   "status": "...", "verified_with": "6.0.0"},
    "7": {"name": "runtime-verify", "status": "...", "verified_with": "6.0.0", "ac_verdicts": {}},
    "8": {"name": "docs-sync",      "status": "...", "verified_with": "6.0.0"},
    "9": {"name": "wrapup",         "status": "...", "verified_with": "6.0.0"}
  },

  "changelog": [
    {"stage": 2, "iteration": 1, "kind": "initial | fixes", "items": [
      {"type": "decision | step | fix | auto_fix", "text": "<one-line>", "blocker_id": "<optional, only for fix>", "id": "<optional, only for auto_fix>"}
    ]}
  ],

  "code_review": [
    {"iteration": 1, "blockers": [{"id": "B-1", "text": "...", "source": "reviewer | advisor:<persona-id>"}], "auto_fixes": [], "suggestions": [{"text": "...", "source": "reviewer | advisor:<persona-id>"}], "info": [{"text": "...", "source": "reviewer | advisor:<persona-id>"}], "verdict": "needs_revision | converged", "advisor_personas_ran": ["security", "performance"]},
    {"iteration": 2, "prior_blockers_resolved": ["B-1"], "prior_blockers_still_open": [], "new_blockers": [], "auto_fixes": [], "suggestions": [], "info": [], "verdict": "..."}
  ],

  "assumptions_validation": [{"text": "...", "status": "VALIDATED | INVALIDATED | UNVERIFIED", "reason": "..."}],
  "lessons_captured": [{"slug": "<lesson-slug>", "takeaway": "..."}],
  "summary": "<wrapup paragraph>",
  "performance": {"started": "...", "completed": "...", "wall_clock": "...", "active": "...", "stages": [], "code": {}, "agents": {}, "convergence": {}, "reviewer_roi": "..."},

  "blocking_conditions": [],
  "commits": [],
  "workspace_guard": "ok",
  "runtime_build_command": null,
  "lint_command": null,
  "typecheck_command": null,
  "test_command": null,
  "last_green_sha": null,
  "last_green_test_command": null,
  "session_ids": ["<claude-code-session-uuid>"],
  "session_ids_source": "env:CLAUDE_CODE_SESSION_ID | jsonl_fallback"
}
```

**Field ownership:** `intake` (intake step), `testing_strategy` (intake's final sub-step, after heuristic inference + a single dev confirmation), `ac` (Stage 1), `plan` (Stage 2), `changelog` (every doer stage appends), `code_review` (Stage 5 appends), `assumptions_validation` / `lessons_captured` / `summary` / `performance` (Stage 9). The `stages` block is the state machine; the orchestrator updates per-stage `status`, `verified_with`, and stage-specific fields (`retry_used` and `testing_strategy_mode` for 3, `retry_used` for 2, `iterations`/`loop_outcome` for 4/5, `pre_stage4_sha` and `per_task_gate` for 4 when `preferences.sh get-flag stage4_per_task_gate` returns `true`, `parallel_subagents` for 4 when `preferences.sh get-flag stage4_parallel_subagents` returns `true`, `ac_verdicts` for 7). `session_ids` and `session_ids_source` are written at intake and appended on every resume; owned by the orchestrator entry-point and resume flow. `cost.transcript_reconciled` is written by `cost-transcript.sh reconcile` at Stage 9 step 12.

**`code_review[].source` field semantics (added in WK-11).** Each entry in `blockers`, `suggestions`, and `info` carries an optional `source` field: `"reviewer"` (default; from the Stage 5 reviewer LLM) or `"advisor:<persona-id>"` (from a persona invoked via `/wk:advise` when `preferences.sh get-flag stage5_advisor_personas` returns a non-empty list). Absence of the field is interpreted as `"reviewer"` for backward compatibility with pre-WK-11 tickets. The `advisor_personas_ran` field on iteration 1 lists which personas were dispatched; it is absent on iter 2/3 because personas do not re-run.

**`testing_strategy` semantics.** Two modes determine how Stage 3 runs:
- `direct`: Stage 3 is DEFERRED at first entry; Stage 4 runs first; Stage 3 then runs after Stage 4 with a regression test writer (tests expected to PASS, no red phase).
- `bdd`: Stage 3 writes Given/When/Then scenario tests that fail because no implementation exists; Stage 4 implements code derived from the scenarios.

`testing_strategy.mode` is set ONCE at intake and never changes mid-ticket. The dev can override the inferred mode at the confirmation prompt at intake.

**Path resolution for `lessons/`:** use `${CLAUDE_PLUGIN_ROOT}` to resolve the plugin root, e.g. `${CLAUDE_PLUGIN_ROOT}/lessons/` for lessons or `${CLAUDE_PLUGIN_ROOT}/lib/<file>.md` for shared protocols. `${CLAUDE_PLUGIN_ROOT}` is the variable Claude Code substitutes automatically to the installed plugin path; do NOT use `readlink`/`realpath` heuristics on `SKILL.md`.

The global `lessons/` directory ships with the plugin. The per-repo `./.doer/` directory and the `tickets/` subdir under it are created on first invocation if missing.
