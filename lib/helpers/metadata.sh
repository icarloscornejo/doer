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
Usage: metadata.sh <command> [args...]

Commands (take <TICKET-ID> first):
  path <TICKET-ID> [--file <name>]         Print the resolved file path.
  read <TICKET-ID> [--file <name>]         Print the file's current content.
  init <TICKET-ID> [--file <name>]         Create the file from JSON on stdin.
                                            Refuses if the file already exists.
  write <TICKET-ID> <jq-filter> [jq-args...] [--require <stage>:<complete|skipped>] [--file <name>]
                                            Apply ONE jq transform, swap atomically.
                                            With --require, validate the TRANSFORMED
                                            document against lib/state.md's required-
                                            fields table before swapping; on failure the
                                            live file is left untouched and nothing swaps.
  version-check <TICKET-ID> <current-version> [--file <name>]
                                            Compare metadata.skill_version's MAJOR
                                            against <current-version>'s MAJOR.
                                            Prints "compatible" (exit 0) or
                                            "incompatible <old> vs <current>" (exit 1).
  status <TICKET-ID>                       Render a /doer status summary from
                                            metadata.json or bugfix.json, whichever
                                            exists for this ticket. A complete doer
                                            Stage 4 adds a "Verify evidence:" block.

Commands (no <TICKET-ID>):
  check-required <stage> <complete|skipped> [<file>|-]
                                            Same required-fields check as 'write
                                            --require', standalone, against a proposed
                                            document (path, or stdin with '-' or
                                            omitted). Never touches metadata.json.
                                            Prints {"missing":[...]}, exit 0/1.
                                            Stage 4 complete also validates evidence,
                                            anomalies, rationale, recommendation, the
                                            override and accepted_not_exercised fields.
  list                                      One line per ticket under
                                            ./.doer/tickets/, doer and bugfix alike.

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

# missing_fields <doc-file> <stage> <complete|skipped>
# Prints {"missing":[...]} to stdout always; returns 0 if empty, 1 otherwise.
# Table source: lib/state.md, "Required fields before marking a stage complete".
missing_fields() {
  local file="$1" stage="$2" status="$3" json n
  json="$(jq -c --arg stage "$stage" --arg status "$status" '
    # jq-compat:begin missing_fields
    def nonblank: type == "string" and test("\\S");
    def objectish: if type == "object" then . else {} end;
    # Stage 4 complete checks. Runs only under the stage and status guard below,
    # so a malformed stages.4 can never break the checks of another stage.
    def stage4_problems:
      . as $doc
      | ($doc.stages["4"]) as $s4
      | if ($s4 | type) != "object" then ["stages.4"] else
        ($s4.ac_verdicts) as $verdicts_raw
        | ($s4.evidence) as $evidence_raw
        | ($s4.recommendation) as $recommendation
        | ($s4.override) as $override
        | ($s4.accepted_not_exercised) as $accepted_raw
        | ($verdicts_raw | objectish) as $verdicts
        | ($evidence_raw | objectish) as $evidence
        | ($accepted_raw | if type == "array" then map(select(type == "object")) else [] end) as $accepted
        | ($doc.ac.in_scope) as $in_scope
        | (
            (if $verdicts_raw != null and ($verdicts_raw | type) != "object" then ["stages.4.ac_verdicts"] else [] end)
          + (if $evidence_raw != null and ($evidence_raw | type) != "object" then ["stages.4.evidence"] else [] end)
          + (if $s4.anomalies != null and ($s4.anomalies | type) != "array" then ["stages.4.anomalies"] else [] end)
          + (if $accepted_raw != null and (($accepted_raw | type) != "array" or ($accepted_raw | length) != ($accepted | length)) then ["stages.4.accepted_not_exercised"] else [] end)
          + (if $override != null and ($override | type) != "object" then ["stages.4.override"] else [] end)
          + (if $recommendation == "APPROVE" or $recommendation == "RETURN_TO_BUILD" or $recommendation == "NEED_MORE_DATA" then [] else ["stages.4.recommendation"] end)
          + (if ($override == null or ($override | type) == "object") and (($recommendation != "APPROVE") or $override != null)
                and (($override | objectish | .reason | nonblank) | not)
             then ["stages.4.override.reason"] else [] end)
          + [$verdicts | to_entries[] | select((.value == "PASS" or .value == "FAIL" or .value == "NOT_EXERCISED") | not) | "stages.4.ac_verdicts.\(.key)"]
          + (if $evidence_raw != null and ($evidence_raw | type) == "object"
             then [$verdicts | to_entries[] | select(.value == "PASS" or .value == "FAIL") | .key as $id | select(($evidence[$id] | nonblank) | not) | "stages.4.evidence.\($id)"]
             else [] end)
          + [$verdicts | to_entries[] | select(.value == "NOT_EXERCISED") | .key as $id
             | select(([$accepted[] | select(.ac == $id and (.reason | nonblank))] | length) == 0)
             | "stages.4.accepted_not_exercised.\($id)"]
          + (if $in_scope == null then []
             elif ($in_scope | type) != "array" then ["ac.in_scope"]
             else
               (if ([$in_scope[] | select(type != "string")] | length) > 0 then ["ac.in_scope"] else [] end)
               + ([$in_scope[] | select(type == "string") | capture("^(?<id>AC-[0-9]+)") | .id | . as $id | select($verdicts | has($id) | not) | "stages.4.ac_verdicts.\($id)"] | unique)
             end)
          )
      end;
    . as $doc
    | (if $status == "complete" then
      {
        "1": [["stages","1","completed_at"], ["ac"]],
        "2": [["stages","2","completed_at"], ["plan"]],
        "3": [["stages","3","completed_at"], ["stages","3","iterations"], ["stages","3","loop_outcome"], ["last_green_sha"]],
        "4": [["stages","4","completed_at"], ["stages","4","ac_verdicts"], ["stages","4","evidence"], ["stages","4","anomalies"], ["stages","4","rationale"]],
        "5": [["stages","5","completed_at"], ["summary"], ["commit_message"], ["pr_description"]]
      }
    elif $status == "skipped" then
      {
        "4": [["stages","4","completed_at"], ["stages","4","skipped_reason"], ["stages","4","skipped_acknowledged_by"]]
      }
    else {} end)[$stage] // [] as $paths
    | [$paths[] as $p | select(($doc | getpath($p)) == null) | ($p | join("."))] as $missing_presence
    | (if $stage == "4" and $status == "skipped"
          and (($doc | getpath(["stages","4","skipped_acknowledged_by"])) != null)
          and (($doc | getpath(["stages","4","skipped_acknowledged_by"])) != "dev")
       then ["stages.4.skipped_acknowledged_by must equal \"dev\""] else [] end) as $missing_value
    | (if $stage == "4" and $status == "complete" then ($doc | stage4_problems) else [] end) as $missing_stage4
    | {missing: ($missing_presence + $missing_value + $missing_stage4)}
    # jq-compat:end
  ' "$file")" || { echo '{"missing":["<internal: jq failed>"]}' ; return 1; }
  printf '%s\n' "$json"
  n="$(printf '%s' "$json" | jq '.missing | length')"
  [ "$n" -eq 0 ]
}

CMD="$1"; shift

# --- Commands that do NOT take <TICKET-ID> first ---
case "$CMD" in
  check-required)
    [ $# -ge 2 ] || usage
    STAGE="$1"; STATUS="$2"; shift 2
    DOC_FILE="${1:--}"
    if [ "$DOC_FILE" = "-" ]; then
      TMPCHECK="$(mktemp)"
      trap 'rm -f "$TMPCHECK"' EXIT
      cat > "$TMPCHECK"
      missing_fields "$TMPCHECK" "$STAGE" "$STATUS"
      exit $?
    fi
    [ -f "$DOC_FILE" ] || { echo "metadata.sh: check-required: file not found: $DOC_FILE" >&2; exit 2; }
    missing_fields "$DOC_FILE" "$STAGE" "$STATUS"
    exit $?
    ;;

  list)
    TICKETS_DIR="./.doer/tickets"
    [ -d "$TICKETS_DIR" ] || exit 0
    for d in "$TICKETS_DIR"/*/; do
      [ -e "$d" ] || continue
      TID="$(basename "$d")"
      if [ -f "${d}metadata.json" ]; then
        jq -r --arg id "$TID" '
          def stagenames: {"1":"ac","2":"plan","3":"build","4":"verify","5":"wrapup"};
          ($id) + "\tdoer\t" + (.status // "?") + "\t" + ((.current_stage // 0) | tostring) +
          "\t" + (stagenames[(.current_stage // 0) | tostring] // "?") + "\t" + (.branch // "")
        ' "${d}metadata.json"
      elif [ -f "${d}bugfix.json" ]; then
        jq -r --arg id "$TID" '
          def stagenames: {"0":"init","1":"ingest","2":"download","3":"evidence","4":"verdict","5":"execute","6":"verify"};
          ($id) + "\tbugfix\t" + (.status // "?") + "\t" + ((.current_stage // 0) | tostring) +
          "\t" + (stagenames[(.current_stage // 0) | tostring] // "?") + "\t"
        ' "${d}bugfix.json"
      fi
    done | awk -F'\t' '{printf "%-9s %-7s [%-11s] Stage %-2s (%s)%s\n", $1, $2, $3, $4, $5, ($6 != "" ? "    " $6 : "")}'
    exit 0
    ;;
esac

# --- Everything below takes <TICKET-ID> next ---
[ $# -ge 1 ] || usage
TICKET_ID="$1"; shift

FILE_NAME="metadata.json"
REQUIRE=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || { echo "metadata.sh: --file requires a value" >&2; exit 2; }
      FILE_NAME="$2"
      shift 2
      ;;
    --require)
      [ $# -ge 2 ] || { echo "metadata.sh: --require requires a value" >&2; exit 2; }
      REQUIRE="$2"
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
    if [ -n "$REQUIRE" ]; then
      RSTAGE="${REQUIRE%%:*}"
      RSTATUS="${REQUIRE#*:}"
      MISSING_JSON="$(missing_fields "$TMP" "$RSTAGE" "$RSTATUS" || true)"
      if [ "$(printf '%s' "$MISSING_JSON" | jq '.missing | length')" -ne 0 ]; then
        rm -f "$TMP"
        echo "metadata.sh: write --require $REQUIRE failed, $TARGET left untouched:" >&2
        printf '%s\n' "$MISSING_JSON" >&2
        exit 1
      fi
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

  version-check)
    [ $# -ge 1 ] || { echo "metadata.sh: version-check requires <current-version>" >&2; exit 2; }
    CURRENT_VERSION="$1"
    [ -f "$TARGET" ] || { echo "metadata.sh: $TARGET does not exist" >&2; exit 1; }
    OLD_VERSION="$(jq -r '.skill_version // empty' "$TARGET")"
    OLD_MAJOR="${OLD_VERSION%%.*}"
    CUR_MAJOR="${CURRENT_VERSION%%.*}"
    if [ "$OLD_MAJOR" = "$CUR_MAJOR" ]; then
      echo "compatible"
    else
      echo "incompatible ${OLD_VERSION:-<none>} vs $CURRENT_VERSION"
      exit 1
    fi
    ;;

  status)
    [ -f "$TARGET" ] || {
      ALT="metadata.json"; [ "$FILE_NAME" = "metadata.json" ] && ALT="bugfix.json"
      ALT_TARGET="${TICKET_DIR}/${ALT}"
      [ -f "$ALT_TARGET" ] && TARGET="$ALT_TARGET" && FILE_NAME="$ALT"
    }
    [ -f "$TARGET" ] || { echo "metadata.sh: no metadata.json or bugfix.json under $TICKET_DIR" >&2; exit 1; }
    KIND="doer"; [ "$FILE_NAME" = "bugfix.json" ] && KIND="bugfix"
    jq -r --arg id "$TICKET_ID" --arg kind "$KIND" '
      # jq-compat:begin status
      def stagenames_doer: {"1":"ac","2":"plan","3":"build","4":"verify","5":"wrapup"};
      def stagenames_bugfix: {"0":"init","1":"ingest","2":"download","3":"evidence","4":"verdict","5":"execute","6":"verify"};
      (if $kind == "doer" then stagenames_doer else stagenames_bugfix end) as $names
      | (.stages // {}) as $stages
      | ($names | keys) as $order
      | def stage_status(n): ($stages[n] // null) | if type == "object" then .status else . end;
      def mark(n): stage_status(n) as $s |
        if ($s == "complete" or $s == "skipped" or $s == "imported") then "x"
        elif $s == "in_progress" then "~" else " " end;
      # Tolerant on purpose: tickets completed before 7.11.0 lack the evidence fields.
      def or_none: if . == null or . == "" then "(none recorded)" else tostring end;
      def verify_block($s4):
        ($s4.ac_verdicts | if type == "object" then . else {} end) as $verdicts
        | ($s4.evidence | if type == "object" then . else {} end) as $evidence
        | ($s4.accepted_not_exercised | if type == "array" then . else [] end) as $accepted
        | "\n\nVerify evidence:\n" +
          ([$verdicts | to_entries[] | "  \(.key): \(.value | tostring)\n    evidence: \($evidence[.key] | or_none)"] | join("\n")) + "\n" +
          "  anomalies: " + ($s4.anomalies | if type == "array" then (if length == 0 then "(none)" else map(tostring) | join("; ") end) else or_none end) + "\n" +
          "  rationale: " + ($s4.rationale | or_none) +
          (if ($accepted | length) == 0 then "" else "\n  accepted_not_exercised:\n" + ([$accepted[] | "    \(if type == "object" then (.ac | or_none) else tostring end): \(if type == "object" then (.reason | or_none) else "" end)"] | join("\n")) end);
      (((.code_review[-1].blockers // []) + (.code_review[-1].prior_blockers_still_open // []) + (.code_review[-1].new_blockers // [])) | length) as $open_blockers
      | "Ticket: \($id), \(.title // "")\n" +
        "Branch: \(.branch // "n/a")  Status: \(.status // "?")\n" +
        "Current Stage: \((.current_stage // 0))  (\($names[((.current_stage // 0) | tostring)] // "?"))\n\n" +
        "Progress:\n" +
        ([$order[] | "  [\(mark(.))] \(.) \($names[.])"] | join("\n")) + "\n\n" +
        "Blockers: " + (if $open_blockers == 0 then "none" else "\($open_blockers) open" end) +
        (if $kind == "doer" and ($stages | type) == "object" and ($stages["4"] | type) == "object" and $stages["4"].status == "complete"
         then verify_block($stages["4"]) else "" end)
      # jq-compat:end
    ' "$TARGET"
    ;;

  *)
    usage
    ;;
esac
