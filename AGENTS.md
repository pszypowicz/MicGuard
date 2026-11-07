# MicGuard project instructions

MicGuard is a macOS menu bar app that keeps the default input device on a preferred microphone when Bluetooth devices take it over. It's a Swift package for macOS 15+ on Apple Silicon.

## Layout

- `Sources/MicGuardCore` holds the logic: CoreAudio monitoring in `AudioMonitor`, settings in `Preferences`, and the `statusChanged` notification. It reaches CoreAudio only through `AudioDeviceProviding` and posts status through an injected closure, so tests run without real devices.
- `Sources/MicGuard` is the AppKit and SwiftUI shell: the status item, the Settings and About windows, and launch at login through `SMAppService`.
- `Plugins/BuildMetadata` generates the version, git hash, and build date that the About window shows.
- `scripts/` holds the bundle, notarization, and DMG scripts, plus `audio-logger.swift`, which prints raw CoreAudio events while you connect and disconnect devices.

## Build and test

- `swift test` runs the unit tests in `Tests/MicGuardCoreTests`.
- `make build` builds `.build/MicGuard.app` with an ad hoc signature, and `make dev` rebuilds and relaunches it. Pass `IDENTITY=` to sign with one of your certificates.
- CI runs `swift test`, an ad hoc bundle build, and shellcheck over `scripts/`. Changes reach `main` through pull requests that pass the `build-and-test` and `shellcheck` checks.
- `.claude/skills/verify/SKILL.md` explains how to launch the app and watch a change work in it. It covers driving the Settings window, reading the log and the defaults, and the parts of the app that macOS doesn't expose to automation.

## Tests

- Build a monitor with `makeMonitor` from `TestHelpers.swift`, which wires in `MockAudioDevices`. Pass a `StatusRecorder` to check `statusChanged` payloads.
- Tests must not touch real CoreAudio devices or post real distributed notifications. New hardware access goes through `AudioDeviceProviding` so the mock can stand in for it.
- A bug fix comes with a test that fails without the fix.

## Compatibility

MicGuard follows semantic versioning, as the README's Compatibility section states. Within 1.x, these stay compatible:

- The `cz.szypowi.micguard` defaults domain, its keys (`preferredDevice`, `mode`, `settleSeconds`, `showMenuBarIcon`), and their documented values.
- The `cz.szypowi.micguard.statusChanged` notification and its userInfo. `device` is the device name, or empty when there is no input device. `muted` is the string `"true"` or `"false"`.

A change that breaks either of them needs a 2.0 release. A new key or a new userInfo field goes into a minor release. Log messages can change in any release.

## Versions and releases

- `VERSION` is the single source of truth. `scripts/bundle.sh` stamps it into `Info.plist`, and `BuildMetadata` reports it in the About window.
- A release candidate is `X.Y.Z-rc.N`. Only the `X.Y.Z` part goes into `CFBundleShortVersionString`, because macOS expects plain numbers there.
- The maintainer builds, signs, and notarizes releases locally with `scripts/notarize-release.sh`, because the Developer ID credentials never leave that machine. CI doesn't publish anything.
- Release candidates are GitHub pre-releases and ship through the `micguard@beta` cask in pszypowicz/homebrew-tap. A stable release updates both `micguard` and `micguard@beta`.

## Writing

- Use American English in code, comments, and docs.
- Use a plain `-` where an em dash would go.
- Comments explain why and describe the code as it is. History belongs in commit messages.
- Commit messages and pull request descriptions say what changed and why.
