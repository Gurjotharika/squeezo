import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import CompressCore

@Suite struct ImageEditorTests {
    let dir: Scratch
    init() throws { dir = try Scratch() }

    /// 40×20: red top-left, green top-right, blue bottom-left, white bottom-right.
    private func quadrants(width: Int = 40, height: Int = 20) throws -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: Fixtures.sRGB,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) {
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1)); ctx.fill(rect)
        }
        let hw = CGFloat(width) / 2, hh = CGFloat(height) / 2
        fill(1, 0, 0, CGRect(x: 0, y: hh, width: hw, height: hh))      // top-left (CG origin is bottom-left)
        fill(0, 1, 0, CGRect(x: hw, y: hh, width: hw, height: hh))     // top-right
        fill(0, 0, 1, CGRect(x: 0, y: 0, width: hw, height: hh))       // bottom-left
        fill(1, 1, 1, CGRect(x: hw, y: 0, width: hw, height: hh))      // bottom-right
        return ctx.makeImage()!
    }

    private func source(_ name: String = "a.png", image: CGImage? = nil, type: String = "public.png", properties: [CFString: Any] = [:]) throws -> URL {
        try Fixtures.write(try image ?? quadrants(), type: type, to: dir.url.appendingPathComponent(name), quality: type == "public.png" ? nil : 1.0, properties: properties)
    }

    private func run(_ family: OperationFamily, _ operation: ToolAction, input: URL, strip: Bool = false) async throws -> URL {
        let editor = ImageEditor(family)
        let preset = Preset(stripMetadata: strip, operation: operation)
        let out = dir.url.appendingPathComponent("out-\(UUID().uuidString).\(editor.outputExtension(for: input, preset: preset))")
        try await editor.compress(input: input, output: out, preset: preset) { _ in }
        return out
    }

    private func pixel(_ image: RGBAImage, _ x: Int, _ y: Int) -> [Int] {
        (0..<3).map { Int(image.pixels[(y * image.width + x) * 4 + $0]) }
    }

    private func close(_ a: [Int], _ b: [Int], tolerance: Int = 12) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    // MARK: Resize

    @Test func resizeFitsLongestSide() async throws {
        let input = try source(image: try quadrants(width: 400, height: 200))
        let out = try await run(.resize, .resize(ResizeSpec(mode: .fit(maxSide: 100))), input: input)
        let image = try #require(Fixtures.cgImage(at: out))
        #expect(image.width == 100 && image.height == 50)
    }

    @Test func resizeByPercent() async throws {
        let input = try source(image: try quadrants(width: 400, height: 200))
        let out = try await run(.resize, .resize(ResizeSpec(mode: .percent(25))), input: input)
        let image = try #require(Fixtures.cgImage(at: out))
        #expect(image.width == 100 && image.height == 50)
    }

    @Test func resizeNeverEnlargesUnlessAllowed() async throws {
        let input = try source()
        let kept = try #require(Fixtures.cgImage(at: try await run(.resize, .resize(ResizeSpec(mode: .fit(maxSide: 400))), input: input)))
        #expect(kept.width == 40)
        let grown = try #require(Fixtures.cgImage(at: try await run(.resize, .resize(ResizeSpec(mode: .fit(maxSide: 400), allowEnlarge: true)), input: input)))
        #expect(grown.width == 400 && grown.height == 200)
    }

    @Test func exactSizeWithCropFillsTheFrame() async throws {
        let input = try source(image: try quadrants(width: 400, height: 200))
        let out = try await run(.resize, .resize(ResizeSpec(mode: .exact(width: 100, height: 100, crop: true))), input: input)
        let image = try #require(Fixtures.rgba(at: out))
        #expect(image.width == 100 && image.height == 100)
        // The centre square keeps the left/right halves' colours at its edges.
        #expect(close(pixel(image, 5, 5), [255, 0, 0]) || close(pixel(image, 5, 5), [0, 255, 0]))
    }

    // MARK: Crop

    @Test func cropKeepsTheChosenArea() async throws {
        let input = try source()
        // The right half of the picture: green over white.
        let out = try await run(.crop, .crop(NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)), input: input)
        let image = try #require(Fixtures.rgba(at: out))
        #expect(image.width == 20 && image.height == 20)
        #expect(close(pixel(image, 10, 3), [0, 255, 0]))
        #expect(close(pixel(image, 10, 16), [255, 255, 255]))
    }

    @Test func cropAreaIsKeptInsideThePicture() {
        let rect = NormalizedRect(x: 0.9, y: -0.2, width: 0.5, height: 2).clamped
        #expect(rect.x + rect.width <= 1.0001 && rect.y >= 0 && rect.height <= 1)
        #expect(NormalizedRect.full.isFull)
    }

    // MARK: Rotate and flip

    @Test func rotatingRightMovesTopLeftToTopRight() async throws {
        let input = try source()
        let out = try await run(.rotate, .rotate(RotateSpec(quarterTurns: 1)), input: input)
        let image = try #require(Fixtures.rgba(at: out))
        #expect(image.width == 20 && image.height == 40)
        #expect(close(pixel(image, 17, 3), [255, 0, 0]), "red was top-left, now top-right")
        #expect(close(pixel(image, 17, 36), [0, 255, 0]), "green was top-right, now bottom-right")
        #expect(close(pixel(image, 3, 3), [0, 0, 255]), "blue was bottom-left, now top-left")
    }

    @Test func halfTurnAndFlips() async throws {
        let input = try source()
        let turned = try #require(Fixtures.rgba(at: try await run(.rotate, .rotate(RotateSpec(quarterTurns: 2)), input: input)))
        #expect(close(pixel(turned, 36, 16), [255, 0, 0]), "red ends up bottom-right")
        let flipped = try #require(Fixtures.rgba(at: try await run(.rotate, .rotate(RotateSpec(quarterTurns: 0, flipHorizontal: true)), input: input)))
        #expect(close(pixel(flipped, 3, 3), [0, 255, 0]), "green is now top-left")
        let flippedV = try #require(Fixtures.rgba(at: try await run(.rotate, .rotate(RotateSpec(quarterTurns: 0, flipVertical: true)), input: input)))
        #expect(close(pixel(flippedV, 3, 3), [0, 0, 255]), "blue is now top-left")
    }

    @Test func exifOrientationIsAppliedBeforeEditing() async throws {
        // A 40×20 picture marked "rotate 90°" is really 20×40 on screen.
        let input = try source("o.jpg", type: "public.jpeg", properties: [kCGImagePropertyOrientation: 6])
        let out = try await run(.resize, .resize(ResizeSpec(mode: .fit(maxSide: 1000))), input: input)
        let image = try #require(Fixtures.cgImage(at: out))
        #expect(image.width == 20 && image.height == 40)
        #expect((Fixtures.properties(at: out)[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    // MARK: Convert

    @Test func convertsPNGToJPEGWithAWhiteBackground() async throws {
        let ctx = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: Fixtures.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: 20, height: 20))
        let input = try source("t.png", image: ctx.makeImage()!)
        let editor = ImageEditor(.convert)
        let preset = Preset(operation: .convert(ConvertSpec(target: .image(.jpeg))))
        #expect(editor.outputExtension(for: input, preset: preset) == "jpg")
        let out = try await run(.convert, preset.operation, input: input)
        let image = try #require(Fixtures.rgba(at: out))
        #expect(close(pixel(image, 10, 10), [255, 255, 255], tolerance: 6), "transparent became white, not black")
    }

    @Test(arguments: [ImageFormat.png, .tiff, .heic])
    func convertsJPEGTo(format: ImageFormat) async throws {
        let input = try source("a.jpg", image: Fixtures.photoLike(width: 200, height: 150), type: "public.jpeg")
        let out = try await run(.convert, .convert(ConvertSpec(target: .image(format))), input: input)
        #expect(out.pathExtension == format.fileExtension)
        let type = CGImageSourceCreateWithURL(out as CFURL, nil).flatMap { CGImageSourceGetType($0) } as String?
        #expect(type == format.typeIdentifier)
    }

    @Test func imageToPDFMakesOnePage() async throws {
        let input = try source()
        let out = try await run(.convert, .convert(ConvertSpec(target: .imageToPDF)), input: input)
        #expect(out.pathExtension == "pdf")
        #expect(PDFDocument(url: out)?.pageCount == 1)
    }

    @Test func unwritableFormatsBecomePNGWhenEdited() {
        let editor = ImageEditor(.resize)
        #expect(editor.outputExtension(for: URL(fileURLWithPath: "/x/a.bmp"), preset: Preset(operation: .resize(ResizeSpec()))) == "png")
    }

    // MARK: Upscale

    @Test func upscaleEnlargesBySetFactor() async throws {
        let input = try source(image: Fixtures.photoLike(width: 120, height: 80))
        let out = try await run(.upscale, .upscale(UpscaleSpec(factor: 3, sharpness: 0.5)), input: input)
        let image = try #require(Fixtures.cgImage(at: out))
        #expect(image.width == 360 && image.height == 240)
    }

    @Test func upscaleRefusesAbsurdSizes() async throws {
        let input = try source(image: Fixtures.photoLike(width: 4200, height: 100))
        do {
            _ = try await run(.upscale, .upscale(UpscaleSpec(factor: 4)), input: input)
            Issue.record("should have thrown")
        } catch let error as CompressionError {
            #expect(error.localizedDescription.contains("too big"))
        }
    }

    // MARK: Watermark

    @Test func textWatermarkChangesOnlyNearItsCorner() async throws {
        let base = Fixtures.photoLike(width: 600, height: 400)
        let input = try source(image: base)
        let spec = WatermarkSpec(content: .text("© Test"), position: .bottomRight, scale: 0.3, opacity: 1)
        let out = try await run(.watermark, .watermark(spec), input: input)
        let before = try #require(Fixtures.rgba(at: input))
        let after = try #require(Fixtures.rgba(at: out))
        #expect(after.width == before.width)

        func changed(in x: Range<Int>, _ y: Range<Int>) -> Int {
            var count = 0
            for yy in y { for xx in x where pixel(before, xx, yy) != pixel(after, xx, yy) { count += 1 } }
            return count
        }
        #expect(changed(in: 400..<600, 330..<400) > 200, "the mark is drawn bottom right")
        #expect(changed(in: 0..<200, 0..<60) == 0, "the top-left corner is untouched")
    }

    @Test func tiledWatermarkCoversTheWholePicture() async throws {
        let input = try source(image: Fixtures.photoLike(width: 600, height: 400))
        let spec = WatermarkSpec(content: .text("DRAFT"), position: .tiled, scale: 0.2, opacity: 1, rotationDegrees: -30)
        let out = try await run(.watermark, .watermark(spec), input: input)
        let before = try #require(Fixtures.rgba(at: input))
        let after = try #require(Fixtures.rgba(at: out))
        var corners = 0
        for (x, y) in [(50, 50), (500, 60), (60, 340), (520, 350)] {
            // Search a window around each corner for any change.
            var any = false
            for yy in max(0, y - 40)..<min(400, y + 40) { for xx in max(0, x - 40)..<min(600, x + 40) where pixel(before, xx, yy) != pixel(after, xx, yy) { any = true } }
            if any { corners += 1 }
        }
        #expect(corners >= 3)
    }

    @Test func imageWatermarkUsesTheLogo() async throws {
        let logoURL = try source("logo.png", image: try quadrants(width: 50, height: 50))
        let input = try source("base.png", image: Fixtures.photoLike(width: 400, height: 300))
        let spec = WatermarkSpec(content: .image(path: logoURL.path), position: .center, scale: 0.3, opacity: 1)
        let out = try await run(.watermark, .watermark(spec), input: input)
        let after = try #require(Fixtures.rgba(at: out))
        // The logo's red quadrant lands left of centre, above the middle line.
        #expect(close(pixel(after, 170, 130), [255, 0, 0], tolerance: 30))
    }

    // MARK: Obscuring

    @Test func obscuringChangesOnlyTheRegion() throws {
        let base = Fixtures.photoLike(width: 300, height: 200)
        let region = NormalizedRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)
        let result = try ImageTools.obscure(base, regions: [region], spec: BlurSpec(style: .pixelate, strength: 0.8))
        let before = try #require(RGBAImage(base)), after = try #require(RGBAImage(result))
        var insideChanged = 0, outsideChanged = 0
        for y in 0..<200 {
            for x in 0..<300 where pixel(before, x, y) != pixel(after, x, y) {
                let inside = x > 110 && x < 190 && y > 55 && y < 125
                if inside { insideChanged += 1 } else if x < 80 || x > 220 || y < 30 || y > 150 { outsideChanged += 1 }
            }
        }
        #expect(insideChanged > 500)
        #expect(outsideChanged == 0)
    }

    @Test func solidStyleCoversWithBlack() throws {
        let base = Fixtures.photoLike(width: 200, height: 200)
        let result = try ImageTools.obscure(base, regions: [NormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)], spec: BlurSpec(style: .solid))
        let after = try #require(RGBAImage(result))
        #expect(close(pixel(after, 100, 100), [0, 0, 0], tolerance: 8))
    }

    @Test func blurringFacesFailsClearlyWhenThereAreNone() async throws {
        let input = try source(image: Fixtures.photoLike(width: 300, height: 200))
        do {
            _ = try await run(.blurFaces, .blurFaces(BlurSpec()), input: input)
            Issue.record("should have thrown")
        } catch let error as CompressionError {
            #expect(error.localizedDescription.contains("No faces"))
        }
    }

    @Test func removeBackgroundEitherWorksOrExplainsWhy() async throws {
        let input = try source(image: Fixtures.photoLike(width: 300, height: 200))
        do {
            let out = try await run(.removeBackground, .removeBackground, input: input)
            #expect(out.pathExtension == "png")
        } catch let error as CompressionError {
            #expect(error.localizedDescription.contains("subject") || error.localizedDescription.contains("background"))
        }
    }

    // MARK: Through the queue

    @Test func nonCompressionResultsAreKeptEvenWhenLarger() async throws {
        let input = try source(image: Fixtures.photoLike(width: 100, height: 80))
        let before = Fixtures.size(input)
        let queue = JobQueue(registry: CompressorRegistry([ImageEditor(.upscale)]), maxConcurrent: 1)
        let preset = Preset(operation: .upscale(UpscaleSpec(factor: 2)))
        let id = await queue.enqueue(urls: [input], preset: preset, outputPolicy: .suffix("-upscaled")).accepted[0]
        await queue.waitUntilIdle()
        guard case .completed(let result) = await queue.job(id)?.state else {
            Issue.record("job did not complete: \(String(describing: await queue.job(id)?.state))")
            return
        }
        #expect(result.outcome == .processed)
        #expect(result.outputBytes > Int64(before))
        #expect(result.outputURL.lastPathComponent == "a-upscaled.png")
    }

    @Test func theQueueFindsTheEngineForTheTool() async throws {
        let input = try source()
        let queue = JobQueue(registry: CompressorRegistry([ImageEditor(.rotate)]), maxConcurrent: 1)
        // No resize engine is registered, so this must fail rather than run the wrong tool.
        let id = await queue.enqueue(urls: [input], preset: Preset(operation: .resize(ResizeSpec())), outputPolicy: .suffix("-x")).accepted[0]
        await queue.waitUntilIdle()
        guard case .failed = await queue.job(id)?.state else {
            Issue.record("should fail without a matching engine")
            return
        }
    }
}

@Suite struct EngineCoverageTests {
    private let registry = Engines.registry()

    @Test func everyToolHasAnEngineForTheFilesItAccepts() {
        let coverage: [OperationFamily: [MediaKind]] = [
            .compress: [.image, .video, .gif, .pdf, .document, .audio],
            .resize: [.image, .video, .gif],
            .crop: [.image, .video, .gif, .pdf],
            .rotate: [.image, .video, .gif, .pdf],
            .convert: [.image, .video, .gif, .pdf, .audio],
            .upscale: [.image, .video],
            .watermark: [.image, .video, .gif, .pdf],
            .blurFaces: [.image, .video],
            .removeBackground: [.image],
            .extractText: [.pdf, .image],
            .merge: [.pdf, .image],
            .split: [.pdf],
        ]
        for (family, kinds) in coverage {
            for kind in kinds { #expect(registry.supports(family, on: kind), "\(family) on \(kind)") }
        }
        #expect(OperationFamily.allCases.count == coverage.count, "a new tool needs a row here")
    }

    @Test func unsupportedCombinationsAreReportedAsUnsupported() {
        #expect(!registry.supports(.crop, on: .audio))
        #expect(!registry.supports(.upscale, on: .pdf))
        #expect(!registry.supports(.split, on: .image))
        #expect(!registry.supports(.convert, on: .document))
    }

    @Test func videoConversionPicksTheRightSpecialist() {
        let engine = ConvertEngine(kind: .video)
        let url = URL(fileURLWithPath: "/x/a.mov")
        #expect(engine.outputExtension(for: url, preset: Preset(operation: .convert(ConvertSpec(target: .video(.mp4))))) == "mp4")
        #expect(engine.outputExtension(for: url, preset: Preset(operation: .convert(ConvertSpec(target: .videoToAudio(.wav))))) == "wav")
        #expect(engine.outputExtension(for: url, preset: Preset(operation: .convert(ConvertSpec(target: .video(.gif))))) == "gif")
    }

    @Test func actionsSurviveEncoding() throws {
        let actions: [ToolAction] = [
            .compress, .resize(ResizeSpec(mode: .exact(width: 10, height: 20, crop: true))), .crop(NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)),
            .rotate(RotateSpec(quarterTurns: 3, flipHorizontal: true)), .convert(ConvertSpec(target: .pdfToImages(.png, dpi: 150))),
            .watermark(WatermarkSpec(content: .image(path: "/x/logo.png"))), .split(SplitSpec(mode: .ranges("1-3"))),
        ]
        for action in actions {
            let data = try JSONEncoder().encode(Preset(operation: action))
            #expect(try JSONDecoder().decode(Preset.self, from: data).operation == action)
        }
    }
}
