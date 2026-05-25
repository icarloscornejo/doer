# Jira Transition Sub-protocol

Loaded by `/wk:publish` when `--transition <state>` is passed AND `metadata.intake.tracker.kind == "jira"`. The PR/MR has already been created at this point; failures here MUST NOT roll back the PR/MR.

If `--transition` is passed but `metadata.intake.tracker.kind` is NOT `"jira"`, abort the transition with a clear message. Do NOT roll back the PR/MR already created:

```
PR/MR created successfully: <URL>
WARN: Jira transition requested but intake.tracker.kind is not "jira" (got: "<actual kind>").
Skipping transition. The PR/MR is live.
```

## Resolve the transition ID

Required environment variables:
- `WK_JIRA_EMAIL`: Jira account email.
- `WK_JIRA_TOKEN`: Jira API token (not password).
- `WK_JIRA_BASE_URL`: Jira base URL (e.g. `https://myorg.atlassian.net`).

If any variable is unset, abort the transition step only (PR/MR is already created):

```
PR/MR created successfully: <URL>
ABORT (Jira transition only): WK_JIRA_EMAIL, WK_JIRA_TOKEN, and WK_JIRA_BASE_URL must be set.
Set them and re-run /wk:publish <TICKET-ID> --transition "<state>" --reuse to retry.
```

Fetch available transitions:

```bash
JIRA_ID=$(echo "<metadata.ticket_id>" | sed 's/^WK-//')  # use the raw ticket id for Jira
curl -s \
  -u "${WK_JIRA_EMAIL}:${WK_JIRA_TOKEN}" \
  "${WK_JIRA_BASE_URL}/rest/api/3/issue/<jira-id>/transitions" \
  | jq '.transitions[] | {id: .id, name: .name}'
```

Find the transition whose `name` matches the requested state (case-insensitive):

```bash
TRANSITION_ID=$(curl -s \
  -u "${WK_JIRA_EMAIL}:${WK_JIRA_TOKEN}" \
  "${WK_JIRA_BASE_URL}/rest/api/3/issue/<jira-id>/transitions" \
  | jq -r --arg state "<requested state lowercased>" \
    '.transitions[] | select((.name | ascii_downcase) == $state) | .id')
```

If no matching transition is found, fail the transition step only:

```
PR/MR created successfully: <URL>
WARN: no Jira transition named "<state>" found on ticket <jira-id>.
Available transitions: <comma-separated list of .name values>.
Skipping. Re-run /wk:publish --reuse --transition "<correct name>" to retry.
```

## POST the transition

```bash
HTTP_STATUS=$(curl -s -o /tmp/jira-transition-response.json -w "%{http_code}" \
  -X POST \
  -u "${WK_JIRA_EMAIL}:${WK_JIRA_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"transition\": {\"id\": \"${TRANSITION_ID}\"}}" \
  "${WK_JIRA_BASE_URL}/rest/api/3/issue/<jira-id>/transitions")
```

A `204` response indicates success. Any other status code is a failure.

## On success

Persist into `metadata.publish.jira_transition`:

```json
"jira_transition": {
  "to_state": "<requested state as passed>",
  "transition_id": "<id>",
  "transitioned_at": "<ISO8601>"
}
```

Narrate:

```
Jira ticket <jira-id> transitioned to "<state>".
```

## On failure

Persist into `metadata.publish.jira_transition`:

```json
"jira_transition": {
  "error": "HTTP <status>: <first 200 chars of response body>"
}
```

Narrate:

```
PR/MR created successfully: <URL>
ERROR (Jira transition): HTTP <status>. See metadata.publish.jira_transition.error.
Re-run /wk:publish <TICKET-ID> --reuse --transition "<state>" after resolving auth.
```

Exit with a non-zero code so the dev knows the Jira step failed and the PR/MR was not rolled back.
