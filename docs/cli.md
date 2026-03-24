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

## Global flags

| Flag | Description |
|------|-------------|
| `-q`, `--quiet` | Suppress confirmation output |

## Commands

### `mic-guard list`

List all input devices.

```bash
$ mic-guard list
MacBook Pro Microphone
External USB Mic
AirPods Pro
```

With `--output json`, each device includes extended fields:

```bash
$ mic-guard list --output json
[
  {
    "current" : true,
    "muted" : false,
    "name" : "MacBook Pro Microphone",
    "preferred" : true,
    "volume" : 100
  },
  {
    "current" : false,
    "muted" : false,
    "name" : "AirPods Pro",
    "preferred" : false,
    "volume" : 75
  }
]
```

| Field | Type | Description |
|-------|------|-------------|
| `name` | String | Device name |
| `current` | Boolean | `true` if this is the active input device |
| `preferred` | Boolean | `true` if this is the configured preferred device |
| `volume` | Integer | Input volume 0–100 (omitted if device doesn't support volume) |
| `muted` | Boolean | Native mute flag state (omitted if device doesn't support mute) |

### `mic-guard current`

Print the current default input device.

```bash
$ mic-guard current
External USB Mic
```

### `mic-guard set <name>`

Set the preferred device and switch to manual mode.

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

```bash
$ mic-guard enable
enabled
```

### `mic-guard disable`

Disable MicGuard. The default input device can change freely.

```bash
$ mic-guard disable
disabled
```

### `mic-guard toggle`

Toggle MicGuard on/off. Prints the new state.

```bash
$ mic-guard toggle
disabled
$ mic-guard toggle
enabled
```

### `mic-guard status`

Print whether MicGuard is enabled or disabled. When enabled, the current mode is shown in parentheses.

```bash
$ mic-guard status
enabled (auto)
$ mic-guard status   # when disabled
disabled
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
