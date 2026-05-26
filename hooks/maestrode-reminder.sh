#!/bin/sh
# Soft reminder when maestrode mode is active and brain reaches for direct
# Edit/Write. State is the existence of ~/.config/maestrode/active.
# Writes JSON to stdout so the reminder feeds back into Claude's context
# without blocking the tool call.

STATE="${HOME}/.config/maestrode/active"

if [ ! -f "$STATE" ]; then
  exit 0
fi

# Pull the tool name from the hook input (JSON via stdin).
TOOL=$(jq -r '.tool_name // empty')

case "$TOOL" in
  Edit|Write|MultiEdit|NotebookEdit)
    # Build the reminder message. Avoid em/en dashes (em-dash-check.sh).
    MSG='[maestrode reminder] mode is ON. Direct Edit/Write detected. If you are applying muscle output, that is fine; tag your reply with [maestrode: delegated <files>]. If brain is authoring direct for a real reason (one-line tweak, vague brief gathering, user said do it yourself, architecture / security call), tag with [maestrode: direct: <reason>]. Otherwise consider delegating: maestrode -f <path> --files out/ "<brief>".'
    # additionalContext on PreToolUse feeds text into Claude'"'"'s next turn.
    jq -nc --arg msg "$MSG" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        additionalContext: $msg
      }
    }'
    ;;
esac

exit 0
