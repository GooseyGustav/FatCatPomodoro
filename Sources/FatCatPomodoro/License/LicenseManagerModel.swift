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
            let status = try await withRetry { try await self.manager.activate(key: key) }
            self.status = status
            self.isLicensed = status.isLicensed
            self.lastError = status.isLicensed ? nil : "Activation did not unlock FatCatPomodoro."
        } catch let error as LicenseClientError {
            apply(clientError: error)
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

    private func apply(clientError error: LicenseClientError) {
        switch error.statusCode {
        case 410:
            // Server says revoked/expired now — no grace.
            let code = error.apiError?.error ?? ""
            self.status = code == "expired" ? .expired : .revoked
            self.isLicensed = false
            self.lastError = error.localizedDescription
        case 409:
            self.status = .invalid(error.localizedDescription)
            self.isLicensed = false
            self.lastError = error.localizedDescription
        default:
            self.status = .invalid(error.localizedDescription)
            self.isLicensed = false
            self.lastError = error.localizedDescription
        }
    }

    /// Retry transient failures (network, 429, 5xx) with short backoff.
    /// A 410 is never retried — it is a definitive state.
    private func withRetry<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch let error as LicenseClientError {
                let transient: Bool
                if case .transport = error { transient = true }
                else if let status = error.statusCode { transient = [429, 500, 502, 503, 504].contains(status) }
                else { transient = false }

                if transient && attempt < 3 {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                    continue
                }
                throw error
            }
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
