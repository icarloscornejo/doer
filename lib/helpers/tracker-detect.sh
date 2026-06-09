#!/usr/bin/env bash
# wk plugin: tracker connectivity detection.
# Detects available tracker access via environment variables.
# MCP tool detection happens at the orchestrator level (Claude), not here.
#
# Usage: tracker-detect.sh resolve <TICKET-ID>
#
# Output: JSON to stdout with detection results. Token values are NEVER printed.

set -eu

usage() {
  cat >&2 <<EOF
Usage: tracker-detect.sh <command> [args...]

Commands:
  resolve <TICKET-ID>    Detect tracker type from ID shape and check env var connectivity.

Output (JSON):
  {
    "tracker": "jira|linear|gh|ambiguous|unknown",
    "method":  "wk_env|common_env|gh_cli|none",
    "vars":    { "base_url_var": "...", "email_var": "...", "token_set": true|false }
  }

Notes:
  - Requires jq.
  - Token values are never printed; only "token_set": true/false.
  - MCP detection is NOT handled here (orchestrator-level concern).
EOF
  exit 2
}

[ $# -ge 1 ] || usage

if ! command -v jq >/dev/null 2>&1; then
  echo "tracker-detect.sh requires jq" >&2
  exit 2
fi

detect_id_shape() {
  local id="$1"
  if printf '%s' "$id" | grep -qE '^[A-Z][A-Z0-9_]+-[0-9]+$'; then
    printf 'project_key\n'
  elif printf '%s' "$id" | grep -qE '^#?[0-9]+$'; then
    printf 'gh_short\n'
  elif printf '%s' "$id" | grep -qE '^[A-Za-z0-9_./-]+#[0-9]+$'; then
    printf 'gh_full\n'
  else
    printf 'unknown\n'
  fi
}

check_jira_env() {
  # Priority 1: WK_JIRA_* (doer convention)
  if [ -n "${WK_JIRA_BASE_URL:-}" ] && [ -n "${WK_JIRA_EMAIL:-}" ] && [ -n "${WK_JIRA_TOKEN:-}" ]; then
    jq -n \
      --arg base_var "WK_JIRA_BASE_URL" \
      --arg email_var "WK_JIRA_EMAIL" \
      '{method: "wk_env", vars: {base_url_var: $base_var, email_var: $email_var, token_set: true}}'
    return 0
  fi

  # Priority 2: common env var patterns
  local base_url_var="" email_var="" token_set="false"

  if [ -n "${JIRA_BASE_URL:-}" ]; then
    base_url_var="JIRA_BASE_URL"
  elif [ -n "${JIRA_URL:-}" ]; then
    base_url_var="JIRA_URL"
  fi

  if [ -n "${JIRA_EMAIL:-}" ]; then
    email_var="JIRA_EMAIL"
  elif [ -n "${JIRA_USER:-}" ]; then
    email_var="JIRA_USER"
  elif [ -n "${JIRA_USERNAME:-}" ]; then
    email_var="JIRA_USERNAME"
  fi

  if [ -n "${JIRA_TOKEN:-}" ] || [ -n "${JIRA_API_TOKEN:-}" ]; then
    token_set="true"
  fi

  if [ -n "$base_url_var" ] && [ -n "$email_var" ] && [ "$token_set" = "true" ]; then
    jq -n \
      --arg base_var "$base_url_var" \
      --arg email_var "$email_var" \
      --argjson token_set true \
      '{method: "common_env", vars: {base_url_var: $base_var, email_var: $email_var, token_set: $token_set}}'
    return 0
  fi

  return 1
}

check_linear_env() {
  if [ -n "${WK_LINEAR_API_KEY:-}" ]; then
    jq -n '{method: "wk_env", vars: {api_key_var: "WK_LINEAR_API_KEY", token_set: true}}'
    return 0
  fi
  if [ -n "${LINEAR_API_KEY:-}" ]; then
    jq -n '{method: "common_env", vars: {api_key_var: "LINEAR_API_KEY", token_set: true}}'
    return 0
  fi
  return 1
}

check_gh_cli() {
  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      jq -n '{method: "gh_cli", vars: {tool: "gh", authenticated: true}}'
      return 0
    fi
  fi
  return 1
}

resolve() {
  local ticket_id="$1"
  local shape
  shape="$(detect_id_shape "$ticket_id")"

  case "$shape" in
    project_key)
      # Could be Jira or Linear. Check both.
      local jira_result="" linear_result=""
      jira_result="$(check_jira_env 2>/dev/null)" || true
      linear_result="$(check_linear_env 2>/dev/null)" || true

      if [ -n "$jira_result" ] && [ -n "$linear_result" ]; then
        # Both available: ambiguous
        jq -n \
          --arg id "$ticket_id" \
          --argjson jira "$jira_result" \
          --argjson linear "$linear_result" \
          '{tracker: "ambiguous", method: "multiple", vars: {jira: $jira, linear: $linear}}'
      elif [ -n "$jira_result" ]; then
        local method vars
        method="$(printf '%s' "$jira_result" | jq -r '.method')"
        vars="$(printf '%s' "$jira_result" | jq '.vars')"
        jq -n --arg method "$method" --argjson vars "$vars" \
          '{tracker: "jira", method: $method, vars: $vars}'
      elif [ -n "$linear_result" ]; then
        local method vars
        method="$(printf '%s' "$linear_result" | jq -r '.method')"
        vars="$(printf '%s' "$linear_result" | jq '.vars')"
        jq -n --arg method "$method" --argjson vars "$vars" \
          '{tracker: "linear", method: $method, vars: $vars}'
      else
        jq -n '{tracker: "jira", method: "none", vars: {}}'
      fi
      ;;

    gh_short|gh_full)
      local gh_result=""
      gh_result="$(check_gh_cli 2>/dev/null)" || true
      if [ -n "$gh_result" ]; then
        local vars
        vars="$(printf '%s' "$gh_result" | jq '.vars')"
        jq -n --argjson vars "$vars" \
          '{tracker: "gh", method: "gh_cli", vars: $vars}'
      else
        jq -n '{tracker: "gh", method: "none", vars: {}}'
      fi
      ;;

    *)
      jq -n '{tracker: "unknown", method: "none", vars: {}}'
      ;;
  esac
}

CMD="$1"
shift

case "$CMD" in
  resolve)
    [ $# -ge 1 ] || { echo "resolve requires <TICKET-ID>" >&2; exit 2; }
    resolve "$1"
    ;;
  *)
    usage
    ;;
esac
