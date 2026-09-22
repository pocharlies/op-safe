#!/usr/bin/env bash
# Tests for bin/op-safe. macOS-only (uses stat -f, pgrep -f).
#
#   ./tests/run-tests.sh [path-to-op-safe]      # default: ../bin/op-safe
#
# Nothing here touches the real 1Password: `op`, `osascript` and `open` are
# stubbed on PATH, and the "app" the heal kills and relaunches is a symlink to
# /usr/bin/yes pointed at by OP_SAFE_APP_BIN.
#
# Two macOS facts that shaped this harness, both measured 2026-09-22:
#   - a *copy* of a system binary is killed on exec by SIP ("Killed: 9"), and a
#     shebang script shows the interpreter in argv[0], so neither is visible to
#     `pgrep -f ^<path>`. A symlink is: its argv[0] is the link path.
#   - `osascript -e 'tell app ... to quit'` does nothing from a non-GUI context
#     (ssh). The stub below reproduces that by doing nothing, which is exactly
#     what forces op-safe's SIGTERM fallback.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$HERE/../bin/op-safe}"
[ -f "$TARGET" ] || { echo "op-safe not found: $TARGET" >&2; exit 2; }

T="$(mktemp -d)"
cleanup() { pkill -9 -f "$T/fakeapp" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/home/.claude/logs"
cp "$TARGET" "$T/op-safe"
LOG="$T/home/.claude/logs/op-safe.log"; : > "$LOG"
ln -s /usr/bin/yes "$T/fakeapp"

cat > "$T/relaunch.sh" <<EOF
#!/bin/bash
nohup "$T/fakeapp" --silent --just-updated --should-restart >/dev/null 2>&1 &
echo \$! > "$T/fake.pid"
EOF
chmod +x "$T/relaunch.sh"

printf '#!/bin/bash\necho "osascript $*" >> "$HEALED"\n' > "$T/bin/osascript"
cat > "$T/bin/open" <<EOF
#!/bin/bash
echo "open \$*" >> "\$HEALED"
[ "\${OPEN_RELAUNCH:-yes}" = yes ] && "$T/relaunch.sh"
EOF
chmod +x "$T/bin/osascript" "$T/bin/open"

mk_op() {                       # $1 = how the stubbed op should behave
  cat > "$T/bin/op" <<EOF
#!/bin/bash
n=\$(( \$(cat "$T/calls" 2>/dev/null || echo 0) + 1 )); echo \$n > "$T/calls"
case "$1" in
  fail_once)   if [ "\$n" = 1 ]; then echo "[ERROR] couldn't connect to the 1Password desktop app" >&2; exit 1; fi ;;
  fail_always) echo "[ERROR] authorization timeout" >&2; exit 1 ;;
  hang)        sleep 30 ;;
  plain_error) echo "[ERROR] unknown flag --nope" >&2; exit 1 ;;
  dismissed)   echo "[ERROR] authorization prompt dismissed, please try again" >&2; exit 1 ;;
esac
echo "STUB-STDOUT-CALL-\$n"
exit 0
EOF
  chmod +x "$T/bin/op"
}

fails=0
check() {   # check <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "  ok    $1"
  else echo "  FAIL  $1: got [$2] want [$3]"; fails=$((fails + 1)); fi
}

# run <label> <op-mode> <op-timeout> <does-open-relaunch>
# Sets RC, OUT, HEALS, APP_PID, NEW_PID and CASELOG (only this case's log lines,
# so a check can never pass off another case's log line).
run() {
  mk_op "$2"; : > "$T/calls"
  CASE="$T/case-$1"; mkdir -p "$CASE"
  "$T/relaunch.sh"; APP_PID="$(cat "$T/fake.pid")"
  local before; before=$(wc -l < "$LOG" | tr -d ' ')
  OUT="$(env HOME="$T/home" TMPDIR="$CASE" HEALED="$CASE/healed" \
              OPEN_RELAUNCH="$4" OP_SAFE_APP_BIN="$T/fakeapp" \
              OP_SAFE_OP_TIMEOUT="$3" OP_SAFE_HEAL_COOLDOWN="${COOLDOWN:-120}" \
              PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
              bash "$T/op-safe" vault list 2>/dev/null)"
  RC=$?
  HEALS=0; [ -f "$CASE/healed" ] && HEALS="$(wc -l < "$CASE/healed" | tr -d ' ')"
  NEW_PID="$(cat "$T/fake.pid")"
  CASELOG="$(tail -n +"$((before + 1))" "$LOG")"
  pkill -9 -f "$T/fakeapp" 2>/dev/null
}
logged() { printf '%s\n' "$CASELOG" | grep -c "$1"; }

echo "op-safe tests — script under test: $TARGET"

echo "healthy op: no heal, value passes through, exit 0"
run healthy ok 120 yes
check "exit code" "$RC" 0
check "no heal attempted" "$HEALS" 0
check "stdout passed straight through" "$OUT" "STUB-STDOUT-CALL-1"
check "logged as ok" "$(logged 'op ok subcommand=vault exit=0')" 1

echo "bridge error: heals once (via SIGTERM) and the retry succeeds"
run bridge fail_once 120 yes
check "exit code" "$RC" 0
check "one heal (osascript + open)" "$HEALS" 2
check "retry succeeded" "$(logged 'pattern_after=ok')" 1
check "heal found the app pid" "$(logged 'pid=[0-9]')" 1
check "osascript quit detected as ineffective" "$(logged 'osascript quit did not take')" 1
check "app really restarted (new pid)" "$([ "$APP_PID" != "$NEW_PID" ] && echo changed || echo same)" "changed"
check "value still passed through" "$OUT" "STUB-STDOUT-CALL-2"

echo "hanging op: bounded by OP_SAFE_OP_TIMEOUT, healed, exit 124"
run hang hang 2 yes
check "exit code" "$RC" 124
check "classified as timeout" "$(logged 'pattern=timeout')" 1
check "a hang is healed too" "$(logged 'healing 1Password bridge')" 1

echo "ordinary op error: no heal, no retry, exit code passed through"
run plain plain_error 120 yes
check "exit code" "$RC" 1
check "no heal attempted" "$HEALS" 0
check "classified as none" "$(logged 'pattern=none')" 1

echo "dismissed prompt: no heal (a human has to approve it)"
run dismissed dismissed 120 yes
check "exit code" "$RC" 1
check "no heal attempted" "$HEALS" 0
check "classified as prompt_pending" "$(logged 'pattern=prompt_pending')" 1

echo "a heal that does not restart the app is reported, not pretended"
run ineffective fail_once 120 no
check "exit code" "$RC" 0
check "ineffective heal logged" "$(logged 'heal INEFFECTIVE')" 1
check "app pid did not change" "$([ "$APP_PID" = "$NEW_PID" ] && echo same || echo changed)" "same"

echo "cooldown: a burst of failures heals once, not once per call"
COOLDOWN=120
mk_op fail_always; : > "$T/calls"
BURST="$T/case-burst"; mkdir -p "$BURST"; rm -f "$BURST/healed"
burst_before=$(wc -l < "$LOG" | tr -d ' ')
for _ in 1 2 3; do
  env HOME="$T/home" TMPDIR="$BURST" HEALED="$BURST/healed" OP_SAFE_APP_BIN="$T/fakeapp" \
      OP_SAFE_OP_TIMEOUT=120 OP_SAFE_HEAL_COOLDOWN=120 \
      PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" bash "$T/op-safe" vault list >/dev/null 2>&1
done
BURSTLOG="$(tail -n +"$((burst_before + 1))" "$LOG")"
check "3 failing calls -> 1 heal" "$(printf '%s\n' "$BURSTLOG" | grep -c 'healing 1Password bridge')" 1
check "2 heals skipped by cooldown" "$(printf '%s\n' "$BURSTLOG" | grep -c 'heal skipped')" 2

echo
[ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails check(s) FAILED"
exit "$fails"
