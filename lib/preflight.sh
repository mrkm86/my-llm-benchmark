#!/usr/bin/env bash
# preflight.sh — memory / host safety gates (macOS).
#
# The three-stage guard (BB-374 R6):
#   1. preflight gate   : before pulling or loading anything
#   2. post-load recheck: after the model is resident (inactive is not fully reclaimable)
#   3. live monitor     : every MONITOR_INTERVAL seconds while a scenario runs
#
# We come down on our own rather than waiting for Jetsam. Not measuring is
# cheaper than taking the host down — this machine runs production jobs.

MEM_HEADROOM=1.3          # required = weight * MEM_HEADROOM
SWAP_FREE_ABORT_MB=200    # live abort threshold
SWAP_FREE_GATE_MB=1024    # start gate
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

mem_snapshot() {
  printf 'usable=%s free+spec=%s swap_free=%sM' \
    "$(gb "$(mem_usable_bytes)")" "$(gb "$(mem_free_bytes)")" "$(swap_free_mb)"
}

# gateway_alive — 200 or 401 both mean the daemon answered (401 = auth required)
gateway_alive() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$GATEWAY_TIMEOUT" "$GATEWAY_URL" 2>/dev/null)
  case "$code" in 200|401) echo "alive($code)"; return 0 ;; *) echo "DOWN($code)"; return 1 ;; esac
}

# preflight_gate <required_bytes> — 0 = go, 1 = stand down
preflight_gate() {
  local need="$1" usable swapfree
  usable=$(mem_usable_bytes); swapfree=$(swap_free_mb)
  log "preflight: need $(gb "$need") / $(mem_snapshot)"
  if [ "$usable" -lt "$need" ]; then
    warn "preflight FAILED: usable $(gb "$usable") < required $(gb "$need")"
    return 1
  fi
  if [ "${swapfree:-0}" -lt "$SWAP_FREE_GATE_MB" ]; then
    warn "preflight FAILED: swap free ${swapfree}M < ${SWAP_FREE_GATE_MB}M"
    return 1
  fi
  log "preflight OK"
  return 0
}

# postload_recheck <required_bytes> — inactive is not guaranteed reclaimable,
# so measure again once the weights are actually resident.
postload_recheck() {
  local need="$1" free swapfree
  free=$(mem_free_bytes); swapfree=$(swap_free_mb)
  log "post-load: $(mem_snapshot)"
  if [ "${swapfree:-0}" -lt "$SWAP_FREE_ABORT_MB" ]; then
    warn "post-load FAILED: swap free ${swapfree}M < ${SWAP_FREE_ABORT_MB}M"
    return 1
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
  (
    while true; do
      sf=$(swap_free_mb)
      printf '%s swap_free=%sM usable=%s\n' "$(date '+%H:%M:%S')" "$sf" "$(gb "$(mem_usable_bytes)")" >> "$mlog"
      if [ "${sf:-0}" -lt "$SWAP_FREE_ABORT_MB" ]; then
        echo "swap free ${sf}M < ${SWAP_FREE_ABORT_MB}M" > "$abort"; exit 0
      fi
      sleep "$MONITOR_INTERVAL"
    done
  ) >/dev/null 2>&1 &
  echo $!
}

monitor_stop() { [ -n "$1" ] && kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; return 0; }
