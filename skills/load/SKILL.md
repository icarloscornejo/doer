---
name: load
description: >-
  Import a ticket from Jira, Linear, or GitHub Issues into the local doer
  intake. After import, run /wk:doer <TICKET-ID> to start the pipeline.
  Auto-detects the tracker by ID shape; override with --tracker.
version: 6.0.0
user-invocable: true
allowed-tools: [Read, Write, Bash, AskUserQuestion]
---

# Load. Tracker Import

Imports a single ticket from Jira, Linear, or GitHub Issues into the local
`.doer/` intake. The result is a fully populated `metadata.json` that
`/wk:doer <TICKET-ID>` can pick up immediately. No manual copy-paste from the
tracker required.

---

## Invocation

```
/wk:load <ID>
/wk:load <ID> --tracker <jira|linear|gh>
/wk:load <ID> --branch <branch-name>
/wk:load <ID> --dry-run
/wk:load <ID> --force
```

| Flag | Meaning |
|---|---|
| `--tracker` | Force a specific tracker (overrides auto-detection). |
| `--branch` | Override the proposed branch name (default: `<ticket_id>-<slugified-title>`). |
| `--dry-run` | Print the metadata that would be written without persisting any file. |
| `--force` | Overwrite the `intake` block of an existing `metadata.json`. Does not touch `plan`, `changelog`, `code_review`, or other stage fields. |

---

## Tracker Auto-Detection

The skill resolves the tracker from the ID shape and environment:

| ID pattern | Condition | Tracker |
|---|---|---|
| `<owner>/<repo>#<N>` or `#<N>` | Any (inside a git clone with a single GitHub remote) | GitHub Issues (`gh`) |
| `^[A-Z][A-Z0-9_]+-\d+$` | `WK_JIRA_BASE_URL` set AND `WK_LINEAR_API_KEY` not set | Jira |
| `^[A-Z][A-Z0-9_]+-\d+$` | `WK_LINEAR_API_KEY` set AND `WK_JIRA_BASE_URL` not set | Linear |
| `^[A-Z][A-Z0-9_]+-\d+$` | Both env vars set | Ambiguous. Require `--tracker <jira|linear>`. |
| Anything else | | Error: unrecognizable ID format. |

When `--tracker` is provided, the detection step is skipped entirely.

---

## Backends

### Dependencies

| Tool | Required by |
|---|---|
| `gh` (GitHub CLI) | GitHub Issues backend |
| `curl` | Jira and Linear backends |
| `jq` | All backends (JSON parsing and metadata writes) |

### GitHub Issues

Uses `gh` exclusively; no raw HTTP calls.

```bash
# Resolve owner/repo from the remote when using the short #N form.
REMOTE_URL=$(git remote get-url origin 2>/dev/null)
# Parse owner and repo from the remote URL.

gh issue view <ref> --json title,body,labels,state
```

The canonical ticket ID is `<owner>/<repo>#<N>` (or just `#<N>` when running inside a single-remote clone). The `source_url` is `https://github.com/<owner>/<repo>/issues/<N>`.

### Jira

Environment variables required:

| Variable | Purpose |
|---|---|
| `WK_JIRA_BASE_URL` | Base URL of your Jira instance, e.g. `https://yourorg.atlassian.net` |
| `WK_JIRA_EMAIL` | Jira account email for Basic auth |
| `WK_JIRA_TOKEN` | Jira API token (generate at id.atlassian.com) |

```bash
curl -s \
  -u "${WK_JIRA_EMAIL}:${WK_JIRA_TOKEN}" \
  "${WK_JIRA_BASE_URL}/rest/api/3/issue/<ID>" \
  | jq '{
      title:  .fields.summary,
      body:   (.fields.description // ""),
      status: .fields.status.name,
      labels: [.fields.labels[]?]
    }'
```

The `source_url` is `${WK_JIRA_BASE_URL}/browse/<ID>`.

### Linear

Environment variable required:

| Variable | Purpose |
|---|---|
| `WK_LINEAR_API_KEY` | Linear personal or workspace API key |

```bash
curl -s \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: ${WK_LINEAR_API_KEY}" \
  --data '{
    "query": "{ issue(id: \"<ID>\") { title description state { name } labels { nodes { name } } } }"
  }' \
  https://api.linear.app/graphql \
  | jq '.data.issue | {
      title:  .title,
      body:   (.description // ""),
      status: .state.name,
      labels: [.labels.nodes[].name]
    }'
```

The `source_url` is `https://linear.app/issue/<ID>`.

---

## Output Contract

The skill writes `.doer/tickets/<TICKET-ID>/metadata.json` (path per
`${CLAUDE_PLUGIN_ROOT}/lib/memory-paths.md`). The directory is created if
missing.

All writes use a temp-file-then-mv pattern for atomicity:

```bash
jq '<transform>' .doer/tickets/<ID>/metadata.json > .doer/tickets/<ID>/metadata.json.tmp \
  && mv .doer/tickets/<ID>/metadata.json.tmp .doer/tickets/<ID>/metadata.json
```

### Fields written

| Field | Value |
|---|---|
| `ticket_id` | Canonical ID string (e.g. `ABC-123`, never a URL). |
| `title` | Issue title from the tracker. |
| `branch` | `<ticket_id>-<slugified-title>`, or the value of `--branch`. |
| `status` | `"in_progress"` (doer pipeline status, not the tracker status). |
| `current_stage` | `1` |
| `skill_version` | `"6.0.0"` |
| `created_at` | ISO8601 timestamp of the import. |
| `intake.description` | Full body text of the tracker issue. |
| `intake.raw_acs` | Verbatim AC section if detected; otherwise the literal string `"derive"`. |
| `intake.context` | `"labels: <l1>, <l2>; tracker_status: <s>"`, or `"none"` when neither labels nor status is present. |
| `intake.prior_work` | `{exists: false, plan: null, tests: null, code: null, docs: null}` (load never infers prior work). |
| `intake.tracker` | Provenance object (see below). |

### `intake.tracker` shape

```json
{
  "kind":        "jira | linear | gh",
  "source_id":   "<as typed by the user>",
  "source_url":  "<canonical URL to the issue>",
  "imported_at": "<ISO8601>"
}
```

### Fields NOT written by load

`testing_strategy`, `ac`, `plan`, `stages`, `changelog`, `code_review`,
`assumptions_validation`, `lessons_captured`, `summary`, `performance`,
`blocking_conditions`, `commits`, `workspace_guard`, and all `*_command`
fields. Those are populated by `/wk:doer`.

When creating a new `metadata.json` the skill writes only the fields above plus
a minimal `stages` skeleton so that `/wk:doer` can detect the ticket on first
invocation:

```json
"stages": {
  "1": {"name": "ac-confirm",     "status": "pending"},
  "2": {"name": "plan",           "status": "pending"},
  "3": {"name": "tests",          "status": "pending"},
  "4": {"name": "code",           "status": "pending"},
  "5": {"name": "code-review",    "status": "pending"},
  "6": {"name": "quality-gate",   "status": "pending"},
  "7": {"name": "runtime-verify", "status": "pending"},
  "8": {"name": "docs-sync",      "status": "pending"},
  "9": {"name": "wrapup",         "status": "pending"}
}
```

---

## Idempotency and --force

If `.doer/tickets/<TICKET-ID>/metadata.json` already exists and
`intake.description` is non-empty, the skill ABORTS:

```
Ticket already imported. Use --force to overwrite.
```

With `--force`, the skill updates ONLY the following fields, leaving
everything else untouched:

- `ticket_id`, `title`, `branch` (only if `--branch` was given explicitly)
- `skill_version`
- `intake.description`, `intake.raw_acs`, `intake.context`, `intake.tracker`

It never touches `plan`, `changelog`, `code_review`, `stages`, or any other
field that the doer pipeline may have written.

---

## Step-by-Step Procedure

The orchestrator follows these numbered steps when `/wk:load` is invoked.

**1. Parse flags.**
Extract `--tracker`, `--branch`, `--dry-run`, `--force` from the command
line. Everything else is the ticket ID.

**2. Resolve tracker.**
If `--tracker` was given, use that. Otherwise apply the auto-detection rules
(ID shape + env var presence). If ambiguous, error immediately with the
resolution instructions:
```
Cannot auto-detect tracker: both WK_JIRA_BASE_URL and WK_LINEAR_API_KEY are
set and the ID matches both. Re-run with --tracker <jira|linear>.
```

**3. Verify dependencies.**
Check that the required CLI tools are available:
```bash
command -v jq  >/dev/null 2>&1 || { echo "jq is required but not found."; exit 1; }
# gh check (GitHub only):
command -v gh  >/dev/null 2>&1 || { echo "gh is required but not found. Install: https://cli.github.com"; exit 1; }
# curl check (Jira / Linear only):
command -v curl >/dev/null 2>&1 || { echo "curl is required but not found."; exit 1; }
```

**4. Check for existing metadata (pre-flight idempotency guard).**
```bash
META=".doer/tickets/${TICKET_ID}/metadata.json"
if [ -f "$META" ]; then
  EXISTING_DESC=$(jq -r '.intake.description // ""' "$META")
  if [ -n "$EXISTING_DESC" ] && [ "$FORCE" != "true" ]; then
    echo "Ticket already imported. Use --force to overwrite."
    exit 1
  fi
fi
```

**5. Fetch from tracker.**

GitHub:
```bash
gh issue view "<ref>" --json title,body,labels,state
```

Jira:
```bash
curl -s -u "${WK_JIRA_EMAIL}:${WK_JIRA_TOKEN}" \
  "${WK_JIRA_BASE_URL}/rest/api/3/issue/${TICKET_ID}"
```

Linear:
```bash
curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: ${WK_LINEAR_API_KEY}" \
  --data "{\"query\": \"{ issue(id: \\\"${TICKET_ID}\\\") { title description state { name } labels { nodes { name } } } }\"}" \
  https://api.linear.app/graphql
```

Check the HTTP status or `jq` output for errors before proceeding (see Error
Handling section).

**6. Extract fields.**
Parse `title`, `body`/`description`, `state`/`status.name`, and `labels` from
the JSON response using `jq`.

**7. Extract ACs from the body.**
Write the body to a temp file, then run:
```bash
TMPBODY=$(mktemp)
printf '%s' "$BODY" > "$TMPBODY"
RAW_ACS=$(skills/load/lib/extract-acs.sh "$TMPBODY")
rm -f "$TMPBODY"
[ -z "$RAW_ACS" ] && RAW_ACS="derive"
```

The helper script (`skills/load/lib/extract-acs.sh`) detects sections headed
with `## Acceptance Criteria`, `**AC:**`, or plain `AC:` labels and extracts
the verbatim text below them. If no such section is found it prints nothing,
and the skill falls back to `"derive"`.

**8. Build the context string.**
```bash
LABEL_STR=$(echo "$LABELS" | jq -r 'join(", ")')
if [ -n "$LABEL_STR" ] && [ -n "$TRACKER_STATUS" ]; then
  CONTEXT="labels: ${LABEL_STR}; tracker_status: ${TRACKER_STATUS}"
elif [ -n "$LABEL_STR" ]; then
  CONTEXT="labels: ${LABEL_STR}"
elif [ -n "$TRACKER_STATUS" ]; then
  CONTEXT="tracker_status: ${TRACKER_STATUS}"
else
  CONTEXT="none"
fi
```

**9. Derive branch name.**
```bash
if [ -z "$BRANCH_OVERRIDE" ]; then
  SLUG=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\{2,\}/-/g' | sed 's/^-//;s/-$//' | cut -c1-50)
  BRANCH="${TICKET_ID}-${SLUG}"
else
  BRANCH="$BRANCH_OVERRIDE"
fi
```

**10. Compose the metadata object.**
Build the JSON in memory with `jq -n` using `--arg` / `--argjson` for all
values. Do not use shell string interpolation inside JSON values.

**11. Dry-run gate.**
If `--dry-run`, print the composed JSON to stdout and exit 0. No files are
written.

**12. Write to disk (atomic).**
```bash
mkdir -p ".doer/tickets/${TICKET_ID}"
META=".doer/tickets/${TICKET_ID}/metadata.json"
TMPOUT="${META}.tmp"

if [ -f "$META" ] && [ "$FORCE" = "true" ]; then
  # Merge: update only intake + identifying fields; preserve everything else.
  jq --argjson patch "$NEW_INTAKE_JSON" '
    .ticket_id      = $patch.ticket_id      |
    .title          = $patch.title          |
    .skill_version  = $patch.skill_version  |
    .intake         = ($patch.intake + {prior_work: .intake.prior_work})
  ' "$META" > "$TMPOUT"
else
  # Create: write the full initial metadata object.
  printf '%s' "$METADATA_JSON" > "$TMPOUT"
fi

mv "$TMPOUT" "$META"
```

**13. Narrate.**
```
Imported <kind> <ID> as <ticket_id>. Title: "<title>".
Wrote .doer/tickets/<ticket_id>/metadata.json (<intake fields populated>).
Next: /wk:doer <ticket_id>
```

---

## Error Handling

| Situation | Narration |
|---|---|
| Unrecognizable ID format | `Cannot determine tracker for ID "<ID>". Expected: <owner>/<repo>#N (GitHub), or PROJECT-123 (Jira/Linear). Check the ID and retry.` |
| Both Jira + Linear env vars set, no `--tracker` | `Cannot auto-detect tracker: both WK_JIRA_BASE_URL and WK_LINEAR_API_KEY are set. Re-run with --tracker <jira|linear>.` |
| Missing env var (Jira) | `Jira import requires WK_JIRA_BASE_URL, WK_JIRA_EMAIL, and WK_JIRA_TOKEN to be set in the environment.` |
| Missing env var (Linear) | `Linear import requires WK_LINEAR_API_KEY to be set in the environment.` |
| `gh` not installed | `gh (GitHub CLI) is required for GitHub Issues import. Install: https://cli.github.com` |
| Tracker returns 404 | `Tracker returned 404 for <ID>. The issue may not exist or may be in a different project.` |
| Tracker returns 403 | `Tracker returned 403 for <ID>. Check that your credentials have read access to this issue.` |
| Ticket already imported (no `--force`) | `Ticket already imported. Use --force to overwrite.` |
| `jq` not installed | `jq is required but was not found. Install jq to continue.` |

---

## Examples

Reference examples (Jira, Linear, GitHub Issues) showing the resulting `intake` slice for each tracker live in `${CLAUDE_PLUGIN_ROOT}/skills/load/examples.md`. Read on demand only when verifying the output shape.
