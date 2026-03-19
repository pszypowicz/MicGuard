<div align="center">
  <img src="Resources/icon.png" width="128" alt="MicGuard icon">
</div>

# MicGuard

Prevents Bluetooth audio devices (e.g. AirPods) from hijacking the default macOS microphone.

> **Beta:** MicGuard is pre-1.0. Backward compatibility is not guaranteed until version 1.0.0 is reached.

## Install

```bash
brew install pszypowicz/tap/mic-guard
```

## How it works

MicGuard is a macOS menubar app that monitors the default input device via CoreAudio. When the system switches the input (e.g. when AirPods connect), MicGuard immediately reverts to your preferred microphone.

## Documentation

See the full docs at **[pszypowicz.github.io/MicGuard](https://pszypowicz.github.io/MicGuard/)** — covering [CLI reference](https://pszypowicz.github.io/MicGuard/cli.html), [integrations](https://pszypowicz.github.io/MicGuard/integrations.html), [notifications](https://pszypowicz.github.io/MicGuard/notifications.html), and [releasing](https://pszypowicz.github.io/MicGuard/releasing.html).
