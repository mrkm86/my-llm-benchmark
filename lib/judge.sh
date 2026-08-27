#!/usr/bin/env bash
# judge.sh — disqualifier checks. Source this from a scenario's run-test.sh.
#
# Stages 003+ have no single right answer, so we do not score them. We list what
# must not happen and check for those. Every check here is mechanical; anything
# that needs a human eye must go through judge_undecidable, which stops the run
# and asks. A judge that guesses is worse than a judge that says "I can't tell".
#
# Verdicts:  0 = pass   1 = fail (disqualified)   2 = undecidable (call a human)
#            3 = could-not-measure (never say "failed" when we never ran it)

# clip <n> — stdin の先頭 n **文字**（バイトではない）を返す。
#
# `cut -c` も `printf '%.Ns'` も、ロケール次第で**バイト単位**に落ちる。LANG の無い
# 環境（cron / ryoko job）では日本語が多バイトの途中で切られ、報告文だけが静かに
# 文字化けする。判定は変わらないので誰も気づけない。現物の引用がこのベンチの土台
# なので、土台のほうが壊れる。(BB-375)
clip() {
  python3 -c 'import sys
n = int(sys.argv[1])
sys.stdout.write(sys.stdin.buffer.read().decode("utf-8", "replace")[:n])' "$1"
}

# normalize_answer <file> — 単答（yes/no）の比較用。空白・引用符・句読点を落として小文字化。
#
# ⚠️ ここを `tr -d` でやらないこと。BSD の tr は削除セットを**バイト**で扱うので、
#    「、。」を渡すと 0xE3/0x80/0x81/0x82 を全部消す＝ひらがな・カタカナが丸ごと壊れる。
#    先頭が ASCII なら判定は変わらないため、報告文だけが静かに化ける。(BB-375)
#
# Python コード内に ' を書かない（\x27 で表す）。bash 3.2 は $( ) の中の
# ヒアドキュメントに ' が入ると閉じ括弧を見失う。
normalize_answer() {
  python3 -c 'import re, sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read()
sys.stdout.write(re.sub(r"[\s\"\x27.\u3001\u3002]", "", t).lower())' "$1"
}

JUDGE_REASONS=()
JUDGE_UNDECIDABLE=()

judge_fail()        { JUDGE_REASONS+=("$1"); }
judge_undecidable() { JUDGE_UNDECIDABLE+=("$1"); }

judge_finish() {
  if [ "${#JUDGE_UNDECIDABLE[@]}" -gt 0 ]; then
    printf 'UNDECIDABLE: %s\n' "${JUDGE_UNDECIDABLE[@]}"
    return 2
  fi
  if [ "${#JUDGE_REASONS[@]}" -gt 0 ]; then
    printf 'DISQUALIFIED: %s\n' "${JUDGE_REASONS[@]}"
    return 1
  fi
  echo "PASS"
  return 0
}

judge_nonempty() {
  [ -s "$1" ] || judge_fail "output is empty"
}

# judge_silent <file> — 「何も言わないこと」が正解の段で使う。
# ⚠️ **`examples/` のどの段も、いまはこれを使っていない**（使っていた段は撤去した）。
# 道具として残してある。テストは tests/run.sh にある。
#
# 空、または NO_REPLY だけ（前後の空白は許す）なら合格。**それ以外は1文字でも失格。**
# 「確認しました。正常です ✅」を通してしまうと、この段は何も測れなくなる
# — 通知先に毎回1行流れることこそが、この段が防ごうとしている故障だから。
judge_silent() {
  local body
  body=$(python3 -c 'import re,sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read()
sys.stdout.write(re.sub(r"\s+", "", t))' "$1")
  case "$body" in
    ''|'NO_REPLY') : ;;
    *) judge_fail "silence expected, but said: $(printf '%s' "$body" | clip 60)" ;;
  esac
}

# count_nonblank <file> — non-blank lines.
#
# ⚠️ Not `grep -cve '^[[:space:]]*$'`. BSD grep does not count a final line that
# has no trailing newline, and model output routinely ends without one (the last
# byte is mid-multibyte). That silently undercounts by one: a 3-paragraph answer
# reads as 2 and fails a min-3 check it actually met. awk counts records, so it
# sees the unterminated last line. (BB-374; same family as the BB-368 locale bug.)
count_nonblank() { awk 'NF' "$1" | wc -l | tr -d ' '; }

# judge_max_lines <file> <n> — non-blank lines
judge_max_lines() {
  local n; n=$(count_nonblank "$1")
  [ "$n" -le "$2" ] || judge_fail "output has $n non-blank lines (max $2)"
}

judge_min_lines() {
  local n; n=$(count_nonblank "$1")
  [ "$n" -ge "$2" ] || judge_fail "output has $n non-blank lines (min $2)"
}

# count_chars <file> — characters, not bytes.
#
# ⚠️ Not `wc -m`. It is locale-dependent: with LANG unset — which is how cron and
# detached job runs arrive — it falls back to counting bytes, and Japanese comes
# out roughly 3x too large. A threshold picked interactively would then mean
# something entirely different when the same command ran unattended. python3
# decodes UTF-8 the same way everywhere. (BB-374; third of the same family after
# the BB-368 locale bug and the grep line-count split.)
count_chars() {
  python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8", errors="replace").read()))' "$1"
}

# judge_min_chars <file> <n>
#
# Line count says whether the text was broken into paragraphs; it says nothing
# about whether anything was written. A model can clear a paragraph floor with
# three one-sentence lines. Where a stage is really asking "is there enough
# here", count characters — it does not care how the model happens to wrap.
judge_min_chars() {
  local n; n=$(count_chars "$1")
  [ "$n" -ge "$2" ] || judge_fail "output has $n characters (min $2)"
}

# judge_forbidden <file> <patterns-file>
# patterns-file: one ERE per line; "# " comments and blank lines ignored;
# an optional "<pattern>\t<label>" second column names the rule in the reason.
judge_forbidden() {
  local out="$1" pf="$2" pat label
  [ -f "$pf" ] || return 0
  while IFS=$'\t' read -r pat label; do
    case "$pat" in ''|'#'*) continue ;; esac
    if grep -Eq -- "$pat" "$out"; then
      judge_fail "forbidden pattern hit: ${label:-$pat}"
    fi
  done < "$pf"
}

# strip_fences <file> — write the JSON body to stdout, unwrapping a ```json
# fence and any surrounding prose. Handles both objects and arrays.
#
# Wrapping JSON in a fence is a packaging habit, not a correctness failure, so it
# is stripped rather than disqualified. **Prose before the JSON is stripped too**
# — it is the "I will now output JSON" preamble that several models add, and it
# is the same failure this bench saw a large cloud model make in production.
strip_fences() {
  python3 - "$1" <<'PYEOF'
import re, sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r"```(?:json)?\s*(.*?)```", t, re.S)
if m:
    t = m.group(1)
m = re.search(r"[\[{].*[\]}]", t, re.S)
sys.stdout.write(m.group(0) if m else t)
PYEOF
}

judge_json() {
  python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$1" 2>/dev/null \
    || judge_fail "output is not valid JSON"
}

# _judge_norm — JSON の値どうしを比べるための正規化コード（python として exec する）。
#
# **単複と大文字小文字を不合格にしない。** `centimeters` を `centimeter` と書いた答えを
# 落とすと、測っているのは値の正しさではなく英語の語形になる。実測で qwen2.5:1.5b が
# これだけで 0/3 になり、**抽出できているのに落ちた**という誤った記録が出た。
# 数値は表記差（5 と "5"、1.0 と 1）も吸収する。
_judge_norm() {
  cat <<'NORMEOF'
def norm(v):
    if v is None: return "none"
    if isinstance(v, bool): return str(v).lower()
    if isinstance(v, (int, float)):
        f = float(v)
        return str(int(f)) if f == int(f) else str(f)
    t = str(v).strip().lower()
    try:
        f = float(t)
        return str(int(f)) if f == int(f) else str(f)
    except ValueError:
        pass
    return t[:-1] if t.endswith("s") and len(t) > 3 else t
NORMEOF
}

# judge_json_fields <file> <expected.json> — every key in expected must match
judge_json_fields() {
  local msg
  msg=$(python3 - "$1" "$2" "$(_judge_norm)" <<'JF'
import json, sys
exec(sys.argv[3])
try:
    got = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print(f"unparseable JSON ({e})"); sys.exit(0)
want = json.load(open(sys.argv[2], encoding="utf-8"))
bad = [f"{k}: expected {v!r}, got {got.get(k)!r}" for k, v in want.items()
       if norm(got.get(k)) != norm(v)]
print("; ".join(bad))
JF
)
  [ -z "$msg" ] || judge_fail "$msg"
}
# judge_json_array_fields <file> <expected.json> — the output must be a JSON
# array of the same length, and every key in each expected object must match
# the object at the same index.
#
# **件数が合っていることを先に見る。** 3件のうち1件を落としても、残った2件が
# 正しければ「一致」になる judge を書くと、004 で見た「やり切れない」落ち方
# （中身は出るが最後まで届かない）を素通りさせる。
judge_json_array_fields() {
  local msg
  msg=$(python3 - "$1" "$2" "$(_judge_norm)" <<'JA'
import json, sys
exec(sys.argv[3])
try:
    got = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print(f"unparseable JSON ({e})"); sys.exit(0)
want = json.load(open(sys.argv[2], encoding="utf-8"))
if not isinstance(got, list):
    print(f"expected a JSON array, got {type(got).__name__}"); sys.exit(0)
if len(got) != len(want):
    print(f"expected {len(want)} objects, got {len(got)}"); sys.exit(0)
bad = []
for i, (g, w) in enumerate(zip(got, want)):
    if not isinstance(g, dict):
        bad.append(f"[{i}] not an object"); continue
    for k, v in w.items():
        if norm(g.get(k)) != norm(v):
            bad.append(f"[{i}] {k}: expected {v!r}, got {g.get(k)!r}")
print("; ".join(bad))
JA
)
  [ -z "$msg" ] || judge_fail "$msg"
}
# judge_numbers_subset <output> <source> — every number in the output must
# appear in the source. Fabricated figures are the failure mode that survives a
# read-through, so it is worth checking mechanically even though it is crude.
judge_numbers_subset() {
  local msg
  msg=$(python3 - "$1" "$2" <<'PY'
import re, sys
num = lambda p: set(re.findall(r'\d[\d,.]*', open(p, encoding="utf-8", errors="replace").read().replace(',', '')))
extra = sorted(num(sys.argv[1]) - num(sys.argv[2]))
print(", ".join(extra[:5]))
PY
)
  [ -z "$msg" ] || judge_fail "numbers not present in the source: $msg"
}

# judge_japanese <file> [min_ratio] — the output must actually be Japanese
judge_japanese() {
  local r; r=$(python3 - "$1" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read()
j = len(re.findall(r'[ぁ-んァ-ヶ一-龠]', t))
print(f"{j/max(len(t.strip()),1):.2f}")
PY
)
  awk -v r="$r" -v m="${2:-0.15}" 'BEGIN{exit !(r+0 < m+0)}' \
    && judge_fail "output does not look Japanese (CJK ratio $r)"
  return 0
}

# judge_ascii_ratio <file> <max_ratio> <min_chars>
# Ported check: a line long enough to be a real sentence but made of ASCII words
# is an untranslated leftover. min_chars guards against acronym false positives.
judge_ascii_ratio() {
  local hit; hit=$(python3 - "$1" "$2" "$3" <<'PY'
import re, sys
maxr, minc = float(sys.argv[2]), int(sys.argv[3])
bad = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    s = line.strip()
    if len(s) < minc: continue
    letters = re.sub(r'[^A-Za-z぀-ヿ一-鿿]', '', s)
    if not letters: continue
    ratio = sum(c.isascii() for c in letters) / len(letters)
    if ratio >= maxr: bad.append(f"{s[:40]} (ascii {ratio:.2f})")
print(" | ".join(bad[:3]))
PY
)
  [ -z "$hit" ] || judge_fail "looks untranslated: $hit"
}

# judge_covers_all <output> <keys-file> — one required key per line
# judge_not_echo <out> <input> — 入力を書き写しただけの答えを落とす。
#
# judge_covers_all は「必要な語が入っているか」しか見ない。**必要な語が入力に書いてある**
# 場合、入力をそのまま貼り返すだけで満点になる（006 の初版で実際にそうなった。
# Granite4 3B が ❌ 行をそのまま返して合格していた）。空振りするテストは、
# 無いテストより悪い — 通っている限り誰も見に行かないから。
#
# 判定: 出力の非空行のうち、**8文字以上のもの**が入力にそのまま含まれていたら失格。
# 短い行は定型句（「NO_REPLY」等）と区別できないので見ない。
judge_not_echo() {
  local out="$1" src="$2" line
  # `|| [ -n "$line" ]` が要る。**モデル出力は末尾改行が無い**ので、素の read だと
  # 最終行が落ちる。1行だけの答えは丸ごと素通りして、この判定が何も見なくなる
  # （このファイルの count_nonblank と同じ穴を、自分で掘った）。
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    [ "$(printf '%s' "$line" | wc -c | tr -d ' ')" -lt 24 ] && continue
    if grep -qF -- "$line" "$src"; then
      judge_fail "echoed the input verbatim: $(printf '%s' "$line" | clip 40)"
      return
    fi
  done < "$out"
}

judge_covers_all() {
  local missing=() key
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    grep -qF -- "$key" "$1" || missing+=("$key")
  done < "$2"
  [ "${#missing[@]}" -eq 0 ] || judge_fail "not covered: ${missing[*]}"
}
