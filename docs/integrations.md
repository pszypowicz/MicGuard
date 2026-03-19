---
title: Integrations
---

# Integrations

MicGuard posts [distributed notifications](notifications.md) whenever the input device changes, monitoring is toggled, or the app terminates. Any macOS app or script that can observe `DistributedNotificationCenter` can react to these events.

[Home](index.md) · [CLI Reference](cli.md) · [Notifications](notifications.md) · [Releasing](releasing.md)

## SketchyBar

The reference integration is a [SketchyBar](https://github.com/FelixKratz/SketchyBar) item that shows mic status in the menubar with 4 visual states:

| State | Icon | Color | Label | Meaning |
|-------|------|-------|-------|---------|
| Active | nf-md-microphone | White | Device name | Mic is live, MicGuard is monitoring |
| Muted | nf-md-microphone_off | Red | Device name | Input volume is 0 |
| Disabled | nf-md-microphone | Yellow | Device name | MicGuard running, monitoring off |
| Off | nf-md-microphone | Yellow | "Off" | MicGuard not running or no valid device |

Icons are [Nerd Font](https://www.nerdfonts.com/) glyphs (`U+F0D6C` and `U+F0D6D`). A patched font is required.

### Features

- **Left-click** — toggle mute/unmute (sets input volume to 0 or 100)
- **Right-click** — popup picker listing all input devices + monitoring toggle; selecting a device sets it as default and updates `preferred-mic`

### Setup

#### 1. Register events and create the item

In your SketchyBar items directory (e.g. `items/mic.sh`):

```bash
#!/usr/bin/env bash

mic=(
  updates=on
  update_freq=60
  label.drawing=on
  icon.width=22
  padding_right=4
  label.padding_right=2
  popup.align=right
  popup.height=0
  script="$PLUGIN_DIR/mic.sh"
  click_script="$PLUGIN_DIR/mic_click.sh"
)

sketchybar --add event mic_clicked
sketchybar --add event mic_status_changed "com.micguard.statusChanged"
sketchybar --add event mic_app_terminated "com.micguard.appTerminated"

sketchybar --add item mic right \
  --set mic "${mic[@]}" \
  --subscribe mic mic_clicked mic_status_changed mic_app_terminated mouse.exited mouse.exited.global

# Request current status from MicGuard
mic-guard ping 2>/dev/null &
```

The `mic-guard ping` at the end asks the running MicGuard daemon to re-broadcast its status via `com.micguard.statusChanged`, so the mic item populates immediately when sketchybar starts (or restarts) regardless of when MicGuard launched.

Key points:
- `mic_status_changed` maps to the `com.micguard.statusChanged` distributed notification
- `mic_app_terminated` maps to `com.micguard.appTerminated`
- `mic_clicked` is a custom event triggered after mute/unmute or device change to refresh the display
- `mouse.exited` / `mouse.exited.global` close the device picker popup

#### 2. Update script

The plugin script (`plugins/mic.sh`) runs on every subscribed event and periodic update:

```bash
#!/usr/bin/env bash

export PATH="/opt/homebrew/bin:$PATH"
source "$CONFIG_DIR/colors.sh"

# Close popup when mouse leaves
if [[ "$SENDER" == "mouse.exited" || "$SENDER" == "mouse.exited.global" ]]; then
  sketchybar --set mic popup.drawing=off
  exit 0
fi

# MicGuard app terminated — show off state
if [[ "$SENDER" == "mic_app_terminated" ]]; then
  # Nerd Font: nf-md-microphone (U+F0D6C)
  sketchybar -m --set mic label="Off" icon=󰍬 icon.color=$YELLOW label.color=$YELLOW
  exit 0
fi

# Check if MicGuard.app is running
if ! pgrep -f 'MicGuard.app/Contents/MacOS/MicGuard' >/dev/null 2>&1; then
  sketchybar -m --set mic label="Off" icon=󰍬 icon.color=$YELLOW label.color=$YELLOW
  exit 0
fi

MIC_NAME=$(mic-guard current 2>/dev/null) || exit 0
MIC_NAME=$(echo $MIC_NAME | awk '{print $1}')

# Check if monitoring is disabled
ENABLED=$(cat ~/.config/mic-guard/enabled 2>/dev/null)
if [[ "$ENABLED" == "0" ]]; then
  sketchybar -m --set mic label="$MIC_NAME" icon=󰍬 icon.color=$YELLOW label.color=$YELLOW
  exit 0
fi

MIC_VOLUME=$(osascript -e 'input volume of (get volume settings)' 2>/dev/null) || exit 0

if [[ $MIC_VOLUME -eq 0 ]]; then
  # Nerd Font: nf-md-microphone_off (U+F0D6D)
  sketchybar -m --set mic label="$MIC_NAME" icon=󰍭 icon.color=$RED label.color=$RED
else
  sketchybar -m --set mic label="$MIC_NAME" icon=󰍬 icon.color=$WHITE label.color=$WHITE
fi
```

#### 3. Click handler

The click script (`plugins/mic_click.sh`) handles left-click mute/unmute, right-click device picker, and monitoring toggle:

```bash
#!/usr/bin/env bash

export PATH="/opt/homebrew/bin:$PATH"
source "$CONFIG_DIR/colors.sh"

PREF_FILE="$HOME/.config/mic-guard/preferred-mic"

# Do nothing if MicGuard.app is not running
if ! pgrep -f 'MicGuard.app/Contents/MacOS/MicGuard' >/dev/null 2>&1; then
  exit 0
fi

if [[ "$BUTTON" == "right" ]]; then
  # Right-click: build popup with all input devices
  DEVICES=$(mic-guard list)
  CURRENT=$(mic-guard current)

  sketchybar --remove '/mic\.(device|sep|monitoring)\..*/' 2>/dev/null

  INDEX=0
  while IFS= read -r device; do
    [[ -z "$device" ]] && continue
    ITEM_NAME="mic.device.$INDEX"

    if [[ "$device" == "$CURRENT" ]]; then
      ICON="󰄬"  # Nerd Font: nf-md-check (U+F0126)
      COLOR="$WHITE"
    else
      ICON=" "
      COLOR="$ORANGE"
    fi

    sketchybar --add item "$ITEM_NAME" popup.mic \
      --set "$ITEM_NAME" \
        label="$device" \
        icon="$ICON" \
        icon.width=20 \
        icon.color="$COLOR" \
        label.color="$COLOR" \
        background.color=0x00000000 \
        background.height=30 \
        background.drawing=on \
        click_script="mic-guard set '$device'; echo '$device' > '$PREF_FILE'; sketchybar --set mic popup.drawing=off; sketchybar --trigger mic_clicked"

    INDEX=$((INDEX + 1))
  done <<< "$DEVICES"

  # Determine monitoring toggle state
  ENABLED=$(cat ~/.config/mic-guard/enabled 2>/dev/null)
  if [[ "$ENABLED" == "0" ]]; then
    MONITOR_LABEL="Enable Monitoring"
    MONITOR_ICON="󰍬"
    MONITOR_CMD="mic-guard enable"
  else
    MONITOR_LABEL="Disable Monitoring"
    MONITOR_ICON="󰍭"
    MONITOR_CMD="mic-guard disable"
  fi

  # Separator — build dash line matching the longest popup entry
  MAX_LEN=${#MONITOR_LABEL}
  while IFS= read -r device; do
    [[ ${#device} -gt $MAX_LEN ]] && MAX_LEN=${#device}
  done <<< "$DEVICES"
  # +3 accounts for icon + icon padding equivalent in characters
  SEP_LINE=$(printf '—%.0s' $(seq 1 $(( (MAX_LEN + 3) * 17 / 8 ))))

  sketchybar --add item mic.sep.0 popup.mic \
    --set mic.sep.0 \
      icon.drawing=off \
      label="$SEP_LINE" \
      label.font="CaskaydiaCove Nerd Font:Bold:8.0" \
      label.color=0x44ffffff \
      label.padding_left=4 \
      label.padding_right=4

  sketchybar --add item mic.monitoring.0 popup.mic \
    --set mic.monitoring.0 \
      label="$MONITOR_LABEL" \
      icon="$MONITOR_ICON" \
      icon.color="$YELLOW" \
      label.color="$YELLOW" \
      background.color=0x00000000 \
      background.height=30 \
      background.drawing=on \
      click_script="$MONITOR_CMD; sketchybar --set mic popup.drawing=off; sketchybar --trigger mic_clicked"

  sketchybar --set mic popup.drawing=toggle
else
  # Left-click: mute/unmute toggle
  MIC_VOLUME=$(osascript -e 'input volume of (get volume settings)')

  if [[ $MIC_VOLUME -gt 0 ]]; then
    osascript -e 'set volume input volume 0'
  else
    osascript -e 'set volume input volume 100'
  fi

  sketchybar --trigger mic_clicked
fi
```

### Reference implementation

See the full working config in the [dotfiles repo](https://github.com/pszypowicz/dotfiles/tree/main/dot-config/sketchybar).

## Building your own integration

MicGuard's distributed notifications make it straightforward to build custom integrations. See the [Notifications](notifications.md) page for the full reference and code examples.
