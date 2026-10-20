import AppKit

/// Keeps track of folders the user has granted the sandboxed app access to.
///
/// A dropped or opened file only grants access to that file, not its folder, so saving a
/// compressed copy next to it needs the folder to be granted once. Grants are stored as
/// security-scoped bookmarks and restored at launch.
@MainActor
final class FolderAccess {
    private let defaults: UserDefaults
    private let bookmarksKey = "folderBookmarks"
    private var active: [String: URL] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
    }

    /// Whether files can be created in `dir` right now.
    func canWrite(_ dir: URL) -> Bool {
        let probe = dir.appendingPathComponent(".compress-probe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    /// Asks the user to grant access to every folder in `directories` that isn't writable yet.
    /// Returns the folders that are still not writable afterwards.
    func ensureWritable(directories: Set<URL>) -> Set<URL> {
        var denied: Set<URL> = []
        for dir in directories.sorted(by: { $0.path < $1.path }) where !canWrite(dir) {
            if let granted = requestAccess(to: dir) { remember(granted) }
            if !canWrite(dir) { denied.insert(dir) }
        }
        return denied
    }

    /// Shows a folder picker and returns the chosen folder, or nil if cancelled.
    func requestAccess(to dir: URL?, message: String? = nil, prompt: String = "Grant Access") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.directoryURL = dir
        panel.message = message
            ?? "\(AppInfo.name) needs permission to save files in “\(dir?.lastPathComponent ?? "this folder")”."
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Stores a bookmark for `url` and keeps it accessible for the rest of the session.
    func remember(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope) else { return }
        var all = storedBookmarks()
        all[url.standardizedFileURL.path] = data
        defaults.set(all, forKey: bookmarksKey)
        if active[url.standardizedFileURL.path] == nil, url.startAccessingSecurityScopedResource() {
            active[url.standardizedFileURL.path] = url
        }
    }

    /// The previously granted folder at `path`, if its bookmark is still valid.
    func grantedFolder(atPath path: String) -> URL? { active[path] }

    private func storedBookmarks() -> [String: Data] {
        defaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
    }

    private func restore() {
        var all = storedBookmarks()
        for (path, data) in all {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource()
            else {
                all[path] = nil  // folder is gone or access was revoked
                continue
            }
            active[path] = url
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) { all[path] = fresh }
        }
        defaults.set(all, forKey: bookmarksKey)
    }
}
