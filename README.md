# MicGuard

Prevents Bluetooth audio devices (e.g. AirPods) from hijacking the default macOS microphone.

## How it works

MicGuard is a headless macOS app that registers a CoreAudio property listener on the default input device. When the system switches the input (e.g. when AirPods connect), MicGuard immediately reverts to your preferred microphone using native CoreAudio APIs.

On first launch, MicGuard registers itself as a Login Item via `SMAppService`, so it starts automatically on login. It appears in System Settings > Login Items with its own icon.

The preferred mic is stored in `~/.config/mic-guard/preferred-mic`. If the file doesn't exist on first run, MicGuard initializes it with the current input device.

## Requirements

- macOS 15+

## Build & Install

```bash
make install    # builds .app bundle, copies to /Applications, symlinks mic-guard CLI
```

## CLI

MicGuard doubles as a CLI tool for querying and switching audio input devices:

```bash
mic-guard list       # list all input devices
mic-guard current    # print current default input device
mic-guard set <name> # set default input device by name
```

## Configuration

Edit `~/.config/mic-guard/preferred-mic` with the exact name of your preferred input device. List available devices with:

```bash
mic-guard list
```

## Architecture

```
MicGuard.app (headless, LSUIElement)
  ├── SMAppService.mainApp.register() → auto-start on login
  └── CoreAudio listener (kAudioHardwarePropertyDefaultInputDevice)
        → reads ~/.config/mic-guard/preferred-mic
        → compares with current input (AudioObjectGetPropertyData)
        → reverts if different (AudioObjectSetPropertyData)
```

The [dotfiles repo](https://github.com/pszypowicz/dotfiles) contains SketchyBar integration for changing the preferred mic via right-click on the mic icon.
