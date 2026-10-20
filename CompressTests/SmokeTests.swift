import CompressCore
import Foundation
import Testing
@testable import Compress

@MainActor
@Suite struct AppModelTests {
    private func makeModel() -> AppModel {
        let defaults = UserDefaults(suiteName: "CompressTests-\(UUID().uuidString)")!
        let registry = CompressorRegistry(
            MediaKind.allCases.map { FakeCompressor(kind: $0, steps: 2, stepDelay: .milliseconds(1)) })
        return AppModel(defaults: defaults, registry: registry)
    }

    private func scratchFile(_ name: String, bytes: Int = 1000) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompressTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    private func waitForFinished(_ model: AppModel, count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if model.finishedCount == count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func addingFilesQueuesAndCompletesThem() async throws {
        let model = makeModel()
        let observer = Task { await model.run() }
        defer { observer.cancel() }
        let photo = try scratchFile("a.jpg")
        let notes = try scratchFile("notes.txt")

        await model.add(urls: [photo, notes])

        #expect(await waitForFinished(model, count: 1))
        #expect(model.jobs.count == 1)
        #expect(model.totalSavedBytes > 0)
        #expect(model.notice == "1 unsupported file skipped")
    }

    @Test func settingsPersist() throws {
        let suite = "CompressTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = AppModel(defaults: defaults, registry: AppModel.defaultRegistry())
        first.level = .low
        first.stripMetadata = true

        let second = AppModel(defaults: defaults, registry: AppModel.defaultRegistry())
        #expect(second.level == .low)
        #expect(second.stripMetadata)
    }

    @Test func watchedFolderCompressesNewFilesOnceAndIgnoresItsOwnOutput() async throws {
        let model = makeModel()
        model.entitlements.isUnlocked = true
        let observer = Task { await model.run() }
        defer { observer.cancel() }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Watched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1000).write(to: folder.appendingPathComponent("existing.jpg"))

        model.watch.add(folder)
        let start = Date()
        await model.watch.pollOnce(now: start)  // remembers what is already there
        try Data(repeating: 1, count: 1000).write(to: folder.appendingPathComponent("new.jpg"))
        await model.watch.pollOnce(now: start + 1)  // first sighting
        #expect(model.jobs.isEmpty)
        await model.watch.pollOnce(now: start + 4)  // settled
        #expect(await waitForFinished(model, count: 1))
        #expect(model.jobs.map { $0.sourceURL.lastPathComponent } == ["new.jpg"])

        // The compressed copy and the original must not be queued again.
        await model.watch.pollOnce(now: start + 8)
        await model.watch.pollOnce(now: start + 12)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.jobs.count == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["existing.jpg", "new-compressed.jpg", "new.jpg"])
    }

    @Test func pausedWatcherDoesNothing() async throws {
        let model = makeModel()
        model.entitlements.isUnlocked = true
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Watched-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.watch.add(folder)
        model.watch.isPaused = true
        let start = Date()
        await model.watch.pollOnce(now: start)
        try Data(repeating: 1, count: 1000).write(to: folder.appendingPathComponent("new.jpg"))
        await model.watch.pollOnce(now: start + 1)
        await model.watch.pollOnce(now: start + 4)
        #expect(model.jobs.isEmpty)
    }

    @Test func replacingMovesOriginalToTrashAndUndoBringsItBack() async throws {
        let model = makeModel()
        let observer = Task { await model.run() }
        defer { observer.cancel() }
        model.outputMode = .replace
        let photo = try scratchFile("r.jpg", bytes: 1000)

        await model.add(urls: [photo])
        #expect(await waitForFinished(model, count: 1))
        #expect(try Data(contentsOf: photo).count == 500)
        let job = try #require(model.jobs.first)
        #expect(model.canUndo(job))

        model.undo(job)
        let deadline = ContinuousClock.now + .seconds(3)
        while !model.jobs.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.jobs.isEmpty)
        #expect(try Data(contentsOf: photo).count == 1000, "original restored")
    }
}
