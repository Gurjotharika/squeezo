import CoreGraphics
import Foundation

/// Shrinks PDFs by re-encoding their large images. Text and vector content is never touched.
///
/// If a file can't be rewritten safely (encrypted, damaged, or the result doesn't check out) it is
/// copied unchanged, so the queue reports it as already optimal.
public struct PDFCompressor: Compressor {
    public var kind: MediaKind { .pdf }

    public init() {}

    public func compress(
        input: URL,
        output: URL,
        preset: Preset,
        progress: @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard let document = CGPDFDocument(input as CFURL), document.numberOfPages > 0 else {
            throw CompressionError.failed("“\(input.lastPathComponent)” can't be read as a PDF.")
        }
        if document.isEncrypted {
            // Rewriting would break the encryption, so leave these alone.
            try FileManager.default.copyItem(at: input, to: output)
            return
        }

        let original = try Data(contentsOf: input, options: .mappedIfSafe)
        progress(0.05)

        let rewritten: Data?
        do {
            let file = try PDFFile(original)
            rewritten = try PDFRewriter.rewrite(file, preset: preset) { progress(0.05 + 0.85 * $0) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            rewritten = nil
        }
        try Task.checkCancellation()

        // Trust the result only if a PDF reader opens it and finds the same pages.
        if let rewritten, rewritten.count < original.count,
           let check = CGDataProvider(data: rewritten as CFData).flatMap({ CGPDFDocument($0) }),
           check.numberOfPages == document.numberOfPages {
            try rewritten.write(to: output)
        } else {
            try FileManager.default.copyItem(at: input, to: output)
        }
    }
}
