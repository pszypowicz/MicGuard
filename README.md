# MicGuard

Prevents Bluetooth audio devices (e.g. AirPods) from hijacking the default macOS microphone.

## How it works

MicGuard is a macOS menubar app that registers a CoreAudio property listener on the default input device. When the system switches the input (e.g. when AirPods connect), MicGuard immediately reverts to your preferred microphone using native CoreAudio APIs.

On first launch, MicGuard registers itself as a Login Item via `SMAppService`, so it starts automatically on login. The preferred mic is stored in `~/.config/mic-guard/preferred-mic`. If the file doesn't exist on first run, MicGuard initializes it with the current input device.

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
- Toggle monitoring on/off
- Toggle launch at login
- Quit the app

## CLI

MicGuard doubles as a CLI tool:

```bash
mic-guard list       # list all input devices
mic-guard current    # print current default input device
mic-guard set <name> # set default input device by name
mic-guard enable     # enable monitoring
mic-guard disable    # disable monitoring
mic-guard status     # print enabled/disabled
```

## Configuration

All config lives in `~/.config/mic-guard/`:

| File | Purpose |
|------|---------|
| `preferred-mic` | Exact name of your preferred input device |
| `enabled` | `1` or `0` — whether monitoring is active |

## Architecture

```
MicGuard.app (MenuBarExtra, LSUIElement)
  ├── SwiftUI MenuBarExtra (.window style) → popover UI
  ├── SMAppService.mainApp.register() → auto-start on login
  └── CoreAudio listener (kAudioHardwarePropertyDefaultInputDevice)
        → reads ~/.config/mic-guard/preferred-mic
        → compares with current input (AudioObjectGetPropertyData)
        → reverts if different (AudioObjectSetPropertyData)
```

## Releasing

1. Tag and push: `git tag v<version> && git push origin v<version>`
2. GitHub Actions builds the app and creates a release with `MicGuard.zip`
3. Update `homebrew-tap/Casks/mic-guard.rb`:
   - Set `version` to the new version
   - Update `sha256` — get it with:
     ```bash
     curl -sL https://github.com/pszypowicz/MicGuard/releases/download/v<version>/MicGuard.zip | shasum -a 256
     ```

The [dotfiles repo](https://github.com/pszypowicz/dotfiles) contains SketchyBar integration for displaying and changing the preferred mic.
