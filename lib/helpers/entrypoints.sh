#!/usr/bin/env bash
# wk plugin: per-repo entry-points store (topic -> investigation entry files).
# Spec: ${CLAUDE_PLUGIN_ROOT}/lib/state.md ("./.doer/entry-points.json").
#
# Storage: ./.doer/entry-points.json, relative to cwd (repo root). Per-repo,
# NOT the cross-project lessons pool: entries are file paths in this exact
# codebase, so they never apply to another repo.
#
# Single point of write access, and every write is ONE jq transform applied
# atomically (temp file + mv, a single rename() syscall), never an in-place
# rewrite. Same rationale as metadata.sh: rapid successive in-place rewrites
# of a file inside a hidden directory is a known corporate EDR ransomware
# heuristic and can get the file locked at the OS level.

set -eu

FILE=".doer/entry-points.json"
EMPTY_STORE='{"version":1,"entries":[]}'

usage() {
  cat >&2 <<EOF
Usage: entrypoints.sh <command> [args...]

Commands:
  path                                       Print the resolved file path.
  list                                       Print all entries (empty array if no store).
  match <term>...                            Print entries whose topic/keywords match any
                                              term (case-insensitive substring, either
                                              direction), sorted by hit count descending.
  save --topic <t> --paths <p1,p2>[,...]     Upsert by topic.
       [--keywords <k1,k2>[,...]]              --mode merge (default): union paths/keywords,
       [--note <n>] [--from <KEY>]              append --from to captured_from.
       [--mode merge|replace]                   --mode replace: paths become exactly the
                                                 given set; keywords/captured_from still merge.
  forget --topic <t>                         Delete the entry for that topic.

Notes:
  - Requires jq.
  - All writes are atomic (write to .tmp.\$\$ then mv); a failed jq transform
    or a failed mv never touches the live file.
  - Distinct from the cross-project lessons pool (lessons/{slug}.md): this
    store is per-repo and paths are only ever valid in this checkout.
EOF
  exit 2
}

[ $# -ge 1 ] || usage
command -v jq >/dev/null 2>&1 || { echo "entrypoints.sh requires jq" >&2; exit 2; }

CMD="$1"; shift

ensure_store() {
  [ -f "$FILE" ] || {
    mkdir -p "$(dirname "$FILE")"
    TMP="${FILE}.tmp.$$"
    printf '%s' "$EMPTY_STORE" | jq . > "$TMP"
    mv "$TMP" "$FILE"
  }
}

read_store() {
  if [ -f "$FILE" ]; then cat "$FILE"; else printf '%s' "$EMPTY_STORE"; fi
}

atomic_write() { # atomic_write <jq-filter> [jq-args...]
  FILTER="$1"; shift
  ensure_store
  TMP="${FILE}.tmp.$$"
  if ! jq "$FILTER" "$@" "$FILE" > "$TMP"; then
    rm -f "$TMP"
    echo "entrypoints.sh: jq transform failed, $FILE left untouched" >&2
    exit 1
  fi
  if ! mv "$TMP" "$FILE" 2>/dev/null; then
    rm -f "$TMP"
    {
      echo "entrypoints.sh: could not write $FILE (mv failed)."
      echo "This looks like an OS/EDR-level lock, not a normal permission issue --"
      echo "hidden directories plus rapid successive rewrites of the same file are"
      echo "a known corporate EDR ransomware heuristic. DO NOT retry this write and"
      echo "do NOT attempt mv/xattr/chflags/rm on the target from here. Wait, then"
      echo "retry 'entrypoints.sh save' later."
    } >&2
    exit 2
  fi
}

split_csv() { # split_csv <csv> -> JSON array on stdout ([] for empty input)
  if [ -z "$1" ]; then printf '[]'; return 0; fi
  printf '%s' "$1" | jq -R 'split(",") | map(select(length > 0))'
}

case "$CMD" in
  path)
    printf '%s\n' "$FILE"
    ;;

  list)
    read_store | jq '.entries // []'
    ;;

  match)
    [ $# -ge 1 ] || { echo "entrypoints.sh: match requires at least one <term>" >&2; exit 2; }
    TERMS_JSON="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
    read_store | jq --argjson terms "$TERMS_JSON" '
      ($terms | map(ascii_downcase)) as $t |
      [ (.entries // [])[] | . as $e |
        (($e.keywords // []) + [$e.topic] | map(ascii_downcase)) as $k |
        ( [ $k[] as $kw | select( [ $t[] as $term |
              select(($term | contains($kw)) or ($kw | contains($term))) ] | length > 0 )
          ] | unique | length ) as $hits |
        select($hits > 0) | $e + {"_hits": $hits}
      ] | sort_by(-._hits) | map(del(._hits))
    '
    ;;

  save)
    TOPIC=""; PATHS_CSV=""; KEYWORDS_CSV=""; NOTE=""; FROM=""; MODE="merge"
    while [ $# -gt 0 ]; do
      case "$1" in
        --topic) TOPIC="$2"; shift 2 ;;
        --paths) PATHS_CSV="$2"; shift 2 ;;
        --keywords) KEYWORDS_CSV="$2"; shift 2 ;;
        --note) NOTE="$2"; shift 2 ;;
        --from) FROM="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        *) echo "entrypoints.sh: unknown save argument: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$TOPIC" ] || { echo "entrypoints.sh: save requires --topic" >&2; exit 2; }
    [ -n "$PATHS_CSV" ] || { echo "entrypoints.sh: save requires --paths" >&2; exit 2; }
    case "$MODE" in merge|replace) ;; *) echo "entrypoints.sh: --mode must be merge or replace" >&2; exit 2 ;; esac

    PATHS_JSON="$(split_csv "$PATHS_CSV")"
    KEYWORDS_JSON="$(split_csv "$KEYWORDS_CSV")"
    NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    atomic_write '
      (.entries // []) as $entries
      | ($entries | map(.topic) | index($topic)) as $idx
      | if $idx == null then
          .entries = $entries + [{
            topic: $topic,
            keywords: $keywords,
            paths: $paths,
            note: (if $note == "" then null else $note end),
            captured_from: (if $from == "" then [] else [$from] end),
            updated_at: $now
          }]
        else
          .entries[$idx] |= (
            .paths = (if $mode == "replace" then $paths else (.paths + $paths | unique) end)
            | .keywords = ((.keywords // []) + $keywords | unique)
            | .captured_from = (if $from == "" then (.captured_from // []) else ((.captured_from // []) + [$from] | unique) end)
            | .note = (if $note == "" then .note else $note end)
            | .updated_at = $now
          )
        end
    ' --arg topic "$TOPIC" --argjson paths "$PATHS_JSON" --argjson keywords "$KEYWORDS_JSON" \
      --arg note "$NOTE" --arg from "$FROM" --arg mode "$MODE" --arg now "$NOW"

    read_store | jq --arg topic "$TOPIC" '.entries[] | select(.topic == $topic)'
    ;;

  forget)
    TOPIC=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --topic) TOPIC="$2"; shift 2 ;;
        *) echo "entrypoints.sh: unknown forget argument: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$TOPIC" ] || { echo "entrypoints.sh: forget requires --topic" >&2; exit 2; }
    atomic_write '.entries = ((.entries // []) | map(select(.topic != $topic)))' --arg topic "$TOPIC"
    ;;

  *)
    usage
    ;;
esac
