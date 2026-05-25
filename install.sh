#!/usr/bin/env bash
# maestrode installer. Works two ways:
#   1) curl piped:  curl -fsSL https://raw.githubusercontent.com/<user>/maestrode/main/install.sh | bash
#   2) from clone:  ./install.sh  (uses the local src/maestrode file)
# Idempotent: safe to re-run.
#
# uninstall:
#   ./install.sh --uninstall            (remove binary + config + sessions)
#   ./install.sh --uninstall --keep-config   (remove binary only)
#   curl -fsSL .../install.sh | bash -s -- --uninstall

set -euo pipefail

REPO="${MAESTRODE_REPO:-doedja/maestrode}"
BRANCH="${MAESTRODE_BRANCH:-main}"
INSTALL_DIR="${MAESTRODE_INSTALL_DIR:-${HOME}/.local/bin}"
CONFIG_DIR="${MAESTRODE_CONFIG_DIR:-${HOME}/.config/maestrode}"

RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

ACTION="install"
KEEP_CONFIG=0
for arg in "$@"; do
  case "$arg" in
    --uninstall)    ACTION="uninstall" ;;
    --keep-config)  KEEP_CONFIG=1 ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
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
