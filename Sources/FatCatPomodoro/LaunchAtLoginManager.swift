import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService` for macOS 13+ login-item registration.
/// Setting `isEnabled` registers/unregisters the app with the system immediately;
/// on older macOS versions it stays false and does nothing.
class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? enable() : disable()
        }
    }

    private init() {
        if #available(macOS 13.0, *) {
            isEnabled = SMAppService.mainApp.status == .enabled
        } else {
            isEnabled = false
        }
    }

    private func enable() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
            } catch {
                print("Failed to enable launch at login: \(error)")
            }
        }
    }

    private func disable() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                print("Failed to disable launch at login: \(error)")
            }
        }
    }
}
