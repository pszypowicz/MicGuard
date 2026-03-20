---
title: Integrations
---

# Integrations

MicGuard posts [distributed notifications](notifications.md) whenever the input device changes, MicGuard is toggled on/off, or the app terminates. Any macOS app or script that can observe `DistributedNotificationCenter` can react to these events.

[Home](index.md) · [CLI Reference](cli.md) · [Debugging](debugging.md) · [Notifications](notifications.md) · [Releasing](releasing.md)

## SketchyBar

The reference integration is a [SketchyBar](https://github.com/FelixKratz/SketchyBar) item that shows mic status in the menubar using a two-item layout: a **shield** item (icon only) representing MicGuard protection status, and a **mic** item (icon + label) representing audio state and device name.

Two items sit on the right side of the bar. `mic` is added first (rightmost), then `mic.shield` is added to its left. Together they read as a single visual unit:

`[mic.shield][mic]` — shield icon, then mic icon + device name label.

Icons are [Nerd Font](https://www.nerdfonts.com/) glyphs. A patched font is required.

| Glyph name | Codepoint |
|------------|-----------|
| `nf-md-shield_check` | `U+F0565` |
| `nf-md-shield_off` | `U+F099E` |
| `nf-md-microphone` | `U+F036C` |
| `nf-md-microphone_off` | `U+F036D` |

**Enabled + Active** — shield: `shield_check` (white), mic: `microphone` + device name (white)

**Enabled + Muted** — shield: `shield_check` (white), mic: `microphone_off` + device name (red)

**Disabled + Active** — shield: `shield_off` (yellow), mic: `microphone` + device name (yellow)

**Disabled + Muted** — shield: `shield_off` (yellow), mic: `microphone_off` + device name (red)

**App not running** — shield: `shield_off` + "Off" label (red), mic item hidden

### Features

- **Left-click** — toggle mute/unmute (sets input volume to 0 or 100)
- **Right-click** — popup picker listing all input devices + enable/disable toggle; selecting a device sets it as default and updates `preferred-mic`

### Setup

#### 1. Register events and create items

In your SketchyBar items directory (e.g. `items/mic.sh`):

```bash
#!/usr/bin/env bash

set -e

mic=(
  updates=on
  update_freq=60
  icon.width=20
  label.drawing=on
  padding_right=4
  padding_left=0
  label.padding_right=2
  popup.align=right
  popup.height=0
  script="$PLUGIN_DIR/mic.sh"
  click_script="$PLUGIN_DIR/mic_click.sh"
)

mic_shield=(
  icon.drawing=on
  icon.width=20
  label.drawing=off
  padding_right=0
  padding_left=5
  click_script="$PLUGIN_DIR/mic_click.sh"
)

# Events
sketchybar --add event mic_clicked
sketchybar --add event mic_status_changed "com.pszypowicz.MicGuard.statusChanged"
sketchybar --add event mic_app_terminated "com.pszypowicz.MicGuard.appTerminated"

# mic item (rightmost — mic icon + device name label)
sketchybar --add item mic right \
  --set mic "${mic[@]}" \
  --subscribe mic mic_clicked mic_status_changed mic_app_terminated mouse.exited mouse.exited.global

# mic.shield item (left of mic — shield icon only)
sketchybar --add item mic.shield right \
  --set mic.shield "${mic_shield[@]}" \
  --subscribe mic.shield mouse.exited mouse.exited.global

# Request current status from MicGuard
mic-guard ping 2>/dev/null &
```

The `mic-guard ping` at the end asks the running MicGuard daemon to re-broadcast `com.pszypowicz.MicGuard.statusChanged`, so bar items and popup content populate immediately when sketchybar starts (or restarts) regardless of when MicGuard launched.

Key points:
- Two items: `mic` (mic icon + device name label) and `mic.shield` (shield icon only)
- `mic_status_changed` maps to the `com.pszypowicz.MicGuard.statusChanged` distributed notification. The notification carries a unified JSON payload under `userInfo["info"]` with enabled state, device list, and per-device volume/mute — the plugin updates both bar icons and popup items from this single notification
- `mic_app_terminated` maps to `com.pszypowicz.MicGuard.appTerminated`
- `mic_clicked` is a custom event triggered after mute/unmute or device change to refresh the display
- `mouse.exited` / `mouse.exited.global` close the device picker popup
- Padding is tightened between items so they read as a visual unit

#### 2. Update script

The plugin script (`plugins/mic.sh`) runs on every subscribed event and periodic update. It updates both `mic.shield` and `mic` in a single `sketchybar` call:

```bash
#!/usr/bin/env bash

export PATH="/opt/homebrew/bin:$PATH"
source "$CONFIG_DIR/colors.sh"

# Close popup when mouse leaves
if [[ "$SENDER" == "mouse.exited" || "$SENDER" == "mouse.exited.global" ]]; then
  sketchybar --set mic popup.drawing=off
  exit 0
fi

# Nerd Font glyphs
SHIELD_CHECK=󰕥  # nf-md-shield_check (U+F0565)
SHIELD_OFF=󰦞   # nf-md-shield_off (U+F099E)
MIC_ON=󰍬       # nf-md-microphone (U+F036C)
MIC_OFF=󰍭      # nf-md-microphone_off (U+F036D)

# Helper: update both items in a single sketchybar call
update_bar() {
  local shield_icon=$1 shield_color=$2 mic_icon=$3 mic_color=$4 mic_label=$5 label_color=$6
  sketchybar -m \
    --set mic.shield icon="$shield_icon" icon.color=$shield_color label.drawing=off drawing=on \
    --set mic icon="$mic_icon" icon.color=$mic_color label="$mic_label" label.color=$label_color drawing=on
}

# Show shield with "Off" label, hide mic item
show_off() {
  sketchybar -m \
    --set mic.shield icon="$SHIELD_OFF" icon.color=$RED label="Off" label.color=$RED label.drawing=on drawing=on \
    --set mic drawing=off
}

# MicGuard app terminated
if [[ "$SENDER" == "mic_app_terminated" ]]; then
  show_off
  exit 0
fi

# Fast path: notification from MicGuard with full state in $INFO
if [[ "$SENDER" == "mic_status_changed" && -n "$INFO" ]]; then
  ENABLED=$(echo "$INFO" | sed -n 's/.*"enabled"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  MIC_NAME=$(echo "$INFO" | sed -n 's/.*"device"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  MIC_VOLUME=$(echo "$INFO" | sed -n 's/.*"volume"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  MIC_MUTED=$(echo "$INFO" | sed -n 's/.*"muted"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  if [[ ${#MIC_NAME} -gt 12 ]]; then
    MIC_NAME="${MIC_NAME:0:11}…"
  fi

  if [[ "$ENABLED" == "0" && "$MIC_MUTED" == "1" ]]; then
    update_bar "$SHIELD_OFF" $YELLOW "$MIC_OFF" $RED "$MIC_NAME" $RED
  elif [[ "$ENABLED" == "0" ]]; then
    update_bar "$SHIELD_OFF" $YELLOW "$MIC_ON" $YELLOW "$MIC_NAME" $YELLOW
  elif [[ "$MIC_MUTED" == "1" ]]; then
    update_bar "$SHIELD_CHECK" $WHITE "$MIC_OFF" $RED "$MIC_NAME" $RED
  else
    update_bar "$SHIELD_CHECK" $WHITE "$MIC_ON" $WHITE "$MIC_NAME" $WHITE
  fi
  exit 0
fi

# Health check: periodic 60s update / mic_clicked — only detects a dead app
if ! pgrep -xq MicGuard; then
  show_off
fi
```

#### 3. Click handler

The click script (`plugins/mic_click.sh`) handles left-click mute/unmute and right-click popup toggle.

Popup items are pre-built by the `mic_devices_changed` handler in the update script, so right-click just toggles `popup.drawing` — no CLI calls, no JSON parsing, no flicker.

```bash
#!/usr/bin/env bash

export PATH="/opt/homebrew/bin:$PATH"
source "$CONFIG_DIR/colors.sh"

# Guard: do nothing if MicGuard.app is not running
if ! pgrep -xq MicGuard; then
  exit 0
fi

if [[ "$BUTTON" == "right" ]]; then
  # Right-click: toggle popup visibility
  # Popup items are pre-built by mic_devices_changed handler
  sketchybar --set mic popup.drawing=toggle
else
  # Left-click: mute/unmute toggle via native CoreAudio
  mic-guard mute
  sketchybar --trigger mic_clicked
fi
```

### Reference implementation

See the full working config in the [dotfiles repo](https://github.com/pszypowicz/dotfiles/tree/main/dot-config/sketchybar).

### Debugging with a development build

The plugin scripts invoke `mic-guard` via `$PATH`. During development you can make SketchyBar use the Xcode build product instead of the installed `mic-guard`:

**1. Stop SketchyBar**

```bash
brew services stop sketchybar
```

**2. Create a symlink for the dev binary (one-time)**

Xcode builds the product as `MicGuard`, but the plugin scripts call `mic-guard`. Create a symlink so the name resolves:

bash:

```bash
DEBUG_DIR=~/Library/Developer/Xcode/DerivedData/MicGuard-*/Build/Products/Debug
ln -sf "$DEBUG_DIR"/MicGuard "$DEBUG_DIR"/mic-guard
```

fish:

```fish
set DEBUG_DIR ~/Library/Developer/Xcode/DerivedData/MicGuard-*/Build/Products/Debug
ln -sf $DEBUG_DIR/MicGuard $DEBUG_DIR/mic-guard
```

**3. Run SketchyBar with the dev PATH**

bash:

```bash
PATH="$DEBUG_DIR:$PATH" sketchybar
```

fish:

```fish
env PATH=(string join : $DEBUG_DIR $PATH) sketchybar
```

SketchyBar inherits the modified `PATH`, so all plugin scripts will invoke the development `mic-guard` binary.

**4. Stop and restore**

Press `Ctrl-C` in the terminal to stop SketchyBar, then restart the managed instance:

```bash
brew services start sketchybar
```

## Building your own integration

MicGuard's distributed notifications make it straightforward to build custom integrations. See the [Notifications](notifications.md) page for the full reference and code examples.
