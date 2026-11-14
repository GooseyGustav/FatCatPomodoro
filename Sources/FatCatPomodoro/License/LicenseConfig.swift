import Foundation
import LicenseKit

/// FatCatPomodoro's product configuration for the shared AsIfThatWorks license
/// service. Keep this in sync with docs/COORDINATION.md in
/// asifthatworks-licensing.
enum LicenseConfig {
    static let productID = "fatcatpomodoro"
    static let keyPrefix = "FATC"
    static let appMajorVersion = 1
    static let buyURL = URL(string: "https://fatcatpomodoro.asifthatworks.com/#buy")!
    static let recoverURL = URL(string: "https://fatcatpomodoro.asifthatworks.com/#recover")!
    static let activateScheme = "fatcatpomodoro"

    /// Staging key from the shared service. The production service is still a
    /// placeholder, so Debug builds point at staging. Release builds use the
    /// frozen production URL.
    static let publicKeys: [String: Data] = [
        "fatc-2026-01": Data(base64URLEncoded: "MxpFfILWXQA8u_x9R4yHz02TrtxmhGR5ARwdnz4wZHQ")!
    ]

    static var baseURL: URL {
        #if LICENSE_STAGING
        return URL(string: "https://staging.api.asifthatworks.com")!
        #else
        return URL(string: "https://api.asifthatworks.com")!
        #endif
    }

    static func configuration() -> LicenseConfiguration {
        LicenseConfiguration(
            baseURL: baseURL,
            productID: productID,
            keyPrefix: keyPrefix,
            appMajorVersion: appMajorVersion,
            publicKeys: publicKeys,
            bundleID: Bundle.main.bundleIdentifier ?? "com.fatcat.FatCatPomodoro"
        )
    }
}
