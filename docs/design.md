# Design and state

Where the kit keeps things and the rules it follows. Back to the
[README](../README.md).

## State layout

```
${CLAUDE_PLUGIN_ROOT}/               # plugin install
├── skills/{doer,bugfix,replay,protologs}/  # work skills
├── skills/{setup,locale,jira}/      # config skills
├── lib/                             # shared protocols + helpers (see AGENTS.md)
└── lessons/{slug}.md                # GLOBAL lessons pool, cross-project

${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json    # locale only, global

./.doer/config.json                  # per-repo Jira config (base URL + token env var name)
./.doer/entry-points.json            # per-repo bugfix entry-point map (topic -> files)
./.doer/tickets/{ID}/                # per-repo control state (metadata.json | bugfix.json)
~/Downloads/{KEY}/                   # bugfix heavy artifacts
```

**`.doer/` never reaches the team.** The Workspace Guard adds it to
`.git/info/exclude` at every entry point and verifies the exclusion works;
wrapup can scrub any stragglers from branch history. The team sees only real
code commits.

Full schemas live in [`lib/state.md`](../lib/state.md).

## Design notes

- **One branch, one ticket.** All commits use `--no-verify`; you run the real
  checks before the PR. The kit never pushes.
- **Orchestrator is the sole voice.** Sub-agents write artifacts and return
  JSON; only the orchestrator talks to you.
- **No hidden state.** Everything lives on disk; closing the session is
  pausing.
- **No internal vocabulary in team artifacts.** `AC-N` labels, `PROTOLOG`,
  `PROTOLOG_RESPONSE`, `REPLAY` and `DOER` tags, and stage names never reach
  committed code, commit messages, or PR text; every generated artifact is
  grep-validated before it is shown.
- **Lessons are global.** Each wrapup can save a lesson; every future ticket in
  any repo reads the applicable ones before planning.

## Upgrading from 6.x

7.0.0 removed the migration machinery along with the `load`, `advise`,
`review`, and `publish` satellites, cost tracking, and the heartbeat, lock and
inbox protocols. Completed 6.x tickets need nothing. An in-flight 6.x ticket
cannot be auto-resumed under 7.0.0: finish it by hand or recreate it with
`/wk:doer`. The 6.x changelog is archived at
[`CHANGELOG-archive-6x.md`](CHANGELOG-archive-6x.md).
