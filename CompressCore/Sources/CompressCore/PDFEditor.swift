import CoreGraphics
import Foundation
import PDFKit

/// Rotate, crop, watermark, merge, split and turn pages into pictures.
public struct PDFEditor: Compressor {
    public let family: OperationFamily
    public let kind: MediaKind

    public init(_ family: OperationFamily, kind: MediaKind = .pdf) {
        self.family = family
        self.kind = kind
    }

    public func outputExtension(for input: URL, preset: Preset) -> String {
        switch preset.operation {
        case .split: return ""
        case .convert(let spec):
            if case .pdfToImages = spec.target { return "" }
            return "pdf"
        default: return "pdf"
        }
    }

    public func compress(input: URL, output: URL, preset: Preset, progress: @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        switch preset.operation {
        case .rotate(let spec): try rotate(input, output, spec)
        case .crop(let rect): try crop(input, output, rect)
        case .watermark(let spec): try await watermark(input, output, spec, progress)
        case .merge(let spec): try await merge(spec, output, progress)
        case .split(let spec): try await split(input, output, spec, progress)
        case .convert(let spec):
            guard case .pdfToImages(let format, let dpi) = spec.target else {
                throw CompressionError.failed("This conversion doesn't work on PDFs.")
            }
            try await pagesToImages(input, output, format: format, dpi: dpi, quality: spec.quality, progress)
        default:
            throw CompressionError.failed("This tool doesn't work on PDFs.")
        }
    }

    // MARK: Opening

    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw CompressionError.failed("“\(url.lastPathComponent)” can't be read as a PDF.")
        }
        if document.isLocked {
            throw CompressionError.failed("“\(url.lastPathComponent)” is password protected.")
        }
        return document
    }

    private static func write(_ document: PDFDocument, to url: URL) throws {
        guard document.write(to: url) else { throw CompressionError.failed("The PDF couldn't be saved.") }
    }

    // MARK: Rotate and crop

    private func rotate(_ input: URL, _ output: URL, _ spec: RotateSpec) throws {
        if spec.flipHorizontal || spec.flipVertical {
            throw CompressionError.failed("PDF pages can be turned but not mirrored.")
        }
        let document = try Self.open(input)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.rotation = (page.rotation + spec.quarterTurns * 90) % 360
        }
        try Self.write(document, to: output)
    }

    private func crop(_ input: URL, _ output: URL, _ rect: NormalizedRect) throws {
        let document = try Self.open(input)
        let r = rect.clamped
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let media = page.bounds(for: .mediaBox)
            // The rectangle is in what the reader sees, so undo the page's rotation before applying it.
            var x = r.x, y = r.y, w = r.width, h = r.height
            switch page.rotation % 360 {
            case 90: (x, y, w, h) = (r.y, 1 - r.x - r.width, r.height, r.width)
            case 180: (x, y) = (1 - r.x - r.width, 1 - r.y - r.height)
            case 270: (x, y, w, h) = (1 - r.y - r.height, r.x, r.height, r.width)
            default: break
            }
            // Normalised y runs down from the top; PDF y runs up from the bottom.
            let box = CGRect(
                x: media.minX + x * media.width, y: media.minY + (1 - y - h) * media.height,
                width: w * media.width, height: h * media.height)
            page.setBounds(box, for: .cropBox)
        }
        try Self.write(document, to: output)
    }

    // MARK: Watermark

    private func watermark(_ input: URL, _ output: URL, _ spec: WatermarkSpec, _ progress: @Sendable (Double) -> Void) async throws {
        let document = try Self.open(input)
        guard let pdf = CGPDFDocument(input as CFURL) else { throw CompressionError.failed("The PDF couldn't be read.") }
        var first = document.page(at: 0)?.bounds(for: .cropBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(output as CFURL, mediaBox: &first, nil) else {
            throw CompressionError.failed("The PDF couldn't be created.")
        }
        // Pages are redrawn rather than edited, so text and drawings stay sharp at any zoom.
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let cgPage = pdf.page(at: index + 1) else { continue }
            let box = page.bounds(for: .cropBox)
            let turned = page.rotation % 180 != 0
            var pageBox = CGRect(origin: .zero, size: turned ? CGSize(width: box.height, height: box.width) : box.size)
            let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            context.saveGState()
            context.concatenate(cgPage.getDrawingTransform(.cropBox, rect: pageBox, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(cgPage)
            context.restoreGState()
            ImageTools.drawWatermark(spec, in: context, size: pageBox.size)
            context.endPDFPage()
            progress(Double(index + 1) / Double(document.pageCount))
        }
        context.closePDF()
    }

    // MARK: Merge

    private func merge(_ spec: MergeSpec, _ output: URL, _ progress: @Sendable (Double) -> Void) async throws {
        let merged = PDFDocument()
        for (n, source) in spec.sources.enumerated() {
            try Task.checkCancellation()
            if source.pathExtension.lowercased() == "pdf" {
                let document = try Self.open(source)
                for index in 0..<document.pageCount {
                    if let page = document.page(at: index)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
                }
            } else {
                let loaded = try ImageTools.load(source)
                let image = NSImage(cgImage: loaded.image, size: NSSize(width: loaded.image.width, height: loaded.image.height))
                guard let page = PDFPage(image: image) else {
                    throw CompressionError.failed("“\(source.lastPathComponent)” couldn't be added.")
                }
                merged.insert(page, at: merged.pageCount)
            }
            progress(Double(n + 1) / Double(spec.sources.count))
        }
        guard merged.pageCount > 0 else { throw CompressionError.failed("There was nothing to merge.") }
        try Self.write(merged, to: output)
    }

    // MARK: Split

    /// Parses `1-3, 5, 8-10` into page ranges (1-based), checked against the page count.
    static func parseRanges(_ text: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let pieces = part.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(pieces.count), let first = Int(pieces[0]), let last = Int(pieces.last!) else {
                throw CompressionError.failed("“\(part.trimmingCharacters(in: .whitespaces))” isn't a page range. Use something like 1-3, 5, 8-10.")
            }
            guard first >= 1, last >= first else { throw CompressionError.failed("The range \(part) is back to front.") }
            guard last <= pageCount else {
                throw CompressionError.failed("Page \(last) is past the end; this PDF has \(pageCount) \(pageCount == 1 ? "page" : "pages").")
            }
            ranges.append(first...last)
        }
        guard !ranges.isEmpty else { throw CompressionError.failed("Enter the pages to keep, such as 1-3, 5.") }
        return ranges
    }

    private func split(_ input: URL, _ output: URL, _ spec: SplitSpec, _ progress: @Sendable (Double) -> Void) async throws {
        let document = try Self.open(input)
        let count = document.pageCount
        let ranges: [ClosedRange<Int>]
        switch spec.mode {
        case .everyPage: ranges = (1...count).map { $0...$0 }
        case .everyN(let n):
            let step = max(1, n)
            ranges = stride(from: 1, through: count, by: step).map { $0...min($0 + step - 1, count) }
        case .ranges(let text): ranges = try Self.parseRanges(text, pageCount: count)
        }

        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let name = input.deletingPathExtension().lastPathComponent
        let digits = String(ranges.count).count
        for (n, range) in ranges.enumerated() {
            try Task.checkCancellation()
            let part = PDFDocument()
            for pageNumber in range {
                if let page = document.page(at: pageNumber - 1)?.copy() as? PDFPage { part.insert(page, at: part.pageCount) }
            }
            let label = range.count == 1 ? "page-\(range.lowerBound)" : "pages-\(range.lowerBound)-\(range.upperBound)"
            let file = output.appendingPathComponent("\(name)-\(String(format: "%0\(digits)d", n + 1))-\(label).pdf")
            try Self.write(part, to: file)
            progress(Double(n + 1) / Double(ranges.count))
        }
    }

    // MARK: Pages as pictures

    public static func renderPage(_ page: CGPDFPage, dpi: Int) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let turned = page.rotationAngle % 180 != 0
        let scale = Double(dpi) / 72
        let width = Int(((turned ? box.height : box.width) * scale).rounded())
        let height = Int(((turned ? box.width : box.height) * scale).rounded())
        guard width > 0, height > 0, width * height < 200_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    private func pagesToImages(
        _ input: URL, _ output: URL, format: ImageFormat, dpi: Int, quality: Double, _ progress: @Sendable (Double) -> Void
    ) async throws {
        guard let pdf = CGPDFDocument(input as CFURL), pdf.numberOfPages > 0 else {
            throw CompressionError.failed("“\(input.lastPathComponent)” can't be read as a PDF.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let name = input.deletingPathExtension().lastPathComponent
        let digits = String(pdf.numberOfPages).count
        for number in 1...pdf.numberOfPages {
            try Task.checkCancellation()
            guard let page = pdf.page(at: number), let image = Self.renderPage(page, dpi: min(max(dpi, 36), 600)) else {
                throw CompressionError.failed("Page \(number) couldn't be rendered.")
            }
            let data = try ImageTools.encode(
                image, type: format.typeIdentifier, quality: format.isLossy ? quality : nil, properties: [:], stripMetadata: true)
            try data.write(to: output.appendingPathComponent("\(name)-page-\(String(format: "%0\(digits)d", number)).\(format.fileExtension)"))
            progress(Double(number) / Double(pdf.numberOfPages))
        }
    }
}
