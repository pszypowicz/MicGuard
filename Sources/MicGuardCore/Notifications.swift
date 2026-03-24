import Foundation

public enum MicGuardNotification {
    public static let statusChanged = NSNotification.Name("com.pszypowicz.MicGuard.statusChanged")
    public static let appTerminated = NSNotification.Name("com.pszypowicz.MicGuard.appTerminated")
    public static let requestStatus = NSNotification.Name("com.pszypowicz.MicGuard.requestStatus")
    public static let toggleMute = NSNotification.Name("com.pszypowicz.MicGuard.toggleMute")
    public static let setVolume = NSNotification.Name("com.pszypowicz.MicGuard.setVolume")
}
