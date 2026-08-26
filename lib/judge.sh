#!/usr/bin/env bash
# judge.sh — disqualifier checks. Source this from a scenario's run-test.sh.
#
# Stages 003+ have no single right answer, so we do not score them. We list what
# must not happen and check for those. Every check here is mechanical; anything
# that needs a human eye must go through judge_undecidable, which stops the run
# and asks. A judge that guesses is worse than a judge that says "I can't tell".
#
# Verdicts:  0 = pass   1 = fail (disqualified)   2 = undecidable (call a human)
#            3 = could-not-measure (never say "failed" when we never ran it)

JUDGE_REASONS=()
JUDGE_UNDECIDABLE=()

judge_fail()        { JUDGE_REASONS+=("$1"); }
judge_undecidable() { JUDGE_UNDECIDABLE+=("$1"); }

judge_finish() {
  if [ "${#JUDGE_UNDECIDABLE[@]}" -gt 0 ]; then
    printf 'UNDECIDABLE: %s\n' "${JUDGE_UNDECIDABLE[@]}"
    return 2
  fi
  if [ "${#JUDGE_REASONS[@]}" -gt 0 ]; then
    printf 'DISQUALIFIED: %s\n' "${JUDGE_REASONS[@]}"
    return 1
  fi
  echo "PASS"
  return 0
}

judge_nonempty() {
  [ -s "$1" ] || judge_fail "output is empty"
}

# judge_max_lines <file> <n> — non-blank lines
judge_max_lines() {
  local n; n=$(grep -cve '^[[:space:]]*$' "$1" || true)
  [ "$n" -le "$2" ] || judge_fail "output has $n non-blank lines (max $2)"
}

judge_min_lines() {
  local n; n=$(grep -cve '^[[:space:]]*$' "$1" || true)
  [ "$n" -ge "$2" ] || judge_fail "output has $n non-blank lines (min $2)"
}

# judge_forbidden <file> <patterns-file>
# patterns-file: one ERE per line; "# " comments and blank lines ignored;
# an optional "<pattern>\t<label>" second column names the rule in the reason.
judge_forbidden() {
  local out="$1" pf="$2" pat label
  [ -f "$pf" ] || return 0
  while IFS=$'\t' read -r pat label; do
    case "$pat" in ''|'#'*) continue ;; esac
    if grep -Eq -- "$pat" "$out"; then
      judge_fail "forbidden pattern hit: ${label:-$pat}"
    fi
  done < "$pf"
}

judge_json() {
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null \
    || judge_fail "output is not valid JSON"
}

# judge_json_fields <file> <expected.json> — every key in expected must match
judge_json_fields() {
  local msg
  msg=$(python3 - "$1" "$2" <<'PY'
import json, sys
try:
    got = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"unparseable JSON ({e})"); sys.exit(0)
want = json.load(open(sys.argv[2]))
bad = [f"{k}: expected {v!r}, got {got.get(k)!r}" for k, v in want.items()
       if str(got.get(k, "")).strip() != str(v).strip()]
print("; ".join(bad))
PY
)
  [ -z "$msg" ] || judge_fail "$msg"
}

# judge_numbers_subset <output> <source> — every number in the output must
# appear in the source. Fabricated figures are the failure mode that survives a
# read-through, so it is worth checking mechanically even though it is crude.
judge_numbers_subset() {
  local msg
  msg=$(python3 - "$1" "$2" <<'PY'
import re, sys
num = lambda p: set(re.findall(r'\d[\d,.]*', open(p).read().replace(',', '')))
extra = sorted(num(sys.argv[1]) - num(sys.argv[2]))
print(", ".join(extra[:5]))
PY
)
  [ -z "$msg" ] || judge_fail "numbers not present in the source: $msg"
}

# judge_japanese <file> [min_ratio] — the output must actually be Japanese
judge_japanese() {
  local r; r=$(python3 - "$1" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
j = len(re.findall(r'[ぁ-んァ-ヶ一-龠]', t))
print(f"{j/max(len(t.strip()),1):.2f}")
PY
)
  awk -v r="$r" -v m="${2:-0.15}" 'BEGIN{exit !(r+0 < m+0)}' \
    && judge_fail "output does not look Japanese (CJK ratio $r)"
  return 0
}

# judge_ascii_ratio <file> <max_ratio> <min_chars>
# Ported check: a line long enough to be a real sentence but made of ASCII words
# is an untranslated leftover. min_chars guards against acronym false positives.
judge_ascii_ratio() {
  local hit; hit=$(python3 - "$1" "$2" "$3" <<'PY'
import re, sys
maxr, minc = float(sys.argv[2]), int(sys.argv[3])
bad = []
for line in open(sys.argv[1]):
    s = line.strip()
    if len(s) < minc: continue
    letters = re.sub(r'[^A-Za-z぀-ヿ一-鿿]', '', s)
    if not letters: continue
    ratio = sum(c.isascii() for c in letters) / len(letters)
    if ratio >= maxr: bad.append(f"{s[:40]} (ascii {ratio:.2f})")
print(" | ".join(bad[:3]))
PY
)
  [ -z "$hit" ] || judge_fail "looks untranslated: $hit"
}

# judge_covers_all <output> <keys-file> — one required key per line
judge_covers_all() {
  local missing=() key
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    grep -qF -- "$key" "$1" || missing+=("$key")
  done < "$2"
  [ "${#missing[@]}" -eq 0 ] || judge_fail "not covered: ${missing[*]}"
}
