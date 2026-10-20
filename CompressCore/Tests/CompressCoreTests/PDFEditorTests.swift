import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import CompressCore

private enum DocFixtures {
    /// A Quartz PDF whose pages carry text drawn with the given lines: (text, font, size).
    static func make(_ url: URL, pages: [[(String, String, CGFloat)]]) throws -> URL {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        for lines in pages {
            context.beginPDFPage(nil)
            var y: CGFloat = 720
            for (text, fontName, size) in lines {
                let attributed = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(fontName as CFString, size, nil),
                ])
                context.textPosition = CGPoint(x: 60, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                y -= size * 1.5
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}

@Suite struct PDFEditorTests {
    let dir: Scratch
    init() throws { dir = try Scratch() }

    private func pdf(_ name: String, pages: Int, label: String = "Page") throws -> URL {
        try DocFixtures.make(dir.url.appendingPathComponent(name), pages: (1...pages).map { [("\(label) \($0) of \(name)", "Helvetica", 14)] })
    }

    private func run(_ family: OperationFamily, _ action: ToolAction, input: URL, kind: MediaKind = .pdf) async throws -> URL {
        let editor = PDFEditor(family, kind: kind)
        let preset = Preset(operation: action)
        let ext = editor.outputExtension(for: input, preset: preset)
        let out = dir.url.appendingPathComponent("out-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)"))
        try await editor.compress(input: input, output: out, preset: preset) { _ in }
        return out
    }

    private func texts(_ url: URL) -> [String] {
        guard let document = PDFDocument(url: url) else { return [] }
        return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    // MARK: Rotate and crop

    @Test func rotatesEveryPage() async throws {
        let input = try pdf("a.pdf", pages: 3)
        let out = try await run(.rotate, .rotate(RotateSpec(quarterTurns: 1)), input: input)
        let document = try #require(PDFDocument(url: out))
        #expect(document.pageCount == 3)
        #expect((0..<3).allSatisfy { document.page(at: $0)?.rotation == 90 })

        let again = try await run(.rotate, .rotate(RotateSpec(quarterTurns: 3)), input: out)
        #expect(PDFDocument(url: again)?.page(at: 0)?.rotation == 0, "90 + 270 is a full turn")
    }

    @Test func mirroringPDFsIsRefused() async throws {
        let input = try pdf("a.pdf", pages: 1)
        do {
            _ = try await run(.rotate, .rotate(RotateSpec(quarterTurns: 0, flipHorizontal: true)), input: input)
            Issue.record("should have thrown")
        } catch let error as CompressionError {
            #expect(error.localizedDescription.contains("mirrored"))
        }
    }

    @Test func cropShrinksTheVisibleArea() async throws {
        let input = try pdf("a.pdf", pages: 2)
        let out = try await run(.crop, .crop(NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)), input: input)
        let page = try #require(PDFDocument(url: out)?.page(at: 0))
        let box = page.bounds(for: .cropBox)
        #expect(abs(box.width - 306) < 1 && abs(box.height - 396) < 1)
        #expect(abs(box.minX - 153) < 1 && abs(box.minY - 198) < 1)
    }

    @Test func cropFollowsTheViewOnRotatedPages() async throws {
        let input = try pdf("a.pdf", pages: 1)
        let turned = try await run(.rotate, .rotate(RotateSpec(quarterTurns: 1)), input: input)
        // Keep the left half of what the reader sees: on a 90° page that is the lower half of the sheet.
        let out = try await run(.crop, .crop(NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)), input: turned)
        let box = try #require(PDFDocument(url: out)?.page(at: 0)).bounds(for: .cropBox)
        #expect(abs(box.width - 612) < 1 && abs(box.height - 396) < 1)
        #expect(box.minY < 1)
    }

    // MARK: Watermark

    @Test func watermarkKeepsPagesAndTextAndDrawsTheMark() async throws {
        let input = try pdf("a.pdf", pages: 2)
        let spec = WatermarkSpec(content: .text("CONFIDENTIAL"), position: .center, scale: 0.5, opacity: 1, rotationDegrees: 30)
        let out = try await run(.watermark, .watermark(spec), input: input)
        #expect(PDFFixtures.pageCount(out) == 2)
        #expect(texts(out)[0].contains("Page 1 of a.pdf"), "original text stays real text")
        let before = try #require(PDFFixtures.render(input)), after = try #require(PDFFixtures.render(out))
        var changed = 0
        for y in 150..<250 { for x in 100..<200 where before.pixels[(y * before.width + x) * 4] != after.pixels[(y * after.width + x) * 4] { changed += 1 } }
        #expect(changed > 100, "the mark appears around the middle of the page")
    }

    // MARK: Merge

    @Test func mergesPDFsAndPicturesInOrder() async throws {
        let a = try pdf("a.pdf", pages: 2), b = try pdf("b.pdf", pages: 3)
        let image = try Fixtures.write(Fixtures.photoLike(width: 200, height: 100), type: "public.png",
                                       to: dir.url.appendingPathComponent("pic.png"), quality: nil)
        let out = try await run(.merge, .merge(MergeSpec(sources: [b, image, a])), input: b)
        let all = texts(out)
        #expect(all.count == 6)
        #expect(all[0].contains("Page 1 of b.pdf") && all[2].contains("Page 3 of b.pdf"))
        #expect(all[3].isEmpty, "the picture becomes a page without text")
        #expect(all[4].contains("Page 1 of a.pdf") && all[5].contains("Page 2 of a.pdf"))
    }

    @Test func mergeReportsAnUnreadableFile() async throws {
        let a = try pdf("a.pdf", pages: 1)
        let junk = try dir.file("junk.pdf", bytes: 100)
        do {
            _ = try await run(.merge, .merge(MergeSpec(sources: [a, junk])), input: a)
            Issue.record("should have thrown")
        } catch let error as CompressionError {
            #expect(error.localizedDescription.contains("junk.pdf"))
        }
    }

    // MARK: Split

    private func files(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @Test func splitsIntoSinglePages() async throws {
        let input = try pdf("doc.pdf", pages: 3)
        let out = try await run(.split, .split(SplitSpec(mode: .everyPage)), input: input)
        let names = try files(in: out)
        #expect(names == ["doc-1-page-1.pdf", "doc-2-page-2.pdf", "doc-3-page-3.pdf"])
        #expect(texts(out.appendingPathComponent(names[1])).first?.contains("Page 2") == true)
    }

    @Test func splitsByRanges() async throws {
        let input = try pdf("doc.pdf", pages: 6)
        let out = try await run(.split, .split(SplitSpec(mode: .ranges("1-2, 4, 5-6"))), input: input)
        let names = try files(in: out)
        #expect(names.count == 3)
        #expect(PDFFixtures.pageCount(out.appendingPathComponent(names[0])) == 2)
        #expect(PDFFixtures.pageCount(out.appendingPathComponent(names[1])) == 1)
        #expect(PDFFixtures.pageCount(out.appendingPathComponent(names[2])) == 2)
    }

    @Test func splitsEveryN() async throws {
        let input = try pdf("doc.pdf", pages: 5)
        let out = try await run(.split, .split(SplitSpec(mode: .everyN(2))), input: input)
        let counts = try files(in: out).map { PDFFixtures.pageCount(out.appendingPathComponent($0)) }
        #expect(counts == [2, 2, 1])
    }

    @Test func rangeErrorsAreSpecific() throws {
        #expect(throws: CompressionError.self) { try PDFEditor.parseRanges("1-9", pageCount: 5) }
        #expect(throws: CompressionError.self) { try PDFEditor.parseRanges("abc", pageCount: 5) }
        #expect(throws: CompressionError.self) { try PDFEditor.parseRanges("4-2", pageCount: 5) }
        #expect(throws: CompressionError.self) { try PDFEditor.parseRanges("", pageCount: 5) }
        #expect(try PDFEditor.parseRanges(" 1 - 3 ;5 ", pageCount: 5) == [1...3, 5...5])
    }

    // MARK: Pages as pictures

    @Test func rendersPagesAtTheChosenResolution() async throws {
        let input = try pdf("doc.pdf", pages: 2)
        let out = try await run(.convert, .convert(ConvertSpec(target: .pdfToImages(.png, dpi: 144))), input: input)
        let names = try files(in: out)
        #expect(names == ["doc-page-1.png", "doc-page-2.png"])
        let image = try #require(Fixtures.cgImage(at: out.appendingPathComponent(names[0])))
        #expect(image.width == 1224 && image.height == 1584)
        let pixels = try #require(Fixtures.rgba(at: out.appendingPathComponent(names[0])))
        #expect(pixels.pixels.chunked4.contains { $0 < 100 }, "some ink was drawn")
    }

    // MARK: Through the queue

    @Test func mergeAndSplitRunThroughTheQueue() async throws {
        let a = try pdf("a.pdf", pages: 2), b = try pdf("b.pdf", pages: 2)
        let queue = JobQueue(registry: CompressorRegistry([PDFEditor(.merge), PDFEditor(.split)]), maxConcurrent: 1)

        let mergeID = await queue.enqueue(urls: [a], preset: Preset(operation: .merge(MergeSpec(sources: [a, b]))),
                                          outputPolicy: .suffix("-merged")).accepted[0]
        let splitID = await queue.enqueue(urls: [b], preset: Preset(operation: .split(SplitSpec(mode: .everyPage))),
                                          outputPolicy: .suffix("-split")).accepted[0]
        await queue.waitUntilIdle()

        guard case .completed(let merged) = await queue.job(mergeID)?.state, case .completed(let split) = await queue.job(splitID)?.state else {
            Issue.record("jobs did not complete: \(String(describing: await queue.job(mergeID)?.state)) \(String(describing: await queue.job(splitID)?.state))")
            return
        }
        #expect(merged.outputURL.lastPathComponent == "a-merged.pdf")
        #expect(PDFFixtures.pageCount(merged.outputURL) == 4)
        #expect(split.outputURL.lastPathComponent == "b-split")
        #expect(try files(in: split.outputURL).count == 2)
        #expect(split.outputBytes > 0, "the size of a folder is what is inside it")
        #expect(merged.outcome == .processed && split.outcome == .processed)
    }
}

private extension Array where Element == UInt8 {
    /// The red channel of every pixel in RGBA data.
    var chunked4: [UInt8] { stride(from: 0, to: count, by: 4).map { self[$0] } }
}

@Suite struct TextExtractionTests {
    let dir: Scratch
    init() throws { dir = try Scratch() }

    private func extract(_ input: URL, kind: MediaKind, _ spec: TextSpec = TextSpec()) async throws -> String {
        let editor = TextEditor(kind: kind)
        let preset = Preset(operation: .extractText(spec))
        let out = dir.url.appendingPathComponent("out.\(editor.outputExtension(for: input, preset: preset))")
        try await editor.compress(input: input, output: out, preset: preset) { _ in }
        return try String(contentsOf: out, encoding: .utf8)
    }

    private func report() throws -> URL {
        try DocFixtures.make(dir.url.appendingPathComponent("report.pdf"), pages: [
            [
                ("Annual Report", "Helvetica-Bold", 30),
                ("This is the first paragraph of the report and", "Helvetica", 12),
                ("it continues on a second line.", "Helvetica", 12),
                ("• apples", "Helvetica", 12),
                ("• pears", "Helvetica", 12),
                ("1. first step", "Helvetica", 12),
            ],
            [
                ("Details", "Helvetica-Bold", 20),
                ("Everything else is described here in a sentence.", "Helvetica", 12),
            ],
        ])
    }

    @Test func markdownKeepsHeadingsParagraphsAndLists() async throws {
        let text = try await extract(try report(), kind: .pdf)
        #expect(text.contains("# Annual Report"), "the largest type becomes a top heading:\n\(text)")
        #expect(text.contains("This is the first paragraph of the report and it continues on a second line."))
        #expect(text.contains("- apples\n- pears"))
        #expect(text.contains("1. first step"))
        #expect(text.contains("# Details"), "a lone heading on a page is still a heading")
        #expect(text.contains("Everything else is described here in a sentence."))
    }

    @Test func plainTextHasNoMarkup() async throws {
        let text = try await extract(try report(), kind: .pdf, TextSpec(format: .plain))
        #expect(!text.contains("#"))
        #expect(text.contains("Annual Report"))
        #expect(text.contains("• apples"))
    }

    @Test func readsTextFromAPicture() async throws {
        let ctx = CGContext(data: nil, width: 1200, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: Fixtures.sRGB,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 300))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Hello World from Compress", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 90, nil),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.textPosition = CGPoint(x: 40, y: 110)
        CTLineDraw(line, ctx)
        let image = try Fixtures.write(ctx.makeImage()!, type: "public.png", to: dir.url.appendingPathComponent("text.png"), quality: nil)

        let text = try await extract(image, kind: .image)
        #expect(text.lowercased().contains("hello world"), "recognised: \(text)")
    }

    @Test func scannedPagesNeedRecognition() async throws {
        // A PDF page that is only a picture of text.
        let ctx = CGContext(data: nil, width: 1200, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: Fixtures.sRGB,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 300))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Scanned invoice total", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 90, nil),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
        ctx.textPosition = CGPoint(x: 40, y: 110)
        CTLineDraw(line, ctx)
        let imageURL = try Fixtures.write(ctx.makeImage()!, type: "public.png", to: dir.url.appendingPathComponent("scan.png"), quality: nil)
        let scan = dir.url.appendingPathComponent("scan.pdf")
        try ImageEditor.writePDF(try #require(Fixtures.cgImage(at: imageURL)), to: scan)

        let text = try await extract(scan, kind: .pdf)
        #expect(text.lowercased().contains("scanned invoice"), "recognised: \(text)")

        do {
            _ = try await extract(scan, kind: .pdf, TextSpec(recognizeText: false))
            Issue.record("should have thrown")
        } catch let error as CompressionError {
            #expect(error.localizedDescription.contains("No text"))
        }
    }

    @Test func structureRulesWorkOnPlainLines() {
        let lines: [TextEditor.Line] = [
            .init(text: "Title", size: 24, bold: true), .init(text: "", size: 0, bold: false),
            .init(text: "A para-", size: 12, bold: false), .init(text: "graph here.", size: 12, bold: false),
            .init(text: "* one", size: 12, bold: false), .init(text: "* two", size: 12, bold: false),
        ]
        let blocks = TextEditor.structure(lines)
        #expect(blocks.map(\.text) == ["Title", "A paragraph here.", "one", "two"])
        #expect(blocks[0].kind == .heading(2) || blocks[0].kind == .heading(1))
    }
}
