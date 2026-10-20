import CompressCore
import SwiftUI

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if model.hasActive {
            let running = model.jobs.filter { !$0.state.isFinished }.count
            Text("Compressing \(running) \(running == 1 ? "file" : "files")…")
        } else if model.totalSavedBytes > 0 {
            Text("Saved \(model.totalSavedBytes.formatted(.byteCount(style: .file))) so far")
        } else {
            Text("Nothing to compress")
        }
        Divider()

        Button("Show \(AppInfo.name)") { showWindow() }
        Button("Add Files…") {
            showWindow()
            Task { await model.chooseFiles() }
        }
        Button(DropZoneController.shared.isVisible ? "Hide Drop Zone" : "Show Drop Zone") {
            DropZoneController.shared.toggle(model: model)
        }
        Divider()

        if !model.watch.folders.isEmpty {
            @Bindable var watch = model.watch
            Toggle("Watch \(model.watch.activeCount) \(model.watch.activeCount == 1 ? "folder" : "folders")",
                   isOn: Binding(get: { !watch.isPaused }, set: { watch.isPaused = !$0 }))
        }
        #if DIRECT
        Button("Check for Updates…") { model.updater.checkForUpdates() }
        #endif
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit \(AppInfo.name)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showWindow() {
        NSApp.activate()
        openWindow(id: "main")
    }
}
