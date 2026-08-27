#!/usr/bin/env bash
# 002 — one passage in, a 3-line Japanese summary out.
#
# **No answer key here, on purpose.** A summary has no single right answer, and a
# key would fail a model that wrote something better than the key
# (that is exactly how the retired 001-scout-filter broke). Instead: a floor
# (facts that must survive) plus disqualifiers (form, language, invented numbers).
set -uo pipefail
source "$BENCH_LIB/judge.sh"
SD="$BENCH_SCENARIO_DIR"; RD="$BENCH_RUN_DIR"

for c in "$SD"/cases/*/; do
  name=$(basename "$c")
  bash "$BENCH_INVOKE" --model "$BENCH_MODEL" --prompt "$c/input.txt" \
    --system "$SD/system.txt" --max-tokens 400 \
    --out "$RD/$name.out" --meta "$RD/$name.meta.json" \
    || { judge_fail "$name: invocation failed"; continue; }

  judge_nonempty       "$RD/$name.out"
  judge_max_lines      "$RD/$name.out" 3
  judge_japanese       "$RD/$name.out"
  judge_covers_all     "$RD/$name.out" "$c/must-cover.txt"
  judge_not_echo       "$RD/$name.out" "$c/input.txt"
  judge_forbidden      "$RD/$name.out" "$SD/disqualifiers.patterns"
  judge_numbers_subset "$RD/$name.out" "$c/source.txt"
done
judge_finish
