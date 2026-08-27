#!/usr/bin/env python3
"""$var の直後に全角括弧が来ていないことを確認する（BB-368 / BB-375）。

bash 3.2 は C 以外のロケールだと `$pl）` の全角括弧を**変数名に吸い込む**。
`set -u` の下では unbound variable で即死する。しかも死ぬのは、その文字列を
組み立てる条件が揃ったときだけ — 例えば「メモリプレッシャーが warn になったとき」
のように、**普段は通るが本番の忙しい機械でだけ踏む**。

⚠️ この検査を grep で書かないこと。`[（）]` は多バイト文字の**ブラケット**なので、
   ロケールが C だと grep がバイト単位で解釈し、黙って何も拾わなくなる。
"""
import re, sys, pathlib

PAT = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*[（）]")
bad = []
for root in sys.argv[1:]:
    for path in sorted(pathlib.Path(root).rglob("*.sh")):
        if ".git" in path.parts:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for n, line in enumerate(text.splitlines(), 1):
            # コメント行は実行されないので見逃す（この検査自身の説明文が引っかかるため）
            if line.lstrip().startswith("#"):
                continue
            if PAT.search(line):
                bad.append(f"{path}:{n}: {line.strip()[:90]}")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
