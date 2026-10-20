import Foundation

/// Checks that can fail a job early, with a message the user can act on, instead of partway through.
enum Preflight {
    /// Room needed to hold a compressed copy next to the original, with a margin.
    static func hasRoom(free: Int64, fileSize: Int64) -> Bool {
        free >= fileSize + fileSize / 10 + 50_000_000
    }

    static func check(source: URL, policy: OutputPolicy) throws {
        let name = source.lastPathComponent

        let cloud = try? source.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if cloud?.isUbiquitousItem == true, let status = cloud?.ubiquitousItemDownloadingStatus, status != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: source)
            throw CompressionError.failed("“\(name)” is still in iCloud. Its download has been started; try again once it has finished.")
        }

        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw CompressionError.failed("“\(name)” can't be read. Check that the app has permission to open it.")
        }

        let anchor: URL
        if case .folder(let folder) = policy { anchor = folder } else { anchor = source.deletingLastPathComponent() }
        let target = FileManager.default.fileExists(atPath: anchor.path) ? anchor : anchor.deletingLastPathComponent()
        let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if let free = (try? target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage, !hasRoom(free: free, fileSize: size) {
            throw CompressionError.failed("There isn't enough free disk space to compress “\(name)”.")
        }
    }
}
