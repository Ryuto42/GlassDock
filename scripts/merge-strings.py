#!/usr/bin/env python3
# Resources/i18n/*.json（{"日本語": "English"}）を Resources/en.lproj/Localizable.strings にまとめる。
# 既存の訳は残し、JSON にある訳で上書きする
import glob, json, os, re, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(root, "Resources/en.lproj/Localizable.strings")

def unescape(s):
    return s.replace('\\n', '\n').replace('\\"', '"').replace('\\\\', '\\')

def escape(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

table = {}
if os.path.exists(out):
    for m in re.finditer(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', open(out, encoding="utf-8").read(), re.M):
        table[unescape(m.group(1))] = unescape(m.group(2))
for path in sorted(glob.glob(os.path.join(root, "Resources/i18n/*.json"))):
    data = json.load(open(path, encoding="utf-8"))
    for k, v in data.items():
        if not isinstance(v, str) or not v:
            sys.exit(f"{path}: empty translation for {k!r}")
        table[k] = v

with open(out, "w", encoding="utf-8") as f:
    f.write("/* GlassDock English translations. Keys are the Japanese source strings. */\n\n")
    for k in sorted(table):
        f.write(f'"{escape(k)}" = "{escape(table[k])}";\n')
print(f"{len(table)} strings -> {os.path.relpath(out, root)}")
