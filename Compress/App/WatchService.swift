import CompressCore
import Foundation
import Observation

/// A folder whose new files are compressed automatically.
struct WatchedFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var level: QualityLevel = .high
    var replaceOriginals = false
    var stripMetadata = false
    var enabled = true

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { url.lastPathComponent }
}

/// Watches folders and hands new files to the compression queue.
@MainActor
@Observable
final class WatchService {
    typealias Enqueue = @MainActor (_ urls: [URL], _ preset: Preset, _ policy: OutputPolicy) async -> [JobID]

    private(set) var folders: [WatchedFolder] = []
    var isPaused: Bool {
        didSet { defaults.set(isPaused, forKey: "watchPaused") }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let access: FolderAccess
    @ObservationIgnored private let basePreset: @MainActor () -> Preset
    @ObservationIgnored private let isAllowed: @MainActor () -> Bool
    @ObservationIgnored private let enqueue: Enqueue
    @ObservationIgnored private var scanners: [UUID: FolderScanner] = [:]
    /// Which folder and file each running job belongs to.
    @ObservationIgnored private var owners: [JobID: (folder: UUID, source: URL)] = [:]

    private static let foldersKey = "watchedFolders"
    private static let processedLimit = 1000

    init(defaults: UserDefaults, access: FolderAccess, basePreset: @escaping @MainActor () -> Preset, isAllowed: @escaping @MainActor () -> Bool, enqueue: @escaping Enqueue) {
        self.defaults = defaults
        self.access = access
        self.basePreset = basePreset
        self.isAllowed = isAllowed
        self.enqueue = enqueue
        self.isPaused = defaults.bool(forKey: "watchPaused")
        if let data = defaults.data(forKey: Self.foldersKey),
           let saved = try? JSONDecoder().decode([WatchedFolder].self, from: data) {
            folders = saved
        }
    }

    var activeCount: Int { folders.filter(\.enabled).count }

    // MARK: Editing

    /// Asks the user for a folder and starts watching it.
    func chooseFolder() {
        guard let url = access.requestAccess(
            to: nil, message: "Choose a folder to watch. New images, videos, GIFs and PDFs in it are compressed automatically.",
            prompt: "Watch Folder") else { return }
        add(url)
    }

    func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !folders.contains(where: { $0.path == path }) else { return }
        access.remember(url)
        folders.append(WatchedFolder(path: path))
        save()
    }

    func remove(_ id: UUID) {
        folders.removeAll { $0.id == id }
        scanners[id] = nil
        defaults.removeObject(forKey: processedKey(id))
        save()
    }

    func update(_ folder: WatchedFolder) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index] = folder
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(folders), forKey: Self.foldersKey)
    }

    // MARK: Watching

    /// Checks every enabled folder every couple of seconds for as long as the calling task lives.
    func run() async {
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func pollOnce(now: Date = Date()) async {
        // Watching is part of the unlock, so nothing is picked up (or marked as seen) without it.
        guard !isPaused, isAllowed() else { return }
        for folder in folders where folder.enabled {
            var scanner = scanner(for: folder)
            let files = scanner.poll(now: now)
            scanners[folder.id] = scanner
            guard !files.isEmpty else { continue }

            var preset = basePreset()
            preset.level = folder.level
            preset.stripMetadata = folder.stripMetadata
            let policy: OutputPolicy = folder.replaceOriginals ? .replaceAndTrash : .suffix("-compressed")
            let ids = await enqueue(files, preset, policy)
            // Jobs come back in the same order as the files that were accepted.
            for (id, file) in zip(ids, files) { owners[id] = (folder.id, file) }
        }
    }

    private func scanner(for folder: WatchedFolder) -> FolderScanner {
        if let existing = scanners[folder.id] { return existing }
        var scanner = FolderScanner(folder: folder.url, processed: loadProcessed(folder.id))
        if defaults.data(forKey: processedKey(folder.id)) == nil {
            scanner.markExistingAsProcessed()  // first time: only react to files that arrive from now on
            saveProcessed(scanner, folder.id)
        }
        scanners[folder.id] = scanner
        return scanner
    }

    /// Stops a file from being picked up again, e.g. after the user restored an original.
    func markHandled(_ url: URL) {
        let folder = url.deletingLastPathComponent().standardizedFileURL.path
        guard let signature = FileSignature(url: url) else { return }
        for watched in folders where watched.path == folder {
            guard var scanner = scanners[watched.id] else { continue }
            scanner.markProcessed(signature)
            scanners[watched.id] = scanner
            saveProcessed(scanner, watched.id)
        }
    }

    /// Records the outcome of a job so its files are never picked up again.
    func jobFinished(_ job: CompressionJob) {
        guard let owner = owners.removeValue(forKey: job.id), var scanner = scanners[owner.folder] else { return }
        var urls = [owner.source]
        if case .completed(let result) = job.state { urls.append(result.outputURL) }
        for url in urls {
            if let signature = FileSignature(url: url) { scanner.markProcessed(signature) }
        }
        scanners[owner.folder] = scanner
        saveProcessed(scanner, owner.folder)
    }

    // MARK: Remembering what was handled

    private func processedKey(_ id: UUID) -> String { "watchProcessed-\(id.uuidString)" }

    private func loadProcessed(_ id: UUID) -> Set<FileSignature> {
        guard let data = defaults.data(forKey: processedKey(id)),
              let list = try? JSONDecoder().decode([FileSignature].self, from: data) else { return [] }
        return Set(list)
    }

    private func saveProcessed(_ scanner: FolderScanner, _ id: UUID) {
        let newest = scanner.processedSignatures.sorted { $0.modified > $1.modified }.prefix(Self.processedLimit)
        defaults.set(try? JSONEncoder().encode(Array(newest)), forKey: processedKey(id))
    }
}
