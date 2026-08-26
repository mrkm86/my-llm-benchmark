#!/usr/bin/env bash
# NNN-name — one run of this stage.
#
# bench.sh calls this once per run with:
#   BENCH_SCENARIO_DIR  this directory
#   BENCH_RUN_DIR       scratch for this run (write artifacts here)
#   BENCH_RUN           run index (1..N)
#   BENCH_MODEL         model id
#   BENCH_INVOKE        the only sanctioned way to call a model
#   BENCH_LIB           library dir (judge.sh lives here)
#
# Exit: 0 pass / 1 disqualified / 2 undecidable (a human is called) / 3 not measurable
set -uo pipefail
source "$BENCH_LIB/judge.sh"

SD="$BENCH_SCENARIO_DIR"; RD="$BENCH_RUN_DIR"

for case_dir in "$SD"/cases/*/; do
  [ -f "$case_dir/input.txt" ] || continue
  name=$(basename "$case_dir")

  bash "$BENCH_INVOKE" --model "$BENCH_MODEL" \
    --prompt "$case_dir/input.txt" \
    --system "$SD/system.txt" \
    --out "$RD/$name.out" --meta "$RD/$name.meta.json" || { judge_fail "$name: invocation failed"; continue; }

  # --- disqualifiers ---------------------------------------------------------
  judge_nonempty      "$RD/$name.out"
  judge_forbidden     "$RD/$name.out" "$SD/disqualifiers.patterns"
  # judge_max_lines   "$RD/$name.out" 3
  # judge_json_fields "$RD/$name.out" "$SD/expected/$name.json"
done

judge_finish
