#!/usr/bin/env python3
"""Minimal jq standing in for the real thing on machines that lack it.

Implements only what the scripts use: `jq -n[c] --arg k v --argjson k v FILTER`
where FILTER is an object or array literal referencing $variables. That is
enough to produce genuine JSON, so the tests assert on real output rather than
on a canned string.

Anything outside that shape exits 64 with a clear message, so a script that
grows a more complex filter fails loudly here instead of silently passing.
"""

import json
import os
import re
import sys


def main(argv):
    args = list(argv)
    variables = {}
    filter_text = None
    null_input = False

    while args:
        arg = args.pop(0)
        if arg in ("-n", "--null-input"):
            null_input = True
        elif arg in ("-c", "--compact-output", "-r", "--raw-output"):
            pass
        elif arg.startswith("-") and len(arg) > 1 and not arg.startswith("--") and set(arg[1:]) <= set("ncr"):
            null_input = null_input or "n" in arg[1:]
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
        sys.stderr.write("stub jq: only -n (null input) is supported\n")
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
