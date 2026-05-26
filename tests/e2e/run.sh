#!/usr/bin/env bash
# maestrode e2e: brain-offload efficiency test.
#
# Hypothesis: running the same fix task through a cheap muscle model
# converges to the same pytest-PASS state as running it through the
# smart model, at a fraction of the token cost.
#
# Arms (same brief, same attached files; only the model varies):
#   A: maestrode --model $SMART_MODEL  (control: smart model as muscle)
#   B: maestrode --model $MUSCLE_MODEL (cheap muscle)
#
# Each arm: stage fixture, call maestrode with --files, run pytest,
# capture tokens + wall time from the [maestrode ...] stderr line.
#
# env:
#   MAESTRODE_API_KEY  required (or in ~/.config/maestrode/env)
#   SMART_MODEL        default: claude-opus-4-7
#   MUSCLE_MODEL       default: deepseek-v4-flash
#   PYTEST             default: pytest (override if not on PATH)
#   SKIP_ARM_A=1       skip the control arm (saves the expensive call)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixture"
MAESTRODE_BIN="${MAESTRODE_BIN:-$HOME/.local/bin/maestrode}"

SMART_MODEL="${SMART_MODEL:-claude-opus-4-7}"
MUSCLE_MODEL="${MUSCLE_MODEL:-deepseek-v4-flash}"
PYTEST="${PYTEST:-pytest}"

if [[ ! -x "$MAESTRODE_BIN" ]]; then
  echo "e2e: maestrode binary not found at $MAESTRODE_BIN (set MAESTRODE_BIN to override)" >&2
  exit 1
fi
if ! command -v "$PYTEST" >/dev/null; then
  echo "e2e: pytest not on PATH (set PYTEST or install: pipx install pytest)" >&2
  exit 1
fi

# Read MAESTRODE_API_KEY from env file too (matches the shim's behavior).
CONFIG_DIR="${MAESTRODE_CONFIG_DIR:-$HOME/.config/maestrode}"
if [[ -z "${MAESTRODE_API_KEY:-}" ]] && [[ -f "$CONFIG_DIR/env" ]]; then
  # shellcheck disable=SC1091
  . "$CONFIG_DIR/env"
fi
if [[ -z "${MAESTRODE_API_KEY:-}" ]]; then
  echo "e2e: MAESTRODE_API_KEY not set (env or $CONFIG_DIR/env). Skipping." >&2
  exit 0
fi

# Sanity: baseline fixture must be in the broken state (1 failing test).
echo "== checking baseline fixture =="
if "$PYTEST" -q "$FIXTURE_DIR" >/dev/null 2>&1; then
  echo "e2e: baseline fixture unexpectedly passes; the bug must be present" >&2
  exit 1
fi
echo "  baseline: 1 failing test (as expected)"

WORK=$(mktemp -d -t maestrode_e2e.XXXXXX)
echo "  workdir: $WORK"

BRIEF=$(cat <<'EOF'
Task: fix the failing pytest in this small Python project.

Failing test: tests/test_app.py::test_min_age_accepted
What it expects: app.register("alice", 18) succeeds; app.lookup("alice") returns 18.
What happens now: register raises store.StoreError("invalid age: 18").

Localize the bug from the attached files. Emit each modified file as:

<<<FILE: relative/path.py>>>
<file contents>
<<<END FILE>>>

Use the same relative paths as the attached files (e.g. <<<FILE: validator.py>>>).
Only emit files you change.

DO NOT:
- modify any file under tests/
- add new dependencies
- change unrelated code
- rewrite working logic outside the bug
EOF
)

# parse_metrics <stderr-file> -> "model prompt out reason cache finish"
parse_metrics() {
  python3 - "$1" <<'PY'
import re, sys, pathlib
txt = pathlib.Path(sys.argv[1]).read_text(errors='ignore')
m = re.search(r'\[maestrode model=(\S+) prompt=(\d+) reason=(\d+) out=(\d+|\?)(?: cache=([^\s\]]+))?(?: finish=(\S+))?\]', txt)
if not m:
    print("? ? ? ? ? ?")
    sys.exit(0)
model, prompt, reason, out, cache, finish = m.groups()
print(f"{model} {prompt} {out or '?'} {reason} {cache or '-'} {finish or 'stop'}")
PY
}

run_arm() {
  local label="$1" model="$2" outdir="$3" stderr_file="$4"
  cp -R "$FIXTURE_DIR" "$outdir"
  local files=()
  for rel in validator.py store.py app.py tests/test_app.py; do
    files+=(-f "$FIXTURE_DIR/$rel")
  done
  echo "== arm $label: $model =="
  local t0 t1
  t0=$(date +%s)
  set +e
  "$MAESTRODE_BIN" --model "$model" --files "$outdir" "${files[@]}" "$BRIEF" \
    >"$outdir/.muscle_stdout" 2>"$stderr_file"
  local rc=$?
  set -e
  t1=$(date +%s)
  local wall=$((t1 - t0))

  local metrics
  metrics=$(parse_metrics "$stderr_file")
  read -r m_model m_prompt m_out m_reason m_cache m_finish <<<"$metrics"

  local pytest_status pytest_summary
  set +e
  pytest_summary=$("$PYTEST" -q "$outdir" 2>&1 | tail -1)
  pytest_status=$?
  set -e

  local files_written
  files_written=$(grep -c '^  + ' "$stderr_file" || true)
  files_written=${files_written:-0}

  local verdict
  if [[ $rc -ne 0 ]]; then
    verdict="MUSCLE_FAIL(rc=$rc)"
  elif [[ $pytest_status -eq 0 ]]; then
    verdict="PASS"
  else
    verdict="PYTEST_FAIL"
  fi

  echo "  model:     $m_model"
  echo "  wall:      ${wall}s"
  echo "  prompt:    $m_prompt tokens"
  echo "  out:       $m_out tokens"
  echo "  reasoning: $m_reason tokens"
  echo "  cache:     $m_cache"
  echo "  finish:    $m_finish"
  echo "  files:     $files_written"
  echo "  pytest:    $pytest_summary"
  echo "  verdict:   $verdict"

  echo "$label|$m_model|$wall|$m_prompt|$m_out|$m_reason|$m_cache|$m_finish|$files_written|$verdict" \
    >>"$WORK/.results"
}

: >"$WORK/.results"

if [[ "${SKIP_ARM_A:-0}" != "1" ]]; then
  run_arm A "$SMART_MODEL"  "$WORK/arm_A" "$WORK/arm_A.stderr"
else
  echo "== arm A skipped (SKIP_ARM_A=1) =="
fi
run_arm B "$MUSCLE_MODEL" "$WORK/arm_B" "$WORK/arm_B.stderr"

echo
echo "============================================"
echo "maestrode e2e: brain offload comparison"
echo "============================================"
python3 - "$WORK/.results" <<'PY'
import sys, pathlib
rows = [l.strip().split("|") for l in pathlib.Path(sys.argv[1]).read_text().splitlines() if l.strip()]
keys = ["arm","model","wall","prompt","out","reason","cache","finish","files","verdict"]
parsed = [dict(zip(keys, r)) for r in rows]
for p in parsed:
    print(f"\nArm {p['arm']}  ({p['model']})")
    print(f"  wall:      {p['wall']}s")
    print(f"  prompt:    {p['prompt']} tokens")
    print(f"  out:       {p['out']} tokens")
    print(f"  reasoning: {p['reason']} tokens")
    print(f"  cache:     {p['cache']}")
    print(f"  finish:    {p['finish']}")
    print(f"  files:     {p['files']}")
    print(f"  verdict:   {p['verdict']}")

by_arm = {p["arm"]: p for p in parsed}
if "A" in by_arm and "B" in by_arm:
    def num(s, default=0):
        try: return int(s)
        except: return default
    a, b = by_arm["A"], by_arm["B"]
    def delta(field):
        av, bv = num(a[field]), num(b[field])
        if av == 0:
            return f"{bv} (A=0)"
        pct = round(100 * (bv - av) / av)
        sign = "+" if pct >= 0 else ""
        return f"{bv} vs {av}  ({sign}{pct}%)"
    print("\nDeltas (B vs A)")
    print(f"  wall:      {delta('wall')}")
    print(f"  prompt:    {delta('prompt')}")
    print(f"  out:       {delta('out')}")
    print(f"  reasoning: {delta('reason')}")
    print(f"  outcome:   A={a['verdict']}  B={b['verdict']}")
    if a["verdict"] == "PASS" == b["verdict"]:
        print("\n  -> same outcome; muscle-side cost delta is the headline.")
    elif b["verdict"] == "PASS" and a["verdict"] != "PASS":
        print("\n  -> cheap muscle converged where the control did not.")
    elif a["verdict"] == "PASS" and b["verdict"] != "PASS":
        print("\n  -> cheap muscle did NOT converge. Tighten brief or iterate.")
else:
    print("\n(Only one arm ran; no delta computed.)")
print(
    "\nNote: this measures muscle-side cost. The brain-side win (brain "
    "reading files via -f vs Claude reading them through its Read tool) "
    "shows up in your Claude session token usage, not here.\n"
)
PY

echo "logs: $WORK"
