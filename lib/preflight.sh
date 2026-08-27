#!/usr/bin/env bash
# preflight.sh — memory / host safety gates (macOS).
#
# The three-stage guard (BB-374 R6, revised R7):
#   1. preflight gate   : before pulling or loading anything
#   2. post-load recheck: after the model is resident (inactive is not fully reclaimable)
#   3. live monitor     : every MONITOR_INTERVAL seconds while a scenario runs
#
# We come down on our own rather than waiting for Jetsam. Not measuring is
# cheaper than taking the host down — this machine runs production jobs.
#
# R7 — what we stopped guarding on, and why (BB-374 comment 5420620134):
#
#   swap free was never a real ceiling. macOS swap is not a fixed area:
#   dynamic_pager grows it against free disk (194Gi here), so "swap free 961M"
#   says how many swapfiles exist right now, not how much is left. Gating on it
#   blocks forever on a machine that is not actually stuck. Removed.
#
#   Running short on `usable` is likewise not a reason to stand down. inactive
#   pages are handed over on demand and macOS will compress to make room. If we
#   push a model in and the host thrashes, that is not a failure — it IS the
#   measurement ("3B q8 runs on a 10-day-up mac01, but at N s/case"). Standing
#   down means that line never gets written. So: warn and go.
#
#   What we still come down for is the host actually being in trouble, and the
#   signal for that is memory pressure (the thing Jetsam itself watches), not a
#   derived free-memory number.

MEM_HEADROOM=1.3           # required = weight * MEM_HEADROOM
HARD_SHORTFALL_RATIO=2     # block only when required is >= this many times usable
PRESSURE_ABORT_LEVEL=4     # kern.memorystatus_vm_pressure_level: 1 normal / 2 warn / 4 critical
MONITOR_INTERVAL=10
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:7777/api/status}"
GATEWAY_TIMEOUT=60

# usable = (free + speculative + inactive) * pagesize
mem_usable_bytes() {
  vm_stat | awk '
    /page size of/ { for(i=1;i<=NF;i++) if($i=="of") ps=$(i+1) }
    /Pages free/         { gsub(/\./,"",$3); f=$3 }
    /Pages speculative/  { gsub(/\./,"",$3); s=$3 }
    /Pages inactive/     { gsub(/\./,"",$3); i=$3 }
    END { printf "%d", (f+s+i)*ps }'
}

mem_free_bytes() {
  vm_stat | awk '
    /page size of/ { for(i=1;i<=NF;i++) if($i=="of") ps=$(i+1) }
    /Pages free/        { gsub(/\./,"",$3); f=$3 }
    /Pages speculative/ { gsub(/\./,"",$3); s=$3 }
    END { printf "%d", (f+s)*ps }'
}

swap_free_mb() {
  /usr/sbin/sysctl -n vm.swapusage 2>/dev/null \
    | sed -E 's/.*free = ([0-9.]+)M.*/\1/' | cut -d. -f1
}

# 1 normal / 2 warn / 4 critical. Absent (non-macOS, sandbox) reads as normal —
# we do not want a missing sysctl to become a permanent stand-down.
pressure_level() {
  /usr/sbin/sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 1
}

# swapins + swapouts, cumulative since boot. Deltas across a run are the
# thrashing evidence; the absolute numbers mean nothing on a 10-day-up host.
swap_io_count() {
  vm_stat | awk '
    /Swapins/  { gsub(/\./,"",$2); si=$2 }
    /Swapouts/ { gsub(/\./,"",$2); so=$2 }
    END { printf "%d", si+so }'
}

mem_snapshot() {
  printf 'usable=%s free+spec=%s swap_free=%sM pressure=%s' \
    "$(gb "$(mem_usable_bytes)")" "$(gb "$(mem_free_bytes)")" \
    "$(swap_free_mb)" "$(pressure_level)"
}

# gateway_alive — 200 or 401 both mean the daemon answered (401 = auth required)
gateway_alive() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$GATEWAY_TIMEOUT" "$GATEWAY_URL" 2>/dev/null)
  case "$code" in 200|401) echo "alive($code)"; return 0 ;; *) echo "DOWN($code)"; return 1 ;; esac
}

# BENCH_GATE_NOTE — set by the gate, read by the report. A run that went ahead
# short on memory has to say so, otherwise its seconds-per-case reads as a clean
# number when it was really a squeeze.
BENCH_GATE_NOTE=""

# preflight_gate <required_bytes> — 0 = go, 1 = stand down.
# Only a hopeless shortfall stands down; a tight fit goes ahead with a note.
preflight_gate() {
  local need="$1" usable floor
  usable=$(mem_usable_bytes)
  log "preflight: need $(gb "$need") / $(mem_snapshot)"
  floor=$((need / HARD_SHORTFALL_RATIO))
  if [ "$usable" -lt "$floor" ]; then
    warn "preflight FAILED: usable $(gb "$usable") is under half of required $(gb "$need") — hopeless, not tight"
    return 1
  fi
  if [ "$usable" -lt "$need" ]; then
    BENCH_GATE_NOTE="起動時に不足（usable $(gb "$usable") < 必要 $(gb "$need")）。押し込んで測定した"
    warn "preflight TIGHT: usable $(gb "$usable") < required $(gb "$need") — going ahead anyway (see docs/method.md 10)"
    return 0
  fi
  log "preflight OK"
  return 0
}

# postload_recheck <required_bytes> — inactive is not guaranteed reclaimable,
# so look again once the weights are actually resident. We only come down if the
# host itself says it is in trouble.
postload_recheck() {
  local need="$1" pl
  pl=$(pressure_level)
  log "post-load: $(mem_snapshot)"
  if [ "${pl:-1}" -ge "$PRESSURE_ABORT_LEVEL" ]; then
    warn "post-load FAILED: memory pressure critical (level $pl)"
    return 1
  fi
  if [ "${pl:-1}" -gt 1 ]; then
    BENCH_GATE_NOTE="${BENCH_GATE_NOTE:+$BENCH_GATE_NOTE / }ロード後にメモリプレッシャー warn（level ${pl}）"
    warn "post-load: pressure level $pl (warn) — going ahead, recording it"
  fi
  return 0
}

# monitor_start <abort-file> <log-file> — background watcher; writes a reason
# into the abort file when a threshold trips. Callers poll the abort file.
#
# The watcher's stdout is closed off deliberately: callers capture the pid with
# $(monitor_start ...), and a background child that keeps the substitution pipe
# open would hang that capture forever.
monitor_start() {
  local abort="$1" mlog="$2"
  rm -f "$abort"
  swap_io_count > "${mlog%.log}.swapio.start"
  (
    while true; do
      pl=$(pressure_level)
      printf '%s swap_free=%sM usable=%s pressure=%s swapio=%s\n' \
        "$(date '+%H:%M:%S')" "$(swap_free_mb)" "$(gb "$(mem_usable_bytes)")" \
        "$pl" "$(swap_io_count)" >> "$mlog"
      if [ "${pl:-1}" -ge "$PRESSURE_ABORT_LEVEL" ]; then
        echo "memory pressure critical (level $pl)" > "$abort"; exit 0
      fi
      sleep "$MONITOR_INTERVAL"
    done
  ) >/dev/null 2>&1 &
  echo $!
}

monitor_stop() { [ -n "$1" ] && kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; return 0; }

# swap_io_delta <monitor-log> — pages swapped in+out during the run. This is the
# thrashing number: "it ran, but it paid N pages for it".
swap_io_delta() {
  local mlog="$1" start
  start=$(cat "${mlog%.log}.swapio.start" 2>/dev/null || echo 0)
  echo $(( $(swap_io_count) - start ))
}
