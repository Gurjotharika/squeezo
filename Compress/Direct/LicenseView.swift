#if DIRECT
import SwiftUI

/// The unlock sheet of the direct edition: buy a key on the website, then paste it here.
struct LicenseView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var key = ""

    var body: some View {
        let license = model.license
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                AppMark(size: 72)
                VStack(spacing: 4) {
                    Text("\(AppInfo.name) Pro").display(30)
                    Text("No limits. Everything on your Mac.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                Feature(icon: "infinity", title: "Unlimited files", detail: "No daily limit.")
                Feature(icon: "folder.badge.gearshape", title: "Watched folders", detail: "New screenshots and downloads shrink by themselves.")
                Feature(icon: "bolt", title: "Shortcuts and automation", detail: "Use \(AppInfo.name) from Shortcuts, Spotlight and scripts.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.entitlements.isUnlocked {
                VStack(spacing: 6) {
                    Label("Everything is unlocked. Thank you.", systemImage: "checkmark.circle").font(.headline)
                    if let masked = license.maskedKey { Text("License \(masked)").font(.caption).foregroundStyle(.secondary) }
                }
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                VStack(spacing: 10) {
                    Button { openURL(LicenseManager.checkoutURL) } label: {
                        Text("Buy a License").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Text("Already have a key?").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    TextField("Paste your license key", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit { activate() }
                    Button { activate() } label: { Text("Activate").frame(maxWidth: .infinity) }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if let message = license.message {
                Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            HStack(spacing: 14) {
                Link("Terms of Use", destination: AppInfo.termsOfUse)
                Link("Privacy Policy", destination: AppInfo.privacyPolicy)
            }
            .buttonStyle(.link).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 26)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle()).padding(14).keyboardShortcut(.cancelAction).accessibilityLabel("Close")
        }
        .disabled(license.isWorking)
        .overlay { if license.isWorking { ProgressView().controlSize(.large) } }
        .onChange(of: license.celebration) { _, new in if new != nil { dismiss() } }
        .onDisappear { license.celebration = nil }
    }

    private func activate() { Task { await model.license.activate(key: key) } }
}
#endif
