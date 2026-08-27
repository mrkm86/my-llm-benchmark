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

judge_json() {
  python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$1" 2>/dev/null \
    || judge_fail "output is not valid JSON"
}

# judge_json_fields <file> <expected.json> — every key in expected must match
judge_json_fields() {
  local msg
  msg=$(python3 - "$1" "$2" <<'PY'
import json, sys
try:
    got = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print(f"unparseable JSON ({e})"); sys.exit(0)
want = json.load(open(sys.argv[2], encoding="utf-8"))
bad = [f"{k}: expected {v!r}, got {got.get(k)!r}" for k, v in want.items()
       if str(got.get(k, "")).strip() != str(v).strip()]
print("; ".join(bad))
PY
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
judge_covers_all() {
  local missing=() key
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    grep -qF -- "$key" "$1" || missing+=("$key")
  done < "$2"
  [ "${#missing[@]}" -eq 0 ] || judge_fail "not covered: ${missing[*]}"
}
