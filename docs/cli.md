---
title: CLI Reference
---

# CLI Reference

MicGuard doubles as a CLI tool. The `mic-guard` binary is symlinked to `/usr/local/bin` on install.

[Home](index.md) · [Debugging](debugging.md) · [Integrations](integrations.md) · [Notifications](notifications.md) · [Releasing](releasing.md)

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Error (invalid arguments, device not found, etc.) |

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

Set the default input device by name. Also updates the `preferred-mic` config file.

```bash
$ mic-guard set "External USB Mic"
```

### `mic-guard volume <0-100>`

Set the input volume directly via CoreAudio. Runs without the daemon.

```bash
$ mic-guard volume 50
```

### `mic-guard mute`

Toggle mute on the current input device. Posts a notification to the running daemon, which handles the toggle (using native mute if the device supports it, or soft-mute via volume otherwise). Requires the MicGuard daemon to be running.

```bash
$ mic-guard mute
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
mic-guard <version>
```

### `mic-guard help`

Show usage information. Also accepts `--help` and `-h`.

## Subcommand help

Every subcommand accepts `--help` and `-h` to print its own usage and description.

```bash
$ mic-guard volume --help
Usage: mic-guard volume <0-100>

Set input volume (0-100).
```
