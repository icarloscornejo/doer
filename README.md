# doer

**Ticket execution orchestrator for Claude Code.**

`/doer` takes a pre-defined ticket (feature, bug, refactor) from acceptance criteria to implementation-ready code on a feature branch. It runs a 9-stage pipeline with doer/reviewer convergence loops, narrating every action so you can pause at any point.

Scope: one ticket, one branch, end-to-end implementation up to (but not including) PR and deploy.

Out of scope: PRD creation, architecture design, Jira creation, pull request assembly, deployment.

---

## Pipeline

1. **AC Confirm** — restate acceptance criteria as Given/When/Then, flag out-of-scope, capture assumptions
2. **Plan** — implementation plan (doer/reviewer loop, delta-aware, max 5 iterations)
3. **Tests (TDD red)** — failing tests that encode the ACs (loop)
4. **Code (TDD green)** — make the tests pass (loop)
5. **Reflect** — cheap self-review before the external reviewer
6. **Code Review** — explicit checklist review (loop)
7. **Quality Gate** — run the full test suite
8. **Docs Sync** — update README / CHANGELOG / user-facing docs if affected
9. **Wrapup** — capture lessons, validate assumptions

Every stage ends with a commit on the feature branch, creating a trail of evidence that later agents can read with `git diff`.

---

## Installation

`/doer` is a single-file Claude Code skill. To install:

```bash
mkdir -p ~/.claude/skills/doer
curl -fsSL https://raw.githubusercontent.com/icarloscornejo/doer/main/SKILL.md \
  -o ~/.claude/skills/doer/SKILL.md
```

Or clone and symlink:

```bash
git clone https://github.com/icarloscornejo/doer.git ~/src/doer
ln -s ~/src/doer ~/.claude/skills/doer
```

To update later, re-run the `curl` command or `cd ~/src/doer && git pull`.

---

## Usage

| Command | Description |
|---------|-------------|
| `/doer <TICKET-ID>` | Start a new ticket. Orchestrator asks for title, description, type, ACs, context, branch name. |
| `/doer continue <TICKET-ID>` | Resume a paused ticket. |
| `/doer status <TICKET-ID>` | Show current stage, loop state, blockers. |
| `/doer list` | List all tickets in `./.doer/tickets/`. |
| `/doer stage <N> <TICKET-ID>` | Jump to stage N (with warnings). |
| `/doer pause` | Persist current state and stop. |

Once a ticket is active, you can also use natural language — "sigue", "pausa aquí", "the plan looks good, keep going" — and the orchestrator will pick up the active ticket from `./.doer/tickets/*/metadata.json`.

---

## State Layout

All state lives under `./.doer/` in the target repo:

```
./.doer/
├── knowledge/
│   ├── lessons/          # Accumulated across tickets. Read before planning.
│   └── assumptions/      # Per-ticket, validated at wrapup.
└── tickets/
    └── <TICKET-ID>/
        ├── metadata.json
        ├── ticket.md
        ├── ac.md
        ├── plan.md
        ├── reflect.md
        ├── wrapup.md
        └── review/
```

Commit this directory to the target repo if you want the knowledge base (lessons, assumptions) to travel with the codebase. Otherwise, add `.doer/` to `.gitignore`.

---

## Design Notes

- **Delta-aware reviewers.** After iteration 1, reviewers receive prior findings + a changelog from the doer. They verify fixes and scan changed areas for new issues, rather than re-analyzing from scratch.
- **Findings are categorized**: `BLOCKER` (must fix), `SUGGESTION` (optional, user decides), `INFO` (observational).
- **Max 5 iterations per loop.** If not converged, the user chooses: one more iteration, accept remaining findings, or pause.
- **The orchestrator is the sole voice.** Subagents write artifacts and return JSON summaries. Only the orchestrator calls `AskUserQuestion`.
- **No push, no PR, no deploy.** `/doer` stops after wrapup. You push and open the PR manually.

---

## License

MIT
