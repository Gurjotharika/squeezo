import Foundation
@testable import CompressCore

/// A scratch directory deleted when the value goes away.
final class Scratch: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompressCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ name: String, bytes: Int = 1000) throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: file)
        return file
    }

    func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}

/// Tracks how many compressions run at once and in what order they started.
actor Probe {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var started: [String] = []

    func begin(_ url: URL) {
        current += 1
        peak = max(peak, current)
        started.append(url.lastPathComponent)
    }

    func end() { current -= 1 }
}

/// Polls until `condition` holds, failing after `timeout`.
func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

func makeQueue(
    _ compressors: [any Compressor],
    maxConcurrent: Int = 2
) -> JobQueue {
    JobQueue(registry: CompressorRegistry(compressors), maxConcurrent: maxConcurrent)
}
