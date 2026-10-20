import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import CompressCore

enum PDFFixtures {
    /// A PDF made by Quartz: page 1 has text and a photo, page 2 has only text.
    @discardableResult
    static func make(
        _ url: URL, photo: CGImage?, title: String? = nil, ownerPassword: String? = nil, pages: Int = 2
    ) throws -> URL {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        if let ownerPassword {
            info[kCGPDFContextOwnerPassword] = ownerPassword
            info[kCGPDFContextUserPassword] = ownerPassword
        }
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for page in 0..<pages {
            context.beginPDFPage(nil)
            let text = NSAttributedString(
                string: "Hello PDF compression page \(page + 1)",
                attributes: [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 24, nil)])
            context.textPosition = CGPoint(x: 50, y: 730)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            if page == 0, let photo {
                context.draw(photo, in: CGRect(x: 50, y: 200, width: 500, height: 480))
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    static func photo(width: Int = 1600, height: Int = 1500) -> CGImage {
        Fixtures.photoLike(width: width, height: height, seed: 9)
    }

    /// The same photo, stored as JPEG so the PDF embeds it as DCT data.
    static func jpegPhoto(width: Int = 1600, height: Int = 1500) throws -> CGImage {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, photo(width: width, height: height),
                                   [kCGImageDestinationLossyCompressionQuality: 0.98] as CFDictionary)
        CGImageDestinationFinalize(destination)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Renders a page to pixels so two PDFs can be compared visually.
    static func render(_ url: URL, page: Int = 1) -> RGBAImage? {
        guard let document = CGPDFDocument(url as CFURL), let pdfPage = document.page(at: page) else { return nil }
        let box = pdfPage.getBoxRect(.mediaBox)
        let width = Int(box.width / 2), height = Int(box.height / 2)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: Fixtures.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 0.5, y: 0.5)
        context.drawPDFPage(pdfPage)
        return context.makeImage().flatMap(RGBAImage.init)
    }

    static func pageCount(_ url: URL) -> Int { CGPDFDocument(url as CFURL)?.numberOfPages ?? 0 }

    // MARK: Hand-written PDFs

    /// Builds a PDF from numbered bodies, with either a classic cross-reference table or an
    /// uncompressed cross-reference stream and an object stream holding the catalog and page tree.
    static func handmade(
        image: (data: Data, width: Int, height: Int)?, smask: (data: Data, width: Int, height: Int)? = nil,
        objectStreams: Bool, content: String = "q 200 0 0 200 0 0 cm /Im0 Do Q"
    ) -> Data {
        var out = Data("%PDF-1.5\n".utf8)
        var offsets: [Int: Int] = [:]

        func object(_ n: Int, _ dict: String, stream: Data? = nil) {
            offsets[n] = out.count
            out.append(Data("\(n) 0 obj\n".utf8))
            if let stream {
                out.append(Data("<< \(dict) /Length \(stream.count) >>\nstream\n".utf8))
                out.append(stream)
                out.append(Data("\nendstream\nendobj\n".utf8))
            } else {
                out.append(Data("\(dict)\nendobj\n".utf8))
            }
        }

        let catalog = "<< /Type /Catalog /Pages 3 0 R >>"
        let pages = "<< /Type /Pages /Kids [4 0 R] /Count 1 >>"
        if objectStreams {
            // Objects 2 and 3 live inside object stream 1.
            let body = "\(catalog)\n\(pages)\n"
            let header = "2 0 3 \(catalog.utf8.count + 1) "
            object(1, "/Type /ObjStm /N 2 /First \(header.utf8.count)", stream: Data((header + body).utf8))
        }
        object(4, "<< /Type /Page /Parent 3 0 R /MediaBox [0 0 200 200] /Resources << /XObject << /Im0 5 0 R >> >> /Contents 6 0 R >>")
        if let image {
            let mask = smask != nil ? " /SMask 8 0 R" : ""
            object(5, "<< /Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode\(mask) >>".replacingOccurrences(of: "<< ", with: "").replacingOccurrences(of: " >>", with: ""), stream: image.data)
        }
        object(6, "", stream: Data(content.utf8))
        if let smask {
            object(8, "/Type /XObject /Subtype /Image /Width \(smask.width) /Height \(smask.height) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode", stream: smask.data)
        }

        let xrefOffset = out.count
        if objectStreams {
            var rows = Data()
            for n in 0...9 {
                switch n {
                case 2: rows.append(2); rows.appendBigEndian(1); rows.append(contentsOf: [0, 0])
                case 3: rows.append(2); rows.appendBigEndian(1); rows.append(contentsOf: [0, 1])
                case 9: rows.append(1); rows.appendBigEndian(UInt32(xrefOffset)); rows.append(contentsOf: [0, 0])
                default:
                    if let offset = offsets[n] { rows.append(1); rows.appendBigEndian(UInt32(offset)); rows.append(contentsOf: [0, 0]) }
                    else { rows.append(0); rows.appendBigEndian(0); rows.append(contentsOf: [0xFF, 0xFF]) }
                }
            }
            out.append(Data("9 0 obj\n<< /Type /XRef /Size 10 /W [1 4 2] /Root 2 0 R /Length \(rows.count) >>\nstream\n".utf8))
            out.append(rows)
            out.append(Data("\nendstream\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        } else {
            // Classic files keep the catalog and page tree in the body.
            offsets[2] = out.count
            out.append(Data("2 0 obj\n\(catalog)\nendobj\n".utf8))
            offsets[3] = out.count
            out.append(Data("3 0 obj\n\(pages)\nendobj\n".utf8))
            let tableOffset = out.count
            out.append(Data("xref\n0 10\n".utf8))
            for n in 0..<10 {
                if let offset = offsets[n] { out.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
                else { out.append(Data("0000000000 65535 f \n".utf8)) }
            }
            out.append(Data("trailer\n<< /Size 10 /Root 2 0 R >>\nstartxref\n\(tableOffset)\n%%EOF\n".utf8))
        }
        return out
    }

    static func rawImage(width: Int, height: Int) throws -> Data {
        let rgba = try #require(RGBAImage(Fixtures.photoLike(width: width, height: height, seed: 5)))
        var rgb = Data(capacity: width * height * 3)
        for i in 0..<width * height { rgb.append(contentsOf: [rgba.pixels[i * 4], rgba.pixels[i * 4 + 1], rgba.pixels[i * 4 + 2]]) }
        return try PNGEncoder.zlib(rgb)
    }
}

@Suite struct PDFCompressorTests {
    let dir: Scratch
    let compressor = PDFCompressor()

    init() throws { dir = try Scratch() }

    private func compress(_ input: URL, _ preset: Preset = .default) async throws -> URL {
        let out = dir.url.appendingPathComponent("out-\(UUID().uuidString).pdf")
        try await compressor.compress(input: input, output: out, preset: preset) { _ in }
        return out
    }

    private func pdf(_ name: String = "a.pdf", photo: CGImage? = PDFFixtures.photo(), title: String? = nil, pages: Int = 2) throws -> URL {
        try PDFFixtures.make(dir.url.appendingPathComponent(name), photo: photo, title: title, pages: pages)
    }

    @Test func shrinksImageHeavyPDFAndKeepsText() async throws {
        let input = try pdf()
        let out = try await compress(input, Preset(level: .medium))

        #expect(Fixtures.size(out) < Fixtures.size(input) / 2, "\(Fixtures.size(out)) vs \(Fixtures.size(input))")
        #expect(PDFFixtures.pageCount(out) == 2)
        let text = PDFDocument(url: out)?.string ?? ""
        #expect(text.contains("Hello PDF compression page 1"))
        #expect(text.contains("page 2"))

        let before = try #require(PDFFixtures.render(input))
        let after = try #require(PDFFixtures.render(out))
        #expect(Fixtures.ssim(before, after) > 0.85)
    }

    @Test func recompressesJPEGImagesToo() async throws {
        let input = try pdf(photo: try PDFFixtures.jpegPhoto())
        let out = try await compress(input, Preset(level: .low))
        #expect(Fixtures.size(out) < Fixtures.size(input) * 6 / 10, "\(Fixtures.size(out)) vs \(Fixtures.size(input))")
        #expect(PDFFixtures.pageCount(out) == 2)
    }

    @Test func lowerLevelsGiveSmallerFiles() async throws {
        let input = try pdf()
        var sizes: [Int] = []
        for level in QualityLevel.allCases { sizes.append(Fixtures.size(try await compress(input, Preset(level: level)))) }
        #expect(sizes == sizes.sorted(by: >), "sizes: \(sizes)")
    }

    @Test func maxDimensionShrinksImagesFurther() async throws {
        let input = try pdf()
        let normal = Fixtures.size(try await compress(input, Preset(level: .high)))
        let small = Fixtures.size(try await compress(input, Preset(level: .high, maxDimension: 500)))
        #expect(small < normal)
    }

    @Test func stripRemovesDocumentInfo() async throws {
        let input = try pdf(title: "Secret plans")
        let kept = try await compress(input, Preset(level: .medium, stripMetadata: false))
        let stripped = try await compress(input, Preset(level: .medium, stripMetadata: true))
        let keptTitle = PDFDocument(url: kept)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        let strippedTitle = PDFDocument(url: stripped)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        #expect(keptTitle == "Secret plans")
        #expect(strippedTitle == nil)
        #expect(PDFFixtures.pageCount(stripped) == 2)
    }

    @Test func textOnlyPDFNeverGetsBiggerAndKeepsItsText() async throws {
        let input = try pdf(photo: nil)
        let out = try await compress(input)
        #expect(Fixtures.size(out) <= Fixtures.size(input))
        #expect(PDFFixtures.pageCount(out) == 2)
        #expect((PDFDocument(url: out)?.string ?? "").contains("Hello PDF compression page 1"))
    }

    @Test func encryptedPDFIsLeftAlone() async throws {
        let input = try PDFFixtures.make(
            dir.url.appendingPathComponent("enc.pdf"), photo: PDFFixtures.photo(), ownerPassword: "owner")
        let out = try await compress(input)
        #expect(try Data(contentsOf: out) == Data(contentsOf: input))
    }

    @Test func notAPDFFailsWithClearMessage() async throws {
        let input = try dir.file("fake.pdf", bytes: 200)
        do {
            _ = try await compress(input)
            Issue.record("should have thrown")
        } catch let error as CompressionError {
            #expect(error.localizedDescription.contains("can't be read"))
        }
    }

    // MARK: Structure handling

    @Test(arguments: [false, true])
    func handmadeFilesWithAndWithoutObjectStreams(objectStreams: Bool) async throws {
        let image = try PDFFixtures.rawImage(width: 500, height: 500)
        let data = PDFFixtures.handmade(image: (image, 500, 500), objectStreams: objectStreams)
        let input = dir.url.appendingPathComponent("h.pdf")
        try data.write(to: input)
        #expect(PDFFixtures.pageCount(input) == 1, "fixture itself must be a valid PDF")

        let out = try await compress(input, Preset(level: .medium))
        #expect(Fixtures.size(out) < Fixtures.size(input) * 7 / 10, "\(Fixtures.size(out)) vs \(Fixtures.size(input))")
        #expect(PDFFixtures.pageCount(out) == 1)
        let before = try #require(PDFFixtures.render(input))
        let after = try #require(PDFFixtures.render(out))
        #expect(Fixtures.ssim(before, after) > 0.85)
        let text = String(decoding: try Data(contentsOf: out), as: UTF8.self)
        #expect(text.contains("DCTDecode"))
        #expect(objectStreams == text.contains("/XRef"))
    }

    @Test func softMasksStayLossless() async throws {
        let image = try PDFFixtures.rawImage(width: 500, height: 500)
        let gray = try PNGEncoder.zlib(Data((0..<500 * 500).map { UInt8($0 % 251) }))
        let data = PDFFixtures.handmade(image: (image, 500, 500), smask: (gray, 500, 500), objectStreams: false)
        let input = dir.url.appendingPathComponent("m.pdf")
        try data.write(to: input)
        let out = try await compress(input, Preset(level: .low))

        let file = try PDFFile(try Data(contentsOf: out))
        let mask = try #require(file.object(8))
        #expect(mask.dict?["Filter"]?.nameValue == "FlateDecode")
        #expect(mask.dict?["Width"]?.intValue == 500)
        #expect(file.object(5)?.dict?["Filter"]?.nameValue == "DCTDecode")
    }

    @Test func incrementalUpdatesKeepTheLatestVersion() async throws {
        let image = try PDFFixtures.rawImage(width: 500, height: 500)
        var data = PDFFixtures.handmade(image: (image, 500, 500), objectStreams: false)
        let previous = data.count - ("trailer\n<< /Size 10 /Root 2 0 R >>\nstartxref\n".utf8.count + String(data.count).utf8.count)
        _ = previous
        // Find the original xref offset, then append an update that replaces the page content (object 6).
        let text = String(decoding: data, as: UTF8.self)
        let startxref = Int(text.components(separatedBy: "startxref\n").last!.split(separator: "\n")[0])!
        let newContent = "q 100 0 0 100 0 0 cm /Im0 Do Q"
        let objectOffset = data.count
        data.append(Data("6 0 obj\n<< /Length \(newContent.utf8.count) >>\nstream\n\(newContent)\nendstream\nendobj\n".utf8))
        let tableOffset = data.count
        data.append(Data("xref\n6 1\n\(String(format: "%010d 00000 n \n", objectOffset))trailer\n<< /Size 10 /Root 2 0 R /Prev \(startxref) >>\nstartxref\n\(tableOffset)\n%%EOF\n".utf8))
        let input = dir.url.appendingPathComponent("inc.pdf")
        try data.write(to: input)
        #expect(PDFFixtures.pageCount(input) == 1)

        let out = try await compress(input, Preset(level: .medium))
        let file = try PDFFile(try Data(contentsOf: out))
        let contents = try #require(file.object(6))
        let body = String(decoding: try #require(file.rawStream(contents)), as: UTF8.self)
        #expect(body == newContent)
        #expect(file.trailer["Prev"] == nil)
        #expect(Fixtures.size(out) < Fixtures.size(input))
    }

    @Test func replacesOriginalThroughTheQueue() async throws {
        let input = try pdf()
        let before = Fixtures.size(input)
        let queue = JobQueue(registry: CompressorRegistry([compressor]), maxConcurrent: 1)
        let id = await queue.enqueue(urls: [input], preset: Preset(level: .medium), outputPolicy: .replaceOriginal).accepted[0]
        await queue.waitUntilIdle()
        guard case .completed(let result) = await queue.job(id)?.state else {
            Issue.record("job did not complete: \(String(describing: await queue.job(id)?.state))")
            return
        }
        #expect(result.outcome == .compressed)
        #expect(Fixtures.size(input) < before)
        #expect(PDFFixtures.pageCount(input) == 2)
    }
}

@Suite struct PDFParserTests {
    @Test func parsesCommonObjects() throws {
        var parser = PDFParser(Data("<< /A 1 /B [1 2.5 (x y) <4142> /N true null] /C 12 0 R /D << /E -3 >> >>".utf8))
        let parsed = parser.parseObject()
        let dict = try #require(parsed?.dictValue)
        #expect(dict["A"] == .int(1))
        #expect(dict["C"] == .ref(12, 0))
        #expect(dict["D"]?.dictValue?["E"] == .int(-3))
        let array = try #require(dict["B"]?.arrayValue)
        #expect(array.count == 7)
        #expect(array[1] == .real("2.5"))
        #expect(array[2] == .string(Data("(x y)".utf8)))
    }

    @Test func roundTripsThroughSerialize() throws {
        let source = "<</Type /XObject /Nums [1 2 3] /Ref 5 0 R /S (a\\)b)>>"
        var parser = PDFParser(Data(source.utf8))
        let parsed = parser.parseObject()
        let object = try #require(parsed)
        var out = Data()
        object.serialize(into: &out)
        var again = PDFParser(out)
        #expect(again.parseObject() == object)
    }

    @Test func inflateHandlesZlibStreams() throws {
        let original = Data((0..<5000).map { UInt8($0 % 17) })
        let packed = try PNGEncoder.zlib(original)
        #expect(Inflate.decode(packed) == original)
    }
}
