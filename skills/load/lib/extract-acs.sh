#!/usr/bin/env bash
# wk load skill: extract an Acceptance Criteria section from a Markdown body.
#
# Usage: extract-acs.sh <body-file>
#   Prints the verbatim AC section if found; prints nothing if not found.
#   Exit 0 in both cases. The caller decides whether to use "derive" or the output.
#
# Detection heuristic (in priority order):
#   1. A heading that matches /^#{1,3}\s*(acceptance criteria|ac:|acs:)/i
#   2. A bold label: **Acceptance Criteria** or **AC:**
#   3. A plain label on its own line: "Acceptance Criteria:" or "AC:"
#
# Extraction: everything from the matching line to the next heading of the
# same or higher level (or end of file). Blank lines at the end are stripped.

set -eu

if [ $# -lt 1 ]; then
  echo "Usage: extract-acs.sh <body-file>" >&2
  exit 2
fi

BODY_FILE="$1"

if [ ! -f "$BODY_FILE" ]; then
  echo "File not found: $BODY_FILE" >&2
  exit 2
fi

awk '
function leading_hashes(line,    n) {
  n = 0
  while (substr(line, n + 1, 1) == "#") n++
  return n
}

BEGIN {
  in_section = 0
  section_level = 0
  buffer = ""
  found = 0
}

{
  lower = tolower($0)
}

# Case 1: Markdown heading (## Acceptance Criteria, # AC:, etc.)
!in_section && /^#{1,3}[[:space:]]/ && (lower ~ /acceptance criteria/ || lower ~ /\<ac:/ || lower ~ /\<acs:/) {
  in_section = 1
  found = 1
  section_level = leading_hashes($0)
  buffer = buffer $0 "\n"
  next
}

# Case 2: Bold label **Acceptance Criteria** or **AC:**
!in_section && (lower ~ /^\*\*acceptance criteria\*\*/ || lower ~ /^\*\*ac:\*\*/) {
  in_section = 1
  found = 1
  section_level = 0
  buffer = buffer $0 "\n"
  next
}

# Case 3: Plain label "Acceptance Criteria:" or "AC:" on its own line
!in_section && (lower ~ /^acceptance criteria:/ || lower ~ /^ac:/) {
  in_section = 1
  found = 1
  section_level = 0
  buffer = buffer $0 "\n"
  next
}

in_section {
  if (section_level > 0 && /^#+[[:space:]]/) {
    cur_level = leading_hashes($0)
    if (cur_level <= section_level) {
      in_section = 0
      next
    }
  }
  if (section_level == 0 && found && buffer != "" && /^\*\*[A-Z]/ && tolower($0) !~ /^\*\*acceptance criteria\*\*/ && tolower($0) !~ /^\*\*ac:\*\*/) {
    in_section = 0
    next
  }
  buffer = buffer $0 "\n"
}

END {
  if (found && buffer != "") {
    while (substr(buffer, length(buffer) - 1, 2) == "\n\n") {
      buffer = substr(buffer, 1, length(buffer) - 1)
    }
    printf "%s", buffer
  }
}
' "$BODY_FILE"
