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

Enable MicGuard. It will revert the default input device whenever it changes away from your preferred mic.

### `mic-guard disable`

Disable MicGuard. The default input device can change freely.

### `mic-guard status`

Print whether MicGuard is enabled or disabled.

```bash
$ mic-guard status
enabled
```

### `mic-guard ping`

Ask the running MicGuard daemon to re-broadcast its current status. Posts a `com.pszypowicz.MicGuard.requestStatus` notification, which causes the daemon to respond with `com.pszypowicz.MicGuard.statusChanged`.

```bash
$ mic-guard ping
```

### `mic-guard version`

Print the version. Also accepts `--version` and `-v`.

```bash
$ mic-guard version
mic-guard 0.5.0
```

### `mic-guard help`

Show usage information. Also accepts `--help` and `-h`.
