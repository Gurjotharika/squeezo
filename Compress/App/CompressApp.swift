import AppKit
import SwiftUI

@main
struct CompressApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-demoSettings") {
                    SettingsView()
                } else { RootView() }
                #else
                RootView()
                #endif
            }
                .environment(model)
                .onOpenURL { model.handle(url: $0) }
                .task { await model.watch.run() }
                #if DIRECT
                .task { await model.license.start() }
                #else
                .task { await model.store.start() }
                #endif
                .task {
                    BackgroundLaunch.hideWindowIfLaunchedAtLogin()
                    BackgroundLaunch.askOnce()
                }
                .task { DragWheelController.shared.setEnabled(model.dragWheel, model: model) }
                #if DEBUG
                .task {
                    try? await Task.sleep(for: .milliseconds(1800))
                    let args = ProcessInfo.processInfo.arguments
                    if args.contains("-demo") { model.loadDemoJobs() }
                    if args.contains("-demoPaywall") { model.showPaywall = true }
                    if args.contains("-demoCelebrate") { model.store.celebration = .purchased; model.showPaywall = true }
                    if args.contains("-demoFolders") { model.watch.add(URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")) }
                    if args.contains("-demoWheel") {
                        DragWheelController.shared.isPinned = true
                        DragWheelController.shared.show(for: [URL(fileURLWithPath: "/tmp/a.jpg")])
                        DragWheelController.shared.state.expanded = 1
                        DragWheelController.shared.state.hit = .child(parent: 1, index: 1)
                    }
                    if args.contains("-demoFloat") {
                        // Screen recordings: the window floats above the backdrop at a fixed place.
                        for window in NSApp.windows where !(window is NSPanel) && window.canBecomeMain {
                            window.level = NSWindow.Level(rawValue: 4)
                            window.setFrame(NSRect(x: 330, y: 180, width: 1340, height: 760), display: true)
                            window.makeKeyAndOrderFront(nil)
                        }
                    }
                    if args.contains("-light") { NSApp.appearance = NSAppearance(named: .aqua) }
                }
                #endif
        }
        .defaultSize(width: 1240, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { Task { await model.chooseFiles() } }
                    .keyboardShortcut("o")
            }
            #if DIRECT
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.updater.checkForUpdates() }
            }
            #endif
            CommandGroup(after: .windowArrangement) {
                Button("Show Drop Zone") { DropZoneController.shared.show(model: model) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra(isInserted: Binding(get: { model.showMenuBarIcon }, set: { model.showMenuBarIcon = $0 })) {
            MenuBarContent().environment(model)
        } label: {
            // Always the app's own icon, busy or not; progress is shown in the menu.
            Image(nsImage: MenuBarIcon.image)
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}
