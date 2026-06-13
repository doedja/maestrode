#!/usr/bin/env bash
# maestrode installer. Works two ways:
#   1) curl piped:  curl -fsSL https://raw.githubusercontent.com/<user>/maestrode/main/install.sh | bash
#   2) from clone:  ./install.sh  (uses the local src/maestrode file)
# Idempotent: safe to re-run.
#
# Also drops the Claude Code skill at ~/.claude/skills/maestrode/SKILL.md and
# registers three persistence hooks in settings.json (UserPromptSubmit,
# PreToolUse, SessionEnd) when ~/.claude exists. The hooks key all state to
# session_id under ~/.config/maestrode/sessions/, so the mode sticks across
# turns yet cannot leak into other sessions.
#   Set MAESTRODE_NO_SKILL=1 to skip the skill.
#   Set MAESTRODE_NO_HOOKS=1 to skip hook registration (conversation-only).
#   Override paths with MAESTRODE_SKILL_DIR / MAESTRODE_HOOK_DIR /
#   MAESTRODE_SETTINGS_FILE.
#
# Every install also runs a one-time cleanup of the legacy PreToolUse
# reminder hook (and the short-lived SessionStart cleanup hook) plus the
# old ~/.config/maestrode/active sentinel. Those were removed because that
# sentinel was a single GLOBAL file: session-end without "maestrode off"
# leaked the mode into future sessions and fired the reminder when the user
# never activated it. The new hooks fix that at the root by keying state to
# session_id, so re-introducing a hook does not repeat the leak.
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

# maestrode_hook_cmd: absolute command string for a given hook event. Uses the
# install path (not bare `maestrode`) so the hook fires regardless of the PATH
# the harness hands to hook subprocesses.
#
# pre-tool is the hot path (fires on every Edit/Write/Bash/Task call in every
# session). It gets a cheap shell guard: when no session is active anywhere, the
# sessions dir is empty and the command is a sub-millisecond `ls` that exits 0,
# with no python startup. Only when a session is active does it exec the shim.
# This keeps the global cost near zero for sessions that never use maestrode.
maestrode_hook_cmd() {
  case "$1" in
    pre-tool)
      # Shell-quote the embedded paths with %q so a CONFIG_DIR/INSTALL_DIR override
      # containing a single quote (or other metachar) can't break or inject into
      # the hook command string. Default paths quote to themselves (no change).
      printf '%s' "[ -n \"\$(ls -A $(printf '%q' "${CONFIG_DIR}/sessions") 2>/dev/null)\" ] && exec $(printf '%q' "${INSTALL_DIR}/maestrode") hook pre-tool || exit 0" ;;
    *)
      printf '%s' "${INSTALL_DIR}/maestrode hook $1" ;;
  esac
}

# PreToolUse matcher: tools whose use we track or nudge on while mode is active.
HOOK_PRETOOL_MATCHER="Edit|Write|MultiEdit|NotebookEdit|Task|Bash"

# install_hooks: register the three persistence hooks in settings.json,
# idempotently (keyed by the exact command string). Unlike the legacy global
# sentinel, these hooks are no-ops unless a per-session_id flag exists, so they
# never leak the mode across sessions. Safe to re-run.
install_hooks() {
  command -v python3 >/dev/null 2>&1 || {
    echo "warn: python3 not found, skipping hook registration in ${SETTINGS_FILE}" >&2
    return 0
  }
  python3 - "$SETTINGS_FILE" \
    "UserPromptSubmit" ""                       "$(maestrode_hook_cmd user-prompt)" \
    "PreToolUse"       "$HOOK_PRETOOL_MATCHER"   "$(maestrode_hook_cmd pre-tool)" \
    "SessionEnd"       ""                        "$(maestrode_hook_cmd session-end)" <<'PY'
import json, os, sys
settings_path = sys.argv[1]
# remaining args are (event, matcher, command) triples
triples = []
rest = sys.argv[2:]
for i in range(0, len(rest), 3):
    triples.append((rest[i], rest[i + 1], rest[i + 2]))

try:
    with open(settings_path) as f:
        d = json.load(f)
except FileNotFoundError:
    d = {}
except (json.JSONDecodeError, OSError):
    print(f"warn: could not parse {settings_path}, skipping hook registration", file=sys.stderr)
    sys.exit(0)

hooks = d.setdefault("hooks", {})
changed = False
for event, matcher, command in triples:
    entries = hooks.setdefault(event, [])
    # already present (same command anywhere in this event)? skip.
    if any(hh.get("command") == command
           for entry in entries for hh in entry.get("hooks", [])):
        continue
    new_entry = {"hooks": [{"type": "command", "command": command}]}
    if matcher:
        new_entry["matcher"] = matcher
    entries.append(new_entry)
    changed = True

if changed:
    with open(settings_path, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    print(f"registered maestrode hooks in {settings_path}")
else:
    print(f"maestrode hooks already present in {settings_path}")
PY
}

# remove_hooks: strip the three persistence hook entries from settings.json on
# uninstall. Matches by command string so it leaves unrelated hooks intact.
remove_hooks() {
  [[ -f "$SETTINGS_FILE" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$SETTINGS_FILE" \
    "$(maestrode_hook_cmd user-prompt)" \
    "$(maestrode_hook_cmd pre-tool)" \
    "$(maestrode_hook_cmd session-end)" <<'PY'
import json, sys
settings_path = sys.argv[1]
our_cmds = set(sys.argv[2:])
try:
    with open(settings_path) as f:
        d = json.load(f)
except (json.JSONDecodeError, OSError):
    sys.exit(0)
hooks = d.get("hooks") or {}
changed = False
for event in list(hooks.keys()):
    new_entries = []
    for entry in hooks[event]:
        kept = [hh for hh in entry.get("hooks", []) if hh.get("command") not in our_cmds]
        if len(kept) != len(entry.get("hooks", [])):
            changed = True
        if kept:
            e = dict(entry)
            e["hooks"] = kept
            new_entries.append(e)
    if new_entries:
        hooks[event] = new_entries
    else:
        del hooks[event]
        changed = True
if changed:
    if hooks:
        d["hooks"] = hooks
    else:
        d.pop("hooks", None)
    with open(settings_path, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    print(f"removed maestrode hook entries from {settings_path}")
PY
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
  remove_hooks
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

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "${CONFIG_DIR}/sessions"

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

# Register the persistence hooks alongside the skill. Same gate as the skill
# (Claude Code present, or an explicit settings override). Set
# MAESTRODE_NO_HOOKS=1 to skip and run conversation-only.
if [[ "${MAESTRODE_NO_HOOKS:-0}" != "1" ]] && \
   { [[ -d "${HOME}/.claude" ]] || [[ -n "${MAESTRODE_SETTINGS_FILE:-}" ]]; }; then
  install_hooks
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
