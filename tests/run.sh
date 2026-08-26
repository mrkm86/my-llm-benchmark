#!/usr/bin/env bash
# tests/run.sh — the judges, tested against fixtures.
#
# Scenarios live outside this repo, so what is testable here is the judging
# itself: does a check fire when it should, and stay quiet when it should not.
#
# Every fixture that stands in for model output ends WITHOUT a trailing newline,
# because real model output does. That is not a detail — the bug this file was
# written for was exactly that (`grep -c` skips an unterminated last line, so a
# 3-paragraph answer counted as 2 and failed a min-3 check it had met).
#
#   bash tests/run.sh
#
# No network, no model, no ollama. Pure logic.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
PASS=0; FAIL=0

# NOTE: no full-width parentheses anywhere in these report paths. A full-width
# "(" immediately after $var is swallowed into the variable name by bash 3.2
# under a non-C locale, and the reporter dies with "unbound variable" while
# reporting someone else's failure. (BB-368)
ok() { PASS=$((PASS+1)); printf '  ok   - %s\n' "$1"; }
ng() { FAIL=$((FAIL+1)); printf '  NG   - %s\n' "$1"; }
sec() { printf '%s\n' "$1"; }

# run_judge <fn> <args...> — run one judge in a subshell and echo its verdict
# as "<rc>|<reasons>". Judges accumulate into arrays, so each call needs a fresh
# shell; that isolation is also what lets a judge that dies be reported as a
# failure instead of taking the test run down with it.
run_judge() {
  ( set +u
    source "$ROOT/lib/judge.sh"
    "$@" >/dev/null 2>&1
    out=$(judge_finish 2>&1); rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
  )
}

expect_rc() {  # expect_rc <want-rc> <label> <judge> <args...>
  local want="$1" label="$2"; shift 2
  local got; got=$(run_judge "$@")
  if [ "${got%%|*}" = "$want" ]; then
    ok "$label"
  else
    ng "$label -- want rc=$want, got $got"
  fi
}

# ---------------------------------------------------------------- 行数の数え方
sec '行数の数え方 - 末尾改行が無い最終行を数え落とさないこと'

# The regression itself. nonl.txt is one non-blank line with no trailing newline.
n=$(awk 'NF' "$FIX/nonl.txt" | wc -l | tr -d ' ')
[ "$n" = "1" ] && ok "末尾改行なし1行を 1 と数える" || ng "末尾改行なし1行を $n と数えた"

n=$(awk 'NF' "$FIX/three-para.txt" | wc -l | tr -d ' ')
[ "$n" = "3" ] && ok "末尾改行なし3段落を 3 と数える" || ng "末尾改行なし3段落を $n と数えた"

n=$(awk 'NF' "$FIX/blank-lines.txt" | wc -l | tr -d ' ')
[ "$n" = "2" ] && ok "空行・空白だけの行は数えない" || ng "空行を含めて $n と数えた"

# Why this is awk and not grep, recorded as an observation rather than an
# assertion: which `grep` answers depends on what is first in PATH, and the two
# on this machine disagree about a final line with no newline.
#
#   /usr/bin/grep  BSD grep 2.6.0-FreeBSD   -> 3   counts it
#   ugrep 7.5.0    first in the login PATH  -> 2   does not
#
# So the count silently changed with the shell the run happened to start from.
# Asserting a particular grep result here would just make this file fail on
# whichever machine has the other one. awk counts records and both agree on it.
old=$(grep -cve '^[[:space:]]*$' "$FIX/three-para.txt" || true)
sec "  [参考] $(command -v grep) は $old と数える / awk は 3。差が出る環境では旧実装が壊れる"

sec 'judge_min_lines / judge_max_lines'
expect_rc 0 "3段落は min 3 を通る"            judge_min_lines "$FIX/three-para.txt" 3
expect_rc 1 "3段落は min 4 で落ちる"          judge_min_lines "$FIX/three-para.txt" 4
expect_rc 0 "末尾改行なし1行は min 1 を通る"  judge_min_lines "$FIX/nonl.txt" 1
expect_rc 1 "1行は min 3 で落ちる"            judge_min_lines "$FIX/nonl.txt" 3
expect_rc 0 "3段落は max 3 を通る"            judge_max_lines "$FIX/three-para.txt" 3
expect_rc 1 "3段落は max 2 で落ちる"          judge_max_lines "$FIX/three-para.txt" 2

sec 'judge_nonempty'
expect_rc 0 "中身があれば通る" judge_nonempty "$FIX/nonl.txt"
expect_rc 1 "空ファイルは落ちる" judge_nonempty "$FIX/empty.txt"

sec 'judge_forbidden'
expect_rc 1 "禁止パターンに当たれば落ちる"       judge_forbidden "$FIX/forbidden-hit.txt"  "$FIX/patterns.txt"
expect_rc 0 "当たらなければ通る"                 judge_forbidden "$FIX/three-para.txt"     "$FIX/patterns.txt"
expect_rc 0 "パターンファイルが無ければ通る"     judge_forbidden "$FIX/three-para.txt"     "$FIX/no-such-file.txt"
# a hit on the very last line, which has no trailing newline
expect_rc 1 "末尾改行なしの最終行の違反も拾う"   judge_forbidden "$FIX/forbidden-lastline.txt" "$FIX/patterns.txt"

sec 'judge_json / judge_json_fields'
expect_rc 0 "正しい JSON は通る"       judge_json "$FIX/valid.json"
expect_rc 1 "壊れた JSON は落ちる"     judge_json "$FIX/broken.json"
expect_rc 0 "期待どおりの値なら通る"   judge_json_fields "$FIX/valid.json"     "$FIX/expected.json"
expect_rc 1 "値が違えば落ちる"         judge_json_fields "$FIX/wrong.json"     "$FIX/expected.json"
expect_rc 1 "キーが空文字なら落ちる"   judge_json_fields "$FIX/empty-field.json" "$FIX/expected.json"

sec 'judge_numbers_subset - 出典に無い数字を作らないこと'
expect_rc 0 "出典にある数字だけなら通る" judge_numbers_subset "$FIX/numbers-ok.txt"  "$FIX/source.txt"
expect_rc 1 "出典に無い数字は落ちる"     judge_numbers_subset "$FIX/numbers-bad.txt" "$FIX/source.txt"

sec 'judge_japanese'
expect_rc 0 "日本語なら通る"     judge_japanese "$FIX/three-para.txt"
expect_rc 1 "英語だけなら落ちる" judge_japanese "$FIX/english.txt"

sec 'judge_undecidable - 判断できないは 1 ではなく 2'
expect_rc 2 "人を呼ぶときは rc=2" judge_undecidable "見ないと分からない"

sec 'fixture 自体の前提'
for f in nonl.txt three-para.txt forbidden-lastline.txt numbers-ok.txt; do
  if [ -n "$(tail -c 1 "$FIX/$f")" ]; then
    ok "$f は末尾改行なし - 実際のモデル出力と同じ形"
  else
    ng "$f に末尾改行が付いてしまっている - この回帰を守れない"
  fi
done

printf '\npass: %d / NG: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
