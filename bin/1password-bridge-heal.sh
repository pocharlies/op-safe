#!/usr/bin/env bash
# 1password-bridge-heal.sh: event-driven healer for 1Password FALLO 2.
# Triggered by launchd WatchPaths on Info.plist (fires on app update install).
# Waits for the update to settle, then checks whether the main process is
# still alive with --just-updated (deaf bridge) and, if so, quits+relaunches.

set -euo pipefail

LOG_FILE="$HOME/.claude/logs/op-safe.log"
APP_BIN="/Applications/1Password.app/Contents/MacOS/1Password"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE"
}

log "watchdog: Info.plist changed, waiting 30s for update to settle"
sleep 30

if pgrep -fl "$APP_BIN" 2>/dev/null | grep -q -- '--just-updated'; then
    log "watchdog: --just-updated flag detected, healing bridge"
    osascript -e 'tell application "1Password" to quit' >/dev/null 2>&1 || true
    sleep 5
    open -a "1Password"
    sleep 20
    log "watchdog: heal complete, relaunched 1Password"
else
    log "watchdog: no --just-updated flag, nothing to do"
fi

exit 0
