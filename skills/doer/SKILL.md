---
name: doer
description: >-
  Ticket execution orchestrator. Takes a pre-defined ticket (feature, bug,
  refactor) from acceptance criteria to implementation-ready code on a feature
  branch. Invoke with "/doer <TICKET-ID>" to start a new ticket or resume an
  existing one (auto-detected). Other entry points: "/doer status <ID>",
  "/doer list", "/doer verify <ID>", "/doer cleanup-history <ID>",
  "/doer locale <code>". Also activates implicitly when the user references
  an active /doer ticket in natural language ("continue", "pause",
  "keep going with ABC-123"). Skips PRD, architecture design, ticket creation,
  PR assembly, and deployment. Keeps spec, plan, tests, code, review, docs,
  and lessons learned.
version: 6.4.0
user-invocable: true
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, AskUserQuestion, Agent]
---

# Doer. Ticket Execution Orchestrator

User-facing orchestrator for executing a single ticket end-to-end on a feature branch. Runs 9 sequential stages with doer/reviewer convergence loops. Narrates every action so the user can pause at any point. State persists on disk so work can be resumed across sessions.

**Scope:** one ticket, one branch, end-to-end implementation up to (but not including) PR and deploy.

**Out of scope:** PRD creation, architecture design, ticket creation, pull request assembly, CI, deployment. By design.

---

## Operating contract

This SKILL is a thin dispatcher. The orchestration logic lives in extracted files; load them on demand instead of all at once. Under context pressure, only the active stage file plus the cross-cutting protocols below stay resident in working memory.

### Cross-cutting protocols (read once, then refer)

| Concern | File |
|---|---|
| Core principles 2-8 (one branch/one ticket, delta-aware reviewers, bounded loops, lessons accumulate, no hidden state, `--no-verify` rule, `.doer/` never reaches team history) | `${CLAUDE_PLUGIN_ROOT}/lib/principles.md` |
| Narration (Principle 1) and em-dash prohibition (Principle 9), turn boundaries, auto-proceed contract, performance counters | `${CLAUDE_PLUGIN_ROOT}/lib/narration.md` |
| Workspace Guard (`.doer/` exclusion + already-tracked detection + tracked-file migration). The bash MUST run inline at every entry point. | `${CLAUDE_PLUGIN_ROOT}/lib/workspace-guard.md` |
| Doer/Reviewer Loop Pattern (severity buckets, `metadata.code_review`, `metadata.changelog`, sub-agent delegation contract, read budgets, iter 1 vs iter 2+ shapes, max-iter escape hatch). Stages 4 and 5 only. | `${CLAUDE_PLUGIN_ROOT}/lib/loop.md` |
| Stage Finalization Checklist (required-fields-per-stage table, agent-invocation gate, top-level required fields when ticket completes, validation procedure) | `${CLAUDE_PLUGIN_ROOT}/lib/stage-checklist.md` |
| `metadata.json` schema, per-repo `./.doer/` layout, global `lessons/` location | `${CLAUDE_PLUGIN_ROOT}/lib/memory-paths.md` |
| Versioning, Migration Check (Phase 1 + Phase 2 with auto-reverify), per-version migration blocks | `${CLAUDE_PLUGIN_ROOT}/lib/migrations.md` |
| Heartbeat self-check at every stage transition and `/doer` entry | `${CLAUDE_PLUGIN_ROOT}/lib/heartbeat.md` |
| Per-ticket lock | `${CLAUDE_PLUGIN_ROOT}/lib/lock.md` |
| Cross-stage inbox | `${CLAUDE_PLUGIN_ROOT}/lib/inbox.md` |
| Cost tracking + transcript reconciliation | `${CLAUDE_PLUGIN_ROOT}/lib/cost.md` |
| Stage 7 cleanup drift handling | `${CLAUDE_PLUGIN_ROOT}/lib/debugging.md` |

### State machine

| Stage | File |
|---|---|
| 1. AC Confirm | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/01-ac-confirm.md` |
| 2. Plan | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/02-plan.md` |
| 3. Tests | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/03-tests.md` |
| 4. Code | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/04-code.md` |
| 5. Code Review | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/05-code-review.md` |
| 6. Quality Gate | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/06-quality-gate.md` |
| 7. Runtime Verify | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/07-runtime-verify.md` |
| 8. Docs Sync | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/08-docs-sync.md` |
| 9. Wrapup | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/09-wrapup.md` |
| Intake (new ticket) | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/_intake.md` |
| Resume flow (existing ticket) | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/_resume.md` |
| Auxiliary commands (`status`, `list`, `verify`, `cleanup-history`, `locale`) | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/_commands.md` |

**Stage transition rule.** When a stage finishes and auto-proceeds to N+1, read ONLY the file for stage N+1. Do NOT pre-load other stage files. The single-stage-resident invariant is what keeps peak working memory bounded.

---

## Commands

| Command | Description |
|---------|-------------|
| `/doer <TICKET-ID>` | Start a new ticket OR resume an existing one (auto-detected by `metadata.json` presence). |
| `/doer status <TICKET-ID>` | Show current stage, loop state, and blockers. |
| `/doer list` | List all tickets in `./.doer/tickets/`. |
| `/doer verify <TICKET-ID>` | Run stages that exist in the current skill but were missing when the ticket was closed. |
| `/doer cleanup-history <TICKET-ID>` | Strip any `.doer/` content from commits on the ticket's feature branch. Auto-runs at wrapup; this command lets you re-run it manually. |
| `/doer locale <code>` | Set the global operating locale (e.g. `/doer locale es`, `/doer locale en`). Persists to `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json`; survives plugin upgrades. |

**Backward compat:** `/doer continue <ID>`, `/doer start <ID>`, etc. are accepted as aliases; the verb is parsed and ignored. `/doer <ID>` always does the right thing.

**There is no `/doer pause`.** State persists automatically after every Agent return. To stop, just close the session or write `stop` / `wait` / `hold on`. To resume, `/doer <TICKET-ID>` from any future session.

**Stages cannot be skipped manually.** Every stage must run. The only way to skip stages is through Stage 1's pre-existing-work detection. The orchestrator decides which stages to skip, not the user.

**Implicit activation:** If the user writes natural language (e.g. "keep going", "pause here", "the plan looks good") and an active ticket exists in `./.doer/tickets/*/metadata.json` with `status == "in_progress"`, treat the message as a directive to the active orchestrator rather than a new query.

---

## Entry-point dispatch

Every `/doer ...` invocation begins with these steps, in order. Do NOT skip any.

### 1. Resolve locale (FIRST action, before any other tool call)

```bash
LOCALE="$("${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh" get-locale)"
```

If `LOCALE` is `en` AND the global preferences file has no explicit locale set (the helper's path either does not exist OR `jq -r '.locale // empty'` is empty), run the heuristic on the user's most recent message:

```bash
DETECTED="$("${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh" detect-locale "<last user message text>")"
```

If `DETECTED == "es"`, ask ONE confirmation via `AskUserQuestion`, in Spanish: *"Detecté que escribes en español. ¿Quieres que toda la narración sea en español a partir de ahora? Y / N"*. On `Y`, run `preferences.sh set-locale es` (persists globally). On `N`, narrate in English from now on and do NOT persist anything.

If `DETECTED == "en"`, proceed in English silently.

The resolved locale binds the entire chat output for this invocation.

### 2. Check for plugin updates (non-blocking)

Fetch the latest published version from GitHub and compare it to the installed version. Best-effort: if the network call fails or takes more than 5 seconds, skip silently with no narration.

```bash
INSTALLED_VERSION="$(grep '^version:' "${CLAUDE_PLUGIN_ROOT}/skills/doer/SKILL.md" | head -1 | awk '{print $2}')"
LATEST_VERSION="$(curl -sf --max-time 5 \
  "https://raw.githubusercontent.com/icarloscornejo/doer/main/.claude-plugin/plugin.json" \
  | jq -r '.version // empty' 2>/dev/null || true)"
```

If `LATEST_VERSION` is non-empty AND `LATEST_VERSION != INSTALLED_VERSION`:

Narrate once at the top of the response (in the resolved locale):
- **English:** *"[wk update available: v<LATEST_VERSION>] You are running v<INSTALLED_VERSION>. Update from the /plugins panel or run: `claude plugin marketplace update wk && claude plugin uninstall wk && claude plugin install wk@wk` then restart Claude Code."*
- **Spanish:** *"[wk actualización disponible: v<LATEST_VERSION>] Tienes instalada la v<INSTALLED_VERSION>. Actualiza desde el panel /plugins o ejecuta: `claude plugin marketplace update wk && claude plugin uninstall wk && claude plugin install wk@wk` y reinicia Claude Code."*

Then proceed normally — this check NEVER blocks ticket work.

### 3. Acquire per-ticket lock

For every command that operates on a specific `<TICKET-ID>` (start, resume, status, verify, cleanup-history), acquire the lock per `${CLAUDE_PLUGIN_ROOT}/lib/lock.md` before touching `metadata.json`. Release at end of stage 9 step 10 (or on any error path that stops the orchestrator). `status` and `list` are read-only and skip the lock.

### 3. Route by command and metadata presence

- `/doer locale <code>` → Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/_commands.md` (locale section). Apply, narrate, end turn.
- `/doer list` → Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/_commands.md` (list section). Render, end turn.
- `/doer status <ID>` → Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/_commands.md` (status section). Render, end turn.
- `/doer verify <ID>` → Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/_commands.md` (verify section). Execute it.
- `/doer cleanup-history <ID>` → Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/_commands.md` (cleanup-history section). Execute it.
- `/doer <ID>` (new or resume) → check for `./.doer/tickets/<ID>/metadata.json`:
  - **Exists** → Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/_resume.md` and ONLY that file. Execute resume flow. Do NOT re-ask any intake question.
  - **Does NOT exist** → Read `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/_intake.md` and ONLY that file. Execute intake.

The dev never has to remember whether a ticket already exists. `/doer ABC-123` always does the right thing.

---

## Agent invocation contract

All sub-agents (doer or reviewer) must:
- Receive a prompt that contains the relevant `metadata.json` slices inlined (no sidecar file reads), specifies the artifacts to produce (code, tests, docs), success criteria, and the "do not" list (e.g. *"do not ask the user questions, the orchestrator handles that"*).
- Write code/test/doc artifacts directly to the working tree (not to `.doer/`).
- Return a JSON object containing a `changelog_appendix` (which the orchestrator persists into `metadata.changelog`) plus any stage-specific output (e.g. `code_review_entry`, `tests_added`, `plan`).
- For doer agents: also include `{"status": "success" | "failed", "summary": "<one line>"}` at the top level.

The orchestrator (this skill) is the sole user-facing voice. Sub-agents must NOT invoke `AskUserQuestion`.

The full delegation rules (which stages MUST delegate, what may run inline, the agent-invocation gate) live in `${CLAUDE_PLUGIN_ROOT}/lib/loop.md` and `${CLAUDE_PLUGIN_ROOT}/lib/stage-checklist.md`.

---

## Error handling

- **Agent returns error:** narrate the error, ask user to retry (max 3), or pause.
- **Git operation fails:** narrate, present options (resolve manually, pause, abort stage).
- **Tests cannot be detected:** ask the user for the test command. Save it to `metadata.test_command` for future stages.
- **User says `stop` / `wait` / `hold on`:** state is already persisted after each Agent return. Narrate the current position and stop. Resume via `/doer <TICKET-ID>` later.

---

*Maintained by hand. The plugin layout (`lib/`, `skills/doer/stages/`) is the source of truth; all stage logic lives in the extracted files referenced above.*
