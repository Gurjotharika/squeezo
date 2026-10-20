import Foundation

/// Shrinks EPUB and Office files (docx, pptx, xlsx) by recompressing the images inside them.
/// Everything else in the archive is copied byte for byte, so the document opens exactly as before.
public struct DocumentCompressor: Compressor {
    public var kind: MediaKind { .document }

    public init() {}

    /// Images smaller than this aren't worth the time.
    private static let minimumImageBytes = 8 * 1024
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png"]

    public func compress(
        input: URL,
        output: URL,
        preset: Preset,
        progress: @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        let original = try Data(contentsOf: input, options: .mappedIfSafe)

        let archive: ZipArchive
        do {
            archive = try ZipArchive(original)
        } catch {
            throw CompressionError.failed("“\(input.lastPathComponent)” can't be read as a document.")
        }

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("doc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Keep the original order: EPUB needs its `mimetype` entry first.
        let entries = archive.entries.sorted { $0.localOffset < $1.localOffset }
        var writer = ZipArchive.Writer()
        let imageCompressor = ImageCompressor()

        do {
            for (index, entry) in entries.enumerated() {
                try Task.checkCancellation()
                progress(Double(index) / Double(max(entries.count, 1)))

                let ext = (entry.name as NSString).pathExtension.lowercased()
                if !entry.isEncrypted, Self.imageExtensions.contains(ext), entry.uncompressedSize >= Self.minimumImageBytes,
                   let pixels = try archive.contents(entry) {
                    let source = scratch.appendingPathComponent("in.\(ext)")
                    let result = scratch.appendingPathComponent("out.\(ext)")
                    try? FileManager.default.removeItem(at: result)
                    try pixels.write(to: source)
                    // A picture that can't be recompressed just stays as it was.
                    if (try? await imageCompressor.compress(input: source, output: result, preset: preset) { _ in }) != nil,
                       let smaller = try? Data(contentsOf: result),
                       Double(smaller.count) < Double(entry.compressedSize) * 0.95 {
                        writer.store(entry, contents: smaller)
                        continue
                    }
                }
                writer.copy(entry, span: try archive.rawSpan(entry))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Anything unexpected in the archive: hand back the file unchanged.
            try FileManager.default.copyItem(at: input, to: output)
            return
        }

        let rewritten = writer.finish()
        if rewritten.count < original.count, (try? ZipArchive(rewritten))?.entries.count == archive.entries.count {
            try rewritten.write(to: output)
        } else {
            try FileManager.default.copyItem(at: input, to: output)
        }
    }
}
