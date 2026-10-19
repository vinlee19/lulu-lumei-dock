#!/usr/bin/env python3
"""Fail if any source comment contains CJK text.

Code comments in this repository are English-only (see CONTRIBUTING.md).
String literals are deliberately ignored: zhHans UI copy and Chinese test
titles live in strings and are allowed.

Usage:
    Scripts/check-comment-language.py            # scan every tracked source file
    Scripts/check-comment-language.py FILE...    # scan only the given files

Exit status: 0 when clean, 1 when violations are found.
"""

import os
import re
import subprocess
import sys

CJK = re.compile(r"[　-〿㐀-䶿一-鿿＀-￯]")

C_LIKE = {".swift", ".c", ".h", ".m", ".js"}
HASH_LIKE = {".sh", ".py", ".yml", ".yaml", ".toml"}


def comment_kind(path):
    ext = os.path.splitext(path)[1]
    if ext in C_LIKE:
        return "c"
    if ext in HASH_LIKE or os.path.basename(path) == "Makefile":
        return "hash"
    return None


def c_like_comments(text):
    """Yield (line, comment_text) for // and (nested) /* */ comments.

    A small lexer that skips "...", \"\"\"...\"\"\" and #"..."# string
    literals so that comment markers inside strings are not mistaken for
    comments.
    """
    i, n, line = 0, len(text), 1
    while i < n:
        ch = text[i]
        if ch == "\n":
            line += 1
            i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            yield line, text[i:end]
            i = end
        elif text.startswith("/*", i):
            depth, j, start_line = 1, i + 2, line
            while j < n and depth:
                if text.startswith("/*", j):
                    depth += 1
                    j += 2
                elif text.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            body = text[i:j]
            for offset, part in enumerate(body.split("\n")):
                yield start_line + offset, part
            line += body.count("\n")
            i = j
        elif ch == "#" and re.match(r'#+"', text[i:]):
            hashes = re.match(r"#+", text[i:]).group(0)
            multi = text.startswith(hashes + '"""', i)
            opener = hashes + ('"""' if multi else '"')
            closer = ('"""' if multi else '"') + hashes
            end = text.find(closer, i + len(opener))
            end = n if end < 0 else end + len(closer)
            line += text.count("\n", i, end)
            i = end
        elif text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
            line += text.count("\n", i, end)
            i = end
        elif ch == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == "\\" else 1
            i = j + 1 if j < n and text[j] == '"' else j
        else:
            i += 1


def hash_comments(text):
    """Yield (line, comment_text) for # comments outside quotes."""
    for number, raw in enumerate(text.split("\n"), start=1):
        quote = None
        k = 0
        while k < len(raw):
            ch = raw[k]
            if quote:
                if ch == "\\" and quote == '"':
                    k += 1
                elif ch == quote:
                    quote = None
            elif ch in "'\"":
                quote = ch
            elif ch == "#" and (k == 0 or raw[k - 1] in " \t"):
                yield number, raw[k:]
                break
            k += 1


def comments(path, text):
    kind = comment_kind(path)
    if kind == "c":
        return c_like_comments(text)
    if kind == "hash":
        return hash_comments(text)
    return iter(())


def tracked_files():
    out = subprocess.check_output(["git", "ls-files"], text=True)
    return [f for f in out.splitlines() if comment_kind(f)]


def main(argv):
    paths = argv[1:] or tracked_files()
    violations = 0
    for path in paths:
        if not comment_kind(path) or not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        for line, comment in comments(path, text):
            if CJK.search(comment):
                violations += 1
                print(f"{path}:{line}: {comment.strip()}")
    if violations:
        print(f"\n{violations} comment line(s) contain CJK text; comments must be English.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
