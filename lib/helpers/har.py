#!/usr/bin/env python3
"""wk plugin: HAR/Charles helpers shared by /wk:bugfix and /wk:replay.

Every mode reads a HAR file (the JSON Charles/makehar produces) and treats
its bodies as untrusted, possibly-huge, possibly-base64, possibly-truncated
blobs: nothing here prints a full response body, and `splice` is the only
mode that ever writes payload bytes anywhere, always straight from the HAR
into the target source file, never through a model's own retyping.

Usage:
  har.py convert <in.chls> <out.har>
      Converts via makehar if installed, else Charles.app's own CLI.
      NO_CONVERTER on stderr if neither is available. Exit 0/1/2.

  har.py list <har>
      One line per entry: "<i>: <METHOD> <STATUS> <SIZE>B <URL>".

  har.py head <har> <idx> [--bytes 400]
      Decodes the body (base64-aware), reports its real byte length versus
      the HAR's own reported content.size (Charles can truncate large
      captures), validates it parses as JSON, and prints a short head.
      Exit 1 if the body does not parse as JSON or looks truncated.

  har.py digest <har> <term...>
      One line per entry whose URL or body contains any <term>
      (case-insensitive): "<METHOD> <STATUS> <URL[:160]>".

  har.py scan <har> <idx>
      JSON array of secret/PII candidates in the entry's headers and body,
      as {"where": "header|body", "path": "...", "kind": "token|cookie|
      email|secret-key|high-entropy"}. NEVER prints a value, only where one
      might be; the dev reviews and picks what to --redact in `splice`.

  har.py splice <har> <idx> --target <file> --marker <str>
                 --lang <kotlin|swift|typescript|python|go>
                 [--redact <path,...>] [--max-bytes 30000]
      Replaces the first (and only permitted) occurrence of <marker> in
      <file> with a string literal whose value, once parsed back by the
      target language, is byte-identical to the (possibly redacted) HAR
      body. Redacts each --redact <path> (a "$.a.b[2]" path as printed by
      `scan`) to a fixed placeholder before emitting anything. Refuses
      (exit 1, target file untouched) if the marker is not found exactly
      once, if the body is not valid UTF-8, or if the Kotlin raw-string
      path would collide with three consecutive double quotes in the body
      under --max-bytes (the body still fits under the escaped-string path, but
      that requires re-running with the size accounted for; this script
      does not silently switch representations underneath a size the dev
      may be relying on).
"""
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

LANGS = ("kotlin", "swift", "typescript", "python", "go")


def load_har(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def entry_body(entry):
    """Returns (body_bytes, truncated). truncated is True when the HAR's
    own reported content.size disagrees with the decoded body length (a
    known Charles behavior on large captures)."""
    content = entry.get("response", {}).get("content", {})
    text = content.get("text", "") or ""
    encoding = content.get("encoding")
    if encoding == "base64":
        body = base64.b64decode(text)
    else:
        body = text.encode("utf-8")
    reported = content.get("size")
    truncated = isinstance(reported, int) and reported >= 0 and reported != len(body)
    return body, truncated


def _entry_at(har, idx):
    entries = har["log"]["entries"]
    if idx < 0 or idx >= len(entries):
        raise IndexError(f"index {idx} out of range (0..{len(entries) - 1})")
    return entries[idx]


def cmd_convert(argv):
    if len(argv) != 2:
        print("usage: har.py convert <in.chls> <out.har>", file=sys.stderr)
        return 2
    src, dst = argv
    makehar = shutil.which("makehar")
    if makehar:
        r = subprocess.run([makehar, src], capture_output=True, text=True)
        if r.returncode != 0:
            print(f"NO_CONVERTER: makehar failed: {r.stderr.strip()}", file=sys.stderr)
            return 2
        # makehar's own convention is <in>.har next to <in>; move it into
        # place if the caller asked for a different destination.
        conventional = os.path.splitext(src)[0] + ".har"
        if os.path.abspath(conventional) != os.path.abspath(dst) and os.path.exists(conventional):
            shutil.move(conventional, dst)
        if not os.path.exists(dst):
            print(f"NO_CONVERTER: makehar did not produce {dst}", file=sys.stderr)
            return 2
        return 0
    charles = "/Applications/Charles.app/Contents/MacOS/Charles"
    if os.path.exists(charles) and os.access(charles, os.X_OK):
        r = subprocess.run([charles, "convert", src, dst], capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(dst):
            print(f"NO_CONVERTER: Charles convert failed: {r.stderr.strip()}", file=sys.stderr)
            return 2
        return 0
    print("NO_CONVERTER: neither makehar nor Charles.app found", file=sys.stderr)
    return 1


def cmd_list(argv):
    if len(argv) != 1:
        print("usage: har.py list <har>", file=sys.stderr)
        return 2
    har = load_har(argv[0])
    for i, e in enumerate(har["log"]["entries"]):
        req, res = e["request"], e["response"]
        size = res.get("content", {}).get("size", -1)
        print(f"{i}: {req['method']} {res['status']} {size}B {req['url']}")
    return 0


def cmd_head(argv):
    bytes_n = 400
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == "--bytes":
            bytes_n = int(argv[i + 1])
            i += 2
        else:
            args.append(argv[i])
            i += 1
    if len(args) != 2:
        print("usage: har.py head <har> <idx> [--bytes 400]", file=sys.stderr)
        return 2
    har = load_har(args[0])
    try:
        entry = _entry_at(har, int(args[1]))
    except IndexError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    reported = entry.get("response", {}).get("content", {}).get("size", -1)
    try:
        body, truncated = entry_body(entry)
    except Exception as e:
        print(f"error: could not decode body: {e}", file=sys.stderr)
        return 1
    print(f"bytes: {len(body)} (reported: {reported})")
    if truncated:
        print(
            "WARNING: reported content.size does not match the decoded body "
            "length; Charles may have truncated this capture",
            file=sys.stderr,
        )
    try:
        parsed = json.loads(body.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        print(f"WARNING: body does not parse as JSON: {e}", file=sys.stderr)
        print(body[:bytes_n].decode("utf-8", errors="replace"))
        return 1
    if isinstance(parsed, dict):
        print(f"keys: {list(parsed.keys())}")
    elif isinstance(parsed, list):
        print(f"array of {len(parsed)} items")
    print(body[:bytes_n].decode("utf-8", errors="replace"))
    return 1 if truncated else 0


def cmd_digest(argv):
    if len(argv) < 2:
        print("usage: har.py digest <har> <term...>", file=sys.stderr)
        return 2
    har = load_har(argv[0])
    terms = [t.lower() for t in argv[1:]]
    for e in har["log"]["entries"]:
        req = e["request"]
        url = req["url"]
        blob = (url + " " + (e.get("response", {}).get("content", {}).get("text", "") or "")).lower()
        if any(t in blob for t in terms):
            print(req["method"], e["response"]["status"], url[:160])
    return 0


_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
_SECRET_KEY_RE = re.compile(r"(token|session|password|secret)", re.IGNORECASE)
_HIGH_ENTROPY_CHARSET = set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-."
)


def _is_high_entropy(s: str) -> bool:
    if len(s) < 20:
        return False
    charset = set(s)
    if not charset <= _HIGH_ENTROPY_CHARSET:
        return False
    return len(charset) >= 10


def _walk_body(value, path, findings):
    if isinstance(value, dict):
        for k, v in value.items():
            child = f"{path}.{k}"
            if _SECRET_KEY_RE.search(k):
                findings.append({"where": "body", "path": child, "kind": "secret-key"})
            _walk_body(v, child, findings)
    elif isinstance(value, list):
        for i, v in enumerate(value):
            _walk_body(v, f"{path}[{i}]", findings)
    elif isinstance(value, str):
        if _EMAIL_RE.match(value):
            findings.append({"where": "body", "path": path, "kind": "email"})
        elif _is_high_entropy(value):
            findings.append({"where": "body", "path": path, "kind": "high-entropy"})


def cmd_scan(argv):
    if len(argv) != 2:
        print("usage: har.py scan <har> <idx>", file=sys.stderr)
        return 2
    har = load_har(argv[0])
    try:
        entry = _entry_at(har, int(argv[1]))
    except IndexError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    findings = []
    for section in ("request", "response"):
        for h in entry.get(section, {}).get("headers", []):
            name = h.get("name", "")
            if name.lower() == "authorization":
                findings.append({"where": "header", "path": name, "kind": "token"})
            elif name.lower() in ("set-cookie", "cookie"):
                findings.append({"where": "header", "path": name, "kind": "cookie"})

    try:
        body, _truncated = entry_body(entry)
        parsed = json.loads(body.decode("utf-8"))
        _walk_body(parsed, "$", findings)
    except Exception:
        pass  # non-JSON or undecodable body: the header scan above still stands

    print(json.dumps(findings))
    return 0


def _redact_one(root, path):
    tokens = re.findall(r"\.([A-Za-z0-9_]+)|\[(\d+)\]", path)
    if not tokens:
        raise ValueError(f"unparseable redact path: {path!r}")
    steps = [name if name else int(idx) for name, idx in tokens]
    node = root
    for step in steps[:-1]:
        node = node[step]
    node[steps[-1]] = "[REDACTED]"


def _escape_char(ch: str, lang: str) -> str:
    if ch == "\\":
        return "\\\\"
    if ch == '"':
        return '\\"'
    if ch == "\n":
        return "\\n"
    if ch == "\r":
        return "\\r"
    if ch == "\t":
        return "\\t"
    if lang == "kotlin" and ch == "$":
        return "${'$'}"
    o = ord(ch)
    if 0x20 <= o <= 0x7E:
        return ch
    # Control char or non-ASCII: language-specific unicode escape syntax.
    if lang == "swift":
        return f"\\u{{{o:x}}}"
    if lang == "python":
        if o < 0x100:
            return f"\\x{o:02x}"
        if o <= 0xFFFF:
            return f"\\u{o:04x}"
        return f"\\U{o:08x}"
    if lang == "go":
        if o <= 0xFFFF:
            return f"\\u{o:04x}"
        return f"\\U{o:08x}"
    # kotlin, typescript: \uXXXX is one UTF-16 code unit; a non-BMP code
    # point needs a surrogate pair, since both languages' strings are
    # UTF-16 based.
    if o > 0xFFFF:
        o -= 0x10000
        hi = 0xD800 + (o >> 10)
        lo = 0xDC00 + (o & 0x3FF)
        return f"\\u{hi:04x}\\u{lo:04x}"
    return f"\\u{o:04x}"


def _escape_tokens(text: str, lang: str):
    return [_escape_char(c, lang) for c in text]


def _chunk_tokens(tokens, max_bytes: int):
    """Groups already-escaped (pure-ASCII) tokens into chunks of at most
    max_bytes each, never splitting a token (each token is one atomic
    escape sequence or a single literal character)."""
    chunks = []
    current = []
    current_len = 0
    for tok in tokens:
        tok_len = len(tok)  # ASCII by construction: 1 byte per character
        if current and current_len + tok_len > max_bytes:
            chunks.append("".join(current))
            current = []
            current_len = 0
        current.append(tok)
        current_len += tok_len
    if current:
        chunks.append("".join(current))
    return chunks


def _join_syntax(chunks, lang: str) -> str:
    quoted = [f'"{c}"' for c in chunks]
    if lang == "kotlin":
        return "listOf(" + ", ".join(quoted) + ').joinToString("")'
    if lang == "swift":
        return "[" + ", ".join(quoted) + "].joined()"
    if lang == "typescript":
        return "[" + ", ".join(quoted) + '].join("")'
    if lang == "python":
        return '"".join([' + ", ".join(quoted) + "])"
    if lang == "go":
        return "strings.Join([]string{" + ", ".join(quoted) + '}, "")'
    raise ValueError(lang)


def cmd_splice(argv):
    max_bytes = 30000
    target = marker = lang = None
    redact_paths = []
    args = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--target":
            target = argv[i + 1]
            i += 2
        elif a == "--marker":
            marker = argv[i + 1]
            i += 2
        elif a == "--lang":
            lang = argv[i + 1]
            i += 2
        elif a == "--redact":
            redact_paths = [p for p in argv[i + 1].split(",") if p]
            i += 2
        elif a == "--max-bytes":
            max_bytes = int(argv[i + 1])
            i += 2
        else:
            args.append(a)
            i += 1

    if len(args) != 2 or target is None or marker is None or lang is None:
        print(
            "usage: har.py splice <har> <idx> --target <file> --marker <str> "
            "--lang <kotlin|swift|typescript|python|go> [--redact <path,...>] "
            "[--max-bytes 30000]",
            file=sys.stderr,
        )
        return 2
    if lang not in LANGS:
        print(f"error: unknown --lang {lang!r}, want one of {', '.join(LANGS)}", file=sys.stderr)
        return 1

    har = load_har(args[0])
    try:
        entry = _entry_at(har, int(args[1]))
    except IndexError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    try:
        body, _truncated = entry_body(entry)
    except Exception as e:
        print(f"error: could not decode body: {e}", file=sys.stderr)
        return 1

    if redact_paths:
        try:
            parsed = json.loads(body.decode("utf-8"))
        except Exception as e:
            print(f"error: --redact requires a JSON body: {e}", file=sys.stderr)
            return 1
        try:
            for p in redact_paths:
                _redact_one(parsed, p)
        except (KeyError, IndexError, TypeError, ValueError) as e:
            print(f"error: --redact path failed: {e}", file=sys.stderr)
            return 1
        body = json.dumps(parsed).encode("utf-8")

    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError as e:
        print(f"error: body is not valid UTF-8, cannot emit as a string literal: {e}", file=sys.stderr)
        return 1

    over_threshold = len(body) >= max_bytes
    chunks_n = 1

    if lang == "kotlin" and not over_threshold and '"""' in text:
        print(
            'error: body contains """ and is under --max-bytes; the Kotlin '
            "raw-string literal is unsafe here (would truncate early). "
            "Redact the offending value or lower --max-bytes to force chunking.",
            file=sys.stderr,
        )
        return 1

    if lang == "kotlin" and not over_threshold:
        literal = '"""' + text.replace("$", "${'$'}") + '"""'
    else:
        tokens = _escape_tokens(text, lang)
        if over_threshold:
            chunks = _chunk_tokens(tokens, max_bytes)
            chunks_n = len(chunks)
            literal = _join_syntax(chunks, lang)
        else:
            literal = f'"{"".join(tokens)}"'

    if not os.path.isfile(target):
        print(f"error: target file not found: {target}", file=sys.stderr)
        return 1
    with open(target, "r", encoding="utf-8") as f:
        src = f.read()
    count = src.count(marker)
    if count != 1:
        print(f"error: marker {marker!r} appears {count} time(s) in {target}, expected exactly 1", file=sys.stderr)
        return 1
    with open(target, "w", encoding="utf-8") as f:
        f.write(src.replace(marker, literal, 1))

    digest = hashlib.sha256(body).hexdigest()[:12]
    print(f"{entry['request']['url']}, {len(body)} bytes, sha256:{digest}, chunks:{chunks_n}")
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    mode = argv[1]
    handlers = {
        "convert": cmd_convert,
        "list": cmd_list,
        "head": cmd_head,
        "digest": cmd_digest,
        "scan": cmd_scan,
        "splice": cmd_splice,
    }
    handler = handlers.get(mode)
    if handler is None:
        print(f"unknown mode: {mode}", file=sys.stderr)
        return 2
    try:
        return handler(argv[2:])
    except (OSError, json.JSONDecodeError, KeyError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
