---
title: Integrations
---

# Integrations

MicGuard posts [distributed notifications](notifications.md) whenever the input device changes, MicGuard is toggled on/off, or the app terminates. Any macOS app or script that can observe `DistributedNotificationCenter` can react to these events.

[Home](index.md) · [CLI Reference](cli.md) · [Debugging](debugging.md) · [Notifications](notifications.md) · [Releasing](releasing.md)

## Building an integration

The building blocks:

- **`com.pszypowicz.MicGuard.statusChanged`** - broadcast on every state change with a unified JSON payload (enabled state, device list, per-device volume/mute) under `userInfo["info"]`. One notification carries everything needed to render a status indicator.
- **`com.pszypowicz.MicGuard.appTerminated`** - broadcast when the app quits, so an indicator can switch to an "off" state.
- **`mic-guard -q ping`** - asks the running daemon to re-broadcast `statusChanged`. Call it when your integration starts so it renders the current state immediately instead of waiting for the next event.
- **CLI commands** (`mic-guard toggle`, `mute`, `set <device>`, ...) - drive MicGuard from click handlers or hotkeys; every command triggers a fresh `statusChanged` broadcast.

A typical status-bar integration subscribes to both notifications, parses the JSON payload, renders an icon plus the current device name, and wires clicks to CLI commands. A periodic health check (`pgrep -x MicGuard`) catches the daemon dying without an `appTerminated` notification.

See [Notifications](notifications.md) for the full payload schema and observer code examples.
