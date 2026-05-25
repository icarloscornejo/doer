# Load Worked Examples

Reference-only. Read on demand if you need to see the resulting `metadata.json` shape for each tracker.

---

## Example 1: Jira

**Invocation:**
```
/wk:load ABC-123
```

**Environment:** `WK_JIRA_BASE_URL=https://acme.atlassian.net`,
`WK_JIRA_EMAIL=dev@acme.com`, `WK_JIRA_TOKEN=<token>`.

**Resulting `intake` slice in metadata.json:**
```json
{
  "ticket_id": "ABC-123",
  "title": "Add rate limiting to the public API",
  "branch": "ABC-123-add-rate-limiting-to-the-public-api",
  "status": "in_progress",
  "current_stage": 1,
  "skill_version": "6.0.0",
  "created_at": "2026-05-20T18:00:00Z",
  "intake": {
    "description": "We need to limit unauthenticated callers to 100 req/min...",
    "raw_acs": "- AC-1: Given an unauthenticated caller exceeds 100 req/min, the API returns 429.",
    "context": "labels: backend, security; tracker_status: In Progress",
    "prior_work": {"exists": false, "plan": null, "tests": null, "code": null, "docs": null},
    "tracker": {
      "kind": "jira",
      "source_id": "ABC-123",
      "source_url": "https://acme.atlassian.net/browse/ABC-123",
      "imported_at": "2026-05-20T18:00:00Z"
    }
  }
}
```

---

## Example 2: Linear

**Invocation:**
```
/wk:load ENG-88 --tracker linear
```

**Environment:** `WK_LINEAR_API_KEY=lin_api_<key>`.

**Resulting `intake` slice:**
```json
{
  "ticket_id": "ENG-88",
  "title": "Dark mode toggle in settings screen",
  "branch": "ENG-88-dark-mode-toggle-in-settings-screen",
  "status": "in_progress",
  "current_stage": 1,
  "skill_version": "6.0.0",
  "created_at": "2026-05-20T18:05:00Z",
  "intake": {
    "description": "Users should be able to switch between light and dark mode from Settings...",
    "raw_acs": "derive",
    "context": "labels: mobile, ui; tracker_status: Todo",
    "prior_work": {"exists": false, "plan": null, "tests": null, "code": null, "docs": null},
    "tracker": {
      "kind": "linear",
      "source_id": "ENG-88",
      "source_url": "https://linear.app/issue/ENG-88",
      "imported_at": "2026-05-20T18:05:00Z"
    }
  }
}
```

---

## Example 3: GitHub Issues

**Invocation:**
```
/wk:load acme/api#42 --branch feature/fix-cors-headers
```

**Resulting `intake` slice:**
```json
{
  "ticket_id": "acme/api#42",
  "title": "CORS headers missing on /v2/auth endpoints",
  "branch": "feature/fix-cors-headers",
  "status": "in_progress",
  "current_stage": 1,
  "skill_version": "6.0.0",
  "created_at": "2026-05-20T18:10:00Z",
  "intake": {
    "description": "The /v2/auth/login and /v2/auth/refresh endpoints are missing Access-Control-Allow-Origin headers...",
    "raw_acs": "derive",
    "context": "labels: bug, api; tracker_status: open",
    "prior_work": {"exists": false, "plan": null, "tests": null, "code": null, "docs": null},
    "tracker": {
      "kind": "gh",
      "source_id": "acme/api#42",
      "source_url": "https://github.com/acme/api/issues/42",
      "imported_at": "2026-05-20T18:10:00Z"
    }
  }
}
```
