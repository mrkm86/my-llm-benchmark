#!/usr/bin/env bash
# bench.sh — run one model against a set of scenarios and report how far it got.
#
#   bash bench.sh --scenarios <dir> --model <id> [--runs 3]
#
# The framework does not ship scenarios. It is handed a directory. That is the
# whole trust boundary: real cases live outside this repo, so nothing anyone
# forgets to gitignore can leak in here.
#
# See docs/method.md for why it runs three times, why an anchor goes first, and
# when to cut a new version.
set -uo pipefail

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BENCH_ROOT/lib/common.sh"
source "$BENCH_ROOT/lib/preflight.sh"
source "$BENCH_ROOT/lib/judge.sh"
source "$BENCH_ROOT/lib/report.sh"

BENCH_SCENARIOS=""; BENCH_MODEL=""; BENCH_RUNS=3
BENCH_TEMPERATURE=0; BENCH_SEED=42; BENCH_NUM_CTX=8192; BENCH_MAX_TOKENS=1024
BENCH_ONLY=""; BENCH_SCRATCH=""; BENCH_WEIGHT_GB=""; SKIP_PREFLIGHT=0

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --scenarios <dir>   directory of NNN-name/ scenario dirs (required)
  --model <id>        ollama tag, ollama:<tag>, or anchor:<cloud-model-id>
  --runs <n>          runs per scenario (default 3; a stage passes only if all pass)
  --only <prefix>     run just the scenarios whose dir starts with this
  --temperature <t>   default 0
  --seed <n>          default 42
  --num-ctx <n>       default 8192
  --max-tokens <n>    default 1024
  --weight-gb <n>     expected weight; preflight requires weight * 1.3 free
  --scratch <dir>     where run artifacts go (default: mktemp; deleted by you, not kept)
  --skip-preflight    only for non-local models / debugging
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --scenarios) BENCH_SCENARIOS="$2"; shift 2 ;;
    --model) BENCH_MODEL="$2"; shift 2 ;;
    --runs) BENCH_RUNS="$2"; shift 2 ;;
    --only) BENCH_ONLY="$2"; shift 2 ;;
    --temperature) BENCH_TEMPERATURE="$2"; shift 2 ;;
    --seed) BENCH_SEED="$2"; shift 2 ;;
    --num-ctx) BENCH_NUM_CTX="$2"; shift 2 ;;
    --max-tokens) BENCH_MAX_TOKENS="$2"; shift 2 ;;
    --weight-gb) BENCH_WEIGHT_GB="$2"; shift 2 ;;
    --scratch) BENCH_SCRATCH="$2"; shift 2 ;;
    --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (--help)" ;;
  esac
done

[ -n "$BENCH_SCENARIOS" ] || { usage; die "--scenarios is required"; }
[ -n "$BENCH_MODEL" ] || { usage; die "--model is required"; }
[ -d "$BENCH_SCENARIOS" ] || die "no such scenarios directory: $BENCH_SCENARIOS"
BENCH_SCENARIOS="$(cd "$BENCH_SCENARIOS" && pwd)"

BENCH_SCRATCH="${BENCH_SCRATCH:-$(mktemp -d "${TMPDIR:-/tmp}/bench-XXXXXX")}"
mkdir -p "$BENCH_SCRATCH"
BENCH_REPORT="$BENCH_SCRATCH/report.md"
BENCH_MONITOR_LOG="$BENCH_SCRATCH/monitor.log"
BENCH_ABORT="$BENCH_SCRATCH/abort.reason"
export BENCH_ROOT BENCH_SCENARIOS BENCH_MODEL BENCH_TEMPERATURE BENCH_SEED \
       BENCH_NUM_CTX BENCH_MAX_TOKENS BENCH_SCRATCH
export BENCH_INVOKE="$BENCH_ROOT/lib/invoke.sh"
export BENCH_LIB="$BENCH_ROOT/lib"

BENCH_BACKEND="ollama"; case "$BENCH_MODEL" in anchor:*) BENCH_BACKEND="anchor" ;; esac
BENCH_DIGEST="n/a"; BENCH_QUANT="n/a"; BENCH_WEIGHT="${BENCH_WEIGHT_GB:+${BENCH_WEIGHT_GB} GB}"
BENCH_WEIGHT="${BENCH_WEIGHT:-n/a}"
BENCH_SYSTEM_NOTE="per scenario (scenarios/<id>/system.txt when present)"

log "scratch: $BENCH_SCRATCH"

# --- ollama: is it even up? (it is installed on this host but not always running)
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
OLLAMA_STARTED_BY_US=0
ensure_ollama() {
  curl -sf --max-time 5 "$OLLAMA_HOST/api/tags" >/dev/null 2>&1 && { log "ollama: already running"; return 0; }
  command -v ollama >/dev/null || die "ollama is not installed and not reachable at $OLLAMA_HOST"
  log "ollama: not running — starting it"
  nohup ollama serve >"$BENCH_SCRATCH/ollama.log" 2>&1 &
  OLLAMA_STARTED_BY_US=1
  for _ in $(seq 1 30); do
    sleep 1
    curl -sf --max-time 5 "$OLLAMA_HOST/api/tags" >/dev/null 2>&1 && { log "ollama: up"; return 0; }
  done
  die "ollama did not come up within 30s"
}

# We only ever stop a server we started ourselves. Someone else's ollama (or any
# other process on this host) is not ours to kill.
cleanup() {
  monitor_stop "${MONITOR_PID:-}" 2>/dev/null
  if [ "$OLLAMA_STARTED_BY_US" = "1" ]; then
    log "stopping the ollama we started"
    pkill -f 'ollama serve' 2>/dev/null
  fi
}
trap cleanup EXIT

if [ "$BENCH_BACKEND" = "ollama" ]; then
  ensure_ollama
  tag="${BENCH_MODEL#ollama:}"

  if [ "$SKIP_PREFLIGHT" != "1" ]; then
    if [ -n "$BENCH_WEIGHT_GB" ]; then
      need=$(awk -v w="$BENCH_WEIGHT_GB" -v h="$MEM_HEADROOM" 'BEGIN{printf "%d", w*h*1073741824}')
      preflight_gate "$need" || die "stood down at the start gate: the shortfall is hopeless, not tight (required is >= ${HARD_SHORTFALL_RATIO}x what this host has). A tight fit does not stand down — see docs/method.md 10."
    else
      warn "--weight-gb not given: skipping the start gate (say what you expect to load)"
      need=0
    fi
  else
    need=0
  fi

  if ! curl -sf --max-time 10 "$OLLAMA_HOST/api/tags" | grep -qF "\"$tag\""; then
    log "pulling $tag (this is usually the slowest step)"
    ollama pull "$tag" || die "pull failed: $tag"
  fi

  info=$(curl -s --max-time 30 "$OLLAMA_HOST/api/show" -d "{\"model\":\"$tag\"}")
  BENCH_DIGEST=$(printf '%s' "$info" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("details",{}).get("parent_model") or d.get("model_info",{}).get("general.basename") or "n/a")' 2>/dev/null || echo n/a)
  BENCH_QUANT=$(printf '%s' "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("details",{}).get("quantization_level","n/a"))' 2>/dev/null || echo n/a)
  d2=$(curl -s --max-time 10 "$OLLAMA_HOST/api/tags" | python3 -c "
import json,sys
for m in json.load(sys.stdin).get('models',[]):
    if m.get('name')=='$tag': print(m.get('digest','n/a')[:19]); break
else: print('n/a')" 2>/dev/null || echo n/a)
  [ "$d2" != "n/a" ] && BENCH_DIGEST="$d2"

  # Where the system prompt actually lands. A tag whose TEMPLATE is `{{ .Prompt }}`
  # has no system slot, and ollama silently drops the instruction — the model then
  # continues the input text and every stage fails for a reason that has nothing to
  # do with the model. Decide once here; invoke.sh honours BENCH_SYSTEM_DELIVERY.
  # ".Messages" counts too: newer templates walk the message list instead of
  # naming .System, and ollama folds the system field into that list.
  if printf '%s' "$info" | python3 -c 'import json,sys
t = json.load(sys.stdin).get("template","")
sys.exit(0 if (".System" in t or ".Messages" in t) else 1)' 2>/dev/null; then
    BENCH_SYSTEM_DELIVERY="template"
    BENCH_SYSTEM_NOTE="per scenario / chat template の system スロットに渡す"
  else
    BENCH_SYSTEM_DELIVERY="prepended"
    BENCH_SYSTEM_NOTE="per scenario / ⚠️ このタグに system スロットが無いためプロンプト先頭に連結（アンカーと同じ渡し方）"
    warn "this tag has no system slot in its template — folding the system prompt into the prompt"
  fi
  export BENCH_SYSTEM_DELIVERY

  # warm the model, then measure again — inactive pages are not all reclaimable
  curl -s --max-time 300 "$OLLAMA_HOST/api/generate" \
       -d "{\"model\":\"$tag\",\"prompt\":\"ok\",\"stream\":false,\"options\":{\"num_predict\":1,\"num_ctx\":$BENCH_NUM_CTX}}" >/dev/null
  if [ "$SKIP_PREFLIGHT" != "1" ]; then
    postload_recheck "$need" || die "came down after load: the weights are resident but the host has no room left"
  fi
fi

BENCH_GATEWAY_START=$(gateway_alive || true)
log "gateway: $BENCH_GATEWAY_START"

report_header "$BENCH_REPORT"
: > "$BENCH_SCRATCH/gateway.log"
MONITOR_PID=$(monitor_start "$BENCH_ABORT" "$BENCH_MONITOR_LOG")

passed_stages=""
first_fail=""
highest_run=""
aborted=0

for sdir in "$BENCH_SCENARIOS"/*/; do
  sname=$(basename "$sdir")
  [ -f "$sdir/run-test.sh" ] || continue
  case "$sname" in .*) continue ;; esac
  if [ -n "$BENCH_ONLY" ] && [ "${sname#$BENCH_ONLY}" = "$sname" ]; then continue; fi

  if [ -s "$BENCH_ABORT" ]; then
    report_row "$sname" "3 測れなかった" "0/$BENCH_RUNS" "-" "-" "-" "中断後: $(cat "$BENCH_ABORT")"
    continue
  fi

  passes=0; verdict=0; reasons=""; secs=""; ptoks=""; trunc="no"; calls=0
  tot_secs=0; tot_calls=0
  for run in $(seq 1 "$BENCH_RUNS"); do
    if [ -s "$BENCH_ABORT" ]; then verdict=3; reasons="中断: $(cat "$BENCH_ABORT")"; aborted=1; break; fi
    rundir="$BENCH_SCRATCH/$sname/run$run"; mkdir -p "$rundir"
    log "$sname run $run/$BENCH_RUNS"
    out=$(BENCH_RUN="$run" BENCH_RUN_DIR="$rundir" BENCH_SCENARIO_DIR="$sdir" \
          bash "$sdir/run-test.sh" 2>"$rundir/stderr.log")
    rc=$?
    printf '%s\n' "$out" > "$rundir/verdict.txt"
    case "$(scenario_verdict "$rc" "$out")" in
      0) passes=$((passes+1)) ;;
      1) [ "$verdict" -eq 0 ] && verdict=1; reasons="${reasons}${out} " ;;
      2) verdict=2; reasons="${reasons}${out} " ;;
      3) [ "$verdict" -lt 3 ] && verdict=3
         if [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
           reasons="${reasons}${out} "
         else
           reasons="${reasons}シナリオが実行できなかった（rc=${rc}・理由なし）: $(tr '\n' ' ' < "$rundir/stderr.log" | clip 120) "
         fi ;;
    esac
    # roll up the per-call sidecars this run produced
    s=$(RD="$rundir" python3 -c '
import glob, json, os
tot = 0; pt = []; tr = False
for f in glob.glob(os.path.join(os.environ["RD"], "*.meta.json")):
    try: m = json.load(open(f, encoding="utf-8"))
    except Exception: continue
    tot += m.get("elapsed_sec") or 0
    if m.get("prompt_tokens"): pt.append(m["prompt_tokens"])
    tr = tr or bool(m.get("truncated"))
print("%d|%s|%s|%d" % (tot, max(pt) if pt else "n/a", "yes" if tr else "no", len(glob.glob(os.path.join(os.environ["RD"], "*.meta.json")))))' 2>/dev/null || echo "0|n/a|no|0")
    secs="${s%%|*}"; rest="${s#*|}"; ptoks="${rest%%|*}"; rest="${rest#*|}"
    trunc="${rest%%|*}"; calls="${rest##*|}"
    tot_secs=$((tot_secs + secs)); tot_calls=$((tot_calls + calls))
  done

  printf '%s %s -> %s\n' "$(date '+%H:%M:%S')" "$sname" "$(gateway_alive || true)" >> "$BENCH_SCRATCH/gateway.log"

  if [ "$passes" -eq "$BENCH_RUNS" ] && [ "$verdict" -eq 0 ]; then
    label="0 通過"; passed_stages="${passed_stages}${sname} "
    [ -z "$first_fail" ] && highest_run="$sname"
  else
    # 中途半端（全滅でも全勝でもない）＝決定的でないことが確定した段。
    # その段だけ --runs を増やして追いかける（docs/method.md 1）。
    if [ "$passes" -gt 0 ] && [ "$passes" -lt "$BENCH_RUNS" ]; then
      warn "$sname: $passes/$BENCH_RUNS — 決定的でない。この段だけ --runs 10 で追いかけること"
    fi
    case "$verdict" in
      2) label="2 判断できない" ;;
      3) label="3 測れなかった" ;;
      *) label="1 失格" ;;
    esac
    [ -z "$first_fail" ] && first_fail="$sname"
  fi
  # seconds per case (a "1本" of work), averaged over every call made
  if [ "${tot_calls:-0}" -gt 0 ]; then
    per=$(awk -v s="$tot_secs" -v c="$tot_calls" 'BEGIN{printf "%.1fs", s/c}')
  else
    per="-"
  fi
  report_row "$sname" "$label" "$passes/$BENCH_RUNS" "$per" "${ptoks:-0}" "$trunc" "$(printf '%s' "${reasons:-—}" | tr '\n' ' ' | clip 160)"
done

monitor_stop "$MONITOR_PID"; MONITOR_PID=""
report_footer

{
  echo
  echo "## まとめ"
  echo
  echo "- 通った段: ${passed_stages:-なし}"
  # 階段なので「連続して通った一番上」が答え。飛び石で通っても、その上の段は保証されない
  echo "- **連続して通った一番上の段: ${highest_run:-なし}**"
  [ -n "$first_fail" ] && [ -n "$passed_stages" ] && \
    echo "- ⚠️ $first_fail で階段が切れている。それより上の「通過」は飛び石なので、カタログの行には**連続した段まで**を書く"
  echo "- 判定は「全ケース × ${BENCH_RUNS}回すべてが失格条件に当たらない」ときだけ通過"
  [ "$aborted" = "1" ] && echo "- ⚠️ 途中で中断した。落ちたのではなく **測れなかった**"
} >> "$BENCH_REPORT"

log "report: $BENCH_REPORT"
cat "$BENCH_REPORT"
