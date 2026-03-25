---
title: Debugging
---

# Debugging

MicGuard uses Apple's [unified logging system](https://developer.apple.com/documentation/os/logging) (`os.Logger`) with subsystem `com.pszypowicz.MicGuard`. This is the macOS equivalent of `journalctl` on Linux — all log messages go to a centralized system log store that you can query, stream, and filter.

[Home](index.md) · [CLI Reference](cli.md) · [Integrations](integrations.md) · [Notifications](notifications.md) · [Releasing](releasing.md)


## Viewing logs

### Stream logs in real time

```bash
log stream --predicate 'subsystem == "com.pszypowicz.MicGuard"' --level debug
```

This streams all MicGuard messages (debug, info, and error) as they happen — similar to `journalctl -f`. Press `Ctrl-C` to stop.

To see only important messages (info and error), omit `--level debug`:

```bash
log stream --predicate 'subsystem == "com.pszypowicz.MicGuard"'
```

### Show past logs

```bash
log show --predicate 'subsystem == "com.pszypowicz.MicGuard"' --last 1h --info --debug
```

Replace `1h` with any duration: `5m`, `30m`, `2h`, `1d`, etc. Without `--debug`, debug-level messages are excluded (they are kept in memory only briefly).

### Console.app

You can also use the built-in Console app:

1. Open **Console.app** (in `/Applications/Utilities/`)
2. In the search bar, type `com.pszypowicz.MicGuard`
3. Select **Subsystem** from the dropdown to filter by subsystem
4. To include debug messages, go to **Action → Include Debug Messages**

## Log levels

MicGuard uses three log levels:

| Level | Persistence | Used for |
|-------|-------------|----------|
| `debug` | Memory only, near-zero cost when not observed | Volume/mute changes, listener register/unregister, status notifications, "no action" decisions |
| `info` | Memory, persisted on error | Startup, config changes, device preference changes, enforcement actions |
| `error` | Always persisted to disk | Failed listener registration, failed device set, failed config writes |

Debug messages are only captured when a consumer is attached (e.g. `log stream --level debug` or Console.app with debug enabled). This means high-frequency events like volume slider changes have near-zero overhead during normal operation.

## Duplicate CoreAudio callbacks

When a Bluetooth device connects or disconnects, CoreAudio fires `DEVICE_LIST_CHANGED` and `DEFAULT_INPUT_CHANGED` notifications multiple times — typically two or three times per event. This is normal macOS behavior (CoreAudio notifies once per internal phase of the Bluetooth negotiation) and not a MicGuard bug.

You will see duplicate log lines like:

```
DEVICE_LIST_CHANGED: added=["AirPods Pro 3 (Przemek)"] removed=[]
DEVICE_LIST_CHANGED: added=["AirPods Pro 3 (Przemek)"] removed=[]
```

The handlers are idempotent — the second call is harmless since the device was already added to the tracked set on the first call.

## Running from the terminal

To run MicGuard directly from a terminal (useful during development):

```bash
# Run the installed app bundle
/Applications/MicGuard.app/Contents/MacOS/MicGuard
```

MicGuard acquires an `fcntl` advisory lock on `~/.config/mic-guard/lock` at startup. If another instance is already running, the new process logs the existing PID and exits immediately. The lock is kernel-managed — it is released automatically when the process exits, crashes, or is killed (including `SIGKILL`). The lock file itself persists on disk but does not block the next launch; only an active file descriptor holding the lock does.

Since MicGuard uses `os.Logger` instead of stderr, you won't see log output directly in the terminal. Use `log stream` in a separate terminal tab to observe the logs.

## XPC (development only)

In production, the CLI communicates with the daemon via DistributedNotificationCenter (`requestStatus` notification). XPC is available as an alternative transport for development and testing.

### Testing XPC locally

Use the `make dev` target to build the `.app` bundle, register a LaunchAgent with launchd, and start the daemon with XPC enabled:

```bash
make dev
```

This:
1. Builds a release `.app` bundle (`scripts/bundle.sh`)
2. Adds `ProgramArguments` to the embedded LaunchAgent plist (launchd needs the absolute path; `SMAppService` resolves it automatically but raw `launchctl` doesn't)
3. Registers the LaunchAgent via `launchctl bootstrap`
4. launchd starts the daemon with the Mach service advertised

### Stopping the dev daemon

```bash
make dev-stop
```

This kills the daemon and unregisters the LaunchAgent from launchd.

### Why not Xcode debug?

When Xcode launches MicGuard directly, the binary runs outside of launchd's context — no LaunchAgent plist is loaded, so the Mach service isn't advertised. To test the daemon UI (menu bar, settings, CoreAudio listeners), Xcode debug works fine. To test XPC communication, use `make dev`.

## Example debugging session

Terminal tab 1 — start streaming logs:

```bash
log stream --predicate 'subsystem == "com.pszypowicz.MicGuard"' --level debug
```

Terminal tab 2 — start the dev daemon:

```bash
make dev
```

Tab 1 will show startup messages including device enforcement, volume changes, notification handling, and any errors as they occur.

Terminal tab 3 — test CLI commands:

```bash
.build/bin/mic-guard list
.build/bin/mic-guard mute
```

## Fish shell note

If you use fish shell, `log` is a built-in command. Use the full path instead:

```fish
/usr/bin/log stream --predicate 'subsystem == "com.pszypowicz.MicGuard"' --level debug
/usr/bin/log show --predicate 'subsystem == "com.pszypowicz.MicGuard"' --last 1h --info --debug
```

## Common issues

### Preferred mic not found

If MicGuard cannot find the preferred device (e.g. it was disconnected), it will keep monitoring but won't enforce a switch. When the preferred device reconnects, MicGuard will automatically switch back to it. You can change the preferred device via the menubar menu or `mic-guard set`.

### Login item not starting

MicGuard auto-enables "Launch at Login" on first install via `SMAppService.mainApp`. If it's not starting at login:

1. Check **System Settings → General → Login Items** — ensure MicGuard is listed and enabled
2. Try removing and re-adding: toggle "Launch at Login" off in MicGuard Settings, then back on
3. If MicGuard doesn't appear in the list, launch it manually — the login item will be registered automatically on the next daemon start

### Mute not working

If clicking mute in sketchybar (or running `mic-guard mute`) doesn't silence the mic:

1. Check MicGuard is running: `pgrep -x MicGuard`
2. Stream logs and trigger mute to trace the full flow:

```bash
# Tab 1 — stream logs
log stream --predicate 'subsystem == "com.pszypowicz.MicGuard"' --level debug

# Tab 2 — trigger mute
mic-guard mute
```

You should see log entries in sequence:

```
toggleMute: muted 'MacBook Pro Microphone' saved vol=100
postStatusChanged: isMuted=true inputVolume=0 currentDevice='MacBook Pro Microphone'
Posting status notification: {"enabled":true,"mode":"auto","devices":[...]}
```

### Reset configuration

To reset all MicGuard configuration to defaults:

```bash
rm -rf ~/.config/mic-guard
```

Then relaunch MicGuard. It will re-create the config directory and initialize with the current input device as the preferred mic.

