#!/usr/bin/env bash
# maestrode installer. Works two ways:
#   1) curl piped:  curl -fsSL https://raw.githubusercontent.com/<user>/maestrode/main/install.sh | bash
#   2) from clone:  ./install.sh  (uses the local src/maestrode file)
# Idempotent: safe to re-run.
#
# Also drops the Claude Code skill at ~/.claude/skills/maestrode/SKILL.md
# and a PreToolUse reminder hook at ~/.claude/hooks/maestrode-reminder.sh
# (registered in ~/.claude/settings.json) when ~/.claude exists.
#   Set MAESTRODE_NO_SKILL=1 / MAESTRODE_NO_HOOK=1 to skip either.
#   Override paths with MAESTRODE_SKILL_DIR / MAESTRODE_HOOK_DIR /
#   MAESTRODE_SETTINGS_FILE.
#
# uninstall:
#   ./install.sh --uninstall            (remove binary + config + sessions + skill + hook)
#   ./install.sh --uninstall --keep-config   (remove binary + skill + hook only)
#   curl -fsSL .../install.sh | bash -s -- --uninstall

set -euo pipefail

REPO="${MAESTRODE_REPO:-doedja/maestrode}"
BRANCH="${MAESTRODE_BRANCH:-main}"
INSTALL_DIR="${MAESTRODE_INSTALL_DIR:-${HOME}/.local/bin}"
CONFIG_DIR="${MAESTRODE_CONFIG_DIR:-${HOME}/.config/maestrode}"
SKILL_DIR="${MAESTRODE_SKILL_DIR:-${HOME}/.claude/skills/maestrode}"
HOOK_DIR="${MAESTRODE_HOOK_DIR:-${HOME}/.claude/hooks}"
SETTINGS_FILE="${MAESTRODE_SETTINGS_FILE:-${HOME}/.claude/settings.json}"

RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

ACTION="install"
KEEP_CONFIG=0
for arg in "$@"; do
  case "$arg" in
    --uninstall)    ACTION="uninstall" ;;
    --keep-config)  KEEP_CONFIG=1 ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "install.sh: unknown flag $arg" >&2; exit 64 ;;
  esac
done

if [[ "$ACTION" == "uninstall" ]]; then
  removed=0
  BIN="$INSTALL_DIR/maestrode"
  if [[ -e "$BIN" ]]; then
    rm -f "$BIN"
    echo "removed $BIN"
    removed=1
  fi
  SKILL_FILE="$SKILL_DIR/SKILL.md"
  if [[ -e "$SKILL_FILE" ]]; then
    rm -f "$SKILL_FILE"
    rmdir "$SKILL_DIR" 2>/dev/null || true
    echo "removed $SKILL_FILE"
    removed=1
  fi
  HOOK_FILE="$HOOK_DIR/maestrode-reminder.sh"
  if [[ -e "$HOOK_FILE" ]]; then
    rm -f "$HOOK_FILE"
    rmdir "$HOOK_DIR" 2>/dev/null || true
    echo "removed $HOOK_FILE"
    removed=1
  fi
  if [[ -f "$SETTINGS_FILE" ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$SETTINGS_FILE" "$HOOK_FILE" <<'PY'
import json, os, sys
settings_path, hook_cmd = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f:
        d = json.load(f)
except (json.JSONDecodeError, OSError):
    sys.exit(0)
pre = d.get("hooks", {}).get("PreToolUse", [])
new_pre = []
changed = False
for entry in pre:
    orig = entry.get("hooks", [])
    kept = [hh for hh in orig if hh.get("command") != hook_cmd]
    if len(kept) != len(orig):
        changed = True
    if kept:
        e = dict(entry)
        e["hooks"] = kept
        new_pre.append(e)
if changed:
    d["hooks"]["PreToolUse"] = new_pre
    with open(settings_path, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    print(f"removed hook entry from {settings_path}")
PY
  fi
  if [[ $KEEP_CONFIG -eq 0 ]] && [[ -d "$CONFIG_DIR" ]]; then
    rm -rf "$CONFIG_DIR"
    echo "removed $CONFIG_DIR"
    removed=1
  fi
  if [[ $removed -eq 0 ]]; then
    if [[ $KEEP_CONFIG -eq 1 ]]; then
      echo "maestrode is not installed (nothing at $BIN)"
    else
      echo "maestrode is not installed (nothing at $BIN or $CONFIG_DIR)"
    fi
  else
    echo "maestrode uninstalled."
  fi
  exit 0
fi

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

# Prefer local src/maestrode (when run from clone). Fall back to download.
LOCAL_SRC=""
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${SCRIPT_DIR}/src/maestrode" ]]; then
    LOCAL_SRC="${SCRIPT_DIR}/src/maestrode"
  fi
fi

TMP=""
trap '[[ -n "$TMP" && -f "$TMP" ]] && rm -f "$TMP"' EXIT

if [[ -n "$LOCAL_SRC" ]]; then
  echo "Installing from local clone: ${LOCAL_SRC}"
  SRC="$LOCAL_SRC"
else
  echo "Downloading maestrode from ${RAW_BASE}/src/maestrode ..."
  TMP=$(mktemp)
  if ! curl -fsSL "${RAW_BASE}/src/maestrode" -o "$TMP"; then
    echo "error: failed to download maestrode" >&2
    exit 1
  fi
  if ! head -1 "$TMP" | grep -q '^#!/usr/bin/env bash'; then
    echo "error: downloaded file does not look like a bash script" >&2
    exit 1
  fi
  SRC="$TMP"
fi

install -m 0755 "$SRC" "$INSTALL_DIR/maestrode"

# Claude Code skill sync. Default: install if ~/.claude exists.
# Override: MAESTRODE_NO_SKILL=1 to skip, MAESTRODE_SKILL_DIR=/path to relocate.
if [[ "${MAESTRODE_NO_SKILL:-0}" != "1" ]] && [[ -d "${HOME}/.claude" || -n "${MAESTRODE_SKILL_DIR:-}" ]]; then
  LOCAL_SKILL=""
  if [[ -n "${SCRIPT_DIR:-}" ]] && [[ -f "${SCRIPT_DIR}/skill/maestrode.md" ]]; then
    LOCAL_SKILL="${SCRIPT_DIR}/skill/maestrode.md"
  fi
  mkdir -p "$SKILL_DIR"
  if [[ -n "$LOCAL_SKILL" ]]; then
    install -m 0644 "$LOCAL_SKILL" "${SKILL_DIR}/SKILL.md"
    echo "synced skill from ${LOCAL_SKILL} -> ${SKILL_DIR}/SKILL.md"
  else
    SKILL_TMP=$(mktemp)
    if curl -fsSL "${RAW_BASE}/skill/maestrode.md" -o "$SKILL_TMP"; then
      install -m 0644 "$SKILL_TMP" "${SKILL_DIR}/SKILL.md"
      echo "synced skill -> ${SKILL_DIR}/SKILL.md"
    else
      echo "warn: could not download skill from ${RAW_BASE}/skill/maestrode.md" >&2
    fi
    rm -f "$SKILL_TMP"
  fi
fi

# PreToolUse reminder hook. Fires on Edit/Write while ~/.config/maestrode/active
# exists, nudging brain to either delegate or tag the turn. Soft, no block.
# Override: MAESTRODE_NO_HOOK=1 to skip, MAESTRODE_HOOK_DIR / MAESTRODE_SETTINGS_FILE to relocate.
if [[ "${MAESTRODE_NO_HOOK:-0}" != "1" ]] && [[ -d "${HOME}/.claude" || -n "${MAESTRODE_HOOK_DIR:-}" ]]; then
  LOCAL_HOOK=""
  if [[ -n "${SCRIPT_DIR:-}" ]] && [[ -f "${SCRIPT_DIR}/hooks/maestrode-reminder.sh" ]]; then
    LOCAL_HOOK="${SCRIPT_DIR}/hooks/maestrode-reminder.sh"
  fi
  mkdir -p "$HOOK_DIR"
  HOOK_TARGET="${HOOK_DIR}/maestrode-reminder.sh"
  if [[ -n "$LOCAL_HOOK" ]]; then
    install -m 0755 "$LOCAL_HOOK" "$HOOK_TARGET"
    echo "synced hook from ${LOCAL_HOOK} -> ${HOOK_TARGET}"
  else
    HOOK_TMP=$(mktemp)
    if curl -fsSL "${RAW_BASE}/hooks/maestrode-reminder.sh" -o "$HOOK_TMP"; then
      install -m 0755 "$HOOK_TMP" "$HOOK_TARGET"
      echo "synced hook -> ${HOOK_TARGET}"
    else
      echo "warn: could not download hook from ${RAW_BASE}/hooks/maestrode-reminder.sh" >&2
    fi
    rm -f "$HOOK_TMP"
  fi
  # Idempotent settings.json registration.
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$SETTINGS_FILE" "$HOOK_TARGET" <<'PY'
import json, os, sys
settings_path, hook_cmd = sys.argv[1], sys.argv[2]
matcher = "Edit|Write|MultiEdit|NotebookEdit"
if os.path.exists(settings_path):
    try:
        with open(settings_path) as f:
            d = json.load(f)
    except json.JSONDecodeError as e:
        print(f"warn: {settings_path} is not valid JSON, skipping hook registration: {e}", file=sys.stderr)
        sys.exit(0)
else:
    d = {}
hooks = d.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", [])
already = any(
    any(hh.get("command") == hook_cmd for hh in entry.get("hooks", []))
    for entry in pre
)
if already:
    sys.exit(0)
pre.append({
    "matcher": matcher,
    "hooks": [{"type": "command", "command": hook_cmd}]
})
os.makedirs(os.path.dirname(settings_path) or ".", exist_ok=True)
with open(settings_path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
print(f"registered hook in {settings_path}")
PY
  else
    echo "warn: python3 not on PATH; add the PreToolUse entry to ${SETTINGS_FILE} by hand." >&2
  fi
fi

ENV_FILE="${CONFIG_DIR}/env"
if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<'EOF'
# maestrode env. fill in the API key, optionally swap endpoint/model.
# MAESTRODE_API_KEY=sk-...
# MAESTRODE_ENDPOINT=https://api.deepseek.com/v1/chat/completions
# MAESTRODE_MODEL=deepseek-v4-flash
EOF
  chmod 600 "$ENV_FILE"
  echo "wrote ${ENV_FILE} (edit it)"
fi

echo
echo "installed maestrode to ${INSTALL_DIR}/maestrode"
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) echo "warn: ${INSTALL_DIR} is not on PATH. add it in your shell rc." ;;
esac

if [[ ! -s "$ENV_FILE" ]] || ! grep -q '^MAESTRODE_API_KEY=' "$ENV_FILE"; then
  echo
  echo "Next:"
  echo "  1. edit ${ENV_FILE} and uncomment MAESTRODE_API_KEY=<your key>"
  echo "  2. run: maestrode 'say pong'"
fi
