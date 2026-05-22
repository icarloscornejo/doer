---
name: advise
description: >-
  Run configurable advisor personas (security, performance, mobile, a11y, api)
  against specs, ACs, diffs, or files. Personas are JSON files under
  lib/advisor-personas/. Use /wk:advise --list to see available personas.
version: 6.0.0
user-invocable: true
allowed-tools: [Read, Write, Bash, Agent]
---

# Advise. Configurable Persona Review

The `advise` skill runs one or more advisor personas against a target (a file, a git diff, a ticket plan, or ad-hoc text) and returns structured findings grouped by severity. Personas are defined as JSON files so new review domains can be added without touching any skill code. The skill works standalone and is also designed for opt-in integration with Stage 5 of the `/wk:doer` pipeline.

---

## Persona Model

Each persona lives in `${CLAUDE_PLUGIN_ROOT}/lib/advisor-personas/<id>.json`. The skill reads that directory at runtime, so adding a new persona requires only dropping a valid JSON file there.

### JSON shape

```json
{
  "id": "security",
  "display_name": "Security Advisor",
  "summary": "One-line description.",
  "system_prompt": "Multi-paragraph prompt that primes the reviewer agent.",
  "focus_checklist": ["Item 1.", "Item 2.", "..."],
  "out_of_scope": ["Item this persona ignores.", "..."],
  "severity_scale": {
    "blocker": "Confirmed exploitable issue or compliance violation.",
    "high":    "Likely exploitable under realistic conditions.",
    "medium":  "Defense-in-depth weakness; not directly exploitable.",
    "low":     "Hardening suggestion."
  },
  "output_schema": {
    "findings": [
      {
        "severity": "blocker | high | medium | low",
        "title": "Short title.",
        "where": "<file>:<line> or <ac-id> or 'spec'",
        "explain": "What the issue is and why it matters.",
        "fix": "Concrete remediation."
      }
    ]
  }
}
```

The `system_prompt` is injected verbatim as the reviewer agent's system context. The `focus_checklist` and `out_of_scope` lists are appended to the agent prompt so the reviewer has its domain scope explicit at review time.

### Personas shipped by default

| id            | Display name          | Focus area                                       |
|---------------|-----------------------|--------------------------------------------------|
| security      | Security Advisor      | Vulnerabilities, auth, secrets, injection        |
| performance   | Performance Advisor   | N+1 queries, memory, I/O, scalability            |
| mobile        | Mobile Advisor        | Lifecycle, battery, offline, platform APIs       |
| accessibility | Accessibility Advisor | WCAG 2.1 AA, keyboard nav, screen readers        |
| api           | API Advisor           | REST/GraphQL contracts, versioning, error shapes |

---

## Invocation

### List available personas

```
/wk:advise --list
```

Reads every `.json` file in `${CLAUDE_PLUGIN_ROOT}/lib/advisor-personas/`, prints `id`, `display_name`, and `summary` for each. No review is run.

### Explain a persona (introspection mode)

```
/wk:advise --persona security --explain
```

Prints the persona's `system_prompt`, `focus_checklist`, `out_of_scope`, and `severity_scale`. No review is run.

### Run a single persona against a target

```
/wk:advise --persona security --target diff:main..HEAD
/wk:advise --persona performance --target file:src/api/users.ts
/wk:advise --persona api --target ticket:WK-12
/wk:advise --persona accessibility --target text:"AC-1: GIVEN the user opens the modal WHEN they tab through fields THEN focus order follows document order."
```

### Run multiple personas in parallel

```
/wk:advise --personas security,performance --target diff:main..HEAD
```

One Agent call per persona, dispatched in parallel. Findings are aggregated and printed under a header per persona.

---

## Targets

### `--target file:<path>`

Reviews a single file. The skill reads the file at `<path>` (repo-relative or absolute) and passes its full contents to the reviewer agent.

```bash
# Context gathering
cat <path>    # or: Read tool on the absolute path
```

### `--target diff:<base>..<head>`

Reviews a git diff. Default: `--target diff:main..HEAD`.

```bash
git diff <base>..<head>
```

The full diff text is passed inline to the reviewer agent. The agent may also read up to 5 source files mentioned in the diff for additional context (within its read budget).

### `--target ticket:<TICKET-ID>`

Reviews a ticket's plan and acceptance criteria before implementation. Reads `metadata.ac.in_scope`, `metadata.ac.out_of_scope`, and `metadata.plan` from `.doer/tickets/<TICKET-ID>/metadata.json`.

```bash
# Context gathering
cat .doer/tickets/<TICKET-ID>/metadata.json   # or: Read tool on the absolute path
```

Extract `metadata.ac` and `metadata.plan` and pass them inline to the reviewer agent.

When `--target ticket:<TICKET-ID>` is used, the skill ALSO writes findings to disk so future stages can ingest them:

```
.doer/tickets/<TICKET-ID>/advisor-findings/<persona-id>.json
```

The file matches the persona's `output_schema` exactly:

```json
{
  "persona_id": "security",
  "target": "ticket:WK-12",
  "ran_at": "<ISO8601>",
  "findings": [
    {
      "severity": "blocker | high | medium | low",
      "title": "...",
      "where": "<ac-id> or 'spec'",
      "explain": "...",
      "fix": "..."
    }
  ]
}
```

The `.doer/tickets/` tree is gitignored (see the doer skill's Core Principle 8). The findings file never reaches the team's git history.

### `--target text:<inline-text>`

Reviews ad-hoc text passed directly in the command: a spec excerpt, a set of ACs, a PR description, or any other prose. The text is passed verbatim to the reviewer agent.

---

## Persona Dispatch

### Single persona

Invoke one `Agent` call with:

1. The persona's `system_prompt` as the agent's system context.
2. The target content (file text, diff, metadata fields, or inline text) injected inline.
3. The `focus_checklist` and `out_of_scope` lists appended to the prompt.
4. The instruction to output a JSON object matching `output_schema`.

Agent prompt skeleton:

```
<system_prompt from persona JSON>

Focus checklist (check each item against the target):
<focus_checklist items, one per line>

Out of scope for this review:
<out_of_scope items, one per line>

== Target: <target description> ==
<target content inline>

Output a JSON object with this exact shape:
{
  "findings": [
    {
      "severity": "blocker | high | medium | low",
      "title": "...",
      "where": "<file>:<line> or <ac-id> or 'spec'",
      "explain": "...",
      "fix": "..."
    }
  ]
}

If there are no findings, output: {"findings": []}

Read budget: 5 source files beyond what is already inlined above.
Em-dashes are forbidden. Use commas, periods, or parentheses instead.
All output must be in English.
```

### Multiple personas (parallel dispatch)

When `--personas a,b,c` is supplied, dispatch one Agent call per persona in a single tool block (parallel). This follows the same parallel-subagent pattern documented in `skills/doer/SKILL.md` (Stage 4, "Parallel subagents"). Each agent is independent; they do not share state or communicate.

After all agents return, aggregate findings:

```
## Security Advisor (3 findings)

### BLOCKER: Hardcoded API key in config.ts
...

### HIGH: SQL query built by string concatenation in users.ts:42
...

## Performance Advisor (1 finding)

### MEDIUM: N+1 query pattern inside user list loop
...
```

If a persona agent returns `{"findings": []}`, print:

```
## <Display name> (0 findings)

No issues found.
```

---

## Output Contract

### Standalone runs (human-readable stdout)

Findings are grouped by persona, then sorted within each persona by severity (blocker first, low last). Each finding is printed as:

```
### <SEVERITY>: <title>
Where: <where>
<explain>
Fix: <fix>
```

The full output is the orchestrator-facing artifact. The skill does not write to a file for standalone runs (only for `--target ticket:` as described above).

### Pipeline use (ticket target, machine-readable file)

When called with `--target ticket:<TICKET-ID>`, the skill writes:

```
.doer/tickets/<TICKET-ID>/advisor-findings/<persona-id>.json
```

as described in the Targets section. Future pipeline stages can read this file to incorporate advisor findings into their prompts or gate decisions.

---

## Pipeline Integration (Stage 5, Opt-in, Forward-Looking)

This section documents the planned integration with `/wk:doer`. The integration is NOT implemented in this version; it is documented here so the doer skill can wire it when the time comes.

When `${CLAUDE_PLUGIN_ROOT}/lib/helpers/preferences.sh get-flag stage5_advisor_personas` returns a non-empty list (e.g. `security,performance`, persisted in `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/wk/preferences.json`):

```json
{
  "stage5_advisor_personas": ["security", "performance"]
}
```

Stage 5 of the doer pipeline calls `/wk:advise` after its own deterministic pre-checks and before invoking its reviewer LLM. The invocation uses `--target ticket:<TICKET-ID>` so findings are written to `.doer/tickets/<TICKET-ID>/advisor-findings/`. The Stage 5 reviewer LLM prompt includes the findings files inline so it can reference them in its review.

Blockers from advisor personas are treated as Stage 5 BLOCKERs and enter the standard doer/reviewer convergence loop. Suggestions and low-severity findings are appended to `metadata.code_review[].suggestions` for the dev to read at wrapup.

The orchestrator (doer) owns this integration; the advise skill does not modify Stage 5 behavior on its own.

---

## Adding a New Persona

1. Create `${CLAUDE_PLUGIN_ROOT}/lib/advisor-personas/<id>.json` matching the shape described in the Persona Model section above.
2. Set `"id"` to the same value as the filename (without `.json`).
3. Write a `system_prompt` of 150 to 300 words. Em-dashes (U+2014 and U+2013) are prohibited throughout the file.
4. Add at least 6 items to `focus_checklist`.
5. Run `jq empty lib/advisor-personas/<id>.json` to confirm the file is valid JSON.

No code changes, no registration step. The skill reads the directory at invocation time.

---

## Examples

### Example 1. Security review of the current branch diff

```
/wk:advise --persona security --target diff:main..HEAD
```

The skill runs:
1. `git diff main..HEAD` to collect the diff.
2. Invokes one Agent with the security persona and the diff inline.
3. Prints findings grouped by severity.

Sample output:

```
## Security Advisor (2 findings)

### BLOCKER: API key hardcoded in src/config.ts
Where: src/config.ts:14
The string literal "sk-live-..." is assigned directly to API_KEY. Any developer
with read access to the repository can extract and use this credential.
Fix: Remove the literal. Read the key from an environment variable or a secret
manager. Rotate the exposed key immediately.

### MEDIUM: Error response leaks internal file path
Where: src/api/users.ts:87
The catch block appends the Node.js stack trace to the JSON error response body.
Internal paths and dependency versions are visible to any caller.
Fix: Log the full error server-side and return only a stable error code and
human-readable message to the client.
```

### Example 2. Ticket plan review with two personas in parallel

```
/wk:advise --personas security,api --target ticket:WK-42
```

The skill:
1. Reads `.doer/tickets/WK-42/metadata.json`, extracts `metadata.ac` and `metadata.plan`.
2. Dispatches two Agent calls in parallel (one per persona).
3. Writes `.doer/tickets/WK-42/advisor-findings/security.json` and `api.json`.
4. Aggregates and prints findings under separate headers.

### Example 3. Ad-hoc AC review before writing code

```
/wk:advise --persona accessibility --target text:"AC-1: GIVEN a logged-in user WHEN they open the order history modal THEN they can tab through all order rows and activate the reorder button using the keyboard."
```

The skill passes the AC text to the accessibility advisor. Useful for catching a11y gaps at the spec stage, before any implementation exists.

Sample output:

```
## Accessibility Advisor (1 finding)

### MEDIUM: Modal focus management not specified in AC
Where: spec
The AC describes keyboard navigation inside the modal but does not specify
that focus moves into the modal when it opens or returns to the trigger when
it closes. Without this, screen reader users may lose their place in the page.
Fix: Add to the AC: "WHEN the modal opens THEN focus is placed on the first
interactive element inside it; WHEN the modal closes THEN focus returns to
the element that triggered it."
```
