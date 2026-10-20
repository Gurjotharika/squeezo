import Foundation

/// Compresses one kind of media. Implementations must honour task cancellation
/// (throw `CancellationError`, or check `Task.checkCancellation()` regularly).
public protocol Compressor: Sendable {
    var kind: MediaKind { get }

    /// Which kind of work this does. Compression unless it says otherwise.
    var family: OperationFamily { get }

    /// The extension of the file this compressor writes for `input`.
    func outputExtension(for input: URL, preset: Preset) -> String

    /// Writes a compressed copy of `input` to `output`. `progress` takes values in 0...1.
    func compress(
        input: URL,
        output: URL,
        preset: Preset,
        progress: @Sendable (Double) -> Void
    ) async throws
}

public extension Compressor {
    var family: OperationFamily { .compress }

    func outputExtension(for input: URL, preset: Preset) -> String {
        input.pathExtension
    }
}

public struct CompressorRegistry: Sendable {
    private struct Key: Hashable {
        var kind: MediaKind
        var family: OperationFamily
    }

    private let compressors: [Key: any Compressor]

    public init(_ compressors: [any Compressor]) {
        self.compressors = Dictionary(
            compressors.map { (Key(kind: $0.kind, family: $0.family), $0) },
            uniquingKeysWith: { _, last in last }
        )
    }

    public subscript(kind: MediaKind, family: OperationFamily = .compress) -> (any Compressor)? {
        compressors[Key(kind: kind, family: family)]
    }

    /// Whether any engine can do this kind of work on this kind of file.
    public func supports(_ family: OperationFamily, on kind: MediaKind) -> Bool {
        compressors[Key(kind: kind, family: family)] != nil
    }
}
