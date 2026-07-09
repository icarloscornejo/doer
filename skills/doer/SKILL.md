---
name: doer
description: >-
  Ticket execution orchestrator. Takes a pre-defined ticket (feature, bug,
  refactor) from acceptance criteria to implementation-ready code on a feature
  branch, in 5 stages. Invoke with "/doer <TICKET-ID>" to start a new ticket or
  resume an existing one (auto-detected). Other entry points: "/doer status <ID>",
  "/doer list", "/doer cleanup-history <ID>". Also
  activates implicitly when the user references an active /doer ticket in
  natural language ("continue", "pause", "keep going with ABC-123"). Stops
  before PR and deploy. For bug triage from a Jira ticket use /wk:bugfix instead.
  For locale or Jira config use /wk:setup, /wk:locale, or /wk:jira instead.
version: 7.1.0
user-invocable: true
allowed-tools: [Read, Write, Edit, Grep, Glob, Bash, AskUserQuestion, Agent, Skill, EnterPlanMode, ExitPlanMode]
---

# Doer. Ticket Execution Orchestrator

Executes a single ticket end-to-end on a feature branch: 5 sequential stages, a bounded doer/reviewer loop on the build stage, on-device runtime verification via `wk:protologs`, lessons that accumulate across projects. State persists on disk; closing the session is pausing. BDD-style throughout: ACs are captured as Given/When/Then scenarios and tests derive from them (Stage 1, Stage 3), unless the change is trivial/cosmetic.

**Scope:** one ticket, one branch, up to (but not including) PR and deploy.

## Protocols (read once, refer as needed)

| Concern | File |
|---|---|
| Core principles | `${CLAUDE_PLUGIN_ROOT}/lib/principles.md` |
| Transition Sync (unconditional re-hydration per stage transition / resume) | `${CLAUDE_PLUGIN_ROOT}/lib/sync.md` |
| Narration, turn boundaries, AskUserQuestion vs chat, locale | `${CLAUDE_PLUGIN_ROOT}/lib/narration.md` |
| Workspace Guard + per-ticket lock (bash runs inline at every entry) | `${CLAUDE_PLUGIN_ROOT}/lib/workspace-guard.md` |
| Doer/Reviewer loop (severity buckets, iteration shapes, read budgets) | `${CLAUDE_PLUGIN_ROOT}/lib/loop.md` |
| `metadata.json` / `bugfix.json` schemas, `.doer/` layout, required fields | `${CLAUDE_PLUGIN_ROOT}/lib/state.md` |
| Root-cause discipline for any fix | `${CLAUDE_PLUGIN_ROOT}/lib/debugging.md` |

## Stages

| Stage | File |
|---|---|
| 1. AC + Intake | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/01-ac.md` |
| 2. Plan | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/02-plan.md` |
| 3. Build (tests + code + review loop) | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/03-build.md` |
| 4. Verify (on device, via wk:protologs) | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/04-verify.md` |
| 5. Wrapup | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/05-wrapup.md` |
| Resume flow | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/_resume.md` |
| Aux commands (`status`, `list`, `cleanup-history`) | `${CLAUDE_PLUGIN_ROOT}/skills/doer/stages/_commands.md` |

**Stage transition rule.** Every stage transition and every resume runs the Transition Sync (`lib/sync.md`) as its first action, unconditionally: re-read `metadata.json`, then read ONLY the file for the current stage. One stage file resident at a time; this keeps peak context bounded and re-hydrates instructions after any compaction. A finished stage auto-proceeds to N+1 in the same turn; stopping between stages without an explicit pause is a sync violation, not a resting point.

## Entry-point dispatch

Every `/doer ...` invocation, in order:

1. **Resolve locale** (first action): `LOCALE="$("${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh" get-locale)"`. All chat output binds to it (persistent state stays English; see `lib/narration.md`).
2. **Route by command:**
   - `/doer list`, `/doer status <ID>`, `/doer cleanup-history <ID>` → read `_commands.md`, execute, end turn.
   - `/doer <ID>` → check `./.doer/tickets/<ID>/metadata.json`:
     - Exists → read `_resume.md` and ONLY that file. Do NOT re-ask intake questions.
     - Missing → read `01-ac.md` and ONLY that file (intake lives there).
3. **Workspace Guard + lock** (ticket-scoped commands only, not `list`/`status`): run the inline bash in `lib/workspace-guard.md` before touching metadata.

**Version stamp.** New tickets record `skill_version` from this frontmatter. On resume, if the ticket's MAJOR differs from the current MAJOR, stop and narrate: the ticket was created with an incompatible schema; finish it by hand or recreate it. No auto-migration machinery exists; if a future 7.x change ever needs one, it will be written then.

**Implicit activation:** natural language ("keep going", "pause here") with an active ticket (`status == "in_progress"` under `./.doer/tickets/*/metadata.json`) is a directive to the orchestrator, not a new query. There is no `pause` command: state persists after every Agent return; `stop` / `wait` / `hold on` halts, anything else resumes.

**Stages cannot be skipped manually.** The only skip path is Stage 1's pre-existing-work detection; the orchestrator decides.

## Agent invocation contract

Sub-agents receive the relevant `metadata.json` slices inlined in their prompt (no sidecar reads), write real artifacts directly to the working tree, and return JSON with a `changelog_appendix` plus stage-specific output. Doer agents also return `{"status": "success" | "failed", "summary": "<one line>"}`. Sub-agents never call `AskUserQuestion`; the orchestrator is the sole user-facing voice. Heavy artifact work (planning happens in plan mode; test/code writing, reviewing, log analysis go through Agent) is delegated; the orchestrator itself only does state reads/writes, deterministic validation, narration, and transitions.

## Error handling

- **Agent error:** narrate it, end turn; the user decides (retry max 3, or pause).
- **Git failure:** narrate, present options (resolve manually, pause, abort stage).
- **Test command unknown:** ask once, persist as `metadata.test_command`.
- **Halt signal:** narrate current position and stop. Resume later with `/doer <ID>`.
