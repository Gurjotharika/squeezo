import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CompressCore

@Suite struct ImageCompressorTests {
    let dir: Scratch
    let compressor = ImageCompressor()

    init() throws { dir = try Scratch() }

    private func compress(_ input: URL, _ preset: Preset = .default, ext: String? = nil) async throws -> URL {
        let out = dir.url.appendingPathComponent("out-\(UUID().uuidString)")
            .appendingPathExtension(ext ?? compressor.outputExtension(for: input, preset: preset))
        try await compressor.compress(input: input, output: out, preset: preset) { _ in }
        return out
    }

    private func photo(_ name: String, type: String, width: Int = 800, height: Int = 600,
                       quality: Double? = 1.0, properties: [CFString: Any] = [:]) throws -> URL {
        try Fixtures.write(
            Fixtures.photoLike(width: width, height: height), type: type,
            to: dir.url.appendingPathComponent(name), quality: quality, properties: properties)
    }

    // MARK: JPEG

    @Test func jpegGetsSmallerAndStaysSimilar() async throws {
        let input = try photo("a.jpg", type: "public.jpeg")
        let out = try await compress(input, Preset(level: .high))

        #expect(Fixtures.size(out) < Fixtures.size(input) / 2)
        let before = try #require(Fixtures.rgba(at: input))
        let after = try #require(Fixtures.rgba(at: out))
        #expect(after.width == before.width && after.height == before.height)
        #expect(Fixtures.ssim(before, after) > 0.9)
    }

    @Test func lowerLevelsGiveSmallerFiles() async throws {
        let input = try photo("a.jpg", type: "public.jpeg")
        var sizes: [Int] = []
        for level in [QualityLevel.highest, .high, .medium, .low] {
            sizes.append(Fixtures.size(try await compress(input, Preset(level: level))))
        }
        #expect(sizes == sizes.sorted(by: >), "sizes should shrink with level: \(sizes)")
        #expect(Set(sizes).count == 4)
    }

    @Test func qualityStaysAboveFloorAtEveryLevel() async throws {
        let input = try photo("a.jpg", type: "public.jpeg")
        let before = try #require(Fixtures.rgba(at: input))
        let floors: [QualityLevel: Double] = [.highest: 0.95, .high: 0.93, .medium: 0.85, .low: 0.7]
        for (level, floor) in floors {
            let after = try #require(Fixtures.rgba(at: try await compress(input, Preset(level: level))))
            let score = Fixtures.ssim(before, after)
            #expect(score > floor, "\(level) SSIM \(score) should exceed \(floor)")
        }
    }

    // MARK: Metadata

    private var taggedProperties: [CFString: Any] {
        [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 77.5, kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret note"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam"],
        ]
    }

    @Test func keepsMetadataByDefault() async throws {
        let input = try photo("a.jpg", type: "public.jpeg", properties: taggedProperties)
        let out = try await compress(input, Preset(level: .high, stripMetadata: false))
        let props = Fixtures.properties(at: out)

        #expect(props[kCGImagePropertyGPSDictionary] != nil)
        #expect((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String == "TestCam")
        #expect(props[kCGImagePropertyOrientation] as? Int == 6)
    }

    @Test func stripRemovesLocationAndCameraButKeepsOrientation() async throws {
        let input = try photo("a.jpg", type: "public.jpeg", properties: taggedProperties)
        let out = try await compress(input, Preset(level: .high, stripMetadata: true))
        let props = Fixtures.properties(at: out)

        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
        #expect(props[kCGImagePropertyOrientation] as? Int == 6, "image must not turn sideways")
    }

    // MARK: Resize

    @Test func resizesLongestSide() async throws {
        let input = try photo("a.jpg", type: "public.jpeg", width: 1200, height: 800)
        let out = try await compress(input, Preset(level: .high, maxDimension: 600))
        let image = try #require(Fixtures.cgImage(at: out))
        #expect(max(image.width, image.height) == 600)
        #expect(image.width == 600 && image.height == 400)
    }

    @Test func doesNotUpscaleSmallImages() async throws {
        let input = try photo("a.jpg", type: "public.jpeg", width: 400, height: 300)
        let out = try await compress(input, Preset(level: .high, maxDimension: 2000))
        let image = try #require(Fixtures.cgImage(at: out))
        #expect(image.width == 400 && image.height == 300)
    }

    @Test func resizingAppliesOrientationSoImageStaysUpright() async throws {
        let input = try photo("a.jpg", type: "public.jpeg", width: 1200, height: 800,
                              properties: [kCGImagePropertyOrientation: 6])
        let out = try await compress(input, Preset(level: .high, maxDimension: 600))
        let image = try #require(Fixtures.cgImage(at: out))
        // Rotated 90°: displayed portrait, so the long side is the height.
        #expect(image.height == 600 && image.width == 400)
        #expect((Fixtures.properties(at: out)[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    // MARK: Other formats

    @Test func heicGetsSmaller() async throws {
        let input = try photo("a.heic", type: "public.heic")
        let out = try await compress(input, Preset(level: .medium))
        #expect(Fixtures.size(out) < Fixtures.size(input))
        #expect(Fixtures.cgImage(at: out) != nil)
    }

    @Test func avifGetsSmaller() async throws {
        let input = try photo("a.avif", type: "public.avif", quality: 0.95)
        let out = try await compress(input, Preset(level: .low))
        #expect(Fixtures.size(out) < Fixtures.size(input))
        #expect(Fixtures.cgImage(at: out) != nil)
    }

    @Test func tiffIsCompressedLosslessly() async throws {
        let input = try photo("a.tiff", type: "public.tiff", quality: nil)
        let out = try await compress(input, Preset(level: .high))
        #expect(Fixtures.size(out) < Fixtures.size(input))
        let before = try #require(Fixtures.rgba(at: input))
        let after = try #require(Fixtures.rgba(at: out))
        #expect(before.pixels == after.pixels)
    }

    @Test func bmpBecomesPNG() async throws {
        let input = try photo("a.bmp", type: "com.microsoft.bmp", quality: nil)
        #expect(compressor.outputExtension(for: input, preset: .default) == "png")
        let out = try await compress(input)
        #expect(Fixtures.size(out) < Fixtures.size(input))
        let type = CGImageSourceCreateWithURL(out as CFURL, nil).flatMap { CGImageSourceGetType($0) } as String?
        #expect(type == "public.png")
    }

    @Test func unsupportedFormatFailsWithClearMessage() async throws {
        let input = try photo("a.jp2", type: "public.jpeg-2000")
        do {
            _ = try await compress(input)
            Issue.record("should have thrown")
        } catch let error as CompressionError {
            #expect(error.localizedDescription.contains("aren't supported"))
        }
    }

    @Test func notAnImageFailsWithClearMessage() async throws {
        let input = try dir.file("fake.jpg", bytes: 100)
        do {
            _ = try await compress(input)
            Issue.record("should have thrown")
        } catch let error as CompressionError {
            #expect(error.localizedDescription.contains("can't be read"))
        }
    }

    // MARK: PNG

    @Test func losslessPNGKeepsEveryPixel() async throws {
        let input = try photo("a.png", type: "public.png", quality: nil)
        let out = try await compress(input, Preset(level: .highest))
        let before = try #require(Fixtures.rgba(at: input))
        let after = try #require(Fixtures.rgba(at: out))
        #expect(before.pixels == after.pixels)
        // Size isn't asserted: a re-encode of an already-optimal PNG can be a few bytes larger,
        // and the queue keeps the original in that case.
    }

    @Test func fewColourPNGBecomesExactPalette() async throws {
        let input = try Fixtures.write(
            Fixtures.graphic(width: 500, height: 400), type: "public.png",
            to: dir.url.appendingPathComponent("g.png"), quality: nil)
        let out = try await compress(input, Preset(level: .highest))

        #expect(Fixtures.size(out) < Fixtures.size(input) / 2)
        let before = try #require(Fixtures.rgba(at: input))
        let after = try #require(Fixtures.rgba(at: out))
        #expect(after.width == before.width)
        // Exact palette: every visible pixel identical, transparent pixels stay transparent.
        for i in 0..<before.width * before.height {
            let a = before.pixels[i * 4 + 3]
            #expect(after.pixels[i * 4 + 3] == a)
            if a > 0 {
                for k in 0..<3 { #expect(abs(Int(after.pixels[i * 4 + k]) - Int(before.pixels[i * 4 + k])) <= 1) }
            }
        }
    }

    @Test func lossyPNGShrinksALotAndStaysSimilar() async throws {
        let input = try photo("a.png", type: "public.png", width: 500, height: 400, quality: nil)
        let out = try await compress(input, Preset(level: .medium))

        #expect(Fixtures.size(out) < Fixtures.size(input) / 2)
        let before = try #require(Fixtures.rgba(at: input))
        let after = try #require(Fixtures.rgba(at: out))
        #expect(Fixtures.ssim(before, after) > 0.8)
    }

    @Test func lowerPNGLevelIsSmaller() async throws {
        let input = try photo("a.png", type: "public.png", width: 500, height: 400, quality: nil)
        let medium = Fixtures.size(try await compress(input, Preset(level: .medium)))
        let low = Fixtures.size(try await compress(input, Preset(level: .low)))
        #expect(low < medium)
    }

    @Test func pngResizeWorks() async throws {
        let input = try photo("a.png", type: "public.png", width: 800, height: 400, quality: nil)
        let out = try await compress(input, Preset(level: .medium, maxDimension: 200))
        let image = try #require(Fixtures.cgImage(at: out))
        #expect(image.width == 200 && image.height == 100)
    }

    // MARK: Queue integration

    @Test func replacesOriginalWithSmallerValidFile() async throws {
        let input = try photo("a.jpg", type: "public.jpeg")
        let before = Fixtures.size(input)
        let queue = JobQueue(registry: CompressorRegistry([ImageCompressor()]), maxConcurrent: 1)

        let id = await queue.enqueue(urls: [input], outputPolicy: .replaceOriginal).accepted[0]
        await queue.waitUntilIdle()

        guard case .completed(let result) = await queue.job(id)?.state else {
            Issue.record("job did not complete: \(String(describing: await queue.job(id)?.state))")
            return
        }
        #expect(result.outcome == .compressed)
        #expect(Fixtures.size(input) < before)
        #expect(Fixtures.cgImage(at: input) != nil)
        #expect(try dir.contents() == ["a.jpg"])
    }

    @Test func alreadySmallFileIsLeftAlone() async throws {
        let input = try photo("a.jpg", type: "public.jpeg", quality: 0.3)
        let original = try Data(contentsOf: input)
        let queue = JobQueue(registry: CompressorRegistry([ImageCompressor()]), maxConcurrent: 1)

        let id = await queue.enqueue(urls: [input], preset: Preset(level: .highest), outputPolicy: .replaceOriginal).accepted[0]
        await queue.waitUntilIdle()

        guard case .completed(let result) = await queue.job(id)?.state else {
            Issue.record("job did not complete")
            return
        }
        #expect(result.outcome == .keptOriginal)
        #expect(try Data(contentsOf: input) == original)
    }
}
