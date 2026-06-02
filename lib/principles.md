# Core Principles (cross-cutting)

This file owns the operating rules that apply across every doer stage. Narration (Principle 1) and em-dash prohibition (Principle 9) live in `lib/narration.md`. Read both files before any stage work.

1. **One branch, one ticket.** All work happens on a single feature branch. Stages that produce real code commit it; stages that only produce `.doer/` artifacts do NOT commit (see principle 7).
2. **Delta-aware reviewers.** After iteration 1, reviewers receive prior findings + the last `metadata.changelog` entries from the doer (inlined in their prompt). They verify fixes and scan for new issues, rather than re-analyzing from scratch.
3. **Bounded loops.** Stages 4 (Code) and 5 (Code Review) loop with a max of **3 iterations**. Stages 2 (Plan) and 3 (Tests) are single-pass with one optional retry on deterministic-check failure. If still not converged after the cap or retry, the user decides.
4. **Lessons accumulate.** Every ticket captures what went well and what did not. Future tickets read those lessons before planning.
5. **No hidden state.** Everything the orchestrator knows lives in `./.doer/` on disk. Context compression never loses progress.
6. **All commits use `git commit --no-verify`.** Hard rule.
   - The orchestrator runs in developer mode; pre-commit hooks (linters, formatters, fast tests) interrupt flow mid-stage without value (agents may produce intermediate states that fail a hook but are correct for the stage).
   - Every commit and amend in the SKILL shows `--no-verify` explicitly (portable, no aliases needed).
   - **Dev runs real checks manually before PR** (`pre-commit run`, lint, full tests, etc.), then squashes/reorders and pushes. Orchestrator does not push.
7. **`.doer/` NEVER reaches the team's git history.** Non-negotiable.
   - Intake adds `.doer/` to `.git/info/exclude` (per-clone, never committed). The team sees nothing.
   - Commits MUST NOT include paths under `.doer/`. Use `git add <code-paths>` or `git add -A` (respects exclude). NEVER `git add .doer/...` (that bypasses the ignore).
   - Stages whose only output is `.doer/` (1 AC, 2 Plan, 9 Wrapup) SKIP the commit entirely. Stages with real code (3 Tests, 4 Code, 5 Review, 7 Runtime, 8 Docs) commit code only.
   - Stage 7 (Runtime Verify) temp commit + revert still works because it touches real source files, not `.doer/`.
8. (Reserved.)
9. Em-dash prohibition. See `lib/narration.md`, Core Principle 9.
10. **Internal orchestration vocabulary NEVER reaches team-facing artifacts.** Non-negotiable. The orchestrator carries internal labels that mean nothing (or worse, leak process detail) to a teammate reading the repo or a PR. They MUST NOT appear in any artifact the team will see.
    - **Forbidden tokens in team-facing artifacts:** `AC-N` identifiers (AC-1, AC-2, ...); the runtime log tag `DOER ` / `DOER -` (Stage 7 temp logs); the internal per-stage commit prefix word `doer` (e.g. `doer(...)`); stage and loop names ("Stage 4", "iter 2", "the reviewer LLM"); and ticket numbers dragged in from an unrelated context (e.g. `PDE-1234`, `JIRA-99`) unless load-bearing for a future reader of that exact line.
    - **Team-facing artifacts (where this rule applies):** committed source code and its comments; the recommended squash commit message (Stage 9 step 7); the PR description (Stage 9 step 8).
    - **Rule:** describe behavior in plain business language. The orchestrator MUST translate `AC-N` to its behavior (from `metadata.ac.in_scope`) and strip any `DOER` / process wording BEFORE inlining anything into a writer sub-agent prompt. Every generated team-facing artifact is then validated with a grep (mirror of Stage 5 Check D) before it is presented; a match is regenerated or scrubbed, never shown.
    - **Where enforced:** the code-writer and test-writer prompts forbid `AC-N` in source/test (Stages 3, 4); Stage 5 Check D greps the committed diff; Stage 9 steps 7 and 8 carry the same prohibition plus the post-generation validation grep.
    - **Out of scope (intentional):** the internal per-stage commit prefix `doer(<TICKET-ID>):` on Stage 3/4/5/7/8 commits. Those commits are squashed away by the dev using the recommended message (step 7) and `.doer/` history cleanup, so the prefix never survives into the team's history.
