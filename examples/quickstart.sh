#!/usr/bin/env bash
# Maestrode end-to-end demo. Writes a buggy Python file, asks maestrode to fix it,
# runs the test suite to verify the fix landed. ~30 seconds total.
#
# Requires: maestrode installed (run ./install.sh from repo root first),
#           ~/.config/maestrode/env with MAESTRODE_API_KEY set,
#           python3 and pytest on PATH.
#
# Exits 0 if the demo passes, non-zero otherwise.

set -euo pipefail

MAESTRODE_BIN="${MAESTRODE_BIN:-maestrode}"
if ! command -v "$MAESTRODE_BIN" >/dev/null 2>&1; then
  MAESTRODE_BIN="${HOME}/.local/bin/maestrode"
fi
if [[ ! -x "$MAESTRODE_BIN" ]]; then
  echo "error: maestrode binary not found. Run ./install.sh from the repo root first." >&2
  exit 1
fi

PYTEST="${PYTEST:-pytest}"
if ! command -v "$PYTEST" >/dev/null 2>&1; then
  echo "error: pytest not on PATH. Install pytest: pip install pytest" >&2
  exit 1
fi

WORK=$(mktemp -d -t maestrode_demo.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo "==> demo workspace: $WORK"
mkdir -p "$WORK/src" "$WORK/tests"
touch "$WORK/tests/__init__.py"

# ----- step 1: write a buggy file -----
cat > "$WORK/src/slugify.py" <<'EOF'
import re

_NON_ALNUM = re.compile(r'[^a-z0-9]+')

def slugify(s: str) -> str:
    """Convert s into a URL-safe slug.
    Rules: lowercase, replace runs of non-alphanumeric with single dash, trim edge dashes.
    """
    s = _NON_ALNUM.sub('-', s)
    return s.strip('-')
EOF

# ----- step 2: write the test suite -----
cat > "$WORK/tests/test_slugify.py" <<'EOF'
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent.parent / 'src'))
from slugify import slugify

def test_simple():
    assert slugify('hello world') == 'hello-world'

def test_lowercases():
    assert slugify('Hello World') == 'hello-world'

def test_collapses_runs():
    assert slugify('a   b!!!c') == 'a-b-c'

def test_trims_edges():
    assert slugify('  !!hello world!!  ') == 'hello-world'

def test_preserves_numbers():
    assert slugify('Top 100 of 2024') == 'top-100-of-2024'

def test_empty():
    assert slugify('') == ''
EOF

# ----- step 3: confirm tests fail (the bug) -----
echo
echo "==> step 1: run tests to see the failures"
set +e
"$PYTEST" "$WORK/tests" -v --tb=line 2>&1 | tee "$WORK/before.log" | tail -10
PRE_EXIT=$?
set -e

if [[ $PRE_EXIT -eq 0 ]]; then
  echo "error: tests already pass; the demo expects a failing baseline." >&2
  exit 1
fi

FAILED=$(grep -c "FAILED" "$WORK/before.log" || true)
echo
echo "==> $FAILED test(s) failed (expected for the demo). Asking maestrode to fix."

# ----- step 4: build the structured brief -----
BRIEF_FILE="$WORK/brief.txt"
{
  echo "TASK: fix the slugify bug. Multiple tests fail with the same root cause."
  echo
  echo "FAILURES (selected):"
  grep -E "^FAILED" "$WORK/before.log" | head -3
  echo
  echo "SUSPECT: src/slugify.py is missing a step before the regex substitution."
  echo "FIX: lowercase the input string before applying the non-alphanumeric regex."
  echo
  echo "Current file:"
  echo
  echo "<<<FILE: src/slugify.py>>>"
  cat "$WORK/src/slugify.py"
  echo "<<<END FILE>>>"
  echo
  echo "RETURN: only src/slugify.py with the fix applied. delimited block format."
  echo "DO NOT: touch tests, add dependencies, refactor unrelated code."
  echo
  echo "OUTPUT FORMAT (literal, copy markers exactly):"
  echo "<<<FILE: src/slugify.py>>>"
  echo "full new file content"
  echo "<<<END FILE>>>"
} > "$BRIEF_FILE"

# ----- step 5: call maestrode -----
echo
echo "==> step 2: call maestrode"
"$MAESTRODE_BIN" --files "$WORK" --max-tokens 8192 < "$BRIEF_FILE" > "$WORK/muscle.out" 2> "$WORK/muscle.err"
echo "muscle reply (truncated):"
head -c 600 "$WORK/muscle.out"
echo
echo "..."
echo
echo "shim stderr:"
cat "$WORK/muscle.err"

# ----- step 6: confirm tests now pass -----
echo
echo "==> step 3: re-run tests"
set +e
"$PYTEST" "$WORK/tests" -v --tb=short 2>&1 | tee "$WORK/after.log" | tail -10
POST_EXIT=$?
set -e

echo
if [[ $POST_EXIT -eq 0 ]]; then
  echo "==> DEMO PASSED. maestrode found and fixed the bug."
  exit 0
else
  echo "==> DEMO FAILED. maestrode did not converge in 1 round."
  echo "    Inspect: $WORK"
  exit 2
fi
