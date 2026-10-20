import AppKit
import ServiceManagement

/// Keeps the app running after its window is closed, and starts it at login, so the drag wheel and
/// watched folders work without the window being open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set when macOS started the app at login rather than the user opening it.
    private(set) static var launchedAtLogin = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        Self.launchedAtLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Clicking the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
}

@MainActor
enum BackgroundLaunch {
    private static let askedKey = "askedToRunInBackground"

    /// At login the app starts quietly: the window stays closed and only the menu bar icon and wheel are active.
    static func hideWindowIfLaunchedAtLogin() {
        guard AppDelegate.launchedAtLogin else { return }
        NSApp.windows.filter { !($0 is NSPanel) && $0.canBecomeMain }.forEach { $0.close() }
    }

    /// Asks once, on the first launch, whether to keep the app ready in the background. Nothing is turned on without a yes.
    static func askOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: askedKey), !AppDelegate.launchedAtLogin else { return }
        defaults.set(true, forKey: askedKey)
        guard SMAppService.mainApp.status != .enabled else { return }

        let alert = NSAlert()
        alert.messageText = "Keep \(AppInfo.name) ready in the background?"
        alert.informativeText = "Hold Shift while dragging files anywhere to open the action wheel, and watched folders keep working. \(AppInfo.name) starts quietly at login with just a menu bar icon. You can change this in Settings."
        alert.addButton(withTitle: "Start at Login")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? SMAppService.mainApp.register()
    }
}
