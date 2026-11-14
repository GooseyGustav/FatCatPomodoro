import SwiftUI
import AppKit
import LicenseKit

/// Direct-build paywall: buy on the website, activate a key, recover it.
/// Replaces the StoreKit product buttons in the island and Settings.
struct DirectLicenseView: View {
    @ObservedObject var license = LicenseManagerModel.shared
    @State private var key = ""
    @State private var isShowingField = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("FatCatPomodoro Pro")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                if license.isLicensed {
                    Label("Unlocked", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.green)
                }
            }

            Text("One-time €9.99 · free 1.x updates · 3 Macs")
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(.white.opacity(0.6))

            Button {
                NSWorkspace.shared.open(LicenseConfig.buyURL)
            } label: {
                Text("Buy once — €9.99")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundColor(.black)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 20)
                    .background(Color.orange)
                    .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Opens the FatCatPomodoro store in your browser")

            if license.isLicensed {
                Button("Deactivate this Mac") {
                    Task { await license.deactivate() }
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
                .buttonStyle(PlainButtonStyle())
            } else {
                if isShowingField {
                    HStack(spacing: 8) {
                        TextField("FATC-XXXXX-XXXXX-XXXXX-XXXXX", text: $key)
                            .font(.system(size: 10, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 230)
                            .onSubmit { Task { await license.activate(key: key) } }

                        Button("Activate") {
                            Task { await license.activate(key: key) }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.orange)
                        .disabled(license.isBusy || LicenseKey.normalize(key).isEmpty)
                    }
                } else {
                    Button("Already purchased? Activate") {
                        isShowingField = true
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .buttonStyle(PlainButtonStyle())
                }

                Link("Recover your key", destination: LicenseConfig.recoverURL)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.45))
            }

            if let error = license.lastError {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundColor(.red.opacity(0.85))
                    .multilineTextAlignment(.leading)
            }
        }
    }
}
