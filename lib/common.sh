#!/usr/bin/env bash
# common.sh — shared helpers. Source this, do not execute.

BENCH_VERSION="v2"

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '[%s] FATAL: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

# bytes -> "x.xx GB"
gb() { awk -v b="$1" 'BEGIN{printf "%.2f GB", b/1073741824}'; }

# harness commit SHA (records which version of the framework produced a result)
harness_sha() {
  git -C "$BENCH_ROOT" rev-parse --short HEAD 2>/dev/null || echo "uncommitted"
}

# fixture version = content hash of the scenarios tree (so a result can be tied
# to the exact cases it was measured against, even though cases live elsewhere)
fixture_sha() {
  local dir="$1"
  if [ -d "$dir/.git" ] || git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$dir" rev-parse --short HEAD 2>/dev/null && return
  fi
  find "$dir" -type f \( -name '*.txt' -o -name '*.json' -o -name '*.md' \) -print0 2>/dev/null \
    | sort -z | xargs -0 shasum 2>/dev/null | shasum | cut -c1-12
}
