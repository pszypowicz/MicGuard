# MicGuard

Prevents Bluetooth audio devices (e.g. AirPods) from hijacking the default macOS microphone.

## How it works

MicGuard registers a CoreAudio property listener on the default input device. When the system switches the input (e.g. when AirPods connect), MicGuard immediately reverts to your preferred microphone using `SwitchAudioSource`.

The preferred mic is stored in `~/.config/mic-guard/preferred-mic`. If the file doesn't exist on first run, MicGuard initializes it with the current input device.

## Requirements

- macOS 13+
- [SwitchAudioSource](https://github.com/deweller/switchaudio-osx): `brew install switchaudio-osx`

## Build & Install

```bash
# Build
swift build          # debug
make build           # release

# Install to /usr/local/bin
make install

# Or via Homebrew tap
brew tap pszypowicz/tap
brew install mic-guard
brew services start mic-guard
```

## Configuration

Edit `~/.config/mic-guard/preferred-mic` with the exact name of your preferred input device. List available devices with:

```bash
SwitchAudioSource -a -t input
```

## Running as a daemon

When installed via Homebrew, use `brew services` to manage the launchd agent:

```bash
brew services start mic-guard   # start
brew services stop mic-guard    # stop
brew services info mic-guard    # status
```

The dotfiles repo contains the SketchyBar integration for changing the preferred mic via right-click on the mic icon.

## Architecture

```
CoreAudio listener (kAudioHardwarePropertyDefaultInputDevice)
  → reads ~/.config/mic-guard/preferred-mic
  → compares with current input (SwitchAudioSource -t input -c)
  → reverts if different (SwitchAudioSource -t input -s "<preferred>")
```
