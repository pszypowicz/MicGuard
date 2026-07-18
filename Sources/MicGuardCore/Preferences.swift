import Foundation

/// UserDefaults-backed persistence for MicGuard's settings.
public struct Preferences {
    public static let preferredDeviceKey = "preferredDevice"
    public static let modeKey = "mode"
    public static let settleSecondsKey = "settleSeconds"
    public static let showMenuBarIconKey = "showMenuBarIcon"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Self.settleSecondsKey: 2.0,
            Self.showMenuBarIconKey: true,
        ])
    }

    /// Exact name of the input device MicGuard protects; empty until initialized.
    public var preferredDevice: String {
        get { defaults.string(forKey: Self.preferredDeviceKey) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Self.preferredDeviceKey) }
    }

    /// "auto" or "manual"; anything else reads as "auto".
    public var mode: String {
        get { defaults.string(forKey: Self.modeKey) == "manual" ? "manual" : "auto" }
        nonmutating set { defaults.set(newValue, forKey: Self.modeKey) }
    }

    /// Shell-only setting: whether the menu bar icon is installed. With the
    /// icon hidden, reopening the app shows the Settings window.
    public var showMenuBarIcon: Bool {
        get { defaults.bool(forKey: Self.showMenuBarIconKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.showMenuBarIconKey) }
    }

    /// How long after a device connects or disconnects that input switches are
    /// treated as system noise rather than user intent. Must be 1-30 seconds;
    /// out-of-range values read as the default. No UI - tune with:
    /// `defaults write cz.szypowi.micguard settleSeconds -float 5`
    public var settleSeconds: TimeInterval {
        let value = defaults.double(forKey: Self.settleSecondsKey)
        return (1...30).contains(value) ? value : 2.0
    }
}
