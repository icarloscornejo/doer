#!/usr/bin/env bash
# wk plugin: generic Jira REST helper (API v2), supports both auth modes:
#   - Bearer token: Jira Server / Data Center (e.g. jira.example.com)
#   - HTTP Basic (email:api_token): Atlassian Cloud (*.atlassian.net), which
#     rejects Bearer with 403 "Failed to parse Connect Session Auth Token"
# Shared by /wk:bugfix (full triage) and /wk:doer intake (optional auto-fetch).
#
# Config is per-project (each repo can point at a different Jira) and lives at
# ./.doer/config.json, relative to the current working directory:
#   jira_base_url    e.g. https://jira.example.com or https://acme.atlassian.net
#   jira_token_env   name of the env var holding the token (default "JIRA_PAT")
#   jira_auth_email  optional; when set, switches auth mode to HTTP Basic
#                    (email:token) instead of Bearer. Required for Cloud.
#
# The token itself is NEVER read from or written to disk. Only its env var
# NAME is persisted, so people who already export their PAT under a different
# name (JIRA_PROD_PAT, ACME_JIRA_PAT, ...) just point jira_token_env at it.
#
# Every command prints JSON to stdout; on config/network errors it prints
# {"error": "<message>"} and exits non-zero so callers can branch cleanly.

set -eu

CONFIG_DIR=".doer"
CONFIG_FILE="$CONFIG_DIR/config.json"
DEFAULT_TOKEN_ENV="JIRA_PAT"

usage() {
  cat >&2 <<EOF
Usage: jira.sh <command> [args...]

Commands:
  fetch <KEY>                       Print issue as lean JSON: {key, title, status, priority,
                                    issuetype, description, comments: [{author, created, body}],
                                    attachments: [{id, filename, url, size}], source_url}
  download <URL> <local-path>       Download one attachment to a local path.
  comment <KEY> <file>              Post the file's content as a comment on the issue.
                                    Asks nothing; callers gate on explicit user approval.
  config                            Print resolved config: {base_url, token_env, token_present,
                                    auth_mode, auth_email}.
  set-url <URL>                     Persist this project's Jira base URL to ./.doer/config.json.
  set-token-env <NAME>              Persist the env var name holding the token
                                    (default if unset: $DEFAULT_TOKEN_ENV).
  set-auth-email <EMAIL>            Switch to HTTP Basic auth (email:token) instead of Bearer.
                                    Required for Atlassian Cloud (*.atlassian.net); the token
                                    becomes an API token from id.atlassian.com/manage-profile.

Configure once per project (run from the repo root):
  # Jira Server / Data Center:
  jira.sh set-url https://jira.example.com
  jira.sh set-token-env JIRA_PAT      # only needed if your token lives under another name
  export JIRA_PAT="<your PAT>"        # never persisted, session-only

  # Atlassian Cloud (*.atlassian.net):
  jira.sh set-url https://acme.atlassian.net
  jira.sh set-auth-email you@acme.com
  export JIRA_PAT="<your API token>"  # from id.atlassian.com/manage-profile/security/api-tokens

Prefer the guided flow: /doer setup
EOF
  exit 2
}

fail() {
  jq -n --arg m "$1" '{error: $m}'
  exit 1
}

[ $# -ge 1 ] || usage
command -v jq >/dev/null 2>&1 || { echo '{"error": "jira.sh requires jq"}'; exit 1; }
command -v curl >/dev/null 2>&1 || { echo '{"error": "jira.sh requires curl"}'; exit 1; }

read_cfg() { # read_cfg <key> -> value or empty
  [ -f "$CONFIG_FILE" ] || { printf ''; return 0; }
  jq -r --arg k "$1" '.[$k] // empty' "$CONFIG_FILE" 2>/dev/null || true
}

write_cfg() { # write_cfg <key> <value>
  mkdir -p "$CONFIG_DIR"
  [ -f "$CONFIG_FILE" ] || printf '{}' > "$CONFIG_FILE"
  NEW="$(jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$CONFIG_FILE")"
  printf '%s\n' "$NEW" > "$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

resolve_config() {
  BASE_URL="$(read_cfg jira_base_url)"
  [ -n "$BASE_URL" ] || fail "jira_base_url not configured for this project. Run: /doer setup (or: jira.sh set-url <url>)"
  TOKEN_ENV="$(read_cfg jira_token_env)"
  [ -n "$TOKEN_ENV" ] || TOKEN_ENV="$DEFAULT_TOKEN_ENV"
  TOKEN="$(printenv "$TOKEN_ENV" 2>/dev/null || true)"
  if [ -z "$TOKEN" ]; then
    case "$BASE_URL" in
      *.atlassian.net*) fail "Env var \$$TOKEN_ENV is empty. Export your Atlassian API token in this session first (never stored on disk). Atlassian Cloud requires an API token from id.atlassian.com/manage-profile/security/api-tokens, used together with set-auth-email." ;;
      *) fail "Env var \$$TOKEN_ENV is empty. Export your Jira PAT in this session first (never stored on disk)." ;;
    esac
  fi
  BASE_URL="${BASE_URL%/}"

  AUTH_EMAIL="$(read_cfg jira_auth_email)"
  if [ -n "$AUTH_EMAIL" ]; then
    AUTH_MODE="basic"
    AUTH_ARGS=(-u "$AUTH_EMAIL:$TOKEN")
  else
    AUTH_MODE="bearer"
    AUTH_ARGS=(-H "Authorization: Bearer $TOKEN")
    case "$BASE_URL" in
      *.atlassian.net*) fail "Atlassian Cloud requires Basic auth, not Bearer (Bearer gets rejected with 403 'Failed to parse Connect Session Auth Token'). Run: jira.sh set-auth-email <your-email> (token = API token from id.atlassian.com/manage-profile/security/api-tokens)." ;;
    esac
  fi
}

CMD="$1"
shift

case "$CMD" in
  config)
    BASE_URL="$(read_cfg jira_base_url)"
    TOKEN_ENV="$(read_cfg jira_token_env)"
    [ -n "$TOKEN_ENV" ] || TOKEN_ENV="$DEFAULT_TOKEN_ENV"
    TOKEN_PRESENT="false"
    [ -n "$(printenv "$TOKEN_ENV" 2>/dev/null || true)" ] && TOKEN_PRESENT="true"
    AUTH_EMAIL="$(read_cfg jira_auth_email)"
    AUTH_MODE="bearer"
    [ -n "$AUTH_EMAIL" ] && AUTH_MODE="basic"
    jq -n --arg b "$BASE_URL" --arg e "$TOKEN_ENV" --argjson t "$TOKEN_PRESENT" \
      --arg am "$AUTH_MODE" --arg ae "$AUTH_EMAIL" \
      '{base_url: ($b | select(. != "") // null), token_env: $e, token_present: $t,
        auth_mode: $am, auth_email: ($ae | select(. != "") // null)}'
    ;;

  set-url)
    [ $# -ge 1 ] || { echo '{"error": "set-url requires <URL>"}'; exit 2; }
    write_cfg jira_base_url "$1"
    jq -n --arg u "$1" '{jira_base_url: $u}'
    ;;

  set-token-env)
    [ $# -ge 1 ] || { echo '{"error": "set-token-env requires <NAME>"}'; exit 2; }
    write_cfg jira_token_env "$1"
    jq -n --arg e "$1" '{jira_token_env: $e}'
    ;;

  set-auth-email)
    [ $# -ge 1 ] || { echo '{"error": "set-auth-email requires <EMAIL>"}'; exit 2; }
    write_cfg jira_auth_email "$1"
    jq -n --arg e "$1" '{jira_auth_email: $e}'
    ;;

  fetch)
    [ $# -ge 1 ] || { echo '{"error": "fetch requires <KEY>"}'; exit 2; }
    KEY="$1"
    resolve_config
    RAW="$(curl -sf --max-time 20 "${AUTH_ARGS[@]}" \
      "$BASE_URL/rest/api/2/issue/$KEY?fields=summary,description,comment,attachment,issuetype,status,priority" \
      2>/dev/null)" || fail "Fetch failed for $KEY (network, auth, or unknown issue)."
    printf '%s' "$RAW" | jq --arg base "$BASE_URL" --arg key "$KEY" '{
      key: $key,
      title: .fields.summary,
      status: (.fields.status.name // null),
      priority: (.fields.priority.name // null),
      issuetype: (.fields.issuetype.name // null),
      description: (.fields.description // ""),
      comments: [(.fields.comment.comments // [])[] |
        {author: (.author.displayName // .author.name // "unknown"), created: .created, body: .body}],
      attachments: [(.fields.attachment // [])[] |
        {id: .id, filename: .filename, url: .content, size: (.size // null)}],
      source_url: ($base + "/browse/" + $key)
    }'
    ;;

  download)
    [ $# -ge 2 ] || { echo '{"error": "download requires <URL> <local-path>"}'; exit 2; }
    URL="$1"
    DEST="$2"
    resolve_config
    mkdir -p "$(dirname "$DEST")"
    curl -sf --max-time 120 "${AUTH_ARGS[@]}" -o "$DEST" "$URL" \
      || fail "Download failed: $URL"
    jq -n --arg p "$DEST" '{downloaded: $p}'
    ;;

  comment)
    [ $# -ge 2 ] || { echo '{"error": "comment requires <KEY> <file>"}'; exit 2; }
    KEY="$1"
    FILE="$2"
    [ -f "$FILE" ] || fail "Comment body file not found: $FILE"
    resolve_config
    BODY="$(jq -Rs '{body: .}' < "$FILE")"
    curl -sf --max-time 20 -X POST \
      "${AUTH_ARGS[@]}" -H "Content-Type: application/json" \
      --data "$BODY" "$BASE_URL/rest/api/2/issue/$KEY/comment" > /dev/null \
      || fail "Posting comment to $KEY failed."
    jq -n --arg k "$KEY" '{commented: $k}'
    ;;

  *)
    usage
    ;;
esac
