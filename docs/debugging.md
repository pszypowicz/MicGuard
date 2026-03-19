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
