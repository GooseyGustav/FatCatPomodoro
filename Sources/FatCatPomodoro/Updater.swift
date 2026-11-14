#if FATCAT_DIRECT
import Foundation
import AppKit
import Sparkle

/// Sparkle 2 updater for the direct-download build. The Mac App Store build
/// must not ship a third-party updater, so this file is compiled out entirely
/// when FATCAT_APPSTORE is defined.
@MainActor
final class Updater {
    static let shared = Updater()

    let controller: SPUStandardUpdaterController

    private init() {
        // Info.plist owns the schedule: SUEnableAutomaticChecks=YES,
        // SUScheduledCheckInterval=86400, SUAutomaticallyUpdate=NO.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    @objc func checkForUpdates() {
        // The app is LSUIElement, so Sparkle's window can otherwise open behind
        // other apps. Activate first, mirroring Mullion's updater behaviour.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
#endif
