---
title: Distributed Notifications
---

# Distributed Notifications

MicGuard posts macOS distributed notifications that any app or script can observe to react to mic state changes.

[Home](index.md) · [CLI Reference](cli.md) · [Debugging](debugging.md) · [Integrations](integrations.md) · [Releasing](releasing.md)

## Notification reference

| Notification | Direction | Posted when |
|---|---|---|
| `com.pszypowicz.MicGuard.statusChanged` | Outbound | Volume change, mute toggle, enabled toggle, device plug/unplug, default device switch, app launch, ping response |
| `com.pszypowicz.MicGuard.appTerminated` | Outbound | The app is about to quit |
| `com.pszypowicz.MicGuard.requestStatus` | Inbound | External consumers post this to request a `statusChanged` notification |
| `com.pszypowicz.MicGuard.toggleMute` | Inbound | Toggle mute on the current input device |
| `com.pszypowicz.MicGuard.setVolume` | Inbound | Set input volume (expects `userInfo["volume"]` as string 0-100) |


## Payload schema

### `statusChanged` userInfo

| Key | Type | Values |
|-----|------|--------|
| `info` | String | JSON string containing the unified payload (see below) |

The `info` value is a JSON-serialized string with the following structure:

```json
{
  "enabled": true,
  "devices": [
    {
      "name": "MacBook Pro Microphone",
      "current": true,
      "volume": 75,
      "muted": false
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | Boolean | Whether MicGuard device enforcement is active |
| `devices` | Array | All input devices, sorted alphabetically by name |
| `devices[].name` | String | Device name |
| `devices[].current` | Boolean | `true` if this is the active input device |
| `devices[].volume` | Integer | Input volume 0–100 |
| `devices[].muted` | Boolean | Native mute flag state |

Volume and mute changes are debounced (100ms) before posting.

### `setVolume` userInfo

| Key | Type | Values |
|-----|------|--------|
| `volume` | String | Desired volume `"0"`–`"100"` |

Other notifications carry no userInfo payload.

## API stability

MicGuard is pre-1.0. Notification names and payload schema may change before version 1.0.0.

## Observing notifications

### Swift

```swift
import Foundation

let center = DistributedNotificationCenter.default()

center.addObserver(
    forName: NSNotification.Name("com.pszypowicz.MicGuard.statusChanged"),
    object: nil,
    queue: .main
) { notification in
    let info = notification.userInfo as? [String: String] ?? [:]
    guard let jsonString = info["info"],
          let data = jsonString.data(using: .utf8),
          let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    let enabled = payload["enabled"] as? Bool ?? false
    let devices = payload["devices"] as? [[String: Any]] ?? []
    for device in devices {
        let name = device["name"] as? String ?? ""
        let current = device["current"] as? Bool ?? false
        let volume = device["volume"] as? Int ?? 0
        let muted = device["muted"] as? Bool ?? false
        print("  \(current ? "▶" : " ") \(name) vol=\(volume) muted=\(muted)")
    }
    print("MicGuard: enabled=\(enabled) devices=\(devices.count)")
}
```

### Shell (SketchyBar)

SketchyBar can subscribe to distributed notifications as custom events:

```bash
# Register the distributed notification as a SketchyBar event
sketchybar --add event mic_status_changed "com.pszypowicz.MicGuard.statusChanged"

# Subscribe an item to the event
sketchybar --subscribe mic mic_status_changed
```

### Shell (generic)

You can observe notifications from the command line using `notificationlistener` or similar tools, but the most practical approach is through an app that supports distributed notification subscriptions (like SketchyBar, Hammerspoon, or a custom Swift script).

## Use cases

- **Menubar indicators** — show the current mic name, mute state, or enabled/disabled status
- **Automation** — trigger scripts when the mic changes (e.g. adjust audio routing)
- **Logging** — record device change events for debugging audio issues
