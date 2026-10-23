import Foundation
import AppKit
import UserNotifications

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private var alarmSound: NSSound? = NSSound(named: "Glass")

    private override init() {
        super.init()
        setupUserNotifications()
    }

    private func setupUserNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("NotificationManager: UNUserNotificationCenter auth error: \(error.localizedDescription)")
            }
        }
    }

    // Ensure notifications appear even if FatCatPomodoro is the foreground/active app
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func sessionComplete(isBreak: Bool) {
        let title = isBreak ? "Flow Session Complete 😺" : "Break's Over 😸"
        let message = isBreak ? "Time for a break! Your fat cat is waiting." : "Ready for another flow session?"
        
        // Show system notification via native UNUserNotificationCenter
        sendNotification(title: title, message: message)
        
        // Custom sound settings
        let soundName = UserDefaults.standard.string(forKey: "pomodoro.alarmSoundName") ?? "Glass"
        let volume = UserDefaults.standard.double(forKey: "pomodoro.alarmVolume")
        
        alarmSound = NSSound(named: soundName)
        alarmSound?.volume = Float(volume == 0 ? 0.8 : volume)
        
        if isBreak {
            // Peaceful transition: play the alert chime ONLY ONCE so the cat video is quiet
            alarmSound?.loops = false
            alarmSound?.play()
        } else {
            // Break's Over: play a chime once to alert the user
            alarmSound?.loops = false
            alarmSound?.play()
            
            // Aggressively pull the app to the front
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.requestUserAttention(.criticalRequest)
            }
        }
    }
    
    func stopAlarm() {
        alarmSound?.stop()
    }

    // Recognized Shortcut names for toggling DND. Deliberately excludes Apple's
    // gallery shortcuts ("Ablenkungen verhindern" etc.) — those contain interactive
    // app-picker steps that pop UI on every run.
    static let dndOnShortcutNames = ["Turn Do Not Disturb On", "Nicht stören ein", "Focus On", "DND On"]
    static let dndOffShortcutNames = ["Turn Do Not Disturb Off", "Nicht stören aus", "Focus Off", "DND Off"]

    enum DNDSetupStatus {
        case shortcutsReady(on: String, off: String)
        case systemDNDReady
        case needsAccessibility

        var message: String {
            switch self {
            case .shortcutsReady(let on, let off):
                return "✓ Ready — using Shortcuts '\(on)' / '\(off)'"
            case .systemDNDReady:
                return "✓ Ready — toggles the system Do Not Disturb directly."
            case .needsAccessibility:
                return "⚠ One-time approval needed: enable FatCatPomodoro under Privacy & Security → Accessibility (pane just opened) so it can flip the system Do Not Disturb."
            }
        }
    }

    /// Async list of installed Shortcuts for the settings picker (sorted).
    func fetchInstalledShortcuts(completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let names = self.installedShortcutNames().sorted()
            DispatchQueue.main.async { completion(names) }
        }
    }

    /// A shortcut the user explicitly picked in settings — always takes priority.
    private func explicitShortcutName(enabled: Bool) -> String? {
        let key = enabled ? "pomodoro.dndOnShortcut" : "pomodoro.dndOffShortcut"
        guard let custom = UserDefaults.standard.string(forKey: key), !custom.isEmpty else { return nil }
        return custom
    }

    /// Returns the names of all installed Shortcuts, or [] if the CLI is unavailable.
    private func installedShortcutNames() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return Set(output.split(separator: "\n").map(String.init))
        } catch {
            return []
        }
    }

    /// Checks whether the DND auto-toggle can actually work, and (optionally) opens the
    /// Accessibility pane of System Settings when approval is the missing piece.
    func verifyDNDSetup(openSettingsIfNeeded: Bool, completion: @escaping (DNDSetupStatus) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let installed = self.installedShortcutNames()
            let explicitOn = self.explicitShortcutName(enabled: true)
            let explicitOff = self.explicitShortcutName(enabled: false)

            DispatchQueue.main.async {
                // 1. Explicit picker selection wins
                if let explicitOn, let explicitOff,
                   installed.contains(explicitOn), installed.contains(explicitOff) {
                    completion(.shortcutsReady(on: explicitOn, off: explicitOff))
                // 2. Preferred default: direct system DND via Control Center
                } else if AXIsProcessTrusted() {
                    completion(.systemDNDReady)
                // 3. Known non-interactive shortcut names
                } else if let on = Self.dndOnShortcutNames.first(where: installed.contains),
                          let off = Self.dndOffShortcutNames.first(where: installed.contains) {
                    completion(.shortcutsReady(on: on, off: off))
                } else {
                    if openSettingsIfNeeded {
                        // Registers the app in the Accessibility list and shows the
                        // system consent dialog (with its own "Open System Settings"
                        // button) — without this the user would have to add the app
                        // manually via "+".
                        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                        AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    completion(.needsAccessibility)
                }
            }
        }
    }

    func setDND(enabled: Bool) {
        print("NotificationManager: Toggling DND (\(enabled ? "ON" : "OFF"))...")

        DispatchQueue.global(qos: .userInitiated).async {
            // 1. A shortcut explicitly picked in settings always wins.
            if let custom = self.explicitShortcutName(enabled: enabled) {
                if !self.runShortcut(named: custom) {
                    print("NotificationManager: Selected shortcut '\(custom)' failed.")
                }
                return
            }

            // 2. Preferred default: flip the system Do Not Disturb directly via
            // Control Center — silent, no Shortcuts involved. Needs Accessibility.
            if AXIsProcessTrusted() {
                self.toggleSystemDND(enabled: enabled)
                return
            }

            // 3. Fallback: known non-interactive Shortcut names.
            let shortcutNames = enabled ? Self.dndOnShortcutNames : Self.dndOffShortcutNames
            for name in shortcutNames where self.runShortcut(named: name) {
                return
            }
            print("NotificationManager: No DND method available — grant Accessibility or pick a Shortcut in settings.")
        }
    }

    /// Runs a Shortcut via the CLI with a short timeout. Returns success.
    private func runShortcut(named name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        do {
            try process.run()
            // Short timeout to avoid hanging if the shortcuts CLI waits on UI
            let deadline = DispatchTime.now() + 2.0
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                process.waitUntilExit()
                group.leave()
            }
            if group.wait(timeout: deadline) == .success && process.terminationStatus == 0 {
                print("NotificationManager: Successfully ran shortcut '\(name)'")
                return true
            } else if process.isRunning {
                process.terminate()
            }
        } catch {
            return false
        }
        return false
    }

    /// UI-scripts Control Center to set the system Do Not Disturb. Checks the
    /// current state first and only clicks when it differs from the target, so
    /// repeated calls are idempotent.
    private func toggleSystemDND(enabled: Bool) {
        let desired = enabled ? 1 : 0
        let script = """
        tell application "System Events"
            if not (exists process "Control Center") then return
            tell process "Control Center"
                try
                    click menu bar item "Focus" of menu bar 1
                on error
                    try
                        click (first menu bar item of menu bar 1 whose description contains "Focus" or description contains "Fokus" or description contains "Stören")
                    on error
                        try
                            click (first menu bar item of menu bar 1 whose description contains "Control Center" or description contains "Kontrollzentrum")
                        end try
                    end try
                end try
                delay 0.3
                try
                    set dndBox to (first checkbox of group 1 of window "Control Center" whose title contains "Do Not Disturb" or title contains "Nicht stören")
                    if (value of dndBox as integer) is not \(desired) then click dndBox
                end try
                delay 0.2
                key code 53 -- Esc key to close Control Center
            end tell
        end tell
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let err = error {
                print("NotificationManager: AppleScript DND toggle error: \(err)")
            } else {
                print("NotificationManager: AppleScript DND toggle executed.")
            }
        }
    }

    private func sendNotification(title: String, message: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                self?.deliverUNNotification(title: title, message: message, center: center)
            } else if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if granted {
                        self?.deliverUNNotification(title: title, message: message, center: center)
                    } else {
                        self?.deliverNSUserNotification(title: title, message: message)
                    }
                }
            } else {
                // Fallback to native NSUserNotification (uses app icon face_cat without osascript scroll)
                self?.deliverNSUserNotification(title: title, message: message)
            }
        }
    }

    private func deliverUNNotification(title: String, message: String, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        
        if let iconURL = Bundle.main.url(forResource: "face_cat", withExtension: "png"),
           let attachment = try? UNNotificationAttachment(identifier: "face_cat", url: iconURL, options: nil) {
            content.attachments = [attachment]
        }
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            if let error = error {
                print("NotificationManager: Failed UNNotification, falling back: \(error.localizedDescription)")
                self?.deliverNSUserNotification(title: title, message: message)
            }
        }
    }

    private func deliverNSUserNotification(title: String, message: String) {
        DispatchQueue.main.async {
            let notification = NSUserNotification()
            notification.title = title
            notification.informativeText = message
            notification.soundName = NSUserNotificationDefaultSoundName
            
            if let iconURL = Bundle.main.url(forResource: "FatCatPomodoro", withExtension: "png"),
               let iconImage = NSImage(contentsOf: iconURL) {
                notification.contentImage = iconImage
            }
            
            NSUserNotificationCenter.default.deliver(notification)
        }
    }
}

