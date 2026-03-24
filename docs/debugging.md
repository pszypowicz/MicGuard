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
# Run the built app bundle
/Applications/MicGuard.app/Contents/MacOS/MicGuard

# Or if built from source via Xcode, run from the build directory
~/Library/Developer/Xcode/DerivedData/MicGuard-*/Build/Products/Debug/MicGuard.app/Contents/MacOS/MicGuard
```

Note that MicGuard enforces single-instance via a lock file (`~/.config/mic-guard/lock`). If another instance is already running, the new one exits immediately. Quit the existing instance first (via the menubar menu or `killall MicGuard`).

Since MicGuard uses `os.Logger` instead of stderr, you won't see log output directly in the terminal. Use `log stream` in a separate terminal tab to observe the logs.

## Example debugging session

Terminal tab 1 — start streaming logs:

```bash
log stream --predicate 'subsystem == "com.pszypowicz.MicGuard"' --level debug
```

Terminal tab 2 — launch MicGuard:

```bash
/Applications/MicGuard.app/Contents/MacOS/MicGuard
```

Tab 1 will show startup messages, device enforcement, volume changes, and any errors as they occur.

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

MicGuard registers as a login item via `SMAppService`. If it's not starting at login:

1. Check **System Settings → General → Login Items** — ensure MicGuard is listed and enabled
2. Try removing and re-adding: toggle it off in System Settings, then relaunch MicGuard
3. If MicGuard doesn't appear in the list, launch it manually once — it registers itself on first run

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
toggleMute: muted (saved volume 100)
Volume changed to 0% on 'MacBook Pro Microphone'
Posting status notification: {"enabled":true,"mode":"auto","devices":[...]}
```

### Reset configuration

To reset all MicGuard configuration to defaults:

```bash
rm -rf ~/.config/mic-guard
```

Then relaunch MicGuard. It will re-create the config directory and initialize with the current input device as the preferred mic.

### Lock file

MicGuard uses a lock file (`~/.config/mic-guard/lock`) to enforce single-instance. If MicGuard exits abnormally, the lock file is automatically cleaned up on the next launch — no manual removal is needed.
