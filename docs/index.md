---
title: MicGuard
---

# MicGuard

Prevents Bluetooth audio devices (e.g. AirPods) from hijacking the default macOS microphone.

[CLI Reference](cli.md) · [Debugging](debugging.md) · [Integrations](integrations.md) · [Notifications](notifications.md) · [Releasing](releasing.md)

> **Beta:** MicGuard is pre-1.0. Backward compatibility is not guaranteed until version 1.0.0 is reached.

## How it works

MicGuard is a macOS menubar app that registers a CoreAudio property listener on the default input device. When the system switches the input (e.g. when AirPods connect), MicGuard immediately reverts to your preferred microphone using native CoreAudio APIs.

The preferred mic is stored in `~/.config/mic-guard/preferred-mic`. If the file doesn't exist on first run, MicGuard initializes it with the current input device. You can enable "Launch at Login" from the menubar popover, which registers MicGuard as a Login Item via `SMAppService`.

## Requirements

- macOS 15+

## Install

```bash
brew install pszypowicz/tap/mic-guard
```

Or build from source:

```bash
make install    # builds .app bundle, copies to /Applications, symlinks mic-guard CLI
```

## Menubar

Click the shield+mic icon in the menubar to:

- Pick a preferred input device
- Toggle MicGuard on/off
- Toggle launch at login
- Quit the app

## Configuration

All config lives in `~/.config/mic-guard/`:

| File | Purpose |
|------|---------|
| `preferred-mic` | Exact name of your preferred input device |
| `enabled` | `1` or `0` — whether MicGuard is active |
