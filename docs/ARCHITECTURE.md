# FatCatPomodoro — Architecture Guide

> Audience: a developer who has never seen this codebase and needs to change it safely.
> Companion doc: [DEVELOPMENT.md](DEVELOPMENT.md) (build, release, how-to recipes).
> Product-level feature description: [../README.md](../README.md).

FatCatPomodoro is a sandboxed macOS (14.0+) menu-bar-adjacent pomodoro app. Its UI is a
borderless floating panel that disguises itself as a MacBook-notch "Dynamic Island".
Everything else — timers, integrations, purchases — hangs off a small set of singleton
managers observed by SwiftUI.

---

## 1. High-level map

```
IslandApp.swift ─ @main + AppDelegate
 ├── IslandWindow (NSPanel)  ──  IslandView (the island UI, compact + expanded)
 │                                 └── SettingsQuickSetupView (popover)
 │                                       └── ShortcutsSettingsSection (HotkeyManager.swift)
 ├── Break overlay windows (created on demand by AppDelegate):
 │     breakBorderWindow   – full-screen edge glow while dragging the cat
 │     fullScreenWindow    – DraggableCatWindow with LoopingVideoPlayer
 │     skipButtonWindow    – "Skip Break" pill + activity chips
 │     breakTimerWindow    – draggable translucent break countdown
 │     alertWindow         – session-end alert pill (currently mostly disabled)
 └── NSStatusItem           – menu-bar cat (App Review requires a visible presence)

Managers (all `static let shared` singletons, ObservableObject):
 PomodoroManager        session state machine (the core of the app)
 HotkeyManager          customizable global hotkeys (Carbon) + recorder UI
 NotificationManager    notifications, alarm sound, DND automation
 CalendarManager        EventKit facade (local calendars + Apple Reminders)
 JarviManager           HTTPS client for the Jarvi platform (Google Tasks/Calendar relay)
 PomodoroHistoryManager local session log (JSON file) + CSV export + weekly stats
 StoreManager           StoreKit 2 IAP (lifetime + monthly)
 StreakManager          consecutive-day streak counter
 LaunchAtLoginManager   SMAppService wrapper
 MusicManager           intentional stub (excluded feature, kept for compile compatibility)
```

`PomodoroManager` is the only manager instantiated per-app (`AppDelegate.pomodoroManager`)
rather than via `.shared`; it is passed into views as an `@ObservedObject`.

---

## 2. The session state machine (PomodoroManager)

States are expressed through a few published flags rather than one enum — know the
combinations:

| State | `isRunning` | `isPausedConfirming` | `hasActiveWorkSession` | Meaning |
|---|---|---|---|---|
| Idle | false | false | false | nothing in flight; dials visible |
| Flow running | true | false | true | work countdown (or count-up if `isInfiniteFlow`) |
| Flow paused | false | false | true | quietly frozen; resumable |
| Abort prompt | false | true | true | "Log Progress / Discard / Resume" choice |
| Break running | true | false | false | break countdown; overlay windows up |

Transitions worth knowing:

- `start()` — records `sessionStartDate` on first start, fires `FLOW_START`/`BREAK_START`
  to Jarvi, turns DND on (if enabled), starts a 1 s `Timer.publish` on the main run loop.
- `pause(silent:)` — `silent: true` is used by internal transitions so they don't emit
  spurious `FLOW_PAUSE` events.
- `skip()` is **asymmetric by design**: during work it calls `completeSession()` (logs
  elapsed time as a completed session, rolls into break); during break it calls
  `startWorkSession()` (ends the break early).
- `handleAbortClick()` — the **10-second rule**: aborting within 10 s of starting is
  treated as an accidental click and discards silently; later aborts pause and show the
  three-way confirm.
- `completeSession()` fans out to: `PomodoroHistoryManager.logSession` (local JSON),
  `CalendarManager.addEvent` *or* `JarviManager.addGoogleCalendarEvent` (depending on
  `pomodoro.calendarSource`), `JarviManager.logPomodoroSession` (analytics), and
  `StreakManager.recordSession`. It also advances the long-break cycle
  (`sessionsInCycle` vs `sessionsUntilLongBreak`).
- Sleep/wake: `NSWorkspace` sleep notifications auto-pause; wake auto-resumes with
  wall-clock gap compensation (`sessionStartDate` is a date, not an accumulated count,
  precisely so sleep doesn't silently eat minutes).

**Decision — why flags instead of a state enum:** the flags map 1:1 onto SwiftUI view
conditions (`if pomodoroManager.isPausedConfirming { … }`) and each flag is independently
`@Published`. A retrofit to an enum would be cleaner but touches every view; if you do it,
do it in one dedicated PR.

**Decision — why wall-clock dates for timing:** a tick counter drifts across App Nap,
sleep, and timer coalescing. `sessionStartDate`/`breakSessionStart` + 1 s UI ticks give
drift-free logging while keeping the UI simple.

---

## 3. The island UI (IslandView + IslandWindow)

### Window technique

`IslandWindow` is an `NSPanel` with `.borderless`, `.nonactivatingPanel`, level
`CGShieldingWindowLevel() + 1`, and `.canJoinAllSpaces/.fullScreenAuxiliary`. It is
positioned flush against the top edge of the built-in display so the black island
"grows" out of the physical notch.

Decisions baked into this:

- **`.nonactivatingPanel`** — hovering/clicking the island must not steal focus from the
  app the user is working in. The cost: text input needs an explicit
  `NSApp.activate(ignoringOtherApps:)` + `makeKey` dance (see `focusOnOpen` in
  `toggleExpansion` and the `onTapGesture` on the task field). Keep that dance intact.
- **`CGShieldingWindowLevel`** — ordinary `.floating` windows sit below full-screen apps;
  the shielding level keeps the island (and break overlays) above everything.
- **`IslandHostingView`** (IslandWindow.swift) overrides `intrinsicContentSize` to
  no-metric and makes `invalidateIntrinsicContentSize()` a no-op. This is a crash
  workaround: `NSHostingView` re-entrantly invalidates intrinsic size during SwiftUI
  layout and AppKit aborts (`NSPerformVisuallyAtomicChange`). The window frame is the
  single source of size truth. It also zeroes `safeAreaInsets` so macOS doesn't push
  content below the physical notch. **Do not "simplify" this class away.**
- **`capturedHeight` snapshot** (IslandView) — the expanded height is computed once at
  expand time (`snapshotExpandedHeight()`), never from live observables mid-animation,
  because animating a frame whose target reads changing state causes Core Animation
  constraint conflicts → crash.

### Expansion lifecycle

Compact (318×38 wings around the notch) ↔ expanded (480×captured height). The expand
animation runs ~300 ms before `showExpandedContent` fades the content in; collapse
reverses it. Hover-out (with a 200 ms debounce) collapses unless the settings popover is
open. `toggleExpansion(focusOnOpen:)` is the programmatic path used by the global hotkey
and the status-bar menu.

### Keyboard control (added 2026-10)

A single app-local `NSEvent.addLocalMonitorForEvents(.keyDown)` monitor is installed once
in `IslandView.onAppear` (`installKeyMonitor`). `handleIslandKeyDown` early-outs unless:
island expanded + content shown + `NSApp.keyWindow is IslandWindow` + no shortcut
recording in progress. That last two guards are load-bearing:

- `keyWindow is IslandWindow` keeps the monitor from eating keys typed into the settings
  popover (e.g. the Jarvi PIN field) or any other window.
- `HotkeyManager.shared.isRecording` yields to the shortcut recorder's own monitor.

Handled keys, in order (order matters — modifier combos are checked before the bare-key
`guard flags.isEmpty`): `⌘,` settings · `⎋` close settings→island · `⇧←/→` Flow↔Break ·
`⇥/⇧⇥` cycle task chips · `⌘1/2/3` duration presets · `↑/↓` ±5 min nudge · `↩` start ·
digits → minute entry.

**Decision — digit routing heuristic:** typed digits go to the timer *only while the
title is empty* (`currentTask.isEmpty`) or in break mode; once any title character
exists, digits belong to the title. This lets `⌘⇧P → "45" → "write report" → ↩` work
without a mode switch. Known tradeoff: a title that *starts* with a digit needs a letter
typed first.

**Decision — local monitor instead of SwiftUI `.onKeyPress`:** `.onKeyPress` requires
the handling view to own focus, but here keystrokes must be intercepted *before* the
focused `TextField` (digits while title empty) and must work when nothing is focused.
A monitor that returns `nil` consumes the event app-wide; returning the event passes it
through to the field.

---

## 4. Global hotkeys (HotkeyManager)

Three user-customizable actions, persisted per-action in UserDefaults
(`shortcut.v1.<action>` → JSON `KeyCombo`; an **empty `Data()` payload means explicitly
disabled**, absence means "use default"):

| Action | Default | Behavior |
|---|---|---|
| `toggleIsland` | ⌘⇧P | expand/collapse; via hotkey also activates app + focuses title field |
| `toggleTimer` | ⌘⇧S | `PomodoroManager.toggle()` (start/pause) |
| `startBreak` | ⌘⇧B | running/paused flow → `skip()` (logs + rolls into break); idle → start break |

**Decision — Carbon `RegisterEventHotKey` instead of `NSEvent.addGlobalMonitor` or a
`CGEventTap`:** global monitors can't *consume* the keystroke and both monitors and taps
require Accessibility/Input-Monitoring permission (a TCC prompt and an App Review
liability). Carbon hotkeys need no permission, work inside the App Store sandbox, swallow
the key, and fire even over full-screen apps. The API is old but not deprecated.

**Decision — ⌘⇧ defaults:** global hotkeys preempt the frontmost app, so single-modifier
combos like ⌘S/⌘P/⌘B would hijack Save/Print/Bold system-wide. ⌘⇧ is the conventional
tier used by menu-bar utilities (Raycast, Rectangle, CleanShot).

Mechanics to preserve when editing:

- One Carbon event handler is installed once (`installHandlerIfNeeded`); dispatch is by
  `EventHotKeyID.id` == `ShortcutAction.carbonID`. **Never reuse a carbonID.**
- `set(_:for:)` enforces uniqueness by *stealing* the combo from any other action
  (the loser is disabled, its row shows "Record"). Two actions must never share a combo.
- While the recorder is active (`beginRecording`), **all hotkeys are unregistered** so
  the pressed combo arrives as a normal keyDown instead of firing its old action, and
  the recorder's own local monitor swallows everything until a valid combo
  (must include ⌘/⌥/⌃ — see `KeyCombo.init?(event:)`) or ⎋.

The settings UI (`ShortcutsSettingsSection`) lives in the same file so SwiftPM/Xcode
file lists didn't need to change; it also hosts the static cheat-sheet of built-in island
keys — **update the cheat sheet whenever you add a key to `handleIslandKeyDown`.**

---

## 5. Integrations

### EventKit (CalendarManager)

**Decision:** instead of shipping Google/Exchange/iCloud API clients, the app writes to
local `EKEventStore` and lets macOS account sync move the data. Zero OAuth, zero token
storage, works with whatever accounts the user already configured. The flip side: there
is no server-side presence, which is what JarviManager adds.

### Jarvi (JarviManager)

HTTPS client for `https://asifthatworks.com/api/v1`. Responsibilities: PIN/token pairing,
Google Tasks & Calendar relay, focus telemetry (`/fatcat/event`), analytics
(`/analytics/pomodoro/session`, debounced 5 s against duplicates), and remote start via
4 s polling of `/fatcat/pending-command` plus `fatcatpomodoro://` deep links.

Decisions:

- **Token in Keychain** (`com.fatcat.jarvi`, migrating from legacy `com.islandbar.jarvi`),
  never UserDefaults — it's a bearer credential.
- **Identity hardening:** `jarviUserId` is *only* set from a pairing response; it never
  defaults. The settings UI always displays the paired email/ID so a stale identity is
  visible. (Jarvi's rule: messaging channels are transport, the web id is the identity.)
- **Lenient response parsing** — endpoints historically varied between a bare array and
  `{todos|tasks|items: […]}` wrappers, so parsers try multiple shapes instead of failing.
- **Polling over push:** a sandboxed Mac app with no server of its own can't receive
  webhooks; a 4 s poll is the pragmatic channel for remote-start commands (age-limited
  to 90 s so stale commands don't fire).
- Cross-component delivery is via `NotificationCenter` (`JarviStartPomodoro`,
  `JarviRemoteControl`, `JarviTodosUpdated`, `JarviTokenChanged`) to keep JarviManager
  from importing PomodoroManager.

### DND automation (NotificationManager)

There is **no public API for Focus modes**, so `setDND(enabled:)` tries, in order:
a user-selected Shortcut (run via `/usr/bin/shortcuts`, 2 s timeout), Control Center UI
scripting through Accessibility (AppleScript, idempotent — checks state before
clicking), then known default Shortcut names. `verifyDNDSetup` reports which path is
available. The Shortcuts path is preferred because it needs no Accessibility approval.

### StoreKit 2 (StoreManager + PurchaseCoordinator)

StoreKit 2 (`Product`, `Transaction`, async/await) with two products: lifetime
non-consumable and monthly auto-renewable. The free tier locks after 3 sessions/day
(`completedToday >= 3 && !isUnlocked` → paywall).

**Decision — `PurchaseCoordinator` (IslandApp.swift):** since macOS 15.2, StoreKit
anchors purchase sheets to a key, foreground-active window. This app is an `.accessory`
with a non-activating panel → no valid anchor → purchases silently fail. The coordinator
temporarily shows a minimal titled window, flips activation policy to `.regular`, runs
`purchase(confirmIn:)`, then reverts. Removing it re-breaks purchases on 15.2+.

### History (PomodoroHistoryManager)

Plain JSON at `~/Library/Application Support/FatCatPomodoro/history.json` (auto-migrates
from the old `IslandBar` folder). **Decision:** session logs are small append-mostly
records the user may want to export (CSV) — a Codable array beats Core Data/SQLite on
simplicity and has no migration story to maintain.

---

## 6. Persistence inventory

- **UserDefaults** — all user settings via `@AppStorage` (`pomodoro.*`, `break.*`,
  `compact.*`, `streak.*`, `shortcut.v1.*`), plus remembered overlay geometry
  (`pomodoro.breakCat{X,Y,Scale}_v1`, `pomodoro.breakOverlay{X,Y}_v4` — bump the suffix
  when changing semantics so stale values don't apply).
- **Keychain** — Jarvi token only.
- **Files** — `history.json` (above).
- **Nothing else.** No databases, no caches that need invalidation.

## 7. NotificationCenter names (cross-component contracts)

| Name | Posted by | Observed by | Payload |
|---|---|---|---|
| `ToggleIslandExpansion` | HotkeyManager wiring, status menu | IslandView | `userInfo["viaHotkey"] = true` → activate + focus title field |
| `JarviTokenChanged` / `JarviTodosUpdated` | JarviManager | PomodoroManager | — |
| `JarviStartPomodoro` | JarviManager polling | PomodoroManager | title, durations |
| `JarviRemoteControl` | deep-link handler | PomodoroManager | start/pause/complete/discard |

Treat these strings as API: grep before renaming.

## 8. Threading model

Everything user-visible is main-thread: `@Published` mutations, the 1 s timer, EventKit
completions (re-dispatched to main). Network calls (Jarvi) run on global queues with
main-thread completion dispatch. StoreManager is `@MainActor`. NSEvent monitors fire on
the main thread. There are deliberately **no** custom queues or locks — if you add
background work, hop back to main before touching a manager property.

## 9. Known limitations (intentional, documented)

- Strict mode closes tabs via AppleScript in Safari/Chrome only.
- The break video loop point (7.09 s, where the cat finishes walking in) is hardcoded in
  LoopingVideoPlayer — it is content-specific, not a bug.
- Infinite flow counts up forever; only the user ends it.
- MusicManager is an empty stub kept so call sites compile.
- No unit tests yet; see DEVELOPMENT.md → Testing for the manual smoke checklist.
