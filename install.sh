#!/usr/bin/env bash
# maestrode installer. Works two ways:
#   1) curl piped:  curl -fsSL https://raw.githubusercontent.com/<user>/maestrode/main/install.sh | bash
#   2) from clone:  ./install.sh  (uses the local src/maestrode file)
# Idempotent: safe to re-run.
#
# Also drops the Claude Code skill at ~/.claude/skills/maestrode/SKILL.md
# when ~/.claude exists. The skill carries the per-turn footer-tag rule
# that keeps mode visible across turns; no filesystem state, no hooks.
#   Set MAESTRODE_NO_SKILL=1 to skip the skill.
#   Override paths with MAESTRODE_SKILL_DIR / MAESTRODE_HOOK_DIR /
#   MAESTRODE_SETTINGS_FILE.
#
# Every install also runs a one-time cleanup of the legacy PreToolUse
# reminder hook (and the short-lived SessionStart cleanup hook) plus the
# old ~/.config/maestrode/active sentinel. Those were removed because the
# sentinel was global filesystem state masquerading as session state;
# session-end without "maestrode off" leaked it into future sessions and
# triggered the reminder when the user never activated the mode. Mode now
# lives entirely in the conversation: skill description + footer tag.
#
# uninstall:
#   ./install.sh --uninstall            (remove binary + config + sessions + skill + legacy hooks)
#   ./install.sh --uninstall --keep-config   (remove binary + skill + legacy hooks only)
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

# Names of hooks from prior versions that this installer cleans up.
LEGACY_HOOK_NAMES=("maestrode-reminder.sh" "maestrode-session-clear.sh")

# cleanup_legacy_hooks: remove any prior-version hook scripts and strip
# their entries from settings.json. Called on both install and uninstall.
# Reports what it removed so the cleanup is visible. Returns 0 always;
# nothing here should block install.
cleanup_legacy_hooks() {
  local removed_any=0
  for name in "${LEGACY_HOOK_NAMES[@]}"; do
    local path="${HOOK_DIR}/${name}"
    if [[ -e "$path" ]]; then
      rm -f "$path"
      echo "removed legacy hook ${path}"
      removed_any=1
    fi
  done
  rmdir "$HOOK_DIR" 2>/dev/null || true
  if [[ -f "$SETTINGS_FILE" ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$SETTINGS_FILE" "$HOOK_DIR" "${LEGACY_HOOK_NAMES[@]}" <<'PY'
import json, os, sys
settings_path = sys.argv[1]
hook_dir = sys.argv[2]
names = sys.argv[3:]
legacy_cmds = {os.path.join(hook_dir, n) for n in names}
try:
    with open(settings_path) as f:
        d = json.load(f)
except (json.JSONDecodeError, OSError):
    sys.exit(0)
hooks = d.get("hooks") or {}
changed = False
for event in ("PreToolUse", "SessionStart", "PostToolUse", "Stop", "UserPromptSubmit"):
    entries = hooks.get(event, [])
    new_entries = []
    for entry in entries:
        orig = entry.get("hooks", [])
        kept = [hh for hh in orig if hh.get("command") not in legacy_cmds]
        if len(kept) != len(orig):
            changed = True
        if kept:
            e = dict(entry)
            e["hooks"] = kept
            new_entries.append(e)
    if entries != new_entries:
        hooks[event] = new_entries
        if not new_entries:
            del hooks[event]
if changed:
    if hooks:
        d["hooks"] = hooks
    else:
        d.pop("hooks", None)
    with open(settings_path, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    print(f"removed legacy hook entries from {settings_path}")
PY
    removed_any=1
  fi
  return 0
}

# cleanup_legacy_sentinel: remove the old ~/.config/maestrode/active file
# left behind by prior-version sessions that ended without "maestrode off".
# No-op when absent.
cleanup_legacy_sentinel() {
  if [[ -e "${CONFIG_DIR}/active" ]]; then
    rm -f "${CONFIG_DIR}/active"
    echo "removed legacy sentinel ${CONFIG_DIR}/active"
  fi
}

ACTION="install"
KEEP_CONFIG=0
for arg in "$@"; do
  case "$arg" in
    --uninstall)    ACTION="uninstall" ;;
    --keep-config)  KEEP_CONFIG=1 ;;
    -h|--help)
      sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
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
  cleanup_legacy_hooks
  cleanup_legacy_sentinel
  # Strip the PATH export we may have appended on install. Uses the
  # `# maestrode: PATH` marker line + the export below it. Quiet no-op if
  # not present.
  for rc in "${HOME}/.zshrc" "${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.config/fish/config.fish"; do
    [[ -f "$rc" ]] || continue
    if grep -Fq '# maestrode: PATH' "$rc"; then
      python3 - "$rc" <<'PY' || true
import sys, pathlib
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines(keepends=True)
out = []
skip = 0
for ln in lines:
    if skip > 0:
        skip -= 1
        continue
    if ln.strip() == '# maestrode: PATH':
        skip = 1
        continue
    out.append(ln)
p.write_text(''.join(out))
PY
      echo "removed maestrode PATH line from $rc"
      removed=1
    fi
  done
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

# Self-heal any prior-version state before the rest of install runs.
cleanup_legacy_hooks
cleanup_legacy_sentinel

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

# Auto-append PATH export to the user's shell rc so `maestrode "task"` and
# the skill (which invokes `maestrode` by name from Bash) just work. Skip
# if already on PATH or if MAESTRODE_NO_PATH=1.
maestrode_path_setup() {
  case ":$PATH:" in
    *":$INSTALL_DIR:"*) return 0 ;;
  esac
  if [[ "${MAESTRODE_NO_PATH:-0}" == "1" ]]; then
    echo "warn: ${INSTALL_DIR} is not on PATH (MAESTRODE_NO_PATH=1, skipping rc edit)."
    return 0
  fi
  local shell_name rc line marker
  shell_name=$(basename "${SHELL:-/bin/sh}")
  case "$shell_name" in
    zsh)  rc="${HOME}/.zshrc" ;;
    bash)
      if [[ -f "${HOME}/.bashrc" ]]; then rc="${HOME}/.bashrc"
      else rc="${HOME}/.bash_profile"
      fi ;;
    fish)
      rc="${HOME}/.config/fish/config.fish"
      mkdir -p "$(dirname "$rc")"
      line="fish_add_path \"${INSTALL_DIR}\""
      marker="# maestrode: PATH"
      if [[ -f "$rc" ]] && grep -Fq "$marker" "$rc"; then return 0; fi
      printf '\n%s\n%s\n' "$marker" "$line" >> "$rc"
      echo "added ${INSTALL_DIR} to PATH in ${rc}"
      echo "open a new shell, or run: source ${rc}"
      return 0 ;;
    *)
      echo "warn: unknown shell '${shell_name}'. add ${INSTALL_DIR} to PATH manually:"
      echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
      return 0 ;;
  esac
  line="export PATH=\"${INSTALL_DIR}:\$PATH\""
  marker="# maestrode: PATH"
  if [[ -f "$rc" ]] && grep -Fq "$marker" "$rc"; then
    return 0
  fi
  printf '\n%s\n%s\n' "$marker" "$line" >> "$rc"
  echo "added ${INSTALL_DIR} to PATH in ${rc}"
  echo "open a new shell, or run: source ${rc}"
}
maestrode_path_setup

if [[ ! -s "$ENV_FILE" ]] || ! grep -q '^MAESTRODE_API_KEY=' "$ENV_FILE"; then
  echo
  echo "Next:"
  echo "  1. edit ${ENV_FILE} and uncomment MAESTRODE_API_KEY=<your key>"
  echo "  2. run: maestrode 'say pong'"
fi
