import Foundation

/// One-way telemetry for personal integrations (e.g. SketchyBar). MicGuard
/// only tells - there is no notification that controls it.
public enum MicGuardNotification {
    /// Distributed notification posted when the current input device or its
    /// muted state changes. userInfo: "device" (name), "muted" ("true"/"false").
    public static let statusChanged = Notification.Name("cz.szypowi.micguard.statusChanged")
}
