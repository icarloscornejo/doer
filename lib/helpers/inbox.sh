#!/usr/bin/env bash
# wk plugin: per-ticket inbox helper.
# Spec: ${CLAUDE_PLUGIN_ROOT}/lib/inbox.md

set -eu

usage() {
  cat >&2 <<EOF
Usage: inbox.sh <command> <TICKET-ID> [args...]

Commands:
  post <ID> --from <N> --to <M|*> --kind <blocker|advisory|fyi> --text "..." [--details "..."] [--id <existing-id>]
  list <ID> [--to <N>] [--kind <k>] [--unacked]
  ack  <ID> <msg-id> [--by <N>]
  clear <ID> [--acked|--all]

Notes:
  - All operations require jq.
  - metadata.json must exist at .doer/tickets/<ID>/metadata.json. Inbox is created on first post.
  - 'list --to <N>' includes messages addressed to "*" (broadcast).
EOF
  exit 2
}

[ $# -ge 2 ] || usage
CMD="$1"
TICKET_ID="$2"
shift 2

if ! command -v jq >/dev/null 2>&1; then
  echo "inbox.sh requires jq" >&2
  exit 2
fi

META_DIR=".doer/tickets/${TICKET_ID}"
META="${META_DIR}/metadata.json"

if [ ! -f "$META" ]; then
  echo "metadata.json not found at $META" >&2
  exit 2
fi

now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

new_id() {
  if command -v openssl >/dev/null 2>&1; then
    printf 'msg-%s' "$(openssl rand -hex 4)"
  else
    printf 'msg-%08x' "$RANDOM$RANDOM"
  fi
}

write_meta() {
  local tmp="${META}.tmp"
  jq "$1" "$META" > "$tmp" && mv "$tmp" "$META"
}

case "$CMD" in
  post)
    FROM="" TO="" KIND="" TEXT="" DETAILS="" ID=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --from) FROM="$2"; shift 2 ;;
        --to) TO="$2"; shift 2 ;;
        --kind) KIND="$2"; shift 2 ;;
        --text) TEXT="$2"; shift 2 ;;
        --details) DETAILS="$2"; shift 2 ;;
        --id) ID="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
      esac
    done
    [ -n "$FROM" ] && [ -n "$TO" ] && [ -n "$KIND" ] && [ -n "$TEXT" ] || usage
    case "$KIND" in blocker|advisory|fyi) ;; *) echo "Invalid --kind: $KIND" >&2; exit 2 ;; esac

    if [ -n "$ID" ]; then
      EXISTS=$(jq --arg id "$ID" '(.inbox // []) | map(select(.id == $id)) | length' "$META")
      if [ "$EXISTS" -gt 0 ]; then
        echo "$ID"
        exit 0
      fi
    else
      ID=$(new_id)
    fi

    TS=$(now_iso)
    if [ "$TO" = "*" ]; then TO_JSON='"*"'; else TO_JSON="$TO"; fi
    TEXT_JSON=$(jq -n --arg t "$TEXT" '$t')
    if [ -z "$DETAILS" ]; then
      DETAILS_JSON='null'
    else
      DETAILS_JSON=$(jq -n --arg d "$DETAILS" '$d')
    fi
    write_meta "
      .inbox = ((.inbox // []) + [{
        id: \"${ID}\",
        from_stage: ${FROM},
        to_stage: ${TO_JSON},
        kind: \"${KIND}\",
        text: ${TEXT_JSON},
        details: ${DETAILS_JSON},
        created_at: \"${TS}\",
        acked_at: null,
        acked_by_stage: null
      }])
    "
    echo "$ID"
    ;;

  list)
    TO="" KIND="" UNACKED=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --to) TO="$2"; shift 2 ;;
        --kind) KIND="$2"; shift 2 ;;
        --unacked) UNACKED=1; shift ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
      esac
    done

    FILTER='.inbox // []'
    if [ -n "$TO" ]; then
      FILTER="$FILTER | map(select(.to_stage == \"*\" or .to_stage == ${TO}))"
    fi
    if [ -n "$KIND" ]; then
      FILTER="$FILTER | map(select(.kind == \"${KIND}\"))"
    fi
    if [ "$UNACKED" -eq 1 ]; then
      FILTER="$FILTER | map(select(.acked_at == null))"
    fi
    FILTER="$FILTER | sort_by(.created_at)"
    jq "$FILTER" "$META"
    ;;

  ack)
    [ $# -ge 1 ] || usage
    MSG_ID="$1"; shift
    BY=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --by) BY="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
      esac
    done
    if [ -z "$BY" ] && [ "${WK_CURRENT_STAGE:-}" != "" ]; then
      BY="$WK_CURRENT_STAGE"
    fi

    EXISTS=$(jq --arg id "$MSG_ID" '(.inbox // []) | map(select(.id == $id)) | length' "$META")
    if [ "$EXISTS" -eq 0 ]; then
      echo "Message $MSG_ID not found" >&2
      exit 1
    fi

    TS=$(now_iso)
    if [ -n "$BY" ]; then BY_JSON="$BY"; else BY_JSON="null"; fi
    write_meta "
      .inbox = ((.inbox // []) | map(
        if .id == \"${MSG_ID}\" and .acked_at == null
        then .acked_at = \"${TS}\" | .acked_by_stage = ${BY_JSON}
        else . end
      ))
    "
    ;;

  clear)
    MODE="acked"
    while [ $# -gt 0 ]; do
      case "$1" in
        --acked) MODE="acked"; shift ;;
        --all) MODE="all"; shift ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
      esac
    done

    if [ "$MODE" = "all" ]; then
      write_meta '.inbox = []'
    else
      write_meta '.inbox = ((.inbox // []) | map(select(.acked_at == null)))'
    fi
    ;;

  *)
    usage
    ;;
esac
