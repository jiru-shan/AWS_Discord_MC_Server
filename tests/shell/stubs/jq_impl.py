#!/usr/bin/env python3
"""Minimal jq standing in for the real thing on machines that lack it.

Implements only what the scripts use:

  jq -n[c] --arg k v --argjson k v FILTER
      where FILTER is an object or array literal referencing $variables. Enough
      to produce genuine JSON, so the tests assert on real output rather than
      on a canned string.

  jq -r '[.[] | select(.FIELD == LITERAL)][INDEX].FIELD' < stdin
      the one stdin filter in the scripts: picking the newest stable entry out
      of a Fabric meta list.

Anything outside those shapes exits 64 with a clear message, so a script that
grows a more complex filter fails loudly here instead of silently passing.
"""

import json
import os
import re
import sys

# [.[] | select(.stable == true)][0].version
SELECT_FILTER = re.compile(
    r"""^\s*\[\s*\.\[\]\s*\|\s*select\(\s*\.(?P<key>\w+)\s*==\s*(?P<value>true|false|null|-?\d+|"[^"]*")\s*\)\s*\]"""
    r"""\s*\[\s*(?P<index>-?\d+)\s*\]\s*(?:\.(?P<field>\w+))?\s*$"""
)


def run_select(filter_text, raw_output):
    """Evaluate the stdin filter above, or return None if it does not match."""
    match = SELECT_FILTER.match(filter_text)
    if not match:
        return None

    try:
        document = json.load(sys.stdin)
    except json.JSONDecodeError as err:
        sys.stderr.write(f"stub jq: stdin is not JSON: {err}\n")
        return 64

    wanted = json.loads(match.group("value"))
    selected = [item for item in document if isinstance(item, dict) and item.get(match.group("key")) == wanted]

    try:
        chosen = selected[int(match.group("index"))]
    except IndexError:
        # Real jq yields null for an out-of-range index rather than failing.
        print("null" if not raw_output else "null")
        return 0

    result = chosen.get(match.group("field")) if match.group("field") else chosen
    if raw_output and isinstance(result, str):
        print(result)
    else:
        json.dump(result, sys.stdout)
        sys.stdout.write("\n")
    return 0


def run_field(filter_text, raw_output):
    """Evaluate a plain field read -- `.id`, or `.id // empty` -- over stdin.

    seed-players.sh uses this shape to pull a UUID out of a Mojang profile
    lookup. The `// empty` half matters: real jq prints nothing for a missing
    key rather than the string "null", and the caller measures what it gets.
    """
    text = filter_text.strip()
    alternative = text.endswith("// empty")
    if alternative:
        text = text[: -len("// empty")].strip()
    if not text.startswith(".") or not text[1:].isidentifier():
        return None

    try:
        document = json.load(sys.stdin)
    except json.JSONDecodeError as err:
        sys.stderr.write("stub jq: stdin is not JSON: " + str(err) + chr(10))
        return 64
    if not isinstance(document, dict):
        sys.stderr.write("stub jq: a field read needs a JSON object" + chr(10))
        return 64

    value = document.get(text[1:])
    if value is None:
        # `.x` yields null; `.x // empty` yields nothing at all.
        if not alternative:
            print("null")
        return 0

    if raw_output and isinstance(value, str):
        print(value)
    else:
        json.dump(value, sys.stdout)
        sys.stdout.write(chr(10))
    return 0


def main(argv):
    args = list(argv)
    variables = {}
    filter_text = None
    null_input = False
    raw_output = False

    while args:
        arg = args.pop(0)
        if arg in ("-n", "--null-input"):
            null_input = True
        elif arg in ("-r", "--raw-output"):
            raw_output = True
        elif arg in ("-c", "--compact-output"):
            pass
        elif arg.startswith("-") and len(arg) > 1 and not arg.startswith("--") and set(arg[1:]) <= set("ncr"):
            null_input = null_input or "n" in arg[1:]
            raw_output = raw_output or "r" in arg[1:]
        elif arg == "--arg":
            key, value = args.pop(0), args.pop(0)
            variables[key] = value
        elif arg == "--argjson":
            key, value = args.pop(0), args.pop(0)
            variables[key] = json.loads(value)
        elif filter_text is None:
            filter_text = arg
        else:
            sys.stderr.write(f"stub jq: unexpected argument {arg!r}\n")
            return 64

    if filter_text is None:
        sys.stderr.write("stub jq: no filter given\n")
        return 64

    if not null_input:
        result = run_select(filter_text, raw_output)
        if result is not None:
            return result
        result = run_field(filter_text, raw_output)
        if result is not None:
            return result
        sys.stderr.write(
            f"stub jq: unsupported stdin filter {filter_text!r}; "
            "only the select-newest-stable and plain-field shapes are implemented\n"
        )
        return 64

    # Substitute $vars with placeholders first, so a value containing braces or
    # colons cannot be mangled by the key-quoting pass below.
    placeholders = {}

    def take(match):
        name = match.group(1)
        if name not in variables:
            sys.stderr.write(f"stub jq: ${name} is not defined\n")
            raise SystemExit(64)
        token = f"@@V{len(placeholders)}@@"
        placeholders[token] = variables[name]
        return f'"{token}"'

    text = re.sub(r"\$([A-Za-z_][A-Za-z0-9_]*)", take, filter_text)

    # jq allows bare identifiers as object keys; JSON does not.
    text = re.sub(r"([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*):", r'\1"\2"\3:', text)

    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as err:
        sys.stderr.write(f"stub jq: cannot evaluate filter {filter_text!r}: {err}\n")
        return 64

    def restore(node):
        if isinstance(node, str):
            return placeholders.get(node, node)
        if isinstance(node, list):
            return [restore(item) for item in node]
        if isinstance(node, dict):
            return {restore(k): restore(v) for k, v in node.items()}
        return node

    json.dump(restore(parsed), sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as err:  # noqa: BLE001
        sys.stderr.write(f"stub jq: {err}\n")
        sys.exit(64)
