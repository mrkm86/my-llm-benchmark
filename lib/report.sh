#!/usr/bin/env bash
# report.sh — the run report.
#
# A result without its conditions cannot be compared to anything later, so the
# header is not optional: if a field cannot be filled it is written as "n/a"
# rather than left out.
#
# The report is a scratch artifact. What survives is one line in the catalog
# plus a short quote of how a stage broke — see docs/method.md.

report_header() {
  local f="$1"
  cat > "$f" <<EOF
# bench run — ${BENCH_MODEL}

| 条件 | 値 |
|---|---|
| model id | \`${BENCH_MODEL}\` |
| backend | ${BENCH_BACKEND} |
| digest | ${BENCH_DIGEST} |
| quantization | ${BENCH_QUANT} |
| weight (reported) | ${BENCH_WEIGHT} |
| temperature | ${BENCH_TEMPERATURE} |
| seed | ${BENCH_SEED} |
| context length | ${BENCH_NUM_CTX} |
| generation cap | ${BENCH_MAX_TOKENS} |
| system prompt | ${BENCH_SYSTEM_NOTE} |
| runs per scenario | ${BENCH_RUNS} |
| datetime | $(date '+%Y-%m-%d %H:%M:%S %Z') |
| hardware | $(/usr/sbin/sysctl -n hw.model 2>/dev/null) / $(/usr/sbin/sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f GB", $1/1073741824}') |
| bench version | ${BENCH_VERSION} |
| harness commit | $(harness_sha) |
| scenarios path | ${BENCH_SCENARIOS} |
| fixture version | $(fixture_sha "$BENCH_SCENARIOS") |
| memory at start | $(mem_snapshot) |
| gateway at start | ${BENCH_GATEWAY_START} |

## 結果

| 段 | 判定 | N回中何回 | 1本あたり秒 | 入力トークン | 切り詰め | 壊れ方 |
|---|---|---|---|---|---|---|
EOF
}

report_row() { printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$@" >> "$BENCH_REPORT"; }

report_footer() {
  {
    echo
    echo "## 実行中の監視"
    echo
    echo '```'
    tail -n 40 "$BENCH_MONITOR_LOG" 2>/dev/null || echo "(no samples)"
    echo '```'
    echo
    echo "gateway 生存確認（段ごと）:"
    echo
    echo '```'
    cat "$BENCH_SCRATCH/gateway.log" 2>/dev/null || echo "(none)"
    echo '```'
    [ -s "$BENCH_SCRATCH/abort.reason" ] && {
      echo
      echo "## ⚠️ 中断"
      echo
      echo "中断条件に当たったので自分で降りた: $(cat "$BENCH_SCRATCH/abort.reason")"
    }
    # 目視の呼び出し。合否ではないので表には出さず、ここで拾う。
    reviews=$(find "$BENCH_SCRATCH" -name 'REVIEW-REQUESTED' 2>/dev/null | head -5)
    if [ -n "$reviews" ]; then
      echo
      echo "## 👀 目視の呼び出し"
      echo
      for r in $reviews; do
        echo "- $(basename "$(dirname "$(dirname "$r")")"): $(cat "$r")"
      done
      echo
      echo "（合否は変えない。実際に見るのは**初めてその段を超えたモデルが出たとき**）"
    fi
    echo
    echo "---"
    echo "判定: 0=通過 / 1=失格 / 2=判断できない（人を呼ぶ） / 3=測れなかった"
  } >> "$BENCH_REPORT"
}
