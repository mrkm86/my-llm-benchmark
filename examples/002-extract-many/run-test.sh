#!/usr/bin/env bash
# 003 — three passages in, a JSON array out. **Same capability as 001, at scale.**
# The rung above 001 is not "harder facts" but "do not drop one".
set -uo pipefail
source "$BENCH_LIB/judge.sh"
SD="$BENCH_SCENARIO_DIR"; RD="$BENCH_RUN_DIR"

for c in "$SD"/cases/*/; do
  name=$(basename "$c")
  bash "$BENCH_INVOKE" --model "$BENCH_MODEL" --prompt "$c/input.txt" \
    --system "$SD/system.txt" --max-tokens 800 \
    --out "$RD/$name.raw" --meta "$RD/$name.meta.json" \
    || { judge_fail "$name: invocation failed"; continue; }

  strip_fences "$RD/$name.raw" > "$RD/$name.out"
  judge_json              "$RD/$name.out"
  judge_json_array_fields "$RD/$name.out" "$c/expected.json"
done
judge_finish
