# MicGuard project instructions

MicGuard is a macOS menu bar app that keeps the default input device on a preferred microphone when Bluetooth devices take it over. It's a Swift package for macOS 15+ on Apple Silicon, and it builds with Xcode 26 or later.

## Layout

- `Sources/MicGuardCore` holds the logic: CoreAudio monitoring in `AudioMonitor`, settings in `Preferences`, and the `statusChanged` notification. It reaches CoreAudio only through `AudioDeviceProviding` and posts status through an injected closure, so tests run without real devices.
- `Sources/MicGuard` is the AppKit and SwiftUI shell: the status item, the Settings and About windows, and launch at login through `SMAppService`.
- `Plugins/BuildMetadata` generates the version, git hash, and build date that the About window shows.
- `Resources/` holds the app icon, the DMG background, and `Localizable.xcstrings`, the string catalog with every translation.
- `scripts/` holds the bundle, notarization, DMG, and string catalog scripts, plus `audio-logger.swift`, which prints raw CoreAudio events while you connect and disconnect devices.

## Build and test

- `swift test` runs the unit tests in `Tests/MicGuardCoreTests`.
- `make build` builds `.build/MicGuard.app` with an ad hoc signature, and `make dev` rebuilds and relaunches it. Pass `IDENTITY=` to sign with one of your certificates.
- CI runs `swift test` with warnings treated as errors, the string catalog check, an ad hoc bundle build, and shellcheck over `scripts/`. Changes reach `main` through pull requests that pass the `build-and-test` and `shellcheck` checks.
- `.claude/skills/verify/SKILL.md` explains how to launch the app and watch a change work in it. It covers driving the Settings window, reading the log and the defaults, and the parts of the app that macOS doesn't expose to automation.

## Concurrency

- Every target defaults to main actor isolation, set in `Package.swift`, so types and functions don't need `@MainActor`. Mark code that can run off the main actor `nonisolated`, as `AppDelegate.observeValue` does for KVO callbacks.
- The package also turns on the upcoming features that the Swift 7 language mode enables. In MicGuardCore, a module whose types appear in public API is imported with `public import`. Each file imports the modules it uses, such as `os` for logging, because imports from another module don't carry over.

## Tests

- Build a monitor with `makeMonitor` from `TestHelpers.swift`, which wires in `MockAudioDevices`. Pass a `StatusRecorder` to check `statusChanged` payloads.
- Tests must not touch real CoreAudio devices or post real distributed notifications. New hardware access goes through `AudioDeviceProviding` so the mock can stand in for it.
- A bug fix comes with a test that fails without the fix.

## Localization

- User-facing text lives in `Resources/Localizable.xcstrings`, a String Catalog keyed by the English text. English needs no entries, and a missing translation falls back to English.
- SwiftUI literals such as `Text("Auto Mode")` and `Label("Microphone", systemImage:)` are localized automatically. A plain `String` that reaches the UI is not. Wrap AppKit menu titles, window titles, and strings picked by a ternary in `String(localized:)`, or pick between `Text` literals instead. A parameter that carries UI text is typed `LocalizedStringKey`, as in `InfoDot`. Show device names and other data with `Text(verbatim:)`.
- When the same English text needs different translations in different places, give one of them its own key with `String(localized: "key", defaultValue: "English text")`. The About window title does this, because Polish macOS titles the About menu item "MicGuard…", which reads oddly as a window title.
- After adding or changing UI text, run `scripts/sync-strings.sh`. It builds with the compiler's string extraction and updates the catalog. CI runs `scripts/sync-strings.sh --check`, which fails if the catalog is out of date or not in the layout the tool writes.
- To add a language, add its translations to the catalog, in Xcode's catalog editor or by editing the JSON, then run `scripts/sync-strings.sh` to normalize the file. `scripts/bundle.sh` compiles a `<language>.lproj` folder for every language that has translations and lists it in `CFBundleLocalizations`, so nothing else changes.
- Use the terms macOS itself uses in that language where they exist, such as the standard About, Settings, and Quit menu titles and the names of System Settings panes. macOS ships them as `.loctable` files, binary plists with one table per language. Look under `/System/Library/ExtensionKit/Extensions/*.appex/Contents/Resources/` for System Settings panes, for example `LoginItems.appex` and `LoginItemsIntentsExtension.appex`, and `/System/Library/Frameworks/AppKit.framework/Resources/` for menus. `plutil -p` prints a table, so you can match the English string to its translation. Polish macOS titles the About menu item "<app>…" and the Quit item "Zakończ <app>", for example.
- To check a language, run `make build`, then `open .build/MicGuard.app --args -AppleLanguages '(pl)'`, and open the app again to show Settings. Also check a list such as `'(en-GB, pl)'`, which must stay in English.
- Compiling the catalog needs Xcode. Without it, `scripts/bundle.sh` builds English only and prints a warning, and `scripts/notarize-release.sh` refuses to release.

## Compatibility

MicGuard follows semantic versioning, as the README's Compatibility section states. Within 1.x, these stay compatible:

- The `cz.szypowi.micguard` defaults domain, its keys (`preferredDevice`, `mode`, `settleSeconds`, `showMenuBarIcon`), and their documented values.
- The `cz.szypowi.micguard.statusChanged` notification and its userInfo. `device` is the device name, or empty when there is no input device. `muted` is the string `"true"` or `"false"`.

A change that breaks either of them needs a 2.0 release. A new key or a new userInfo field goes into a minor release. Log messages can change in any release.

## Versions and releases

- `VERSION` is the single source of truth. `scripts/bundle.sh` stamps it into `Info.plist`, and `BuildMetadata` reports it in the About window.
- A release candidate is `X.Y.Z-rc.N`. Only the `X.Y.Z` part goes into `CFBundleShortVersionString`, because macOS expects plain numbers there.
- The maintainer builds, signs, and notarizes releases locally with `scripts/notarize-release.sh`, because the Developer ID credentials never leave that machine. CI doesn't publish anything.
- Release candidates are GitHub pre-releases and ship through the `micguard@beta` cask in pszypowicz/homebrew-tap. A stable release updates `micguard` only. `micguard@beta` moves only with release candidates and stays on the last one between them.

## Writing

- Use American English in code, comments, and docs.
- Use a plain `-` where an em dash would go.
- Comments explain why and describe the code as it is. History belongs in commit messages.
- Commit messages and pull request descriptions say what changed and why.
