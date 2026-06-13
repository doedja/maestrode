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

echo "workflow mode: activation + banner"
out=$(hook user-prompt '{"session_id":"S6","prompt":"maestrode workflow"}')
assert_contains "workflow activates" "$out" "maestrode WORKFLOW"
assert_contains "workflow banner names Workflow tool" "$out" "Workflow tool"
assert_contains "workflow banner forces cheap-tier override" "$out" "cheap tier"
assert_file "workflow writes session flag" "$SESS/S6"
if [[ "$(head -1 "$SESS/S6")" == "workflow" ]]; then ok "mode stored as workflow"; else ko "mode stored ($(head -1 "$SESS/S6"))"; fi

echo 'workflow mode: incidental "workflow mode" mention does NOT activate'
out=$(hook user-prompt '{"session_id":"S7","prompt":"i hate workflow mode honestly"}')
assert_empty "discussing workflow does not activate (needs maestrode adjacency)" "$out"
assert_nofile "no flag from incidental mention" "$SESS/S7"

echo "workflow mode: drift counting is suppressed (subagents ARE the muscle)"
out=$(hook pre-tool '{"session_id":"S6","tool_name":"Task","tool_input":{}}')
assert_empty "Task spawn silent in workflow mode" "$out"
assert_nofile "Task does not create drift counter" "$SESS/S6.direct"
out=$(hook pre-tool '{"session_id":"S6","tool_name":"Edit","tool_input":{"file_path":"/x.py"}}')
assert_empty "cold edit silent in workflow mode (audit is direct)" "$out"
assert_nofile "cold edit does not create drift counter" "$SESS/S6.direct"
out=$(hook user-prompt '{"session_id":"S6","prompt":"next"}')
assert_contains "standing workflow banner re-injected" "$out" "maestrode WORKFLOW"

echo "workflow mode: deactivation"
out=$(hook user-prompt '{"session_id":"S6","prompt":"turn off maestrode workflow"}')
assert_contains "workflow off-phrase injects OFF" "$out" "maestrode OFF"
assert_nofile "workflow off clears flag" "$SESS/S6"

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

echo "== install_hooks prunes a stale-format maestrode hook (no duplicate) =="
# Pull the embedded registration python out of install.sh and run it against a
# settings file that already holds an OLD-format maestrode pre-tool entry plus an
# unrelated hook. Re-registering the new (printf %q quoted) command must converge
# to a single maestrode entry and leave the unrelated hook intact.
INSTALL_SH="${SCRIPT_DIR}/../install.sh"
PRUNE_PY="$TMP/prune.py"
awk '/python3 - "\$SETTINGS_FILE" \\$/{f=1} f&&/<<.PY.$/{f=2;next} f==2&&/^PY$/{exit} f==2{print}' "$INSTALL_SH" > "$PRUNE_PY"
HSET="$TMP/hook_settings.json"
cat > "$HSET" <<'JEOF'
{"hooks":{"PreToolUse":[
  {"matcher":"Edit","hooks":[{"type":"command","command":"[ -n \"$(ls -A '/c/sessions' 2>/dev/null)\" ] && exec '/i/maestrode' hook pre-tool || exit 0"}]},
  {"matcher":"Bash","hooks":[{"type":"command","command":"some-other-tool hook pre-tool"}]}
]}}
JEOF
NEWPRE="[ -n \"\$(ls -A $(printf '%q' '/c/sessions') 2>/dev/null)\" ] && exec $(printf '%q' '/i/maestrode') hook pre-tool || exit 0"
python3 "$PRUNE_PY" "$HSET" "PreToolUse" "Edit|Write" "$NEWPRE" >/dev/null
python3 "$PRUNE_PY" "$HSET" "PreToolUse" "Edit|Write" "$NEWPRE" >/dev/null  # idempotent re-run
mcount=$(python3 -c "import json;s=json.load(open('$HSET'));print(sum(1 for e in s['hooks']['PreToolUse'] for h in e['hooks'] if 'maestrode' in h['command']))")
ocount=$(python3 -c "import json;s=json.load(open('$HSET'));print(sum(1 for e in s['hooks']['PreToolUse'] for h in e['hooks'] if h['command']=='some-other-tool hook pre-tool'))")
[[ "$mcount" == "1" ]] && ok "exactly one maestrode pre-tool hook after re-register" || ko "got $mcount maestrode pre-tool hooks"
[[ "$ocount" == "1" ]] && ok "unrelated hook preserved" || ko "unrelated hook lost ($ocount)"

echo
echo "hook tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
