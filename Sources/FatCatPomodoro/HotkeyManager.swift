import Foundation
import Carbon
import AppKit
import SwiftUI

// MARK: - Key combo model

/// A global keyboard shortcut: a Carbon virtual key code plus Carbon modifier mask.
/// Stored as JSON in UserDefaults so every action's combo is user-customizable.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Build from a keyDown event. Requires ⌘, ⌥ or ⌃ — a global hotkey without
    /// one of those would swallow plain typing system-wide.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else { return nil }
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
    }

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "key\(keyCode)")
    }

    private static let keyNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_Escape): "⎋",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Backslash): "\\",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]
}

// MARK: - Actions

enum ShortcutAction: String, CaseIterable, Identifiable {
    case toggleIsland
    case toggleTimer
    case startBreak

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleIsland: return "Open / Close Island"
        case .toggleTimer:  return "Start / Pause Session"
        case .startBreak:   return "Start Break"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .toggleIsland: return KeyCombo(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(cmdKey | shiftKey))
        case .toggleTimer:  return KeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(cmdKey | shiftKey))
        case .startBreak:   return KeyCombo(keyCode: UInt32(kVK_ANSI_B), carbonModifiers: UInt32(cmdKey | shiftKey))
        }
    }

    var carbonID: UInt32 {
        switch self {
        case .toggleIsland: return 1
        case .toggleTimer:  return 2
        case .startBreak:   return 3
        }
    }
}

// MARK: - Manager

final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    /// Current combo per action. A missing entry means the shortcut is disabled
    /// (e.g. its combo was reassigned to another action).
    @Published private(set) var combos: [ShortcutAction: KeyCombo] = [:]
    @Published private(set) var recordingAction: ShortcutAction? = nil

    var onToggleExpansion: (() -> Void)?
    var onToggleTimer: (() -> Void)?
    var onStartBreak: (() -> Void)?

    var isRecording: Bool { recordingAction != nil }

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerInstalled = false
    private var recordMonitor: Any?

    private init() {
        for action in ShortcutAction.allCases {
            combos[action] = storedCombo(for: action)
        }
    }

    func setup() {
        installHandlerIfNeeded()
        registerAll()
    }

    func set(_ combo: KeyCombo, for action: ShortcutAction) {
        // A combo can only trigger one action — clear it off any other action.
        for other in ShortcutAction.allCases where other != action && combos[other] == combo {
            combos[other] = nil
            UserDefaults.standard.set(Data(), forKey: storageKey(other))
        }
        combos[action] = combo
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: storageKey(action))
        }
        registerAll()
    }

    func resetToDefault(_ action: ShortcutAction) {
        UserDefaults.standard.removeObject(forKey: storageKey(action))
        set(action.defaultCombo, for: action)
    }

    // MARK: Recording

    /// While recording, all global hotkeys are unregistered so the pressed combo
    /// reaches the app as a normal keyDown instead of firing its old action.
    func beginRecording(_ action: ShortcutAction) {
        endRecording()
        recordingAction = action
        registerAll()
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let target = self.recordingAction else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.endRecording()
                return nil
            }
            if let combo = KeyCombo(event: event) {
                self.set(combo, for: target)
                self.endRecording()
            }
            return nil // swallow keystrokes while recording
        }
    }

    func endRecording() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        if recordingAction != nil { recordingAction = nil }
        registerAll()
    }

    // MARK: Carbon plumbing

    private func storageKey(_ action: ShortcutAction) -> String { "shortcut.v1.\(action.rawValue)" }

    private func storedCombo(for action: ShortcutAction) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: storageKey(action)) else {
            return action.defaultCombo
        }
        guard !data.isEmpty else { return nil } // empty payload = explicitly disabled
        return (try? JSONDecoder().decode(KeyCombo.self, from: data)) ?? action.defaultCombo
    }

    private func registerAll() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        guard recordingAction == nil else { return }

        for action in ShortcutAction.allCases {
            guard let combo = combos[action] else { continue }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(1718512964), id: action.carbonID)
            RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if let ref { hotKeyRefs.append(ref) }
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { (_, theEvent, _) -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(theEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if status == noErr {
                HotkeyManager.shared.dispatch(id: hotKeyID.id)
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventSpec, nil, nil)
    }

    private func dispatch(id: UInt32) {
        switch id {
        case ShortcutAction.toggleIsland.carbonID: onToggleExpansion?()
        case ShortcutAction.toggleTimer.carbonID:  onToggleTimer?()
        case ShortcutAction.startBreak.carbonID:   onStartBreak?()
        default: break
        }
    }
}

// MARK: - Settings UI

/// "KEYBOARD SHORTCUTS" settings section — recorder rows for the global hotkeys
/// plus a cheat sheet of the island's built-in keys.
struct ShortcutsSettingsSection: View {
    @ObservedObject private var hotkeys = HotkeyManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("KEYBOARD SHORTCUTS")
                .font(.system(size: 9, weight: .black))
                .foregroundColor(.white.opacity(0.4))
                .tracking(1)

            VStack(spacing: 6) {
                ForEach(ShortcutAction.allCases) { action in
                    shortcutRow(action)
                }
            }

            Text("INSIDE THE ISLAND")
                .font(.system(size: 8, weight: .black))
                .foregroundColor(.white.opacity(0.3))
                .tracking(1)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                hintRow("↩", "Start flow / attach the typed title")
                hintRow("A–Z", "Type straight into the session title")
                hintRow("0–9", "Type minutes for the timer (0 = ∞ flow)")
                hintRow("↑ ↓", "Nudge the timer in 5-minute steps")
                hintRow("⌘ 1·2·3", "Presets — flow 25/45/90, break 5/10/15")
                hintRow("⇥", "Cycle today's tasks (⇧⇥ backwards)")
                hintRow("⇧ ← →", "Switch between Flow and Break")
                hintRow("⌘ ,", "Open settings")
                hintRow("⎋", "Close the island")
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03))
            .cornerRadius(8)
        }
        .onDisappear { hotkeys.endRecording() }
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        let combo = hotkeys.combos[action]
        let isRecording = hotkeys.recordingAction == action

        return HStack(spacing: 6) {
            Text(action.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.85))

            Spacer()

            if combo != action.defaultCombo && !isRecording {
                Button {
                    hotkeys.resetToDefault(action)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(PlainButtonStyle())
                .help("Reset to \(action.defaultCombo.displayString)")
            }

            Button {
                if isRecording {
                    hotkeys.endRecording()
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                    hotkeys.beginRecording(action)
                }
            } label: {
                Text(isRecording ? "Press keys…" : (combo?.displayString ?? "Record"))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(isRecording ? .black : (combo == nil ? .white.opacity(0.4) : .orange))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(minWidth: 58)
                    .background(isRecording ? Color.orange : Color.white.opacity(0.08))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(isRecording ? Color.orange : Color.orange.opacity(0.25), lineWidth: 1)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .help(isRecording ? "Press the new shortcut (⎋ to cancel)" : "Click, then press a new shortcut")
        }
    }

    private func hintRow(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.orange.opacity(0.9))
                .frame(width: 44, alignment: .leading)
            Text(text)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
        }
    }
}
