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

# stub curl for the rest of the tests. The shim now streams SSE: pipes curl
# stdout into the SSE parser and reads HTTP status from a -D headers file.
# This stub converts the non-stream fixture JSON into a 2-chunk SSE stream
# so the parser is actually exercised end-to-end.
SHIM_BIN="$TMP/bin"
FIXTURE="$TMP/fixture.json"
mkdir -p "$SHIM_BIN"
cat > "$SHIM_BIN/curl" <<EOF
#!/usr/bin/env bash
FIXTURE="$FIXTURE"
hdrs=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -D) hdrs="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "\$hdrs" ]] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "\$hdrs"
python3 - "\$FIXTURE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
choice = d["choices"][0]
msg = choice.get("message") or {}
content = msg.get("content") or ""
finish = choice.get("finish_reason") or "stop"
usage = d.get("usage") or {}
sys.stdout.write("data: " + json.dumps({"choices":[{"delta":{"content":content},"finish_reason":None}]}) + "\n\n")
sys.stdout.write("data: " + json.dumps({"choices":[{"delta":{},"finish_reason":finish}],"usage":usage}) + "\n\n")
sys.stdout.write("data: [DONE]\n\n")
PY
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

# ---- Anthropic Messages protocol (zen minimax/qwen path) ----
# Swap the curl stub for one that captures the request body and emits an
# Anthropic Messages SSE stream from a fixture, so the anthropic branch of the
# parser + payload builder is exercised end-to-end with no network.
REQ_CAP="$TMP/anthropic_req.json"
ANTHRO_FIX="$TMP/anthropic_fix.json"
cat > "$SHIM_BIN/curl" <<EOF
#!/usr/bin/env bash
ANTHRO_FIX="$ANTHRO_FIX"
REQ_CAP="$REQ_CAP"
hdrs=""; body=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -D) hdrs="\$2"; shift 2 ;;
    --data-binary) body="\${2#@}"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "\$body" && -f "\$body" ]] && cp "\$body" "\$REQ_CAP"
[[ -n "\$hdrs" ]] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "\$hdrs"
python3 - "\$ANTHRO_FIX" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
def ev(t, obj):
    obj["type"] = t
    sys.stdout.write("event: " + t + "\n")
    sys.stdout.write("data: " + json.dumps(obj) + "\n\n")
ev("message_start", {"message": {"model": "minimax-m3",
    "usage": {"input_tokens": d.get("input_tokens", 10),
              "cache_read_input_tokens": d.get("cache_read_input_tokens", 0)}}})
ev("content_block_start", {"index": 0, "content_block": {"type": "text", "text": ""}})
if d.get("thinking"):
    ev("content_block_delta", {"index": 0, "delta": {"type": "thinking_delta", "thinking": d["thinking"]}})
if d.get("content"):
    ev("content_block_delta", {"index": 0, "delta": {"type": "text_delta", "text": d["content"]}})
ev("content_block_stop", {"index": 0})
ev("message_delta", {"delta": {"stop_reason": d.get("stop_reason", "end_turn")},
                     "usage": {"output_tokens": d.get("output_tokens", 20)}})
ev("message_stop", {})
PY
EOF
chmod +x "$SHIM_BIN/curl"

echo "== test 19: anthropic protocol request shape (system top-level, no stream_options) =="
cat > "$ANTHRO_FIX" <<'JEOF'
{"content":"hello from anthropic","stop_reason":"end_turn","input_tokens":12,"output_tokens":5}
JEOF
out=$(MAESTRODE_PROTOCOL=anthropic PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --system "be terse" "hi" 2>/dev/null)
[[ "$out" == "hello from anthropic" ]] && ok "anthropic content delivered" || ko "anthropic content wrong: '$out'"
python3 -c "
import json
p=json.load(open('$REQ_CAP'))
assert p.get('system')=='be terse', 'system not top-level'
assert 'stream_options' not in p, 'stream_options leaked'
assert p.get('max_tokens'), 'max_tokens missing'
assert all(m['role']!='system' for m in p['messages']), 'system role in messages'
" >/dev/null 2>&1 && ok "anthropic payload shape correct" || ko "anthropic payload shape wrong"

echo "== test 20: anthropic endpoint auto-detect from /messages path =="
cat > "$ANTHRO_FIX" <<'JEOF'
{"content":"auto detected","stop_reason":"end_turn","input_tokens":1,"output_tokens":1}
JEOF
out=$(MAESTRODE_ENDPOINT="https://x.test/v1/messages" PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --system "s" "hi" 2>/dev/null)
[[ "$out" == "auto detected" ]] && ok "/messages auto-selected anthropic" || ko "auto-detect failed: '$out'"
python3 -c "
import json
p=json.load(open('$REQ_CAP'))
assert p.get('system')=='s' and 'stream_options' not in p
" >/dev/null 2>&1 && ok "auto-detect produced anthropic payload" || ko "auto-detect payload wrong"

echo "== test 21: anthropic thinking_delta routes to reasoning, content stays clean =="
cat > "$ANTHRO_FIX" <<'JEOF'
{"content":"final answer","thinking":"secret reasoning here","stop_reason":"end_turn","input_tokens":12,"output_tokens":5}
JEOF
out=$(MAESTRODE_PROTOCOL=anthropic PATH="$SHIM_BIN:$PATH" "$MAESTRODE" "q" 2>/dev/null)
[[ "$out" == "final answer" ]] && ok "content clean (reasoning not leaked)" || ko "reasoning leaked into content: '$out'"
full=$(MAESTRODE_PROTOCOL=anthropic PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --full "q" 2>/dev/null)
[[ "$full" == *"secret reasoning here"* ]] && ok "reasoning surfaced under --full" || ko "reasoning missing under --full"

echo "== test 22: anthropic inline <think> in text channel stripped (minimax case) =="
cat > "$ANTHRO_FIX" <<'JEOF'
{"content":"<think>deliberating out loud</think>clean output","stop_reason":"end_turn","input_tokens":1,"output_tokens":1}
JEOF
out=$(MAESTRODE_PROTOCOL=anthropic PATH="$SHIM_BIN:$PATH" "$MAESTRODE" "q" 2>/dev/null)
[[ "$out" == "clean output" ]] && ok "inline think stripped from content" || ko "think leaked: '$out'"

echo "== test 23: anthropic stop_reason=max_tokens maps to length =="
cat > "$ANTHRO_FIX" <<'JEOF'
{"content":"partial","stop_reason":"max_tokens","input_tokens":12,"output_tokens":5}
JEOF
err=$(MAESTRODE_PROTOCOL=anthropic PATH="$SHIM_BIN:$PATH" "$MAESTRODE" "q" 2>&1 >/dev/null)
[[ "$err" == *"finish=length"* ]] && ok "max_tokens -> length in stat line" || ko "length map missing: $err"
[[ "$err" == *"cut by max_tokens"* ]] && ok "truncation warning surfaced" || ko "no truncation warning"

echo "== test 24: --think sends MiniMax adaptive thinking (anthropic) =="
cat > "$ANTHRO_FIX" <<'JEOF'
{"content":"x","stop_reason":"end_turn","input_tokens":1,"output_tokens":1}
JEOF
MAESTRODE_PROTOCOL=anthropic PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --think "q" >/dev/null 2>&1
python3 -c "
import json
p=json.load(open('$REQ_CAP'))
assert p.get('thinking')=={'type':'adaptive'}, p.get('thinking')
" >/dev/null 2>&1 && ok "--think -> thinking type=adaptive (no budget)" || ko "--think payload wrong"

echo "== test 25: --thinking-budget sends Anthropic enabled+budget =="
MAESTRODE_PROTOCOL=anthropic PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --thinking-budget 1500 "q" >/dev/null 2>&1
python3 -c "
import json
p=json.load(open('$REQ_CAP'))
t=p.get('thinking') or {}
assert t.get('type')=='enabled' and t.get('budget_tokens')==1500, t
" >/dev/null 2>&1 && ok "--thinking-budget -> enabled + budget_tokens" || ko "budget payload wrong"

echo "== test 26: --thinking-type overrides the default =="
MAESTRODE_PROTOCOL=anthropic PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --thinking-type disabled --think "q" >/dev/null 2>&1
python3 -c "
import json
p=json.load(open('$REQ_CAP'))
assert (p.get('thinking') or {}).get('type')=='disabled', p.get('thinking')
" >/dev/null 2>&1 && ok "--thinking-type wins" || ko "thinking-type override failed"

echo "== test 27: env file is defaults, caller env wins (no clobber) =="
# env file pins one model; caller exports another. Caller must win.
echo 'MAESTRODE_API_KEY=test-key-not-real' > "$MAESTRODE_CONFIG_DIR/env"
echo 'MAESTRODE_MODEL=file-model' >> "$MAESTRODE_CONFIG_DIR/env"
MAESTRODE_PROTOCOL=anthropic MAESTRODE_MODEL=caller-model \
  PATH="$SHIM_BIN:$PATH" "$MAESTRODE" "q" >/dev/null 2>&1
python3 -c "
import json
p=json.load(open('$REQ_CAP'))
assert p.get('model')=='caller-model', p.get('model')
" >/dev/null 2>&1 && ok "caller MAESTRODE_MODEL overrides env file" || ko "env file clobbered caller override"

# ---- --tools agentic write_file loop (maestrode ultra) ----
# Stub curl to return canned NON-streaming Anthropic responses, one per call,
# counted via a file. Exercises the full tool loop: tool_use -> write -> result
# -> re-call, terminating when stop_reason flips to end_turn.
CNT="$TMP/tool_call_count"
RESPDIR="$TMP/tool_resps"; mkdir -p "$RESPDIR"
cat > "$SHIM_BIN/curl" <<EOF
#!/usr/bin/env bash
CNT="$CNT"; RESPDIR="$RESPDIR"
hdrs=""
while [[ \$# -gt 0 ]]; do case "\$1" in -D) hdrs="\$2"; shift 2 ;; *) shift ;; esac; done
n=\$(cat "\$CNT" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "\$CNT"
[[ -n "\$hdrs" ]] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "\$hdrs"
cat "\$RESPDIR/\$n.json"
EOF
chmod +x "$SHIM_BIN/curl"

echo "== test 28: --tools agentic loop writes multiple files then stops =="
echo 0 > "$CNT"
cat > "$RESPDIR/1.json" <<'JEOF'
{"content":[{"type":"thinking","thinking":"plan the files","signature":"sig1"},{"type":"tool_use","id":"t1","name":"write_file","input":{"path":"a.py","content":"print('a')"}}],"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":2}}
JEOF
cat > "$RESPDIR/2.json" <<'JEOF'
{"content":[{"type":"tool_use","id":"t2","name":"write_file","input":{"path":"sub/b.py","content":"print('b')"}}],"stop_reason":"tool_use","usage":{"input_tokens":12,"output_tokens":6}}
JEOF
cat > "$RESPDIR/3.json" <<'JEOF'
{"content":[{"type":"text","text":"all done"}],"stop_reason":"end_turn","usage":{"input_tokens":14,"output_tokens":3}}
JEOF
TOOLDIR="$TMP/tools_out"; rm -rf "$TOOLDIR"
MAESTRODE_PROTOCOL=anthropic PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --tools --files "$TOOLDIR" "write a and b" >/dev/null 2>&1 || true
[[ -f "$TOOLDIR/a.py" ]] && ok "tool wrote a.py" || ko "a.py missing"
[[ -f "$TOOLDIR/sub/b.py" ]] && ok "tool wrote nested sub/b.py" || ko "sub/b.py missing"
[[ "$(cat "$TOOLDIR/a.py" 2>/dev/null)" == "print('a')" ]] && ok "a.py content correct" || ko "a.py content wrong"
[[ "$(cat "$CNT")" == "3" ]] && ok "loop ran 3 iters then stopped on end_turn" || ko "wrong iter count: $(cat "$CNT")"

echo "== test 29: --tools requires --files =="
set +e
MAESTRODE_PROTOCOL=anthropic PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --tools "x" >/dev/null 2>&1
code=$?
set -e
[[ $code -eq 64 ]] && ok "exit 64 without --files" || ko "wrong exit: $code"

echo "== test 30: --tools drives OpenAI tool_calls loop (kimi path) =="
echo 0 > "$CNT"
cat > "$RESPDIR/1.json" <<'JEOF'
{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"write_file","arguments":"{\"path\": \"oa.py\", \"content\": \"print(1)\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}
JEOF
cat > "$RESPDIR/2.json" <<'JEOF'
{"choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":2}}
JEOF
OADIR="$TMP/oa_out"; rm -rf "$OADIR"
MAESTRODE_PROTOCOL=openai PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --tools --files "$OADIR" "write oa" >/dev/null 2>&1 || true
[[ -f "$OADIR/oa.py" ]] && ok "openai tool_calls wrote oa.py" || ko "oa.py missing"
[[ "$(cat "$OADIR/oa.py" 2>/dev/null)" == "print(1)" ]] && ok "oa.py content correct" || ko "oa.py content wrong"
[[ "$(cat "$CNT")" == "2" ]] && ok "openai loop ran 2 iters then stopped on finish=stop" || ko "wrong iter count: $(cat "$CNT")"

echo "== test 31: --tools refuses unsafe write_file path =="
echo 0 > "$CNT"
cat > "$RESPDIR/1.json" <<'JEOF'
{"content":[{"type":"tool_use","id":"t1","name":"write_file","input":{"path":"../escape.py","content":"bad"}},{"type":"tool_use","id":"t2","name":"write_file","input":{"path":"ok.py","content":"good"}}],"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}}
JEOF
cat > "$RESPDIR/2.json" <<'JEOF'
{"content":[{"type":"text","text":"done"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
JEOF
TOOLDIR2="$TMP/tools_out2"; rm -rf "$TOOLDIR2"
MAESTRODE_PROTOCOL=anthropic PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --tools --files "$TOOLDIR2" "x" >/dev/null 2>&1 || true
[[ -f "$TOOLDIR2/ok.py" ]] && ok "safe path written in tool mode" || ko "safe path missing"
[[ ! -f "$TMP/escape.py" ]] && ok "unsafe ../ path refused in tool mode" || ko "unsafe path leaked"

# ---- mode profiles (--ultra / --brain / overrides) ----
# Smart stub: captures the request, returns JSON for non-stream (tool) calls and
# SSE for streaming, so both the tool path and the stream path terminate cleanly.
cat > "$SHIM_BIN/curl" <<EOF
#!/usr/bin/env bash
body=""
while [[ \$# -gt 0 ]]; do case "\$1" in --data-binary) body="\${2#@}"; cp "\$body" "$REQ_CAP" 2>/dev/null ;; -D) printf 'HTTP/1.1 200 OK\r\n\r\n' > "\$2"; shift ;; esac; shift; done
if grep -q '"stream": *false' "\$body" 2>/dev/null; then
  echo '{"choices":[{"message":{"content":"done"},"finish_reason":"stop"}],"usage":{}}'
else
  printf 'data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{}}\ndata: [DONE]\n\n'
fi
EOF
chmod +x "$SHIM_BIN/curl"
PROF="MAESTRODE_MODEL=normal-m MAESTRODE_ENDPOINT=https://x/v1/chat/completions \
MAESTRODE_BRAIN_MODEL=brain-m MAESTRODE_BRAIN_ENDPOINT=https://x/v1/messages \
MAESTRODE_ULTRA_MODEL=ultra-m MAESTRODE_ULTRA_ENDPOINT=https://x/v1/chat/completions"
field() { python3 -c "import json;p=json.load(open('$REQ_CAP'));print($1)" 2>/dev/null; }

echo "== test 32: default uses normal muscle, no tools =="
rm -f "$REQ_CAP"
env $PROF PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --files "$TMP/m0" "x" >/dev/null 2>&1 || true
[[ "$(field "p['model']")" == "normal-m" ]] && ok "normal model resolved" || ko "normal model wrong: $(field "p['model']")"
[[ "$(field "'tools' in p")" == "False" ]] && ok "normal has no tools" || ko "normal leaked tools"

echo "== test 33: --ultra uses ultra muscle + tools + reasoning none =="
rm -f "$REQ_CAP"
env $PROF PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --ultra --files "$TMP/m1" "x" >/dev/null 2>&1 || true
[[ "$(field "p['model']")" == "ultra-m" ]] && ok "ultra model resolved" || ko "ultra model wrong: $(field "p['model']")"
[[ "$(field "'tools' in p")" == "True" ]] && ok "ultra enables tools" || ko "ultra missing tools"
[[ "$(field "p.get('reasoning_effort')")" == "none" ]] && ok "ultra reasoning=none" || ko "ultra reasoning wrong: $(field "p.get('reasoning_effort')")"

echo "== test 34: --brain uses brain model, anthropic, NO auto-thinking =="
rm -f "$REQ_CAP"
env $PROF PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --brain "plan x" >/dev/null 2>&1 || true
[[ "$(field "p['model']")" == "brain-m" ]] && ok "brain model resolved" || ko "brain model wrong: $(field "p['model']")"
# brain reasons into plan text; thinking must NOT be auto-enabled (it would
# burn the token budget before the plan content is written).
[[ "$(field "'thinking' in p")" == "False" ]] && ok "brain does not auto-enable thinking" || ko "brain leaked thinking: $(field "p.get('thinking')")"
[[ "$(field "'stream_options' in p")" == "False" ]] && ok "brain payload is anthropic-shaped" || ko "brain not anthropic"

echo "== test 34b: MAESTRODE_BRAIN_THINK=1 opts back into thinking =="
rm -f "$REQ_CAP"
env $PROF MAESTRODE_BRAIN_THINK=1 PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --brain "plan x" >/dev/null 2>&1 || true
[[ "$(field "(p.get('thinking') or {}).get('type')")" == "adaptive" ]] && ok "BRAIN_THINK=1 enables thinking" || ko "opt-in thinking failed: $(field "p.get('thinking')")"

echo "== test 34c: MAESTRODE_BRAIN_THINKING_TYPE=disabled forces thinking.type=disabled =="
rm -f "$REQ_CAP"
env $PROF MAESTRODE_BRAIN_THINKING_TYPE=disabled PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --brain "plan x" >/dev/null 2>&1 || true
[[ "$(field "(p.get('thinking') or {}).get('type')")" == "disabled" ]] && ok "brain thinking forced disabled" || ko "brain thinking type wrong: $(field "p.get('thinking')")"

echo "== test 34d: CLI --think overrides MAESTRODE_BRAIN_THINKING_TYPE =="
rm -f "$REQ_CAP"
env $PROF MAESTRODE_BRAIN_THINKING_TYPE=disabled PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --brain --think "plan x" >/dev/null 2>&1 || true
[[ "$(field "(p.get('thinking') or {}).get('type')")" == "adaptive" ]] && ok "CLI --think wins over env type" || ko "override precedence wrong: $(field "p.get('thinking')")"

echo "== test 35: --model overrides the profile =="
rm -f "$REQ_CAP"
env $PROF PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --ultra --model my-override --files "$TMP/m2" "x" >/dev/null 2>&1 || true
[[ "$(field "p['model']")" == "my-override" ]] && ok "--model overrides ultra profile" || ko "override failed: $(field "p['model']")"

echo "== test 36: --ultra uses a context-safe default max_tokens (not 256000) =="
rm -f "$REQ_CAP"
env $PROF PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --ultra --files "$TMP/m36" "x" >/dev/null 2>&1 || true
[[ "$(field "p['max_tokens']")" == "32000" ]] && ok "ultra default max_tokens=32000" || ko "ultra max_tokens wrong: $(field "p['max_tokens']")"

echo "== test 37: MAESTRODE_ULTRA_MAX_TOKENS overrides the ultra default =="
rm -f "$REQ_CAP"
env $PROF MAESTRODE_ULTRA_MAX_TOKENS=48000 PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --ultra --files "$TMP/m37" "x" >/dev/null 2>&1 || true
[[ "$(field "p['max_tokens']")" == "48000" ]] && ok "ULTRA_MAX_TOKENS honored" || ko "ULTRA_MAX_TOKENS ignored: $(field "p['max_tokens']")"

echo "== test 38: explicit --max-tokens wins over the ultra default =="
rm -f "$REQ_CAP"
env $PROF PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --ultra --max-tokens 5000 --files "$TMP/m38" "x" >/dev/null 2>&1 || true
[[ "$(field "p['max_tokens']")" == "5000" ]] && ok "explicit --max-tokens wins" || ko "explicit max_tokens lost: $(field "p['max_tokens']")"

echo "== test 39: context clamp reduces max_tokens below the reservation =="
rm -f "$REQ_CAP"
err=$(env $PROF MAESTRODE_ULTRA_CONTEXT_LIMIT=20000 PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --ultra --files "$TMP/m39" "x" 2>&1 >/dev/null) || true
mt=$(field "p['max_tokens']")
[[ -n "$mt" && "$mt" -lt 32000 ]] && ok "max_tokens clamped to $mt (< 32000)" || ko "clamp did not fire: max_tokens=$mt"
[[ "$err" == *"clamped max_tokens"* ]] && ok "clamp diagnostic surfaced" || ko "no clamp message: $err"

echo "== test 40: input larger than context exits non-zero, no call =="
rm -f "$REQ_CAP"
set +e
err=$(env $PROF MAESTRODE_ULTRA_CONTEXT_LIMIT=10 PATH="$SHIM_BIN:$PATH" "$MAESTRODE" --ultra --files "$TMP/m40" "x" 2>&1 >/dev/null)
code=$?
set -e
[[ $code -ne 0 ]] && ok "oversized input exits non-zero ($code)" || ko "oversized input exited 0"
[[ "$err" == *"exceeds"*"context"* ]] && ok "oversized-input diagnostic surfaced" || ko "no oversize message: $err"

# ---- empty output (out=0) fail-loud on the plain-text path ----
# Stub returns a stream whose content delta is controlled by EMPTY_CONTENT.
cat > "$SHIM_BIN/curl" <<EOF
#!/usr/bin/env bash
body=""
while [[ \$# -gt 0 ]]; do case "\$1" in --data-binary) body="\${2#@}" ;; -D) printf 'HTTP/1.1 200 OK\r\n\r\n' > "\$2"; shift ;; esac; shift; done
if [[ "\${EMPTY_CONTENT:-1}" == "1" ]]; then
  printf 'data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"completion_tokens":0,"prompt_tokens":5}}\ndata: [DONE]\n\n'
else
  printf 'data: {"choices":[{"delta":{"content":"a real plan"},"finish_reason":"stop"}],"usage":{"completion_tokens":3,"prompt_tokens":5}}\ndata: [DONE]\n\n'
fi
EOF
chmod +x "$SHIM_BIN/curl"

# plain-text call on the normal (openai) profile so the openai-shaped SSE stub parses.
echo "== test 41: empty plain-text output exits 6 =="
set +e
err=$(env $PROF EMPTY_CONTENT=1 PATH="$SHIM_BIN:$PATH" "$MAESTRODE" "plan a big thing" 2>&1 >/dev/null)
code=$?
set -e
[[ $code -eq 6 ]] && ok "empty output exits 6" || ko "empty output exit wrong: $code"
[[ "$err" == *"empty output (out=0)"* ]] && ok "empty-output diagnostic surfaced" || ko "no empty-output message: $err"

echo "== test 42: non-empty plain-text output still exits 0 =="
set +e
out=$(env $PROF EMPTY_CONTENT=0 PATH="$SHIM_BIN:$PATH" "$MAESTRODE" "plan a big thing" 2>/dev/null)
code=$?
set -e
[[ $code -eq 0 && "$out" == "a real plan" ]] && ok "non-empty output exits 0 with content" || ko "non-empty path broke: code=$code out='$out'"

echo
echo "==== $PASS passed, $FAIL failed ===="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
