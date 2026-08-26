#!/usr/bin/env bash
# 000-hello — 配線確認。ケースごとに行数上限が違うので個別に当てる。
set -uo pipefail
source "$BENCH_LIB/judge.sh"
SD="$BENCH_SCENARIO_DIR"; RD="$BENCH_RUN_DIR"

run_case() { # <name> <max_lines>
  local name="$1" max="$2"
  bash "$BENCH_INVOKE" --model "$BENCH_MODEL" \
    --prompt "$SD/cases/$name/input.txt" --system "$SD/system.txt" \
    --out "$RD/$name.out" --meta "$RD/$name.meta.json" \
    || { judge_fail "$name: invocation failed"; return; }
  judge_nonempty  "$RD/$name.out"
  judge_japanese  "$RD/$name.out"
  judge_max_lines "$RD/$name.out" "$max"
  judge_forbidden "$RD/$name.out" "$SD/disqualifiers.patterns"
}

run_case capital 1
run_case three-lines 3
judge_finish
