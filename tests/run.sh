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
#   ./tests/run.sh        bash / zsh どちらから起動しても通る
#
# No network, no model, no ollama. Pure logic.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
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

sec 'judge_min_chars - 行数では分量を測れないので文字数で見る'
# three-para.txt is 3 paragraphs but short: it clears a paragraph floor and
# should still fail a volume floor. That gap is the whole reason this exists.
expect_rc 0 "3段落は min 3 行を通る"       judge_min_lines "$FIX/three-para.txt" 3
expect_rc 1 "その3段落は min 200 字で落ちる" judge_min_chars "$FIX/three-para.txt" 200
expect_rc 0 "十分な分量なら通る"           judge_min_chars "$FIX/long-enough.txt" 200
# Characters, not bytes, regardless of locale. LANG is deliberately cleared here:
# that is how a cron or detached job arrives, and it is the case where `wc -m`
# silently switches to counting bytes and inflates Japanese roughly 3x.
n=$(env -u LANG -u LC_ALL bash -c "source '$ROOT/lib/judge.sh'; count_chars '$FIX/three-para.txt'")
b=$(wc -c < "$FIX/three-para.txt" | tr -d ' ')
wcm=$(env -u LANG -u LC_ALL wc -m < "$FIX/three-para.txt" | tr -d ' ')
if [ "$n" -lt "$b" ]; then
  ok "LANG 無しでも文字数を返す -- $n 字 / $b バイト"
else
  ng "LANG 無しでバイト数になった -- $n"
fi
if [ "$wcm" = "$b" ]; then
  sec "  [参考] LANG 無しの wc -m は $wcm を返す -- バイト数と同じ。だから使っていない"
fi

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

sec 'clip - 報告文の切り詰めは文字単位（バイトではない）'

# 直した回帰そのもの。`cut -c` / `printf '%.Ns'` はロケール次第でバイト単位に落ち、
# 日本語を多バイトの途中で切る。判定は変わらないので、報告文だけが静かに化ける。
# 現物の引用がこのベンチの土台なので、土台のほうが壊れていた。(BB-375)
# clip は判定器の一部なので judge.sh から取る（ここだけ関数を直接使う）
source "$ROOT/lib/judge.sh"
source "$ROOT/lib/common.sh"
JP=$(cat "$FIX/japanese.txt")

got=$(printf '%s' "$JP" | clip 5)
[ "$got" = "理由：この" ] && ok "先頭5文字を返す" || ng "先頭5文字を返す（実際 ${got}）"

got=$(env -u LANG -u LC_ALL -u LC_CTYPE bash -c "source '$ROOT/lib/judge.sh'; printf '%s' '$JP' | clip 5")
[ "$got" = "理由：この" ] && ok "LANG が無くても文字単位（cron と同じ条件）" || ng "LANG が無いと化ける（実際 ${got}）"

got=$(printf '%s' "$JP" | clip 100)
[ "$got" = "$JP" ] && ok "n が長さを超えても壊さない" || ng "n が長さを超えても壊さない"

# 切った断片が「入力に実在するか」の照合に使われる（002 の捏造判定）。
# バイトで切ると壊れた断片ができ、UTF-8 ロケールの grep が illegal byte sequence で
# 落ちて、正しいタイトルが「捏造」と誤判定される。
needle=$(printf '%s' "$JP" | clip 7)
# ⚠️ 空の needle は grep -F が必ず当たる＝この検査が黙って無意味になる。先に潰す。
if [ -z "$needle" ]; then
  ng "clip が空を返した - 照合の検査が成立していない"
elif grep -qF -- "$needle" "$FIX/japanese.txt" 2>/dev/null; then
  ok "切った断片が grep -F で照合できる - 捏造の誤判定が起きない"
else
  ng "切った断片が grep -F で照合できない - 正しい値を捏造扱いにする"
fi

sec 'scenario_verdict - 壊れた判定器をモデルのせいにしない'

# 実際に踏んだ形: 判定器に構文エラーを入れてしまい、bash が **何も実行しないまま
# rc=1** で死んだ。理由が1つも出ていない rc=1 は「失格」ではなく
# 「測れなかった」。ここを分けないと、レポートが「失格・理由なし」という
# もっともらしい顔で出てくる。(BB-375)
[ "$(scenario_verdict 0 '')" = 0 ] && ok "rc=0 は通過" || ng "rc=0 は通過"
[ "$(scenario_verdict 1 'DISQUALIFIED: x')" = 1 ] && ok "理由のある rc=1 は失格" || ng "理由のある rc=1 は失格"
[ "$(scenario_verdict 1 '')" = 3 ] && ok "理由の無い rc=1 は測れなかった扱い" || ng "理由の無い rc=1 を失格にしている"
[ "$(scenario_verdict 1 '   ')" = 3 ] && ok "空白だけの出力も測れなかった扱い" || ng "空白だけの出力を失格にしている"
[ "$(scenario_verdict 2 'UNDECIDABLE: x')" = 2 ] && ok "rc=2 は人を呼ぶ" || ng "rc=2 は人を呼ぶ"

printf '\npass: %d / NG: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
