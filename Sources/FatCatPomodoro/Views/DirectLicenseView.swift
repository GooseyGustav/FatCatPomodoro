#if FATCAT_DIRECT
import SwiftUI
import AppKit

/// The full activation/deactivation panel. Used as a sheet from Settings and
/// the paywall, and inside the dedicated License window from the menu bar.
struct DirectLicenseView: View {
    @ObservedObject var manager = DirectLicenseManager.shared
    var onClose: (() -> Void)? = nil

    @State private var key: String = ""
    @FocusState private var keyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("FatCatPomodoro License")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundColor(.orange)
                Spacer()
                if let onClose {
                    Button("Close") { onClose() }
                        .buttonStyle(PlainButtonStyle())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(manager.statusText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                if manager.isBusy {
                    ProgressView().controlSize(.small).tint(.orange)
                }
            }

            if manager.isLicensed {
                Text("This Mac is activated. The license covers three Macs and works offline for 30 days at a time.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Refresh") { Task { await manager.refreshIfNeeded() } }
                        .buttonStyle(.bordered)
                    Button("Deactivate this Mac") { Task { await manager.deactivate() } }
                        .buttonStyle(.bordered)
                    Spacer()
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            } else {
                Text("Already bought FatCatPomodoro? Paste the key from your email.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))

                TextField("FATC-XXXXX-XXXXX-XXXXX-XXXXX", text: $key)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
                    .focused($keyFocused)
                    .onSubmit { activate() }

                HStack(spacing: 8) {
                    Button(action: activate) {
                        Text(manager.isBusy ? "Activating…" : "Activate")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.orange)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(manager.isBusy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        NSWorkspace.shared.open(manager.buyURL)
                    } label: {
                        Text("Buy — €9.99")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                Link("Recover a lost key", destination: manager.recoverURL)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.orange.opacity(0.85))
            }

            if let error = manager.lastError {
                Text(error)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(Color(red: 0.06, green: 0.06, blue: 0.07))
        .onAppear { keyFocused = !manager.isLicensed }
    }

    private var statusColor: Color {
        switch manager.state {
        case .licensed: return .green
        case .revoked, .invalid: return .red
        default: return .orange
        }
    }

    private func activate() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await manager.activate(key: trimmed) }
    }
}

/// Compact status + actions for Settings and the paywall. Presents the full
/// activation sheet instead of duplicating the text field.
struct DirectLicenseSection: View {
    @ObservedObject var manager = DirectLicenseManager.shared
    var compact: Bool = false
    @State private var showSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PREMIUM LICENSE")
                .font(.system(size: 9, weight: .black))
                .foregroundColor(.white.opacity(0.4))
                .tracking(1)

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(manager.statusText)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(manager.isLicensed ? .green : .white.opacity(0.75))
                Spacer()
                Text("Lifetime · 3 Macs")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
            }

            HStack(spacing: 8) {
                if manager.isLicensed {
                    Button("Manage license") { showSheet = true }
                        .buttonStyle(PlainButtonStyle())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.orange)
                } else {
                    Button("Buy — €9.99") { NSWorkspace.shared.open(manager.buyURL) }
                        .buttonStyle(PlainButtonStyle())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.orange)
                    Text("·")
                        .foregroundColor(.white.opacity(0.2))
                    Button("I have a key") { showSheet = true }
                        .buttonStyle(PlainButtonStyle())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                }
                Spacer()
            }

            if let error = manager.lastError, !showSheet {
                Text(error)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(compact ? 10 : 14)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
        .sheet(isPresented: $showSheet) {
            DirectLicenseView()
        }
        .task {
            if manager.state == .unknown {
                await manager.refreshIfNeeded()
            }
        }
    }

    private var statusColor: Color {
        switch manager.state {
        case .licensed: return .green
        case .revoked, .invalid: return .red
        default: return .orange
        }
    }
}
#endif
