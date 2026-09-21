#!/usr/bin/env bash
# install.sh — installs op-safe + the 1Password bridge watchdog LaunchAgent.
#
# Idempotent: safe to re-run. Detects an already-installed/loaded LaunchAgent
# and reloads it in place instead of bootstrapping a duplicate. Never invokes
# `op` itself — this only installs plumbing, it never touches your vaults.

set -euo pipefail

PREFIX="$HOME/.claude/bin"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/.claude/logs"
USERNAME="$(id -un)"
LABEL="com.${USERNAME}.1password-bridge-watchdog"
PLIST_SRC="$REPO_DIR/launchagents/com.USERNAME.1password-bridge-watchdog.plist"
PLIST_DEST="$LAUNCH_AGENTS_DIR/${LABEL}.plist"
UID_NUM="$(id -u)"

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            [ $# -ge 2 ] || { echo "install.sh: --prefix requires a value" >&2; exit 1; }
            PREFIX="$2"
            shift 2
            ;;
        --prefix=*)
            PREFIX="${1#--prefix=}"
            shift
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--prefix DIR]

  --prefix DIR   install bin/ scripts into DIR (default: \$HOME/.claude/bin)

Installs op-safe and 1password-bridge-heal.sh into PREFIX, renders the
LaunchAgent plist for this user, installs it into ~/Library/LaunchAgents,
and loads it. Safe to re-run (idempotent).
EOF
            exit 0
            ;;
        *)
            echo "install.sh: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

echo "==> Installing scripts into $PREFIX"
mkdir -p "$PREFIX" "$LOG_DIR"
install -m 0755 "$REPO_DIR/bin/op-safe" "$PREFIX/op-safe"
install -m 0755 "$REPO_DIR/bin/1password-bridge-heal.sh" "$PREFIX/1password-bridge-heal.sh"
echo "    -> $PREFIX/op-safe"
echo "    -> $PREFIX/1password-bridge-heal.sh"

echo "==> Rendering LaunchAgent plist for user '$USERNAME' (prefix: $PREFIX)"
mkdir -p "$LAUNCH_AGENTS_DIR"
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT

# The heal script's own path must follow --prefix; everything else under
# __HOME__ (log paths) always follows $HOME, matching where the scripts
# themselves log regardless of install prefix.
sed \
    -e "s#__HOME__/.claude/bin/1password-bridge-heal.sh#${PREFIX}/1password-bridge-heal.sh#g" \
    -e "s#__HOME__#${HOME}#g" \
    -e "s/USERNAME/${USERNAME}/g" \
    "$PLIST_SRC" > "$RENDERED"

NEEDS_RELOAD=1
if [ -f "$PLIST_DEST" ] && cmp -s "$RENDERED" "$PLIST_DEST"; then
    if launchctl list 2>/dev/null | grep -q "$LABEL"; then
        echo "    already installed and loaded, nothing to do"
        NEEDS_RELOAD=0
    else
        echo "    plist unchanged but not loaded, will load"
    fi
else
    echo "    installing plist -> $PLIST_DEST"
fi

if [ "$NEEDS_RELOAD" -eq 1 ]; then
    if launchctl list 2>/dev/null | grep -q "$LABEL"; then
        echo "    unloading existing agent before reinstall"
        launchctl bootout "gui/${UID_NUM}" "$PLIST_DEST" 2>/dev/null \
            || launchctl unload -w "$PLIST_DEST" 2>/dev/null \
            || true
    fi

    cp "$RENDERED" "$PLIST_DEST"

    echo "    loading agent"
    if ! launchctl bootstrap "gui/${UID_NUM}" "$PLIST_DEST" 2>/dev/null; then
        launchctl load -w "$PLIST_DEST"
    fi
fi

echo "==> Verifying"
if launchctl list 2>/dev/null | grep 1password-bridge; then
    echo "==> op-safe installed. Use it as a drop-in replacement for 'op':"
    echo "      $PREFIX/op-safe vault list"
else
    echo "install.sh: LaunchAgent does not appear in 'launchctl list' — check the plist and logs." >&2
    exit 1
fi
