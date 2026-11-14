#!/usr/bin/env python3
import glob
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
PLACEHOLDER = re.compile(r"%(\d+\$)?@")


def decode_swift(body):
    if "\\(" in body:
        raise ValueError(f"interpolation in a translated string: {body!r}; use %@ and pass the value")
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), body)


def first_argument(src, start):
    depth, i, in_string = 0, start, False
    while i < len(src):
        c = src[i]
        if in_string:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_string = False
        elif c == '"':
            in_string = True
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return src[start:i]
            depth -= 1
        elif c == "," and depth == 0:
            return src[start:i]
        i += 1
    raise ValueError("unterminated call")


def keys_in(expression):
    code = LITERAL.sub("", expression)
    literals = [decode_swift(m) for m in LITERAL.findall(expression)]
    if "?" in code and ":" in code:
        return literals
    return ["".join(literals)] if literals else []


def code_keys():
    keys = {}
    for path in sorted(glob.glob(str(ROOT / "Sources/Clipsie/*.swift"))):
        src = Path(path).read_text()
        name = Path(path).name
        for m in re.finditer(r"(?<![A-Za-z_.])L\(", src):
            for key in keys_in(first_argument(src, m.end())):
                keys.setdefault(key, name)
        if name == "Help.swift":
            for m in re.finditer(r"\b(?:heading|note)\(", src):
                for key in keys_in(first_argument(src, m.end())):
                    keys.setdefault(key, name)
            for m in re.finditer(r"\brow\(", src):
                first = first_argument(src, m.end())
                for key in keys_in(first_argument(src, m.end() + len(first) + 1)):
                    keys.setdefault(key, name)
        if name == "Commands.swift":
            for m in re.finditer(r'\{"name": "((?:[^"\\]|\\.)*)"', src):
                keys.setdefault(m.group(1).replace('\\"', '"'), "Commands.swift (default commands.json)")
    return keys


def read_strings(path):
    text = path.read_text(encoding="utf-8")
    unescape = lambda s: re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), s)
    entry = LITERAL.pattern + r"\s*=\s*" + LITERAL.pattern + r"\s*;"
    leftover = re.sub(entry, "", text).strip()
    if leftover:
        raise ValueError(f"{path}: cannot parse near {leftover[:80]!r}")
    return {unescape(k): unescape(v) for k, v in re.findall(entry, text)}


def main():
    keys = code_keys()
    failed = False
    for folder in sorted(ROOT.glob("Resources/*.lproj")):
        language = folder.stem
        if language == "en":
            continue
        table = read_strings(folder / "Localizable.strings")
        missing = [k for k in keys if k not in table]
        unused = [k for k in table if k not in keys]
        mismatched = [k for k in keys if k in table
                      and len(PLACEHOLDER.findall(k)) != len(PLACEHOLDER.findall(table[k]))]
        print(f"{language}: {len(table)} translated, {len(missing)} missing, {len(unused)} unused, {len(mismatched)} placeholder mismatches")
        for k in missing:
            print(f"  missing  ({keys[k]}): {k!r}")
        for k in unused:
            print(f"  unused: {k!r}")
        for k in mismatched:
            print(f"  placeholders differ: {k!r} -> {table[k]!r}")
        failed |= bool(missing or mismatched)
    print(f"{len(keys)} strings in the code (English)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
