#!/usr/bin/env bash
# Unit tests for the maestrode shim. No network calls (uses --dry-run + curl stub).
# Tests: file-block parser, secret-scan, fence/dash strip, session persistence.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAESTRODE="${SCRIPT_DIR}/../src/maestrode"

PASS=0
FAIL=0
TMP=$(mktemp -d -t maestrode_test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

ok() { PASS=$((PASS+1)); echo "  ok: $1"; }
ko() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

export MAESTRODE_CONFIG_DIR="$TMP/config"
mkdir -p "$MAESTRODE_CONFIG_DIR"
echo 'MAESTRODE_API_KEY=test-key-not-real' > "$MAESTRODE_CONFIG_DIR/env"

echo "== test 1: --dry-run prints payload, no network =="
out=$(echo "hello world" | "$MAESTRODE" --dry-run "task arg" 2>&1) || true
[[ "$out" == *"dry-run"* ]] && ok "dry-run reported" || ko "dry-run not reported: $out"
[[ "$out" == *"chars"* ]] && ok "char count surfaced" || ko "char count missing"

echo "== test 2: secret-scan refuses sk- key =="
set +e
out=$(echo "my key is sk-abcdefghijklmnop1234567890" | "$MAESTRODE" --dry-run "test" 2>&1)
code=$?
set -e
[[ $code -eq 65 ]] && ok "exit 65 on secret detected" || ko "wrong exit: $code"
[[ "$out" == *"API key"* ]] && ok "labels API key" || ko "label missing"

echo "== test 3: secret-scan override allows =="
set +e
out=$(MAESTRODE_ALLOW_SECRETS=1 bash -c "echo 'my key is sk-abcdefghijklmnop1234567890' | '$MAESTRODE' --dry-run 'test'" 2>&1)
code=$?
set -e
[[ $code -eq 0 ]] && ok "override bypass" || ko "override failed: $code"

echo "== test 4: secret-scan catches AWS / GitHub / private key =="
for s in "AKIAIOSFODNN7EXAMPLE" "ghp_abcdefghij0123456789abcdef" "-----BEGIN PRIVATE KEY-----"; do
  set +e
  echo "string: $s" | "$MAESTRODE" --dry-run "x" >/dev/null 2>&1
  code=$?
  set -e
  [[ $code -eq 65 ]] && ok "refused secret pattern" || ko "did not refuse pattern ($code)"
done

echo "== test 5: empty prompt rejected =="
set +e
"$MAESTRODE" --dry-run >/dev/null 2>&1
code=$?
set -e
[[ $code -eq 64 ]] && ok "exit 64 on empty" || ko "wrong exit: $code"

echo "== test 5b: never-closing unix-socket stdin does not hang =="
# Reproduces the Claude Code Bash tool case: child inherits a unix socket
# as stdin whose other end is held open but never written to. The old
# `[[ ! -t 0 ]]` gate let `cat` block forever; the harness then SIGKILLs
# the script, EXIT trap never fires, 0-byte temps + no log write pile up.
# The new gate (`-p` || `-f`) rejects sockets, so cat is skipped.
# Watchdog rolled by hand because GNU `timeout` is not on stock macOS.
set +e
python3 - "$MAESTRODE" >/dev/null 2>&1 <<'PY' &
import os, socket, sys, time
a, b = socket.socketpair()
pid = os.fork()
if pid == 0:
    # child: keep `a` open silently so the parent's stdin never closes.
    b.close()
    time.sleep(10)
    sys.exit(0)
# parent: dup the other socket end onto stdin and exec maestrode.
a.close()
os.dup2(b.fileno(), 0)
os.execvp(sys.argv[1], [sys.argv[1], "--dry-run", "socket stdin task"])
PY
M_PID=$!
( sleep 3; kill -9 "$M_PID" 2>/dev/null ) &
WATCHDOG=$!
wait "$M_PID"
code=$?
set -e
kill "$WATCHDOG" 2>/dev/null || true
wait "$WATCHDOG" 2>/dev/null || true
# Reap any stray socket-holder children python forked.
pkill -P "$$" -f "socket.socketpair" 2>/dev/null || true
if [[ $code -eq 137 || $code -eq 143 ]]; then
  ko "hung on never-closing socket (watchdog had to SIGKILL it)"
elif [[ $code -eq 0 ]]; then
  ok "completed without hanging on never-closing socket"
else
  ko "unexpected exit on socket stdin: $code"
fi

echo "== test 6: missing -f file rejected =="
set +e
"$MAESTRODE" --dry-run -f /nonexistent/path/xxx "task" >/dev/null 2>&1
code=$?
set -e
[[ $code -eq 66 ]] && ok "exit 66 on missing file" || ko "wrong exit: $code"

# stub curl for the rest of the tests
SHIM_BIN="$TMP/bin"
FIXTURE="$TMP/fixture.json"
mkdir -p "$SHIM_BIN"
cat > "$SHIM_BIN/curl" <<EOF
#!/usr/bin/env bash
o=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) o="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "$FIXTURE" "\$o"
echo -n "200"
EOF
chmod +x "$SHIM_BIN/curl"

echo "== test 7: --files block parser =="
cat > "$FIXTURE" <<'JEOF'
{"choices":[{"message":{"content":"some prose\n\n<<<FILE: a.py>>>\nprint('a')\n<<<END FILE>>>\n\n<<<FILE: sub/b.txt>>>\nbody\n<<<END FILE>>>\n"}}],"usage":{"prompt_tokens":10,"completion_tokens":15}}
JEOF
OUTDIR="$TMP/out"
PATH="$SHIM_BIN:$PATH" echo "task" | PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --files "$OUTDIR" "go" >/dev/null 2>&1 || true
[[ -f "$OUTDIR/a.py" ]] && ok "wrote a.py" || ko "a.py missing"
[[ -f "$OUTDIR/sub/b.txt" ]] && ok "wrote sub/b.txt" || ko "sub/b.txt missing"
[[ "$(cat "$OUTDIR/a.py" 2>/dev/null)" == "print('a')" ]] && ok "a.py content" || ko "a.py wrong"

echo "== test 8: empty file block parses =="
cat > "$FIXTURE" <<'JEOF'
{"choices":[{"message":{"content":"<<<FILE: empty.txt>>>\n<<<END FILE>>>\n<<<FILE: nonempty.txt>>>\nhello\n<<<END FILE>>>"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
JEOF
rm -rf "$OUTDIR"
PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --files "$OUTDIR" "x" >/dev/null 2>&1 || true
[[ -f "$OUTDIR/empty.txt" ]] && ok "empty.txt created" || ko "empty.txt missing"
[[ -f "$OUTDIR/nonempty.txt" ]] && ok "nonempty.txt created" || ko "nonempty.txt missing"

echo "== test 9: unsafe paths refused =="
cat > "$FIXTURE" <<'JEOF'
{"choices":[{"message":{"content":"<<<FILE: ../escape.txt>>>\nbad\n<<<END FILE>>>\n<<<FILE: /etc/passwd>>>\nbad\n<<<END FILE>>>\n<<<FILE: ok.txt>>>\ngood\n<<<END FILE>>>"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
JEOF
rm -rf "$OUTDIR"
PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --files "$OUTDIR" "x" >/dev/null 2>&1 || true
[[ -f "$OUTDIR/ok.txt" ]] && ok "safe path written" || ko "safe path missing"
[[ ! -f "$OUTDIR/../escape.txt" ]] && ok "parent path refused" || ko "parent path leaked"

echo "== test 10: fence stripping =="
cat > "$FIXTURE" <<'JEOF'
{"choices":[{"message":{"content":"```python\nx = 1\n```"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
JEOF
out=$(PATH="$SHIM_BIN:$PATH" "$MAESTRODE" "task" 2>/dev/null)
[[ "$out" == "x = 1" ]] && ok "fences stripped" || ko "fence leak: '$out'"

echo "== test 11: --raw preserves fences =="
out=$(PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --raw "task" 2>/dev/null)
[[ "$out" == *'```python'* ]] && ok "raw kept fences" || ko "raw stripped"

echo "== test 12: em-dash strip =="
python3 -c "
import json
fix = '{\"choices\":[{\"message\":{\"content\":\"hello' + chr(0x2014) + 'world\"}}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}'
open('$FIXTURE','w').write(fix)
"
out=$(PATH="$SHIM_BIN:$PATH" "$MAESTRODE" "task" 2>/dev/null)
[[ "$out" == "hello-world" ]] && ok "em-dash replaced" || ko "em-dash leak: '$out'"

echo "== test 13: session persistence =="
cat > "$FIXTURE" <<'JEOF'
{"choices":[{"message":{"content":"reply1"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
JEOF
rm -f "$MAESTRODE_CONFIG_DIR/sessions/sess1.json"
PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --session sess1 "first message" >/dev/null 2>&1
SESS_FILE="$MAESTRODE_CONFIG_DIR/sessions/sess1.json"
[[ -f "$SESS_FILE" ]] && ok "session created" || ko "session missing"
turn1=$(python3 -c "import json; print(len(json.load(open('$SESS_FILE'))))" 2>/dev/null)
[[ "$turn1" == "2" ]] && ok "session has 2 entries after turn 1" || ko "session len wrong: $turn1"

cat > "$FIXTURE" <<'JEOF'
{"choices":[{"message":{"content":"reply2"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
JEOF
PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --session sess1 "second message" >/dev/null 2>&1
turn2=$(python3 -c "import json; print(len(json.load(open('$SESS_FILE'))))" 2>/dev/null)
[[ "$turn2" == "4" ]] && ok "session has 4 entries after turn 2" || ko "session len wrong: $turn2"

echo "== test 14: NEEDS_SMART bare marker exits 5 =="
cat > "$FIXTURE" <<'JEOF'
{"choices":[{"message":{"content":"<<<NEEDS_SMART>>>"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
JEOF
set +e
err=$(PATH="$SHIM_BIN:$PATH" "$MAESTRODE" "task" 2>&1 >/dev/null)
code=$?
set -e
[[ $code -eq 5 ]] && ok "exit 5 on NEEDS_SMART" || ko "wrong exit: $code"
[[ "$err" == *"muscle escalated"* ]] && ok "escalation reason logged" || ko "no escalation log: $err"
[[ "$err" == *"no reason given"* ]] && ok "bare marker shows placeholder reason" || ko "missing placeholder: $err"

echo "== test 15: NEEDS_SMART with rationale =="
cat > "$FIXTURE" <<'JEOF'
{"choices":[{"message":{"content":"<<<NEEDS_SMART: brief lacks the failing assertion text>>>\n\nfollow up junk"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
JEOF
set +e
err=$(PATH="$SHIM_BIN:$PATH" "$MAESTRODE" "task" 2>&1 >/dev/null)
code=$?
set -e
[[ $code -eq 5 ]] && ok "exit 5 with rationale" || ko "wrong exit: $code"
[[ "$err" == *"brief lacks the failing assertion text"* ]] && ok "rationale surfaced" || ko "rationale missing: $err"

echo "== test 16: NEEDS_SMART does not write session or files =="
cat > "$FIXTURE" <<'JEOF'
{"choices":[{"message":{"content":"<<<NEEDS_SMART: too vague>>>"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
JEOF
rm -rf "$OUTDIR"
rm -f "$MAESTRODE_CONFIG_DIR/sessions/sess_esc.json"
set +e
PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --session sess_esc --files "$OUTDIR" "task" >/dev/null 2>&1
set -e
[[ ! -f "$MAESTRODE_CONFIG_DIR/sessions/sess_esc.json" ]] && ok "no session file written on escalation" || ko "session leaked on escalation"
[[ ! -d "$OUTDIR" ]] || [[ -z "$(ls -A "$OUTDIR" 2>/dev/null)" ]] && ok "no files written on escalation" || ko "files leaked on escalation"

echo "== test 17: finish_reason=length emits truncation warning =="
cat > "$FIXTURE" <<'JEOF'
{"choices":[{"message":{"content":"partial content here"},"finish_reason":"length"}],"usage":{"prompt_tokens":10,"completion_tokens":20}}
JEOF
set +e
err=$(PATH="$SHIM_BIN:$PATH" "$MAESTRODE" "task" 2>&1 >/dev/null)
code=$?
set -e
[[ $code -eq 0 ]] && ok "still exits 0 (content delivered)" || ko "wrong exit: $code"
[[ "$err" == *"cut by max_tokens"* ]] && ok "max_tokens warning surfaced" || ko "no truncation warning: $err"
[[ "$err" == *"finish=length"* ]] && ok "finish_reason shown in stat line" || ko "finish missing: $err"

echo "== test 18: unclosed <<<FILE:>>> blocks emit truncation diagnostic =="
cat > "$FIXTURE" <<'JEOF'
{"choices":[{"message":{"content":"<<<FILE: ok.py>>>\nclosed body\n<<<END FILE>>>\n\n<<<FILE: cut.py>>>\nbody that never closes"},"finish_reason":"length"}],"usage":{"prompt_tokens":10,"completion_tokens":20}}
JEOF
rm -rf "$OUTDIR"
set +e
err=$(PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --files "$OUTDIR" "task" 2>&1 >/dev/null)
code=$?
set -e
[[ -f "$OUTDIR/ok.py" ]] && ok "closed block still written" || ko "closed block missing"
[[ ! -f "$OUTDIR/cut.py" ]] && ok "unclosed block not written" || ko "unclosed block leaked"
[[ "$err" == *"opened but not closed"* ]] && ok "unclosed-block diagnostic surfaced" || ko "no unclosed diagnostic: $err"

echo
echo "==== $PASS passed, $FAIL failed ===="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
