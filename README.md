# doer

**Ticket execution orchestrator for Claude Code.**

Takes a pre-defined ticket (feature, bug, refactor) from acceptance criteria to implementation-ready code on a feature branch. Nine sequential stages, delta-aware doer/reviewer loops, narration you can pause at any moment.

Scope stops before PR and deploy.

---

## Pipeline

```mermaid
flowchart TD
    A[1 AC Confirm]:::gate --> B[2 Plan]:::loop
    B --> C[3 Tests TDD red]:::loop
    C --> D[4 Code TDD green]:::loop
    D --> E[5 Reflect]:::plain
    E --> F[6 Code Review]:::loop
    F --> G[7 Quality Gate]:::gate
    G --> H[8 Docs Sync]:::plain
    H --> I[9 Wrapup]:::final

    classDef loop fill:#1e3a5f,stroke:#60a5fa,stroke-width:2px,color:#e0f2fe
    classDef gate fill:#78350f,stroke:#fbbf24,stroke-width:2px,color:#fef3c7
    classDef final fill:#14532d,stroke:#4ade80,stroke-width:2px,color:#dcfce7
    classDef plain fill:#1e293b,stroke:#94a3b8,stroke-width:2px,color:#e2e8f0
```

**Blue** = doer/reviewer loop (max 5 iterations) · **Amber** = validation gate · **Green** = wrapup (lessons captured) · **Slate** = single-pass stage

Every stage ends with a commit on the feature branch, creating a trail of evidence that later agents can read with `git diff`.

---

## Doer / Reviewer Loop

Stages 2, 3, 4, and 6 run a delta-aware convergence loop.

```mermaid
flowchart TD
    Start([Start iteration]):::plain --> Doer[Doer produces artifact + changelog]:::doer
    Doer --> Reviewer[Reviewer categorizes findings]:::reviewer
    Reviewer --> Check{BLOCKERs?}:::decision
    Check -- "0 BLOCKERs" --> Done([Converged]):::success
    Check -- "> 0 BLOCKERs" --> Max{Iteration < 5?}:::decision
    Max -- "yes" --> DoerD[Doer addresses BLOCKERs]:::doer
    DoerD --> ReviewerD[Reviewer checks fixes only, scans changes for new issues]:::reviewer
    ReviewerD --> Check
    Max -- "no" --> Ask([Ask user: retry / accept / pause]):::warn

    classDef plain fill:#1e293b,stroke:#94a3b8,stroke-width:2px,color:#e2e8f0
    classDef doer fill:#1e3a5f,stroke:#60a5fa,stroke-width:2px,color:#e0f2fe
    classDef reviewer fill:#4c1d95,stroke:#a78bfa,stroke-width:2px,color:#ede9fe
    classDef decision fill:#374151,stroke:#9ca3af,stroke-width:2px,color:#f3f4f6
    classDef success fill:#14532d,stroke:#4ade80,stroke-width:2px,color:#dcfce7
    classDef warn fill:#78350f,stroke:#fbbf24,stroke-width:2px,color:#fef3c7
```

**Iteration 1** — reviewer is clean-slate.
**Iteration 2+** — reviewer receives prior findings + doer's changelog. Marks each prior BLOCKER as `RESOLVED` or `STILL_OPEN`. Scans only the areas the doer touched for new issues. No re-analysis of untouched parts.

Findings are categorized:
- `BLOCKER` — must fix before advancing
- `SUGGESTION` — optional, user decides
- `INFO` — observational

---

## Pre-Existing Work

If you already started on the ticket (plan, tests, code, docs), Stage 1 detects it and skips ahead. The orchestrator **reads your commits, classifies touched files, and runs the test suite** to infer where you are — not just counts commits.

```mermaid
flowchart TD
    Q{Any prior work?}:::decision -- "no" --> S1[Start at Stage 1]:::normal
    Q -- "yes" --> Detect[Detect repo state: branch, uncommitted, commits ahead]:::detect
    Detect --> Inspect[Inspect commits: git show, classify files, run tests]:::detect
    Inspect --> Summary[Present inferred summary: plan? tests passing/failing? code? docs?]:::detect
    Summary --> Confirm{User confirms?}:::decision
    Confirm -- "no / correct-me" --> Summary
    Confirm -- "yes" --> Decide{What do you have?}:::decision
    Decide -- "plan only" --> J3[Jump to Stage 3 - tests]:::jump
    Decide -- "plan + tests" --> J4[Jump to Stage 4 - code]:::jump
    Decide -- "code partial" --> J4
    Decide -- "code complete" --> J5[Jump to Stage 5 - reflect]:::jump
    Decide -- "ready for review" --> J6[Jump to Stage 6]:::jump

    J3 --> Import[Mark skipped stages as imported, baseline commit, continue AC confirm]:::import
    J4 --> Import
    J5 --> Import
    J6 --> Import

    classDef decision fill:#374151,stroke:#9ca3af,stroke-width:2px,color:#f3f4f6
    classDef normal fill:#1e293b,stroke:#94a3b8,stroke-width:2px,color:#e2e8f0
    classDef detect fill:#4c1d95,stroke:#a78bfa,stroke-width:2px,color:#ede9fe
    classDef jump fill:#1e3a5f,stroke:#60a5fa,stroke-width:2px,color:#e0f2fe
    classDef import fill:#14532d,stroke:#4ade80,stroke-width:2px,color:#dcfce7
```

---

## Installation

**One-time setup (per machine).** Clone once, symlink from every Claude config you use.

```bash
# 1. Clone the repo (one place only)
mkdir -p ~/src
git clone https://github.com/icarloscornejo/doer.git ~/src/doer

# 2. Symlink from each Claude config you use
ln -s ~/src/doer ~/.claude/skills/doer
ln -s ~/src/doer ~/.claude-work/skills/doer    # optional
ln -s ~/src/doer ~/.claude-me/skills/doer         # optional
# ...repeat for every .claude-* you have
```

**Updates:**

```bash
cd ~/src/doer && git pull
```

One pull refreshes every symlinked Claude at once.

---

## Usage

| Command | Description |
|---------|-------------|
| `/doer <TICKET-ID>` | Start a new ticket. Orchestrator asks for title, description, type, ACs, context, branch name. |
| `/doer continue <TICKET-ID>` | Resume a paused ticket from its last stage. |
| `/doer status <TICKET-ID>` | Show current stage, loop state, blockers. |
| `/doer list` | List all tickets under `./.doer/tickets/`. |
| `/doer pause` | Persist current state and stop. |

Once a ticket is active, natural language works too: "keep going", "pause here", "the plan looks good, continue". The orchestrator picks up the active ticket from `./.doer/tickets/*/metadata.json`.

**Note:** every stage must run — there is no manual stage-skip command. The only way to skip stages is via the Stage 1 pre-existing-work detection.

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
        ├── metadata.json   # Workflow state
        ├── ticket.md       # Intake (title, description, type, context)
        ├── ac.md           # Confirmed acceptance criteria
        ├── plan.md
        ├── reflect.md
        ├── wrapup.md
        └── review/
            ├── plan-review-1.md
            ├── tests-review-1.md
            └── code-review-1.md
```

Commit `./.doer/` to the target repo if you want the knowledge base (lessons, assumptions) to travel with the code and be shared. Otherwise, add it to `.gitignore` for personal use.

---

## Design Notes

- **One branch, one ticket.** All work lands on a single feature branch. Every stage commits its artifact.
- **Orchestrator is the sole voice.** Subagents write artifacts and return JSON summaries. Only the orchestrator prompts the user.
- **Narration first.** Every action is announced before, during, and after. You can pause at any moment.
- **No hidden state.** Everything lives in `./.doer/` on disk. Context compression cannot lose progress.
- **No push, no PR, no deploy.** `/doer` stops after wrapup. You push and open the PR manually.

---

## License

MIT
