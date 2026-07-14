#!/usr/bin/env bash
# wk plugin: per-ticket state file helper (metadata.json / bugfix.json).
# Spec: ${CLAUDE_PLUGIN_ROOT}/lib/state.md ("Writing metadata.json").
#
# Storage: ./.doer/tickets/<TICKET-ID>/<FILE>, relative to cwd (repo root).
# Default FILE is metadata.json (doer); pass --file bugfix.json for bugfix.
#
# Single point of write access, and every write is ONE jq transform applied
# atomically (temp file + mv, a single rename() syscall), never an in-place
# rewrite. This matters: rapid successive in-place rewrites of the same file
# inside a hidden directory is a known corporate EDR ransomware heuristic,
# and can get the file locked at the OS level. Callers MUST batch every
# field of one logical stage transition into a single jq filter and call
# `write` exactly once for it; a post-success correction is a NEW write,
# never a retry of the same transition.

set -eu

usage() {
  cat >&2 <<EOF
Usage: metadata.sh <command> <TICKET-ID> [args...] [--file <name>]

Commands:
  path <TICKET-ID> [--file <name>]         Print the resolved file path.
  read <TICKET-ID> [--file <name>]         Print the file's current content.
  init <TICKET-ID> [--file <name>]         Create the file from JSON on stdin.
                                            Refuses if the file already exists.
  write <TICKET-ID> <jq-filter> [jq-args...] [--file <name>]
                                            Apply ONE jq transform, swap atomically.

Notes:
  - Requires jq.
  - Default file: metadata.json. Override with --file bugfix.json.
  - All writes are atomic (write to .tmp.\$\$ then mv); a failed jq transform
    or a failed mv never touches the live file.
  - Batch every field of one logical transition into a single jq filter and
    call 'write' once. Never call it twice in a row for the same transition.
EOF
  exit 2
}

[ $# -ge 1 ] || usage
command -v jq >/dev/null 2>&1 || { echo "metadata.sh requires jq" >&2; exit 2; }

CMD="$1"; shift
[ $# -ge 1 ] || usage
TICKET_ID="$1"; shift

FILE_NAME="metadata.json"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || { echo "metadata.sh: --file requires a value" >&2; exit 2; }
      FILE_NAME="$2"
      shift 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

TICKET_DIR="./.doer/tickets/${TICKET_ID}"
TARGET="${TICKET_DIR}/${FILE_NAME}"

case "$CMD" in
  path)
    printf '%s\n' "$TARGET"
    ;;

  read)
    [ -f "$TARGET" ] || { echo "metadata.sh: $TARGET does not exist" >&2; exit 1; }
    cat "$TARGET"
    ;;

  init)
    [ ! -f "$TARGET" ] || { echo "metadata.sh: $TARGET already exists; use 'write' to modify it" >&2; exit 1; }
    CONTENT="$(cat)"
    printf '%s' "$CONTENT" | jq . > /dev/null || { echo "metadata.sh: stdin is not valid JSON, $TARGET not created" >&2; exit 1; }
    mkdir -p "$TICKET_DIR"
    TMP="${TARGET}.tmp.$$"
    printf '%s' "$CONTENT" | jq . > "$TMP"
    mv "$TMP" "$TARGET"
    ;;

  write)
    [ $# -ge 1 ] || { echo "metadata.sh: write requires <jq-filter>" >&2; exit 2; }
    [ -f "$TARGET" ] || { echo "metadata.sh: $TARGET does not exist; use 'init' first" >&2; exit 1; }
    FILTER="$1"; shift
    TMP="${TARGET}.tmp.$$"
    if ! jq "$FILTER" "$@" "$TARGET" > "$TMP"; then
      rm -f "$TMP"
      echo "metadata.sh: jq transform failed, $TARGET left untouched" >&2
      exit 1
    fi
    if ! mv "$TMP" "$TARGET" 2>/dev/null; then
      rm -f "$TMP"
      {
        echo "metadata.sh: could not write $TARGET (mv failed)."
        echo "This looks like an OS/EDR-level lock, not a normal permission issue --"
        echo "hidden directories plus rapid successive rewrites of the same file are"
        echo "a known corporate EDR ransomware heuristic (observed: macOS"
        echo "com.apple.provenance tag + EPERM on all further access to this exact"
        echo "path, including read/rename/re-create; other files in the same"
        echo "directory are unaffected)."
        echo "DO NOT retry this write, and do NOT attempt mv/xattr/chflags/rm on the"
        echo "target from here -- those are exactly the operations that fail to help"
        echo "or can make it look more suspicious. Check Console.app (filter:"
        echo "endpointsecurity) around this timestamp, or wait -- these locks are"
        echo "usually time-boxed -- then retry 'metadata.sh write' later."
      } >&2
      exit 2
    fi
    ;;

  *)
    usage
    ;;
esac
