---
title: Distributed Notifications
---

# Distributed Notifications

MicGuard posts macOS distributed notifications that any app or script can observe to react to mic state changes.

[Home](index.md) · [CLI Reference](cli.md) · [Debugging](debugging.md) · [Integrations](integrations.md) · [Releasing](releasing.md)

## Notification reference

| Notification | Direction | Posted when |
|---|---|---|
| `com.pszypowicz.MicGuard.statusChanged` | Outbound | Device change, enabled toggle, app launch, ping response |
| `com.pszypowicz.MicGuard.appTerminated` | Outbound | The app is about to quit |
| `com.pszypowicz.MicGuard.requestStatus` | Inbound | External consumers post this to request a status re-broadcast |

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
    print("MicGuard status changed")
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
