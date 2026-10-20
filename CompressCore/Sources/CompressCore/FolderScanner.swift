import Foundation

/// Identifies one version of a file. A file that is edited or replaced gets a new signature.
public struct FileSignature: Codable, Hashable, Sendable {
    public var path: String
    public var size: Int64
    public var modified: TimeInterval

    public init(path: String, size: Int64, modified: TimeInterval) {
        self.path = path
        self.size = size
        self.modified = modified
    }

    public init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate else { return nil }
        self.init(path: url.standardizedFileURL.path, size: Int64(size), modified: date.timeIntervalSince1970)
    }
}

/// Looks for new files in a folder. A file is reported only after it has stopped changing,
/// so downloads and screenshots that are still being written are left alone.
public struct FolderScanner: Sendable {
    public let folder: URL
    private let minimumAge: TimeInterval

    private var processed: Set<FileSignature> = []
    private var candidates: [String: (signature: FileSignature, since: Date)] = [:]

    /// File extensions browsers and tools use for unfinished files.
    private static let temporaryExtensions: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "opdownload"]

    public init(folder: URL, minimumAge: TimeInterval = 2, processed: Set<FileSignature> = []) {
        self.folder = folder
        self.minimumAge = minimumAge
        self.processed = processed
    }

    public var processedSignatures: Set<FileSignature> { processed }

    /// Treats everything already in the folder as handled, so only files that arrive later are picked up.
    public mutating func markExistingAsProcessed() {
        for url in listing() {
            if let signature = FileSignature(url: url) { processed.insert(signature) }
        }
    }

    public mutating func markProcessed(_ signature: FileSignature) {
        processed.insert(signature)
        candidates[signature.path] = nil
    }

    /// Files that are new, supported, and no longer changing.
    public mutating func poll(now: Date = Date()) -> [URL] {
        var ready: [URL] = []
        var stillPresent = Set<String>()

        for url in listing() {
            guard let signature = FileSignature(url: url) else { continue }
            stillPresent.insert(signature.path)
            if processed.contains(signature) { continue }

            if let known = candidates[signature.path], known.signature == signature {
                if now.timeIntervalSince(known.since) >= minimumAge { ready.append(url) }
            } else {
                candidates[signature.path] = (signature, now)  // new, or changed since last time
            }
        }
        candidates = candidates.filter { stillPresent.contains($0.key) }
        return ready.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func listing() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                && !Self.temporaryExtensions.contains(url.pathExtension.lowercased())
                && MediaKind(url: url) != nil
        }
    }
}
