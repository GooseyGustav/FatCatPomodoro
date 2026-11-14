import Foundation
import Combine
import LicenseKit

/// MainActor observable wrapper around LicenseKit's actor-based manager.
/// The app's SwiftUI views observe this; StoreManager republishes its
/// `isLicensed` changes so existing `storeManager.isUnlocked` call sites work.
@MainActor
final class LicenseManagerModel: ObservableObject {
    static let shared = LicenseManagerModel()

    @Published private(set) var status: LicenseStatus = .unlicensed
    @Published private(set) var isLicensed = false
    @Published private(set) var lastError: String?
    @Published private(set) var isBusy = false

    let manager: LicenseManager

    private init() {
        // The configuration is compile-time constant; a failure here is a build error.
        self.manager = try! LicenseManager(configuration: LicenseConfig.configuration())
        Task { await reload() }
    }

    var isUnlocked: Bool { isLicensed }

    func reload() async {
        let status = await manager.currentEntitlement()
        self.status = status
        self.isLicensed = status.isLicensed
    }

    func activate(key: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let status = try await manager.activate(key: key)
            self.status = status
            self.isLicensed = status.isLicensed
            self.lastError = status.isLicensed ? nil : "Activation did not unlock FatCatPomodoro."
        } catch {
            self.lastError = error.localizedDescription
            self.status = .invalid(error.localizedDescription)
            self.isLicensed = false
        }
    }

    func deactivate() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await manager.deactivate()
            self.status = .unlicensed
            self.isLicensed = false
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }
}

extension LicenseStatus {
    /// FatCatPomodoro has no trial: only an active license unlocks Pro.
    var isLicensed: Bool {
        switch self {
        case .active: return true
        case .trial, .unlicensed, .expired, .revoked, .invalid: return false
        }
    }
}
