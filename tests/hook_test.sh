#!/usr/bin/env bash
# Unit tests for `maestrode hook` (the Claude Code persistence hooks).
# No network. Drives the subcommand with canned stdin JSON and asserts both
# stdout JSON and the per-session filesystem state. Covers the leak guarantee:
# one session never sees another session's active flag.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAESTRODE="${SCRIPT_DIR}/../src/maestrode"

PASS=0
FAIL=0
TMP=$(mktemp -d -t maestrode_hook_test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export MAESTRODE_CONFIG_DIR="$TMP/config"
SESS="$MAESTRODE_CONFIG_DIR/sessions"

ok() { PASS=$((PASS+1)); echo "  ok: $1"; }
ko() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# hook EVENT JSON -> prints stdout of the hook call
hook() { printf '%s' "$2" | bash "$MAESTRODE" hook "$1"; }

assert_contains() { # desc, haystack, needle
  if printf '%s' "$2" | grep -q -- "$3"; then ok "$1"; else ko "$1 (missing: $3)"; fi
}
assert_empty() { # desc, value
  if [[ -z "$2" ]]; then ok "$1"; else ko "$1 (got: $2)"; fi
}
assert_file() { # desc, path
  if [[ -e "$2" ]]; then ok "$1"; else ko "$1 (no file: $2)"; fi
}
assert_nofile() { # desc, path
  if [[ ! -e "$2" ]]; then ok "$1"; else ko "$1 (file exists: $2)"; fi
}

echo "syntax check"
if bash -n "$MAESTRODE"; then ok "shim parses"; else ko "shim parses"; fi

echo "activation"
out=$(hook user-prompt '{"session_id":"S1","prompt":"maestrode on please"}')
assert_contains "activate injects ON banner" "$out" "maestrode ON"
assert_file "activate writes session flag" "$SESS/S1"

echo "standing banner while active"
out=$(hook user-prompt '{"session_id":"S1","prompt":"build the parser"}')
assert_contains "standing banner re-injected" "$out" "delegate to the muscle"

echo "leak guarantee"
out=$(hook user-prompt '{"session_id":"S2","prompt":"hello there"}')
assert_empty "second session sees no banner (no leak)" "$out"
assert_nofile "second session has no flag" "$SESS/S2"

echo "cold direct edit nudges + counts"
out=$(hook pre-tool '{"session_id":"S1","tool_name":"Edit","tool_input":{"file_path":"/x.py"}}')
assert_contains "cold edit nudge" "$out" "Direct edit while mode is ON"
out=$(hook pre-tool '{"session_id":"S1","tool_name":"Edit","tool_input":{"file_path":"/y.py"}}')
assert_file "direct counter file created" "$SESS/S1.direct"
if [[ "$(cat "$SESS/S1.direct")" == "2" ]]; then ok "direct count == 2"; else ko "direct count ($(cat "$SESS/S1.direct"))"; fi

echo "drift escalation in banner"
out=$(hook user-prompt '{"session_id":"S1","prompt":"next step"}')
assert_contains "banner escalates on drift" "$out" "drift"
assert_contains "drift banner shows count" "$out" "bypassed the muscle 2 times"

echo "subagent (Task) spawn nudges + counts"
out=$(hook pre-tool '{"session_id":"S1","tool_name":"Task","tool_input":{}}')
assert_contains "Task nudge" "$out" "spawning a subagent"
if [[ "$(cat "$SESS/S1.direct")" == "3" ]]; then ok "Task increments counter"; else ko "Task count ($(cat "$SESS/S1.direct"))"; fi

echo "real muscle call resets drift, sets lastcall"
out=$(hook pre-tool '{"session_id":"S1","tool_name":"Bash","tool_input":{"command":"maestrode -f a.py \"do x\""}}')
assert_empty "muscle Bash call is silent" "$out"
assert_nofile "direct counter reset" "$SESS/S1.direct"
assert_file "lastcall recorded" "$SESS/S1.lastcall"

echo "warm edit (recent muscle call) stays silent"
out=$(hook pre-tool '{"session_id":"S1","tool_name":"Edit","tool_input":{"file_path":"/x.py"}}')
assert_empty "warm edit silent (applying output)" "$out"

echo "maestrode gain/hook Bash calls do NOT count as delegation"
rm -f "$SESS/S1.lastcall"
out=$(hook pre-tool '{"session_id":"S1","tool_name":"Bash","tool_input":{"command":"maestrode gain"}}')
assert_nofile "gain does not set lastcall" "$SESS/S1.lastcall"

echo "deactivation"
out=$(hook user-prompt '{"session_id":"S1","prompt":"maestrode off"}')
assert_contains "deactivate injects OFF" "$out" "maestrode OFF"
assert_nofile "deactivate clears flag" "$SESS/S1"

# regression: "turn off /maestrode ultra" (leading slash + trailing mode word)
# must deactivate, NOT be re-read as activating ultra (the off-phrase has to
# short-circuit the mode-select even though it contains "maestrode ultra").
hook user-prompt '{"session_id":"S5","prompt":"maestrode ultra"}' >/dev/null
assert_file "S5 ultra active" "$SESS/S5"
out=$(hook user-prompt '{"session_id":"S5","prompt":"ok turn off /maestrode ultra"}')
assert_contains "slash off-phrase injects OFF" "$out" "maestrode OFF"
assert_nofile "slash off-phrase clears (no re-arm)" "$SESS/S5"

echo "session-end cleanup"
hook user-prompt '{"session_id":"S3","prompt":"use maestrode"}' >/dev/null
assert_file "S3 active" "$SESS/S3"
hook session-end '{"session_id":"S3"}' >/dev/null
assert_nofile "session-end removed flag" "$SESS/S3"

echo "missing session_id is a safe no-op (no crash, no global file)"
out=$(hook user-prompt '{"prompt":"maestrode on"}' 2>&1) && rc=0 || rc=$?
assert_empty "no-sid produces no output" "$out"
if [[ "${rc:-0}" == "0" ]]; then ok "no-sid exits 0"; else ko "no-sid exit ($rc)"; fi

echo "stale reaper removes old session files"
old="$SESS/OLD"; : > "$old"
# backdate 8 days
python3 -c "import os,time;p='$old';t=time.time()-8*86400;os.utime(p,(t,t))"
hook user-prompt '{"session_id":"S4","prompt":"hi"}' >/dev/null
assert_nofile "8-day-old session reaped" "$old"

echo
echo "hook tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
