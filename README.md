# op-safe

A reliability wrapper around the [1Password CLI](https://developer.1password.com/docs/cli/)
(`op`) for macOS setups that use **1Password 8 desktop app integration**
(biometric/Touch ID unlock) instead of a service account.

Under that setup `op` isn't a standalone client: every invocation asks the
1Password 8 app to authorize it over a local bridge, and the app can hang,
queue, or go deaf in ways that leave a stuck Touch ID prompt on screen. This
repo packages the wrapper and watchdog that fix it.

## The problem

Three real failure signatures, found in
`~/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/logs/1Password_rCURRENT.log`:

### 1. Bombardment (the most frequent one)

1Password **serializes** authorization requests. Concurrent or bursty `op`
calls (a loop, a script firing several `op` invocations back to back) queue
up, stall, and get auto-cancelled by the app itself — leaving a dead Touch ID
prompt on screen and failing commands:

```
WARN  AppCancel invoked by a timed-out prompt due to serialized queue delay
WARN  System unlock failed: SystemAuthError(FailedSystemAuthenticationChallenge)
ERROR NoNewAccountsUnlocked
```

### 2. Zombie app after auto-update

When 1Password auto-updates, the main process can stay alive but deaf,
relaunched internally with `--silent --just-updated --should-restart`. The
IPC socket still exists but nothing answers on the other end, so `op` reports
`authorization timeout` (the Touch ID sheet never even gets drawn, because
the app that would draw it is unresponsive). Fix: quit and relaunch the app.

### 3. Lock/unlock lifecycle (by design, not a bug)

1Password locks when the screen sleeps, and auto-unlocks when the Mac is
unlocked (`Device-based Unlock, reason: DeviceUnlocked`) — no separate
biometric prompt needed for that part. This is expected behavior, not a
failure mode, but it explains *when* the other two failures actually surface.
Two consecutive cycles measured directly in the log:

| Event | Timestamp |
|---|---|
| 1Password `Locked` | 21:16:48 |
| macOS reaches `LockedPartial` | 21:21:48 |
| 1Password `Locked` | 23:16:00 |
| macOS reaches `LockedPartial` | 23:21:00 |

Both gaps are exactly **5:00** — matching macOS's "require password 5 minutes
after sleep" setting. 1Password locks in step with the screen, not on its own
timer.

## How op-safe fixes it

### `bin/op-safe` — serializing wrapper

A drop-in replacement for `op` that:

- Takes a **global inter-process lock** before running `op`, using an atomic
  `mkdir` (macOS ships no `flock(1)`, so `mkdir`'s atomicity is the portable
  primitive). This alone prevents Failure 1: only one `op` invocation runs at
  a time, so nothing gets queued and auto-cancelled by the app.
  - The lock is considered stale and removed automatically if it's older
    than 180 seconds (covers a crashed holder).
  - Waits up to 120 seconds for the lock before giving up (exit code 75).
- **Never uses `exec` to hand off to `op`.** If it did, `exec` would replace
  the wrapper's own process image, and the `trap ... EXIT` that releases the
  lock would never fire on the way out — the lock directory would be
  orphaned forever, permanently deadlocking every future `op-safe` call. The
  wrapper runs `op` as a child process specifically so the trap always fires.
- Detects Failure 2 before calling `op`: if the main 1Password process is
  still running with `--just-updated`, it quits and relaunches the app first.
- Retries exactly once, after a 10 second pause, if `op` fails with
  `couldn't connect to the 1Password desktop app` or `authorization timeout`
  — both are the zombie-app signature, and a relaunch usually clears them.
- **Never logs `op`'s stdout/stderr.** Command output can contain secrets.
  The log only ever records the subcommand name, the exit code, and which
  known error pattern (if any) matched — nothing from `op` itself.

### `bin/1password-bridge-heal.sh` + LaunchAgent — event-driven watchdog

Handles Failure 2 even when nothing is actively calling `op-safe` at the
moment the update lands:

- Triggered by `launchd`'s `WatchPaths` on
  `/Applications/1Password.app/Contents/Info.plist`, which changes exactly
  when an auto-update installs.
- **Event-driven, not polling** — there is deliberately no `StartInterval`.
- Waits 30 seconds for the update to settle, checks for `--just-updated`,
  and quits + relaunches the app if it's still present.

## Installation

```bash
git clone git@github.com:pocharlies/op-safe.git
cd op-safe
./install.sh
```

By default this installs both scripts into `~/.claude/bin`. Use a different
location with `--prefix`:

```bash
./install.sh --prefix ~/.local/bin
```

`install.sh` is idempotent:

- Re-running it with the same prefix just re-installs the scripts (plain
  file copies) and leaves an already-loaded, unchanged LaunchAgent alone.
- If the rendered plist changed (e.g. you changed `--prefix`), it unloads the
  previous agent first instead of bootstrapping a duplicate.
- It loads the agent with `launchctl bootstrap gui/$(id -u) <plist>`, falling
  back to `launchctl load -w` if `bootstrap` isn't available.
- It verifies success at the end with `launchctl list | grep 1password-bridge`.
- **It never runs `op` itself** — installation only touches scripts, the
  LaunchAgent, and `launchctl`.

## Usage

Use `op-safe` exactly where you'd use `op`, with the same subcommands and
arguments:

```bash
op-safe vault list
op-safe item get "some item" --vault "Some Vault"
```

Do **not** call plain `op` directly once this is installed, and do not call
`op-safe` in a tight loop or in parallel — the lock will serialize those
calls correctly, but each one still may pop a Touch ID prompt, and bursts are
exactly what Failure 1 is about. Leave a few seconds between invocations
where possible.

`op whoami` is **not** a valid health check with desktop app integration — it
always reports "account is not signed in" because the CLI has no session of
its own, it delegates to the app. Use `op-safe vault list` instead.

## Dead ends already explored (do not repeat these)

- **`settings.json` is not hand-editable.** It lives under
  `~/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/settings/`.
  Every key carries an HMAC in an `authTags` object; editing a value without
  recomputing the tag invalidates the file.
- **1Password 8's settings UI exposes no accessibility tree** — only empty
  `AXGroup` nodes. Not automatable via `osascript`/System Events, and
  `AXEnhancedUserInterface` / `AXManualAccessibility` don't help either.
- **`security.autolock.minutes = -1` means "never"**, not "unset". If you see
  that value, autolock is not the cause of a given failure.
- **`op whoami` is a false negative** with desktop app integration (see
  above) — it does not indicate whether `op` can actually reach the app.
- **Service accounts are not an option** when the account is a corporate
  tenant and you aren't a tenant admin.

## What actually breaks authorization

| Event | Breaks auth? | Why | Recovery |
|---|---|---|---|
| Closing the 1Password app | Yes | No app to authorize the bridge | Relaunch the app |
| Restarting the Mac | Yes | App and bridge both restart cold | Unlock normally after login; first `op` call re-authorizes |
| Screen sleep | Yes, ~5 min later | 1Password locks in step with macOS's "require password after sleep" timer, not on its own clock | Unlocking the Mac auto-unlocks 1Password (`Device-based Unlock`) — no extra prompt needed |
| Auto-update | Yes (silently) | Main process relaunches deaf, flagged `--just-updated`; socket exists, nothing answers | `op-safe` or the watchdog quit + relaunch the app |

## License

MIT — see [LICENSE](LICENSE).
