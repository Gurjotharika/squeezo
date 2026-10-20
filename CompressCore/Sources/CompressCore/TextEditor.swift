import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Turns PDFs and pictures into Markdown or plain text, reading scanned pages with on-device text recognition.
public struct TextEditor: Compressor {
    public let kind: MediaKind
    public var family: OperationFamily { .extractText }

    public init(kind: MediaKind) { self.kind = kind }

    public func outputExtension(for input: URL, preset: Preset) -> String {
        if case .extractText(let spec) = preset.operation { return spec.format.fileExtension }
        return "md"
    }

    public func compress(input: URL, output: URL, preset: Preset, progress: @Sendable (Double) -> Void) async throws {
        guard case .extractText(let spec) = preset.operation else {
            throw CompressionError.failed("This tool doesn't extract text.")
        }
        try Task.checkCancellation()
        var pages: [[TextBlock]] = []

        if kind == .pdf {
            let document = try PDFEditor.open(input)
            let pdf = CGPDFDocument(input as CFURL)
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                if let blocks = Self.blocks(fromText: page), !blocks.isEmpty {
                    pages.append(blocks)
                } else if spec.recognizeText, let cgPage = pdf?.page(at: index + 1), let image = PDFEditor.renderPage(cgPage, dpi: 200) {
                    pages.append(try Self.recognize(image))
                } else {
                    pages.append([])
                }
                progress(Double(index + 1) / Double(document.pageCount))
            }
        } else {
            guard spec.recognizeText else { throw CompressionError.failed("Turn on text recognition to read text from pictures.") }
            pages = [try Self.recognize(try ImageTools.load(input).image)]
        }

        let text = Self.render(pages, format: spec.format)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompressionError.failed("No text was found in “\(input.lastPathComponent)”.")
        }
        try text.write(to: output, atomically: true, encoding: .utf8)
    }

    // MARK: Model

    /// One paragraph or heading, with how large its type is compared with the rest.
    struct TextBlock: Equatable {
        enum Kind: Equatable { case heading(Int), paragraph, listItem(marker: String) }
        var kind: Kind
        var text: String
        var bold = false
    }

    struct Line {
        var text: String
        var size: Double
        var bold: Bool
    }

    // MARK: Text that is already in the PDF

    static func blocks(fromText page: PDFPage) -> [TextBlock]? {
        guard let attributed = page.attributedString, attributed.length > 0 else { return nil }
        let string = attributed.string
        guard string.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12 else { return nil }

        // Split into lines, and measure the dominant font size and weight of each.
        var lines: [Line] = []
        var start = 0
        let ns = string as NSString
        while start < ns.length {
            var lineEnd = 0, contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            let range = NSRange(location: start, length: contentsEnd - start)
            start = max(lineEnd, start + 1)
            let text = ns.substring(with: range).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { lines.append(Line(text: "", size: 0, bold: false)); continue }

            var sizeVotes: [Double: Int] = [:], boldChars = 0
            attributed.enumerateAttribute(.font, in: range) { value, run, _ in
                guard let font = value as? NSFont else { return }
                sizeVotes[Double(font.pointSize).rounded(), default: 0] += run.length
                if font.fontDescriptor.symbolicTraits.contains(.bold) { boldChars += run.length }
            }
            let size = sizeVotes.max { $0.value < $1.value }?.key ?? 12
            lines.append(Line(text: text, size: size, bold: boldChars * 2 > range.length))
        }
        return structure(lines)
    }

    /// Turns lines into headings, list items and paragraphs using type size, weight and punctuation.
    static func structure(_ lines: [Line]) -> [TextBlock] {
        let body = lines.filter { !$0.text.isEmpty }
        guard !body.isEmpty else { return [] }
        // The most common size (by amount of text) is what ordinary paragraphs look like.
        var weight: [Double: Int] = [:]
        for line in body { weight[line.size, default: 0] += line.text.count }
        let bodySize = weight.max { $0.value < $1.value }?.key ?? 12

        var blocks: [TextBlock] = []
        var open: TextBlock?

        func flush() {
            if let block = open { blocks.append(block) }
            open = nil
        }

        for line in lines {
            guard !line.text.isEmpty else { flush(); continue }
            let ratio = line.size / bodySize

            if ratio >= 1.15 || (line.bold && line.text.count < 70 && ratio >= 1.0 && body.count > 3 && !line.text.hasSuffix(".")) {
                let level = ratio >= 1.6 ? 1 : (ratio >= 1.3 ? 2 : 3)
                if case .heading(let existing)? = open?.kind, existing == level {
                    open?.text += " " + line.text  // a heading that wrapped onto a second line
                } else {
                    flush()
                    open = TextBlock(kind: .heading(level), text: line.text)
                }
                continue
            }
            if let marker = listMarker(line.text) {
                flush()
                open = TextBlock(kind: .listItem(marker: marker.marker), text: marker.rest)
                continue
            }
            switch open?.kind {
            case .paragraph?, .listItem?:
                // Continue the paragraph; undo hyphenation at line ends.
                if open!.text.hasSuffix("-"), let next = line.text.first, next.isLowercase {
                    open!.text.removeLast()
                    open!.text += line.text
                } else {
                    open!.text += " " + line.text
                }
            default:
                flush()
                open = TextBlock(kind: .paragraph, text: line.text)
            }
        }
        flush()
        return blocks
    }

    private static func listMarker(_ text: String) -> (marker: String, rest: String)? {
        for bullet in ["•", "◦", "▪", "‣", "·", "–", "-", "*"] where text.hasPrefix(bullet + " ") {
            return ("-", String(text.dropFirst(bullet.count + 1)))
        }
        if let match = text.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
            let number = text[match].trimmingCharacters(in: .whitespaces)
            return (number, String(text[match.upperBound...]))
        }
        return nil
    }

    // MARK: Text recognised from pictures

    static func recognize(_ image: CGImage) throws -> [TextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        // Reading order: top to bottom, left to right within a row.
        let observations = (request.results ?? []).sorted {
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
        }
        let lines: [(text: String, box: CGRect)] = observations.compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
        }
        guard !lines.isEmpty else { return [] }

        // Line height stands in for font size; big gaps between lines mean a new paragraph.
        let heights = lines.map { $0.box.height }.sorted()
        let median = heights[heights.count / 2]
        var converted: [Line] = []
        var previous: CGRect?
        for line in lines {
            if let previous, previous.minY - line.box.maxY > median * 0.9 { converted.append(Line(text: "", size: 0, bold: false)) }
            converted.append(Line(text: line.text, size: Double(line.box.height / median * 12).rounded(), bold: false))
            previous = line.box
        }
        return structure(converted)
    }

    // MARK: Output

    static func render(_ pages: [[TextBlock]], format: TextFormat) -> String {
        var out: [String] = []
        for blocks in pages where !blocks.isEmpty {
            var pageText: [String] = []
            var previousWasList = false
            for block in blocks {
                switch block.kind {
                case .heading(let level):
                    pageText.append(format == .markdown ? String(repeating: "#", count: level) + " " + block.text : block.text)
                    previousWasList = false
                case .paragraph:
                    pageText.append(block.text)
                    previousWasList = false
                case .listItem(let marker):
                    let item = (format == .markdown ? (marker == "-" ? "- " : marker + " ") : (marker == "-" ? "• " : marker + " ")) + block.text
                    // Items of one list stay together, without blank lines between them.
                    if previousWasList, !pageText.isEmpty { pageText[pageText.count - 1] += "\n" + item } else { pageText.append(item) }
                    previousWasList = true
                }
            }
            out.append(pageText.joined(separator: "\n\n"))
        }
        return out.joined(separator: "\n\n") + "\n"
    }
}
