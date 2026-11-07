---
name: verify
description: Build, launch, and drive MicGuard to observe a change working - menu bar app with Settings/About windows, defaults-driven behavior, CoreAudio monitoring.
---

# Verifying MicGuard

Menu bar accessory app (LSUIElement, no Dock icon). Surface = status item
menu, Settings/About windows, `cz.szypowi.micguard` defaults domain, and
the unified log.

## Build + launch

- `make dev` - builds `.build/MicGuard.app` and (re)launches it. Kills any
  running instance first, including the user's installed copy.
- `open .build/MicGuard.app` occasionally fails with LS error -600 right
  after a killall; the process usually launches anyway - check
  `pgrep -fl MicGuard.app` before retrying.
- When done, restore the user's instance: `killall MicGuard`, undo any
  defaults you changed (`defaults read cz.szypowi.micguard` first and note
  the original values), then `open /Applications/MicGuard.app`.

## Drive

- Reopen gesture (opens Settings): `open .build/MicGuard.app` while running.
- Window list + IDs for screenshots: AppleScript `windows of process
"MicGuard"` via System Events needs Accessibility for the terminal app.
  CGWindowListCopyWindowInfo from a `swift` script gives window IDs for
  `screencapture -x -l<ID>`, which needs Screen Recording for the terminal
  app. If System Events reports 0 windows while CGWindowList shows the
  window, re-check those two grants before concluding anything about the
  app.
- Region screenshots (`screencapture -R`) capture the active Space - the
  app's windows open on the user's current Space, which may not be yours.
  Capture by window ID instead.
- Status item and About window: not reachable through accessibility on
  macOS 27. The system `MenuBarAgent` process draws every app's menu bar
  extras and its AX elements have no role, name, or description, so no app
  exposes `menu bar 2` and error -1719 does not mean the icon is missing.
  For icon state, read the `showMenuBarIcon` default or the Settings toggle.
  For the version the About window shows, read `BuildMetadata.generated.swift`
  under `.build/plugins/outputs/`.
- Settings controls: walk the window's `UI elements` level by level with a
  recursive AppleScript handler and match role "AXCheckBox" /
  "AXPopUpButton" (SwiftUI Forms have no stable static hierarchy).
  `entire contents of window 1` returns elements whose role and name can't
  be read. Toggle names match their labels. Close the window with
  `click (first button of window 1 whose subrole is "AXCloseButton")`.
- Live-apply: `defaults write cz.szypowi.micguard showMenuBarIcon -bool
false|true` applies via KVO without relaunch.
- Log: `/usr/bin/log show --predicate 'subsystem == "cz.szypowi.micguard"'
--last 5m --info --debug`.

## Gotchas

- This is the user's live machine and mic guard: windows you open pop onto
  their active Space and they may close them mid-test; keep rounds short.
- Do NOT toggle Launch at Login from a dev build - SMAppService would
  register the `.build` path as the login item. The installed app's
  registration also makes `SMAppService.mainApp.status` readings from the
  dev bundle unreliable.
- Restore `mode`/`preferredDevice` if your UI clicks changed them; the app
  writes them through to defaults immediately.
