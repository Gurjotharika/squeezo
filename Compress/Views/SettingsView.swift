import CompressCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            WatchSettings()
                .tabItem { Label("Watched Folders", systemImage: "folder.badge.gearshape") }
        }
        .frame(width: 560, height: 440)
        .sheet(isPresented: Binding(get: { model.showPaywall }, set: { model.showPaywall = $0 })) {
            PaywallView()
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("New files") {
                Picker("Quality", selection: $model.level) {
                    ForEach(QualityLevel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Strip location and camera metadata", isOn: $model.stripMetadata)
                Stepper("Run \(model.concurrentJobs) at a time", value: $model.concurrentJobs, in: 1...8)
            }
            Section("\(AppInfo.name) Pro") {
                if model.entitlements.isUnlocked {
                    Label("Unlocked", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    LabeledContent("Free files left today", value: "\(model.entitlements.remainingToday)")
                    Button("Unlock…") { model.showPaywall = true }
                }
                #if DIRECT
                if let masked = model.license.maskedKey {
                    LabeledContent("License", value: masked)
                    Button("Deactivate on This Mac") { Task { await model.license.deactivate() } }
                }
                #else
                Button("Restore Purchases") { Task { await model.store.restore() } }
                #endif
            }
            #if DIRECT
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(get: { model.updater.automaticallyChecks }, set: { model.updater.automaticallyChecks = $0 }))
                Toggle("Download updates automatically", isOn: Binding(get: { model.updater.automaticallyDownloads }, set: { model.updater.automaticallyDownloads = $0 }))
                Button("Check Now") { model.updater.checkForUpdates() }
            }
            #endif
            Section("App") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Show icon in the menu bar", isOn: $model.showMenuBarIcon)
                Toggle("Notify when a batch finishes", isOn: $model.notifyWhenDone)
                Toggle("Show the action wheel when I drag files with Shift held", isOn: $model.dragWheel)
            }
            Section("Help") {
                Link("Support", destination: AppInfo.support)
                Link("Privacy Policy", destination: AppInfo.privacyPolicy)
                Link("Terms of Use", destination: AppInfo.termsOfUse)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct WatchSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var watch = model.watch
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Watched folders").display(20)
                Text("New images, videos, GIFs and PDFs that appear in these folders are compressed automatically. Files already there are left alone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if watch.folders.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text("No folders yet").font(.system(.headline))
                    Text("Try Downloads or your screenshots folder.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(watch.folders) { folder in WatchedFolderRow(folder: folder) }
                    }
                }
                .scrollIndicators(.hidden)
            }

            HStack {
                Button {
                    if model.entitlements.isUnlocked { watch.chooseFolder() } else { model.showPaywall = true }
                } label: {
                    Label(model.entitlements.isUnlocked ? "Add Folder" : "Add Folder (Pro)", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                Spacer()
                Toggle("Pause watching", isOn: $watch.isPaused)
                    .toggleStyle(.switch)
                    .disabled(watch.folders.isEmpty)
            }
        }
        .padding(20)
    }
}

private struct WatchedFolderRow: View {
    @Environment(AppModel.self) private var model
    @State var folder: WatchedFolder

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 20))
                .foregroundStyle(folder.enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 40, height: 40)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(folder.name).font(.system(.headline))
                Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 10) {
                    Picker("Quality", selection: $folder.level) {
                        ForEach(QualityLevel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 96)
                    Toggle("Replace originals", isOn: $folder.replaceOriginals)
                    Toggle("Strip metadata", isOn: $folder.stripMetadata)
                }
                .toggleStyle(.checkbox)
                .font(.callout)
            }
            Spacer()
            VStack(spacing: 8) {
                Toggle("", isOn: $folder.enabled).labelsHidden().toggleStyle(.switch)
                Button(role: .destructive) { model.watch.remove(folder.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Stop watching")
            }
        }
        .padding(12)
        .surface(radius: 14)
        .onChange(of: folder) { _, new in model.watch.update(new) }
    }
}
