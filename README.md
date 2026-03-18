# AudioGuard

Prevents Bluetooth audio devices (e.g. AirPods) from hijacking the default macOS microphone.

## How it works

AudioGuard registers a CoreAudio property listener on the default input device. When the system switches the input (e.g. when AirPods connect), AudioGuard immediately reverts to your preferred microphone using `SwitchAudioSource`.

The preferred mic is stored in `~/.config/audio-guard/preferred-mic`. If the file doesn't exist on first run, AudioGuard initializes it with the current input device.

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
brew install audio-guard
brew services start audio-guard
```

## Configuration

Edit `~/.config/audio-guard/preferred-mic` with the exact name of your preferred input device. List available devices with:

```bash
SwitchAudioSource -a -t input
```

## Running as a daemon

When installed via Homebrew, use `brew services` to manage the launchd agent:

```bash
brew services start audio-guard   # start
brew services stop audio-guard    # stop
brew services info audio-guard    # status
```

The dotfiles repo contains the SketchyBar integration for changing the preferred mic via right-click on the mic icon.

## Architecture

```
CoreAudio listener (kAudioHardwarePropertyDefaultInputDevice)
  → reads ~/.config/audio-guard/preferred-mic
  → compares with current input (SwitchAudioSource -t input -c)
  → reverts if different (SwitchAudioSource -t input -s "<preferred>")
```
