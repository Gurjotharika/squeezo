import Foundation

/// A stand-in compressor that "compresses" by keeping the first part of the file.
/// Used by tests and by the app until the real engines exist.
public struct FakeCompressor: Compressor {
    public let kind: MediaKind
    public var keepFraction: Double
    public var steps: Int
    public var stepDelay: Duration
    public var failingFileNames: Set<String>
    public var changedExtension: String?
    public var onStart: (@Sendable (URL) async -> Void)?
    public var onFinish: (@Sendable (URL) async -> Void)?

    public init(
        kind: MediaKind,
        keepFraction: Double = 0.5,
        steps: Int = 4,
        stepDelay: Duration = .milliseconds(5),
        failingFileNames: Set<String> = [],
        changedExtension: String? = nil,
        onStart: (@Sendable (URL) async -> Void)? = nil,
        onFinish: (@Sendable (URL) async -> Void)? = nil
    ) {
        self.kind = kind
        self.keepFraction = keepFraction
        self.steps = max(1, steps)
        self.stepDelay = stepDelay
        self.failingFileNames = failingFileNames
        self.changedExtension = changedExtension
        self.onStart = onStart
        self.onFinish = onFinish
    }

    public func outputExtension(for input: URL, preset: Preset) -> String {
        changedExtension ?? input.pathExtension
    }

    public func compress(
        input: URL,
        output: URL,
        preset: Preset,
        progress: @Sendable (Double) -> Void
    ) async throws {
        await onStart?(input)
        for step in 1...steps {
            try await Task.sleep(for: stepDelay)
            progress(Double(step) / Double(steps))
        }
        if failingFileNames.contains(input.lastPathComponent) {
            throw CompressionError.failed("Simulated failure for \(input.lastPathComponent)")
        }
        let data = try Data(contentsOf: input)
        let kept = Int(Double(data.count) * keepFraction)
        try data.prefix(kept).write(to: output)
        await onFinish?(input)
    }
}
