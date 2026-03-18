---
title: CLI Reference
---

# CLI Reference

MicGuard doubles as a CLI tool. The `mic-guard` binary is symlinked to `/usr/local/bin` on install.

[Home](index.md) · [Integrations](integrations.md) · [Notifications](notifications.md) · [Releasing](releasing.md)

## Commands

### `mic-guard list`

List all input devices.

```bash
$ mic-guard list
MacBook Pro Microphone
External USB Mic
AirPods Pro
```

### `mic-guard current`

Print the current default input device.

```bash
$ mic-guard current
External USB Mic
```

### `mic-guard set <name>`

Set the default input device by name.

```bash
$ mic-guard set "External USB Mic"
```

### `mic-guard enable`

Enable monitoring. MicGuard will revert the default input device whenever it changes away from your preferred mic.

Posts a `com.micguard.enabledChanged` notification.

### `mic-guard disable`

Disable monitoring. The default input device can change freely.

Posts a `com.micguard.enabledChanged` notification.

### `mic-guard status`

Print whether monitoring is enabled or disabled.

```bash
$ mic-guard status
enabled
```
