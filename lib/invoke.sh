#!/usr/bin/env bash
# invoke.sh — the only place that talks to a model.
#
# Scenarios call this, never a backend directly. That is what keeps a scenario
# portable across ollama / anchor without growing per-backend branches inside it.
#
# Usage:
#   invoke.sh --model <id> --prompt <file> [--system <file>] [--out <file>]
#             [--meta <file>] [--temperature 0] [--seed 42] [--num-ctx 8192]
#             [--max-tokens 1024]
#
# Model id:
#   ollama:<tag>   or bare <tag>   -> local ollama at OLLAMA_HOST
#   anchor:<id>    (e.g. anchor:claude-opus-5) -> the cloud model we run today.
#                  The anchor exists to prove the problem design, not the model:
#                  if the anchor fails a stage, the stage is broken.
#
# Writes the completion to --out and a JSON sidecar to --meta with the fields a
# result header must carry (elapsed, prompt/eval token counts, truncation).
set -uo pipefail

OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
MODEL=""; PROMPT=""; SYSTEM=""; OUT=""; META=""
TEMPERATURE="${BENCH_TEMPERATURE:-0}"; SEED="${BENCH_SEED:-42}"
NUM_CTX="${BENCH_NUM_CTX:-8192}"; MAX_TOKENS="${BENCH_MAX_TOKENS:-1024}"

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --system) SYSTEM="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --meta) META="$2"; shift 2 ;;
    --temperature) TEMPERATURE="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --num-ctx) NUM_CTX="$2"; shift 2 ;;
    --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
    *) echo "invoke.sh: unknown arg $1" >&2; exit 64 ;;
  esac
done
[ -n "$MODEL" ] && [ -n "$PROMPT" ] || { echo "invoke.sh: --model and --prompt are required" >&2; exit 64; }
OUT="${OUT:-/dev/stdout}"

SYS_TEXT=""
[ -n "$SYSTEM" ] && [ -f "$SYSTEM" ] && SYS_TEXT=$(cat "$SYSTEM")

start=$(date +%s)

if [ "${MODEL#anchor:}" != "$MODEL" ]; then
  # ---- anchor backend -------------------------------------------------------
  anchor_id="${MODEL#anchor:}"
  command -v claude >/dev/null || { echo "invoke.sh: claude CLI not found (anchor)" >&2; exit 69; }
  if [ -n "$SYS_TEXT" ]; then
    printf '%s\n\n---\n\n' "$SYS_TEXT" | cat - "$PROMPT" > "${PROMPT}.anchor"
    claude -p --model "$anchor_id" < "${PROMPT}.anchor" > "$OUT" 2>/dev/null
    rc=$?; rm -f "${PROMPT}.anchor"
  else
    claude -p --model "$anchor_id" < "$PROMPT" > "$OUT" 2>/dev/null; rc=$?
  fi
  elapsed=$(( $(date +%s) - start ))
  # the anchor CLI does not expose token counts; approximate from characters so
  # the field is never silently absent (marked as approximate in the sidecar).
  pchars=$(wc -c < "$PROMPT" | tr -d ' ')
  [ -n "$META" ] && cat > "$META" <<EOF
{"backend":"anchor","model":"$anchor_id","elapsed_sec":$elapsed,
 "prompt_tokens":null,"prompt_chars":$pchars,"eval_tokens":null,
 "temperature":"n/a (anchor default)","seed":"n/a","num_ctx":"n/a",
 "max_tokens":"n/a","truncated":false,"token_counts":"approximate: chars only","exit":$rc}
EOF
  exit $rc
fi

# ---- ollama backend ---------------------------------------------------------
tag="${MODEL#ollama:}"
payload=$(PROMPT_FILE="$PROMPT" SYS="$SYS_TEXT" TAG="$tag" T="$TEMPERATURE" S="$SEED" \
          C="$NUM_CTX" M="$MAX_TOKENS" python3 -c '
import json, os
p = open(os.environ["PROMPT_FILE"]).read()
body = {"model": os.environ["TAG"], "prompt": p, "stream": False,
        "options": {"temperature": float(os.environ["T"]), "seed": int(os.environ["S"]),
                    "num_ctx": int(os.environ["C"]), "num_predict": int(os.environ["M"])}}
if os.environ.get("SYS"): body["system"] = os.environ["SYS"]
print(json.dumps(body))')

resp=$(curl -s --max-time 900 "$OLLAMA_HOST/api/generate" -d "$payload")
rc=$?
elapsed=$(( $(date +%s) - start ))

if [ $rc -ne 0 ] || [ -z "$resp" ]; then
  echo "invoke.sh: ollama request failed (rc=$rc)" >&2
  [ -n "$META" ] && echo "{\"backend\":\"ollama\",\"model\":\"$tag\",\"error\":\"request failed\",\"exit\":$rc}" > "$META"
  exit 70
fi

RESP="$resp" OUT_F="$OUT" META_F="${META:-/dev/null}" TAG="$tag" ELAPSED="$elapsed" \
T="$TEMPERATURE" S="$SEED" C="$NUM_CTX" M="$MAX_TOKENS" python3 -c '
import json, os
r = json.loads(os.environ["RESP"])
open(os.environ["OUT_F"], "w").write(r.get("response", ""))
ctx = int(os.environ["C"]); pt = r.get("prompt_eval_count")
meta = {"backend": "ollama", "model": os.environ["TAG"],
        "elapsed_sec": int(os.environ["ELAPSED"]),
        "prompt_tokens": pt, "eval_tokens": r.get("eval_count"),
        "temperature": float(os.environ["T"]), "seed": int(os.environ["S"]),
        "num_ctx": ctx, "max_tokens": int(os.environ["M"]),
        # ollama silently drops the head of an over-long prompt: flag it so a
        # bad result is read as "input was cut", not as "the model is weak".
        "truncated": bool(pt is not None and pt >= ctx),
        "done_reason": r.get("done_reason"),
        "total_duration_ns": r.get("total_duration")}
open(os.environ["META_F"], "w").write(json.dumps(meta, ensure_ascii=False, indent=2))'
