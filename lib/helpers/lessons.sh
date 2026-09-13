#!/usr/bin/env bash
# wk plugin: global lessons-pool maintenance. Lessons live at
# ${CLAUDE_PLUGIN_ROOT}/lessons/ (gitignored, per-machine, never synced). A
# MAJOR skill_version bump can invalidate advice tied to the old pipeline
# (e.g. the 6.x -> 7.0.0 stage collapse), so a lesson never survives one.

set -eu

usage() {
  cat >&2 <<EOF
Usage: lessons.sh prune <current-major>

Deletes every lessons/*.md whose frontmatter skill_version field has a MAJOR
(the number before the first dot) lower than <current-major>, and any lesson
missing the field entirely (treated as MAJOR 0). Prints "PRUNED <slug> <old-version>"
per file removed, one per line; nothing on stdout if none were pruned.

Lessons directory: \${WK_LESSONS_DIR:-\${CLAUDE_PLUGIN_ROOT}/lessons}.
EOF
  exit 2
}

[ $# -ge 2 ] || usage
CMD="$1"; shift
[ "$CMD" = "prune" ] || usage
CURRENT_MAJOR="$1"
case "$CURRENT_MAJOR" in ''|*[!0-9]*) echo "lessons.sh: <current-major> must be a plain integer" >&2; exit 2 ;; esac

LESSONS_DIR="${WK_LESSONS_DIR:-${CLAUDE_PLUGIN_ROOT:-}/lessons}"
[ -n "$LESSONS_DIR" ] || { echo "lessons.sh: CLAUDE_PLUGIN_ROOT is not set; pass WK_LESSONS_DIR instead" >&2; exit 2; }
[ -d "$LESSONS_DIR" ] || exit 0

for f in "$LESSONS_DIR"/*.md; do
  [ -e "$f" ] || continue
  RAW="$(grep -m1 '^skill_version:' "$f" 2>/dev/null || true)"
  VERSION="${RAW#skill_version:}"
  VERSION="${VERSION# }"
  VERSION="${VERSION%\"}"; VERSION="${VERSION#\"}"
  VERSION="${VERSION%\'}"; VERSION="${VERSION#\'}"
  MAJOR="${VERSION%%.*}"
  case "$MAJOR" in ''|*[!0-9]*) MAJOR=0 ;; esac
  if [ "$MAJOR" -lt "$CURRENT_MAJOR" ]; then
    SLUG="$(basename "$f" .md)"
    rm -f "$f"
    echo "PRUNED $SLUG ${VERSION:-none}"
  fi
done
