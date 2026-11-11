#!/usr/bin/env python3
"""画面の文言の英訳の抜けを調べる。

  python3 tools/i18n_check.py            抜けている訳と、使われていない訳の一覧
  python3 tools/i18n_check.py --stub     抜けている訳を Localizable.strings の形で出す（訳を書いて足す用）

ソースの L("…") を集めて（\\(…) は %@ にする）、Resources/en.lproj/Localizable.strings と比べる。
抜けがあっても動く（その文言は日本語のまま出る）。
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Sources", "VJPlayer")
STRINGS = os.path.join(ROOT, "Resources", "en.lproj", "Localizable.strings")


def parse_swift_literal(src, i):
    """src[i] == '"'。(終わりの位置, キー) を返す"""
    j = i + 1
    raw, esc, interp = "", "", False
    while True:
        c = src[j]
        if c == "\\":
            n = src[j + 1]
            if n == "(":
                j += 2
                depth = 1
                while depth:
                    d = src[j]
                    if d == '"':
                        j, _ = parse_swift_literal(src, j)
                        continue
                    if d == "(":
                        depth += 1
                    elif d == ")":
                        depth -= 1
                    j += 1
                raw += "%@"
                esc += "%@"
                interp = True
                continue
            if n == "u":
                k = src.index("}", j)
                ch = chr(int(src[j + 3:k], 16))
                j = k + 1
            else:
                ch = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}[n]
                j += 2
            raw += ch
            esc += ch.replace("%", "%%")
            continue
        if c == '"':
            return j + 1, (esc if interp else raw)
        raw += c
        esc += c.replace("%", "%%")
        j += 1


def source_keys():
    keys = {}
    for name in sorted(os.listdir(SRC)):
        if not name.endswith(".swift"):
            continue
        src = open(os.path.join(SRC, name), encoding="utf-8").read()
        for m in re.finditer(r'(?<![A-Za-z0-9_])L\("', src):
            start = m.end() - 1
            line_start = src.rfind("\n", 0, start) + 1
            if src.startswith('"""', start) or "//" in src[line_start:start]:
                continue
            end, key = parse_swift_literal(src, start)
            # L("…", note: "…")：場所ごとの訳。見出しは "…#…"
            note = re.match(r'\s*,\s*note:\s*"([^"]*)"', src[end:])
            if note:
                key += "#" + note.group(1)
            line = src.count("\n", 0, start) + 1
            keys.setdefault(key, f"{name}:{line}")
    return keys


def read_strings(path):
    if not os.path.exists(path):
        return {}
    text = open(path, encoding="utf-8").read()
    out = {}
    pat = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
    for m in pat.finditer(re.sub(r"/\*.*?\*/", "", text, flags=re.S)):
        out[unescape(m.group(1))] = unescape(m.group(2))
    return out


def unescape(s):
    return re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t", "r": "\r"}.get(m.group(1), m.group(1)), s)


def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def main():
    keys = source_keys()
    have = read_strings(STRINGS)
    missing = [k for k in keys if k not in have]
    unused = [k for k in have if k not in keys]
    if "--stub" in sys.argv:
        for k in missing:
            print(f'/* {keys[k]} */\n"{escape(k)}" = "";\n')
        return
    print(f"文言 {len(keys)} 個 / 訳あり {len(keys) - len(missing)} 個 / 抜け {len(missing)} 個 / 使われていない訳 {len(unused)} 個")
    for k in missing:
        print(f"  抜け  {keys[k]}  {k!r}")
    for k in unused:
        print(f"  不要  {k!r}")
    # 書式（%@ %d など）の数が合わない訳
    spec = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:@|ll?[dux]|[dfsxXeEgGc])")
    for k, v in have.items():
        if k in keys and v and sorted(re.sub(r"\d+\$", "", s) for s in spec.findall(k)) != sorted(re.sub(r"\d+\$", "", s) for s in spec.findall(v)):
            print(f"  書式が合わない  {keys[k]}  {k!r} → {v!r}")
        # 「：」や空白で終わる文言は後ろに続きがつながるので、訳も空白で終える
        if k in keys and v and (k.endswith("：") or k.endswith(" ")) and not v.endswith(" "):
            print(f"  後ろの空白が無い  {keys[k]}  {k!r} → {v!r}")


if __name__ == "__main__":
    main()
