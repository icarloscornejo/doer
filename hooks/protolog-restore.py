#!/usr/bin/env python3
"""wk plugin: canonical PROTOLOG line stripper for skills/protologs/SKILL.md.

Both hooks/protolog-temp-commit-integrity-guard.sh (as a pre-commit invariant
check) and skills/protologs/SKILL.md's cleanup Step 2-fallback (as the actual
removal operation) call this SAME script, so "the check" and "the fallback"
are provably the same transformation instead of two hand-written copies that
can drift apart. Mirrors hooks/replay-restore.py's role for REPLAY blocks.

A standalone PROTOLOG line looks like one of:

    println("PROTOLOG - some message")
    .also { println("PROTOLOG - result=$it") }

restore() deletes every standalone PROTOLOG line entirely (there is no
REPLAY-ORIG-style payload to preserve; protolog lines are pure injected
diagnostics). "Standalone" is NOT a regex match on the line's prefix: a
naive `^(\\.also \\{ )?println\\(.*PROTOLOG - .*\\)` is greedy across the
call's own closing paren and so also matches business code glued on after
it, e.g. `println("PROTOLOG - x"); updateBusinessState()`, exactly the shape
the injection rules forbid (skills/protologs/SKILL.md, "VALID LINE SHAPES",
rule 5). Recognizing a standalone line instead requires finding the call's
REAL closing paren: a small scanner tracks parenthesis depth and string
state (a `"` inside the call's own string argument does not close it, and a
backslash escape inside that string does not end it either) until depth
returns to 0, then requires nothing but whitespace (or, after a `.also {`
opener, exactly ` }` then whitespace) for the rest of the line. Anything
else trailing after the call's real close is a structural violation, never
silently stripped.

This module works entirely on bytes (never decodes as text) and rebuilds
output using each input line's own line terminator (bytes.splitlines(keepends=True),
not text-mode splitlines/join), so CRLF vs LF and a missing final newline
survive the round trip unchanged, the same rationale as replay-restore.py.

Usage:
  protolog-restore.py check <post-image-file> <parent-file>
    Exit 0 if restore(post) == restore(parent), byte for byte (the two
    images differ only in which PROTOLOG lines are present). Exit 1 on a
    content mismatch (a non-PROTOLOG change slipped in; the old, narrower
    "Check A" only ever looked for ADDED non-PROTOLOG lines via a diff, and
    so missed deletions, this catches both). Exit 2 on a structural
    violation (an embedded or malformed PROTOLOG line, the old "Check B") in
    either file. A one-line diagnostic goes to stderr in every failing case.

  protolog-restore.py strip <file> [--lenient]
    Print restore(file) to stdout: this IS cleanup's Step 2-fallback removal
    operation, the caller writes stdout back over the file in place. Strict
    by default: exit 2 with a diagnostic on a structural violation, same as
    `check`. --lenient additionally applies the one documented embedded-line
    fallback (stripping a ".also { println(\"PROTOLOG - ...\") }" suffix
    glued onto real code via substring replacement, keeping the rest of the
    line) and reports which line numbers it touched to stderr; never used by
    `check`, only by a human-directed cleanup pass on an older or malformed
    session.
"""
import re
import sys

MARKER = b"PROTOLOG - "

# Longest prefix first within a shared first character is not required here:
# each is matched as an exact byte sequence at a fixed position, not via
# alternation, so order does not matter.
CALL_PREFIXES = (
    b"System.out.println",
    b"console.log",
    b"fmt.Println",
    b"println!",
    b"println",
    b"print",
    b"puts",
)

ALSO_OPEN = b".also { "
ALSO_CLOSE = b" }"


class MarkerError(ValueError):
    pass


def _match_call_open(body: bytes, start: int):
    """At byte offset `start`, try to match one of CALL_PREFIXES immediately
    followed by '('. Returns the offset right after that '(' on success, or
    None if no known call starts there."""
    for prefix in CALL_PREFIXES:
        end = start + len(prefix)
        if body[start:end] == prefix and body[end : end + 1] == b"(":
            return end + 1
    return None


def _find_call_close(body: bytes, open_idx: int):
    """`open_idx` is the offset right after a call's opening '('. Scans
    forward tracking paren depth (starting at 1) and double-quoted-string
    state (backslash escapes do not end a string) until depth returns to 0.
    Returns the offset right after that matching ')', or None if the line
    ends first (the call is not closed on this line, so it cannot be a
    standalone line by definition)."""
    depth = 1
    i = open_idx
    n = len(body)
    in_string = False
    while i < n:
        c = body[i : i + 1]
        if in_string:
            if c == b"\\":
                i += 2
                continue
            if c == b'"':
                in_string = False
            i += 1
            continue
        if c == b'"':
            in_string = True
            i += 1
            continue
        if c == b"(":
            depth += 1
            i += 1
            continue
        if c == b")":
            depth -= 1
            i += 1
            if depth == 0:
                return i
            continue
        i += 1
    return None


def is_standalone_protolog_line(body: bytes) -> bool:
    """`body` is one line's content, its line terminator already stripped.
    True iff it is EXACTLY: optional leading whitespace, an optional
    ".also { " opener, one known print-family call whose own argument text
    contains the PROTOLOG marker and is closed on this same line, then (if
    ".also {" opened) exactly " }", then nothing but whitespace to the end
    of the line. Any other trailing content makes this a non-standalone
    (embedded) line."""
    i = 0
    n = len(body)
    while i < n and body[i : i + 1] in (b" ", b"\t"):
        i += 1
    also = False
    if body[i : i + len(ALSO_OPEN)] == ALSO_OPEN:
        also = True
        i += len(ALSO_OPEN)
    call_open = _match_call_open(body, i)
    if call_open is None:
        return False
    call_close = _find_call_close(body, call_open)
    if call_close is None:
        return False
    if MARKER not in body[i:call_close]:
        return False
    rest = body[call_close:]
    if also:
        if rest[: len(ALSO_CLOSE)] != ALSO_CLOSE:
            return False
        rest = rest[len(ALSO_CLOSE) :]
    # A single trailing ";" is a statement terminator for this SAME call
    # (Java/JS/TS/Go/Rust all allow or require one), not separate business
    # logic glued on; the whole line still deletes cleanly either way. Two
    # semicolons, or a semicolon followed by anything but whitespace, is a
    # second statement and is still a violation.
    if rest[:1] == b";":
        rest = rest[1:]
    return rest.strip(b" \t") == b""


def restore(data: bytes) -> bytes:
    """Delete every standalone PROTOLOG line. Raises MarkerError on any
    line that carries the marker but is not standalone (embedded or
    malformed): that line is never silently stripped or partially edited."""
    out = []
    for raw in data.splitlines(keepends=True):
        term_len = len(raw) - len(raw.rstrip(b"\r\n"))
        body = raw[: len(raw) - term_len] if term_len else raw
        if MARKER in body:
            if not is_standalone_protolog_line(body):
                raise MarkerError(
                    f"embedded or malformed PROTOLOG line: {body!r}"
                )
            continue
        out.append(raw)
    return b"".join(out)


_LENIENT_PATTERN = re.compile(
    rb'\.also \{ println\("PROTOLOG - [^"]*"\) \}'
)


def strip_lenient(data: bytes):
    """Best-effort fallback for the one documented embedded shape,
    '.also { println("PROTOLOG - ...") }' glued onto real code: strip just
    that substring via regex, keeping the rest of the line. A standalone
    line is still dropped whole, same as restore(). A line that carries the
    marker but matches neither shape is left untouched (this is a fallback
    of last resort, not a second strict pass). Returns (result_bytes,
    touched_line_numbers)."""
    out = []
    touched = []
    lineno = 0
    for raw in data.splitlines(keepends=True):
        lineno += 1
        term_len = len(raw) - len(raw.rstrip(b"\r\n"))
        body = raw[: len(raw) - term_len] if term_len else raw
        term = raw[len(body) :]
        if MARKER not in body:
            out.append(raw)
            continue
        if is_standalone_protolog_line(body):
            touched.append(lineno)
            continue
        new_body, n = _LENIENT_PATTERN.subn(b"", body)
        if n > 0:
            touched.append(lineno)
            out.append(new_body + term)
        else:
            out.append(raw)
    return b"".join(out), touched


def main(argv):
    if len(argv) < 2:
        print(
            "usage: protolog-restore.py check <post> <parent> | strip <file> [--lenient]",
            file=sys.stderr,
        )
        return 2
    mode = argv[1]
    try:
        if mode == "strip":
            lenient = "--lenient" in argv[2:]
            files = [a for a in argv[2:] if a != "--lenient"]
            if len(files) != 1:
                print("usage: protolog-restore.py strip <file> [--lenient]", file=sys.stderr)
                return 2
            with open(files[0], "rb") as f:
                data = f.read()
            if lenient:
                result, touched = strip_lenient(data)
                if touched:
                    print(f"lenient: stripped line(s) {touched}", file=sys.stderr)
                sys.stdout.buffer.write(result)
            else:
                sys.stdout.buffer.write(restore(data))
            return 0

        if mode == "check":
            if len(argv) != 4:
                print("usage: protolog-restore.py check <post> <parent>", file=sys.stderr)
                return 2
            with open(argv[2], "rb") as f:
                post = restore(f.read())
            with open(argv[3], "rb") as f:
                parent = restore(f.read())
            if post == parent:
                return 0
            print(
                "restore-equality mismatch: post-image and parent differ "
                "after stripping PROTOLOG lines (a non-PROTOLOG change slipped in)",
                file=sys.stderr,
            )
            return 1

        print(f"unknown mode: {mode}", file=sys.stderr)
        return 2
    except MarkerError as e:
        print(f"structural violation: {e}", file=sys.stderr)
        return 2
    except OSError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
