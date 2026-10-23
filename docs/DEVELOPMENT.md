# FatCatPomodoro — Development Guide

> Audience: a developer iterating on the app. Read [ARCHITECTURE.md](ARCHITECTURE.md)
> first for the subsystem map and the design decisions behind it.

---

## 1. Repo layout

```
Package.swift                     SwiftPM manifest (macOS 14+, single executable target)
FatCatPomodoro.xcodeproj/         Xcode project used for signed/App Store builds
Sources/FatCatPomodoro/           all app code
  ├── IslandApp.swift             @main, AppDelegate, overlay windows, PurchaseCoordinator
  ├── IslandView.swift            island UI, keyboard handling, SettingsQuickSetupView
  ├── IslandWindow.swift          NSPanel + the NSHostingView crash workaround
  ├── HotkeyManager.swift         KeyCombo/ShortcutAction model, Carbon hotkeys, recorder UI
  ├── *Manager.swift              one singleton per subsystem (see ARCHITECTURE.md §1)
  ├── Views/                      dial, score widgets, break video player
  ├── Resources/                  cat videos, icons (processed into the SwiftPM bundle)
  ├── Info.plist                  shared by both build paths (embedded via linker for SwiftPM)
  └── FatCatPomodoro.entitlements sandbox + network + calendars + apple-events
scripts/                          Developer-ID (DMG) release pipeline
build_mas.sh                      Mac App Store build + sign + pkg
ExportOptions.plist               Developer-ID export settings (team NZJ6XP9B66)
docs/                             you are here
```

`Test.xcodeproj/` and `test_project.yml` at the repo root are scratch artifacts —
not part of either build path; safe to ignore (or delete once confirmed unused).

### The dual build system — the #1 gotcha

The app builds **two ways** and they discover sources differently:

- **SwiftPM** (`swift build`, used for the fast dev loop) globs every `.swift` under
  `Sources/FatCatPomodoro` automatically.
- **Xcode project** (used for signing/release) references files **individually** in
  `project.pbxproj`.

**A new `.swift` file compiles under SwiftPM but silently missing from release builds
unless you also add it to the Xcode project** (Xcode → right-click the group → Add Files,
make sure the app target is checked). Prefer extending an existing file for small
additions — that's why the shortcut-recorder UI lives inside `HotkeyManager.swift`.

---

## 2. Dev loop

```bash
swift build                      # fast compile check
```

A bare binary can't do everything (bundle-dependent features: notifications, URL scheme,
resources resolve differently), so for a real run assemble a local .app — the exact
commands are in README.md → "Quick Dev Run". Short version: copy the binary, Info.plist
and the `FatCatPomodoro_FatCatPomodoro.bundle` into an .app skeleton, `lsregister` it,
`open` it.

Debugging tips:

- The app is `LSUIElement`-style (`.accessory` activation policy) — no Dock icon.
  Kill it via the status-bar menu → Quit, or `pkill FatCatPomodoro`.
- `print` output: launch the binary directly from a terminal instead of `open` to see
  stdout, or use Console.app filtered on FatCatPomodoro.
- The island window sits at shielding level — if a stray build leaves a phantom island
  on screen, `pkill` is the way out.

### Testing

There is no automated test target yet. Manual smoke checklist before shipping:

1. ⌘⇧P opens the island from another app; typing `25`, a title, ↩ starts a flow.
2. ⌘⇧S pauses/resumes; pause < 10 s discards silently, > 10 s long-press shows
   Log/Discard/Resume.
3. ⌘⇧B during flow logs the elapsed session and the break starts (cat video appears,
   drag to a screen edge ends it).
4. Settings → Keyboard Shortcuts: rebind a combo, confirm old combo stops working,
   ↺ restores default; assigning an in-use combo disables the other action's row.
5. Session completes → entry in Settings history, calendar event written, streak +1.
6. With Jarvi linked: task chips pull from the configured list; completing a chip marks
   the remote task done.
7. Lock check (un-purchased build): 4th session of the day shows the paywall;
   purchase flow opens Apple's sheet (StoreKit sandbox account).
8. Sleep the Mac mid-flow, wake: timer resumed with the gap compensated.

If you add a test target, note that most managers are singletons touching live system
services (EventKit, StoreKit, Keychain) — introduce protocol seams before unit-testing
them; `PomodoroHistoryManager` and the `KeyCombo` codec are the easiest first targets.

---

## 3. Release

### Path A — Developer ID DMG (direct download)

```bash
./scripts/build_archive.sh    # xcodebuild archive + export + codesign verify
export APPLE_ID=… APP_SPECIFIC_PASSWORD=…   # or a notarytool keychain profile
./scripts/notarize.sh         # submit, wait for Accepted, staple, spctl check
./scripts/make_dmg.sh         # build/FatCatPomodoro-1.0.dmg
```

Details, prerequisites and the clean-Mac smoke test are in README.md → "How to Build &
Distribute".

### Path B — Mac App Store

```bash
./build_mas.sh                # archive → sign with Apple Distribution + entitlements
                              # → productbuild signed .pkg → upload via Transporter
```

MAS-specific constraints already handled in the codebase — keep them in mind when
changing related code:

- **Sandbox entitlements** (`FatCatPomodoro.entitlements`): network client (Jarvi),
  calendars (EventKit), apple-events (DND/strict-mode scripting). A new capability means
  a new entitlement *and* usually a new `*UsageDescription` string in Info.plist.
- **Guideline 4 (minimal functionality for accessory apps):** the NSStatusItem menu-bar
  presence exists for App Review — don't remove it.
- **Guideline 3.1.2:** `SubscriptionLegalView` (price, renewal disclosure, Terms/Privacy
  links) must stay visible wherever the subscription can be bought.
- **Paid Apps Agreement:** IAP review has historically failed not for code reasons but
  because the Paid Apps Agreement wasn't active in App Store Connect — check
  Agreements/Tax/Banking before resubmitting after any IAP rejection.
- Carbon hotkeys and the shielding-level panel are sandbox-compatible; no Accessibility
  permission is needed for the hotkeys (that's why Carbon was chosen — see
  ARCHITECTURE.md §4).

---

## 4. How-to recipes

### Add a user setting

1. Add `@AppStorage("pomodoro.<name>") var …` to `PomodoroManager` (namespaced key).
2. Surface it in `SettingsQuickSetupView` (IslandView.swift) — top level if it's a
   headline feature, `advancedSettingsContent` otherwise. Reuse the section pattern:
   9 pt black tracking header + `OrangeToggleStyle` toggles / small menu pickers.
3. If other components must react live, observe the manager property (Combine) rather
   than `UserDefaults.didChangeNotification` where possible.

### Add a global hotkey action

1. New case in `ShortcutAction` (HotkeyManager.swift) with `title`, `defaultCombo`,
   and a **new, never-reused** `carbonID`.
2. Add a callback property on `HotkeyManager` and a case in `dispatch(id:)`.
3. Wire the callback in `AppDelegate.setupHotkeys()` (IslandApp.swift) — always hop to
   the main queue there.
4. The settings UI picks the new case up automatically (`ForEach(ShortcutAction.allCases)`).
5. Choose a ⌘⇧-tier default that doesn't collide with common app shortcuts.

### Add an in-island key

1. Add the branch in `IslandView.handleIslandKeyDown` — **ordering matters**: modifier
   combos go before the `guard flags.isEmpty`, bare keys after. Return `nil` to consume,
   the event to pass through (e.g. to the focused text field).
2. Respect the guards already there (`isIdle` for anything that mutates session state).
3. Update the cheat sheet in `ShortcutsSettingsSection` (HotkeyManager.swift) and the
   README hotkeys section.

### Add an overlay window (break-style)

Follow the `updateFullScreenVideo` pattern in IslandApp.swift: borderless `NSWindow`,
`level = CGShieldingWindowLevel()` (+n to layer), `.canJoinAllSpaces, .fullScreenAuxiliary`,
clear/non-opaque background, content via `NSHostingView` (or `IslandHostingView` if the
content animates its own frame). Create lazily, `orderFrontRegardless()`, and tear down by
`orderOut` + nil-ing the reference. Persist geometry under a versioned UserDefaults key
(`…X_v1`) and clamp restored values on-screen before use.

### Talk to a new Jarvi endpoint

Copy an existing method in JarviManager: background queue, `authedRequest`-style headers
(Bearer + X-API-Key + X-User-ID), lenient JSON parsing, completion dispatched to main.
Never store identity from anything but a pairing response.

---

## 5. Code conventions

- **Singletons + `@Published`** for managers; views observe, never reach into another
  view's state.
- **Design tokens** (keep the island looking coherent): black background, orange accent,
  `.rounded` SF font design; section headers 9 pt `.black` weight, 1–1.5 tracking,
  `white.opacity(0.4)`; capsule chips; `PlainButtonStyle()` everywhere (default style
  draws AppKit bezels that break the look).
- **Comments** explain *why* and non-obvious constraints (crash workarounds, OS-version
  quirks, review-guideline requirements) — not what the next line does. The existing
  files model the tone.
- **UserDefaults keys** are namespaced (`pomodoro.*`, `shortcut.v1.*`) and versioned
  when their semantics change.
- **Notification names** are cross-component API — grep all usages before renaming
  (inventory in ARCHITECTURE.md §7).
- Main thread for all state mutation; background queues only for network/process work
  with an explicit hop back.

## 6. Gotcha index (things that look wrong but are load-bearing)

| Thing | Why it must stay | Where |
|---|---|---|
| `IslandHostingView` no-op intrinsic size | AppKit re-entrancy crash workaround | IslandWindow.swift |
| `capturedHeight` snapshot before animating | CA constraint-conflict crash | IslandView.swift |
| `NSApp.activate` + focus dance on hotkey open | non-activating panel can't take keys otherwise | IslandView.swift |
| `PurchaseCoordinator` anchor window | StoreKit silently fails on macOS 15.2+ without it | IslandApp.swift |
| Hotkeys unregistered during recording | combo must arrive as keyDown, not fire its old action | HotkeyManager.swift |
| Empty `Data()` as "shortcut disabled" sentinel | distinguishes disabled from "use default" | HotkeyManager.swift |
| `skip()` asymmetry (work completes, break ends) | finishing early still logs the flow | PomodoroManager.swift |
| `pause(silent:)` flag | internal transitions must not emit Jarvi pause events | PomodoroManager.swift |
| 7.09 s video seek on loop | cat walk-in plays once, loop starts after | LoopingVideoPlayer.swift |
| Versioned geometry keys (`_v1`, `_v4`) | invalidates stale saved positions | IslandApp.swift |
| Status-bar item | App Review guideline 4 presence requirement | IslandApp.swift |
