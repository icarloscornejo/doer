#!/usr/bin/env bash
# wk plugin: per-ticket lock helper.
# Spec: ${CLAUDE_PLUGIN_ROOT}/lib/lock.md

set -eu

LOCK_TTL_SECONDS="${WK_LOCK_TTL_SECONDS:-1800}"

usage() {
  cat >&2 <<EOF
Usage: lock.sh <command> <TICKET-ID>

Commands:
  acquire   acquire the lock; exit 1 if held by a fresh PID, exit 0 on success or steal
  touch     refresh last_touched_at; no-op if lock missing
  release   remove the lock file; no-op if absent
  check     print state to stdout: "held|stale|none\t<pid>\t<host>\t<last_touched_at>"

Env:
  WK_LOCK_TTL_SECONDS  staleness threshold in seconds (default: 1800)
EOF
  exit 2
}

[ $# -ge 2 ] || usage
CMD="$1"
TICKET_ID="$2"

LOCK_DIR=".doer/tickets/${TICKET_ID}"
LOCK_FILE="${LOCK_DIR}/lock.json"

now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
now_epoch() { date -u +%s; }

iso_to_epoch() {
  local iso="$1"
  if date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null; then return 0; fi
  date -d "$iso" +%s 2>/dev/null
}

write_lock() {
  mkdir -p "$LOCK_DIR"
  local ts
  ts=$(now_iso)
  cat > "$LOCK_FILE" <<JSON
{
  "ticket_id": "${TICKET_ID}",
  "pid": $$,
  "host": "$(hostname -s)",
  "acquired_at": "${ts}",
  "last_touched_at": "${ts}",
  "session_label": "claude-code"
}
JSON
}

read_field() {
  local field="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r ".${field} // empty" "$LOCK_FILE"
  else
    grep -E "\"${field}\"" "$LOCK_FILE" | head -1 | sed -E 's/.*"'"${field}"'"[[:space:]]*:[[:space:]]*"?([^",}]*)"?.*/\1/'
  fi
}

case "$CMD" in
  acquire)
    if [ ! -f "$LOCK_FILE" ]; then
      write_lock
      echo "Lock acquired for ${TICKET_ID} (PID $$)."
      exit 0
    fi
    LAST=$(read_field last_touched_at)
    PID=$(read_field pid)
    HOST=$(read_field host)
    LAST_EPOCH=$(iso_to_epoch "$LAST" 2>/dev/null || echo 0)
    NOW_EPOCH=$(now_epoch)
    AGE=$(( NOW_EPOCH - LAST_EPOCH ))
    if [ "$AGE" -ge "$LOCK_TTL_SECONDS" ]; then
      write_lock
      echo "Stale lock from PID ${PID} reclaimed (last touched ${AGE}s ago, threshold ${LOCK_TTL_SECONDS}s)."
      exit 0
    fi
    echo "Ticket ${TICKET_ID} is locked by PID ${PID} on ${HOST} (last touched ${LAST}, ${AGE}s ago). Close that session or wait for the lock to expire (TTL ${LOCK_TTL_SECONDS}s)." >&2
    exit 1
    ;;
  touch)
    [ -f "$LOCK_FILE" ] || exit 0
    TS=$(now_iso)
    if command -v jq >/dev/null 2>&1; then
      tmp="${LOCK_FILE}.tmp"
      jq --arg ts "$TS" '.last_touched_at = $ts' "$LOCK_FILE" > "$tmp" && mv "$tmp" "$LOCK_FILE"
    else
      sed -i.bak -E 's/("last_touched_at"[[:space:]]*:[[:space:]]*")[^"]*(")/\1'"$TS"'\2/' "$LOCK_FILE"
      rm -f "${LOCK_FILE}.bak"
    fi
    ;;
  release)
    rm -f "$LOCK_FILE"
    ;;
  check)
    if [ ! -f "$LOCK_FILE" ]; then
      printf 'none\t\t\t\n'
      exit 0
    fi
    LAST=$(read_field last_touched_at)
    PID=$(read_field pid)
    HOST=$(read_field host)
    LAST_EPOCH=$(iso_to_epoch "$LAST" 2>/dev/null || echo 0)
    NOW_EPOCH=$(now_epoch)
    AGE=$(( NOW_EPOCH - LAST_EPOCH ))
    if [ "$AGE" -ge "$LOCK_TTL_SECONDS" ]; then
      printf 'stale\t%s\t%s\t%s\n' "$PID" "$HOST" "$LAST"
    else
      printf 'held\t%s\t%s\t%s\n' "$PID" "$HOST" "$LAST"
    fi
    ;;
  *)
    usage
    ;;
esac
