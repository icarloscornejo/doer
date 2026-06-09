#!/usr/bin/env bash
# wk plugin: tracker HTTP fetch helper.
# Fetches a ticket from Jira, Linear, or GitHub Issues and outputs normalized JSON.
# Shared by /wk:load and /wk:doer intake auto-fetch.
#
# Usage:
#   tracker-fetch.sh jira <TICKET-ID> [--var-prefix wk|common]
#   tracker-fetch.sh linear <TICKET-ID> [--var-prefix wk|common]
#   tracker-fetch.sh gh <REF>
#
# Output (JSON to stdout, exit 0 always):
#   { "title": "...", "body": "...", "status": "...", "labels": [...],
#     "source_url": "...", "error": null }

set -eu

CURL_TIMEOUT=15

usage() {
  cat >&2 <<EOF
Usage: tracker-fetch.sh <tracker> <ID> [options]

Trackers:
  jira <TICKET-ID> [--var-prefix wk|common]
  linear <TICKET-ID> [--var-prefix wk|common]
  gh <REF>

Options:
  --var-prefix wk       Use WK_JIRA_*/WK_LINEAR_* env vars (default).
  --var-prefix common   Use JIRA_*/LINEAR_* env vars.

Output: normalized JSON to stdout. Exit 0 always; errors in .error field.

Notes:
  - Requires jq and curl (Jira/Linear) or gh (GitHub).
  - Jira uses ?expand=renderedFields for readable descriptions.
EOF
  exit 2
}

[ $# -ge 2 ] || usage

if ! command -v jq >/dev/null 2>&1; then
  echo "tracker-fetch.sh requires jq" >&2
  exit 2
fi

emit_error() {
  local msg="$1"
  jq -n --arg err "$msg" \
    '{title: null, body: null, status: null, labels: [], source_url: null, error: $err}'
}

resolve_jira_vars() {
  local prefix="${1:-wk}"
  if [ "$prefix" = "wk" ]; then
    JIRA_RESOLVED_BASE_URL="${WK_JIRA_BASE_URL:-}"
    JIRA_RESOLVED_EMAIL="${WK_JIRA_EMAIL:-}"
    JIRA_RESOLVED_TOKEN="${WK_JIRA_TOKEN:-}"
  else
    JIRA_RESOLVED_BASE_URL="${JIRA_BASE_URL:-${JIRA_URL:-}}"
    JIRA_RESOLVED_EMAIL="${JIRA_EMAIL:-${JIRA_USER:-${JIRA_USERNAME:-}}}"
    JIRA_RESOLVED_TOKEN="${JIRA_TOKEN:-${JIRA_API_TOKEN:-}}"
  fi
}

resolve_linear_vars() {
  local prefix="${1:-wk}"
  if [ "$prefix" = "wk" ]; then
    LINEAR_RESOLVED_KEY="${WK_LINEAR_API_KEY:-}"
  else
    LINEAR_RESOLVED_KEY="${LINEAR_API_KEY:-}"
  fi
}

extract_adf_text() {
  # Recursively extract text nodes from Atlassian Document Format JSON.
  local adf_json="$1"
  printf '%s' "$adf_json" | jq -r '
    [.. | select(.type? == "text") | .text // empty] | join("\n")
  ' 2>/dev/null || printf ''
}

fetch_jira() {
  local ticket_id="$1"
  local var_prefix="${2:-wk}"

  if ! command -v curl >/dev/null 2>&1; then
    emit_error "curl is required for Jira fetch but was not found."
    return 0
  fi

  resolve_jira_vars "$var_prefix"

  if [ -z "$JIRA_RESOLVED_BASE_URL" ] || [ -z "$JIRA_RESOLVED_EMAIL" ] || [ -z "$JIRA_RESOLVED_TOKEN" ]; then
    emit_error "Jira credentials incomplete. Required: base URL, email, and token."
    return 0
  fi

  # Strip trailing slash from base URL
  JIRA_RESOLVED_BASE_URL="${JIRA_RESOLVED_BASE_URL%/}"

  local url="${JIRA_RESOLVED_BASE_URL}/rest/api/3/issue/${ticket_id}?expand=renderedFields"
  local http_code body
  local tmpfile
  tmpfile="$(mktemp)"

  http_code="$(curl -s -o "$tmpfile" -w '%{http_code}' \
    --max-time "$CURL_TIMEOUT" \
    -u "${JIRA_RESOLVED_EMAIL}:${JIRA_RESOLVED_TOKEN}" \
    "$url" 2>/dev/null)" || {
    rm -f "$tmpfile"
    emit_error "Network error: curl failed to reach Jira."
    return 0
  }

  body="$(cat "$tmpfile")"
  rm -f "$tmpfile"

  case "$http_code" in
    200) ;;
    401|403)
      emit_error "HTTP ${http_code}: authentication failed. Check credentials."
      return 0
      ;;
    404)
      emit_error "HTTP 404: issue ${ticket_id} not found."
      return 0
      ;;
    *)
      emit_error "HTTP ${http_code}: unexpected response from Jira."
      return 0
      ;;
  esac

  local title status labels source_url
  title="$(printf '%s' "$body" | jq -r '.fields.summary // ""')"
  status="$(printf '%s' "$body" | jq -r '.fields.status.name // ""')"
  labels="$(printf '%s' "$body" | jq '[.fields.labels[]?] // []')"
  source_url="${JIRA_RESOLVED_BASE_URL}/browse/${ticket_id}"

  # Prefer renderedFields.description (HTML) over fields.description (ADF JSON)
  local description=""
  local rendered
  rendered="$(printf '%s' "$body" | jq -r '.renderedFields.description // ""' 2>/dev/null || printf '')"

  if [ -n "$rendered" ] && [ "$rendered" != "null" ]; then
    description="$rendered"
  else
    local raw_desc
    raw_desc="$(printf '%s' "$body" | jq -r '.fields.description // ""')"
    if [ -n "$raw_desc" ] && [ "$raw_desc" != "null" ]; then
      # ADF JSON: extract text nodes recursively
      description="$(extract_adf_text "$raw_desc")"
      if [ -z "$description" ]; then
        description="$raw_desc"
      fi
    fi
  fi

  jq -n \
    --arg title "$title" \
    --arg body "$description" \
    --arg status "$status" \
    --argjson labels "$labels" \
    --arg source_url "$source_url" \
    '{title: $title, body: $body, status: $status, labels: $labels, source_url: $source_url, error: null}'
}

fetch_linear() {
  local ticket_id="$1"
  local var_prefix="${2:-wk}"

  if ! command -v curl >/dev/null 2>&1; then
    emit_error "curl is required for Linear fetch but was not found."
    return 0
  fi

  resolve_linear_vars "$var_prefix"

  if [ -z "$LINEAR_RESOLVED_KEY" ]; then
    emit_error "Linear API key not found."
    return 0
  fi

  local query
  query="$(printf '{"query": "{ issue(id: \\"%s\\") { title description state { name } labels { nodes { name } } url } }"}' "$ticket_id")"

  local http_code tmpfile
  tmpfile="$(mktemp)"

  http_code="$(curl -s -o "$tmpfile" -w '%{http_code}' \
    --max-time "$CURL_TIMEOUT" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: ${LINEAR_RESOLVED_KEY}" \
    --data "$query" \
    https://api.linear.app/graphql 2>/dev/null)" || {
    rm -f "$tmpfile"
    emit_error "Network error: curl failed to reach Linear."
    return 0
  }

  local body
  body="$(cat "$tmpfile")"
  rm -f "$tmpfile"

  case "$http_code" in
    200) ;;
    401|403)
      emit_error "HTTP ${http_code}: authentication failed. Check Linear API key."
      return 0
      ;;
    *)
      emit_error "HTTP ${http_code}: unexpected response from Linear."
      return 0
      ;;
  esac

  # Check for GraphQL errors
  local gql_error
  gql_error="$(printf '%s' "$body" | jq -r '.errors[0].message // empty' 2>/dev/null || true)"
  if [ -n "$gql_error" ]; then
    emit_error "Linear API error: ${gql_error}"
    return 0
  fi

  local issue_data
  issue_data="$(printf '%s' "$body" | jq '.data.issue // empty' 2>/dev/null || true)"
  if [ -z "$issue_data" ] || [ "$issue_data" = "null" ]; then
    emit_error "Issue ${ticket_id} not found in Linear."
    return 0
  fi

  printf '%s' "$body" | jq '.data.issue | {
    title: (.title // ""),
    body: (.description // ""),
    status: (.state.name // ""),
    labels: [(.labels.nodes[]?.name // empty)],
    source_url: (.url // ("https://linear.app/issue/" + "'"$ticket_id"'")),
    error: null
  }'
}

fetch_gh() {
  local ref="$1"

  if ! command -v gh >/dev/null 2>&1; then
    emit_error "gh (GitHub CLI) is required but was not found. Install: https://cli.github.com"
    return 0
  fi

  local tmpfile
  tmpfile="$(mktemp)"

  if ! gh issue view "$ref" --json title,body,labels,state > "$tmpfile" 2>/dev/null; then
    rm -f "$tmpfile"
    emit_error "GitHub CLI failed to fetch issue ${ref}. Check that the issue exists and gh is authenticated."
    return 0
  fi

  local body
  body="$(cat "$tmpfile")"
  rm -f "$tmpfile"

  # Resolve source URL from remote
  local remote_url="" owner="" repo="" issue_num=""
  remote_url="$(git remote get-url origin 2>/dev/null || true)"
  if [ -n "$remote_url" ]; then
    owner="$(printf '%s' "$remote_url" | sed -E 's|.*[:/]([^/]+)/([^/.]+)(\.git)?$|\1|')"
    repo="$(printf '%s' "$remote_url" | sed -E 's|.*[:/]([^/]+)/([^/.]+)(\.git)?$|\2|')"
  fi
  issue_num="$(printf '%s' "$ref" | grep -oE '[0-9]+$' || true)"

  local source_url=""
  if [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$issue_num" ]; then
    source_url="https://github.com/${owner}/${repo}/issues/${issue_num}"
  fi

  printf '%s' "$body" | jq --arg url "$source_url" '{
    title: (.title // ""),
    body: (.body // ""),
    status: (.state // ""),
    labels: [(.labels[]?.name // empty)],
    source_url: $url,
    error: null
  }'
}

TRACKER="$1"
ID="$2"
shift 2

# Parse optional flags
VAR_PREFIX="wk"
while [ $# -gt 0 ]; do
  case "$1" in
    --var-prefix)
      [ $# -ge 2 ] || { echo "--var-prefix requires a value (wk|common)" >&2; exit 2; }
      VAR_PREFIX="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

case "$TRACKER" in
  jira)
    fetch_jira "$ID" "$VAR_PREFIX"
    ;;
  linear)
    fetch_linear "$ID" "$VAR_PREFIX"
    ;;
  gh)
    fetch_gh "$ID"
    ;;
  *)
    emit_error "Unknown tracker: ${TRACKER}. Supported: jira, linear, gh."
    ;;
esac
