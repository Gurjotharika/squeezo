import AppKit
import Foundation

/// The app's name and the web pages App Review expects to find linked from the app.
enum AppInfo {
    static let name = "Squeezo"

    /// The live pages on the Squeezo website. The privacy policy URL must also be entered in App Store Connect.
    static let privacyPolicy = URL(string: "https://squeezo.framer.website/privacy")!
    static let support = URL(string: "https://squeezo.framer.website/support")!
    /// Terms of Use. This page states that Apple's standard licence agreement applies, plus Squeezo's own terms.
    static let termsOfUse = URL(string: "https://squeezo.framer.website/terms")!
}

enum MenuBarIcon {
    /// The app icon at menu bar size, in full colour.
    static let image: NSImage = {
        let icon = NSImage(named: NSImage.applicationIconName) ?? NSImage()
        let result = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            icon.draw(in: rect)
            return true
        }
        result.isTemplate = false
        return result
    }()
}
