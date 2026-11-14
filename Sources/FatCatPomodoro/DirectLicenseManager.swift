#if FATCAT_DIRECT
import Foundation
import Combine
import LicenseKit

/// Owns the direct-download license for this Mac. The Mac App Store build
/// compiles this file out entirely; StoreKit remains the only entitlement
/// source there.
@MainActor
final class DirectLicenseManager: ObservableObject {
    static let shared = DirectLicenseManager()

    enum State: Equatable {
        case unknown
        case unlicensed
        case licensed
        case revoked
        case invalid(String)
    }

    @Published private(set) var state: State = .unknown
    @Published private(set) var isLicensed = false
    @Published private(set) var isBusy = false
    @Published var lastError: String?

    let buyURL = URL(string: "https://asifthatworks.com/fatcatpomodoro#buy")!
    let recoverURL = URL(string: "https://asifthatworks.com/fatcatpomodoro/activate")!

    private let manager: LicenseManager
    private let scheme = "fatcatpomodoro"

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let productID = "fatcatpomodoro"
        let kid = (info["FATCLicenseKeyID"] as? String) ?? "fatc-2026-02"
        let keyString = (info["FATCLicensePublicKey"] as? String) ?? Self.developmentPublicKey
        let base = URL(string: (info["FATCLicenseAPIBaseURL"] as? String) ?? "https://api.asifthatworks.com")
            ?? URL(string: "https://api.asifthatworks.com")!
        let key = Data(base64URLEncoded: keyString) ?? Data()

        let config = LicenseConfiguration(
            baseURL: base,
            productID: productID,
            keyPrefix: "FATC",
            appMajorVersion: 1,
            publicKeys: [kid: key],
            bundleID: Bundle.main.bundleIdentifier ?? "com.fatcat.FatCatPomodoro"
        )
        self.manager = (try? LicenseManager(configuration: config))
            ?? (try! LicenseManager(configuration: config))
    }

    /// Only used if Info.plist is missing the key (e.g. a stale local build).
    /// Production builds read FATCLicensePublicKey from Info.plist.
    private static let developmentPublicKey = "cC-v2bdSBxweUpcQEAPDQHWDLeQZnt4PMXtoIJ_rEpc"

    var statusText: String {
        switch state {
        case .unknown: return "Checking…"
        case .unlicensed: return "Not activated"
        case .licensed: return "Licensed"
        case .revoked: return "License revoked"
        case .invalid(let message): return message
        }
    }

    var statusColor: String {
        switch state {
        case .licensed: return "green"
        case .revoked, .invalid: return "red"
        default: return "orange"
        }
    }

    /// Refresh at launch. Offline failures fall back to the cached envelope for
    /// up to 30 days, so a missing network never blocks the timer.
    func refreshIfNeeded() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let status = await manager.currentEntitlement()
        apply(status)
    }

    func activate(key raw: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        do {
            let status = try await manager.activate(key: raw)
            apply(status)
            if !isLicensed {
                lastError = "That key did not unlock this Mac."
            }
        } catch {
            lastError = friendly(error)
        }
    }

    func deactivate() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        do {
            try await manager.deactivate()
            state = .unlicensed
            isLicensed = false
        } catch {
            lastError = friendly(error)
        }
    }

    /// Handles `fatcatpomodoro://license?key=…` and `…/deactivate`.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let deep = LicenseDeepLink.parse(url, scheme: scheme) else { return false }
        switch deep {
        case .activate(let key):
            Task { await activate(key: key) }
        case .deactivate:
            Task { await deactivate() }
        case .open:
            break
        }
        return true
    }

    private func apply(_ status: LicenseStatus) {
        switch status {
        case .active:
            state = .licensed
            isLicensed = true
            lastError = nil
        case .unlicensed, .trial:
            state = .unlicensed
            isLicensed = false
        case .revoked, .expired:
            state = .revoked
            isLicensed = false
        case .invalid(let message):
            state = .invalid(message)
            isLicensed = false
        }
    }

    private func friendly(_ error: Error) -> String {
        if let client = error as? LicenseClientError {
            switch client {
            case .http(let status, let api):
                if status == 409 { return "This license is already active on three Macs. Deactivate one first." }
                if status == 404 { return "That key could not be found. Check it and try again." }
                if status == 410 { return "This license has been revoked or expired." }
                if status == 429 { return "Too many attempts. Wait a minute and try again." }
                return api?.message ?? "Activation failed (\(status))."
            case .transport:
                return "Could not reach the license server. Check your connection and try again."
            case .decoding:
                return "The license server sent an unexpected response."
            }
        }
        return error.localizedDescription
    }
}
#endif
