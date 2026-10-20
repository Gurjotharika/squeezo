import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CompressCore

private enum GIFFixtures {
    /// A static noisy background with a coloured square sliding across it.
    static func animation(frames: Int, width: Int = 160, height: Int = 120, noisy: Bool = true) -> [CGImage] {
        let background = noisy ? Fixtures.photoLike(width: width, height: height, seed: 3) : nil
        return (0..<frames).map { i in
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: Fixtures.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            if let background {
                ctx.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height))
            } else {
                ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.2, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: i * 4 % (width - 30), y: 40, width: 30, height: 30))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: width - 40 - i * 2 % 60, y: 10, width: 24, height: 24))
            return ctx.makeImage()!
        }
    }

    /// Frames with a transparent background and a moving square.
    static func transparentAnimation(frames: Int, width: Int = 80, height: Int = 60) -> [CGImage] {
        (0..<frames).map { i in
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: Fixtures.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(red: 1, green: 0.2, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 4 + i * 3, y: 20, width: 20, height: 20))
            return ctx.makeImage()!
        }
    }

    @discardableResult
    static func write(_ frames: [CGImage], to url: URL, delay: Double = 0.1, loop: Int = 0) throws -> URL {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frames.count, nil)!
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop],
        ] as CFDictionary)
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    struct Decoded {
        var frames: [RGBAImage]
        var delays: [Double]
        var loopCount: Int?
    }

    static func decode(_ url: URL) throws -> Decoded {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        var frames: [RGBAImage] = []
        var delays: [Double] = []
        for i in 0..<CGImageSourceGetCount(source) {
            frames.append(try #require(CGImageSourceCreateImageAtIndex(source, i, nil).flatMap(RGBAImage.init)))
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            delays.append((gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0)
        }
        let fileProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let loop = (fileProps?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        return Decoded(frames: frames, delays: delays, loopCount: loop)
    }
}

@Suite struct GIFEncoderTests {
    private func decode(_ data: Data) throws -> [RGBAImage] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try (0..<CGImageSourceGetCount(source)).map {
            try #require(CGImageSourceCreateImageAtIndex(source, $0, nil).flatMap(RGBAImage.init))
        }
    }

    @Test(arguments: [2, 5, 16, 100, 200, 255])
    func lzwRoundTripsAnyPaletteSize(colors: Int) throws {
        // Big enough to fill the 4096-entry code table several times.
        let width = 300, height = 200
        var rng = Fixtures.SeededRandom(state: UInt64(colors))
        let palette = (0..<colors).map { RGBA8(r: UInt8($0 * 37 % 256), g: UInt8($0 * 91 % 256), b: UInt8($0 * 13 % 256), a: 255) }
        let indices = (0..<width * height).map { i in
            // Mix of runs and noise, like real images.
            i % 50 < 25 ? UInt8(i / 700 % colors) : UInt8(rng.next() % UInt64(colors))
        }
        let frame = GIFEncoder.Frame(
            x: 0, y: 0, width: width, height: height, indices: indices, delay: 10, transparentIndex: nil, disposal: 1)
        let gif = GIFEncoder.encode(width: width, height: height, palette: palette, frames: [frame], loopCount: 0)

        let image = try #require(try decode(gif).first)
        for (i, index) in indices.enumerated() {
            let c = palette[Int(index)]
            #expect(image.pixels[i * 4] == c.r && image.pixels[i * 4 + 1] == c.g && image.pixels[i * 4 + 2] == c.b,
                    "pixel \(i) wrong")
            if image.pixels[i * 4] != c.r { return }
        }
    }

    @Test func subRectangleFramesComposeOverThePreviousOne() throws {
        let palette = [RGBA8(r: 255, g: 0, b: 0, a: 255), RGBA8(r: 0, g: 255, b: 0, a: 255), RGBA8(r: 0, g: 0, b: 0, a: 0)]
        let first = GIFEncoder.Frame(
            x: 0, y: 0, width: 4, height: 4, indices: [UInt8](repeating: 0, count: 16),
            delay: 10, transparentIndex: 2, disposal: 1)
        let second = GIFEncoder.Frame(
            x: 1, y: 1, width: 2, height: 2, indices: [1, 1, 1, 1],
            delay: 10, transparentIndex: 2, disposal: 1)
        let gif = GIFEncoder.encode(width: 4, height: 4, palette: palette, frames: [first, second], loopCount: 0)

        let frames = try decode(gif)
        #expect(frames.count == 2)
        let after = frames[1].pixels
        func rgb(_ x: Int, _ y: Int) -> [UInt8] { Array(after[(y * 4 + x) * 4..<(y * 4 + x) * 4 + 3]) }
        #expect(rgb(0, 0) == [255, 0, 0])
        #expect(rgb(1, 1) == [0, 255, 0])
        #expect(rgb(2, 2) == [0, 255, 0])
        #expect(rgb(3, 3) == [255, 0, 0])
    }
}

@Suite struct GIFCompressorTests {
    let dir: Scratch
    let compressor = GIFCompressor()

    init() throws { dir = try Scratch() }

    private func compress(_ input: URL, _ preset: Preset = .default) async throws -> URL {
        let out = dir.url.appendingPathComponent("out-\(UUID().uuidString).gif")
        try await compressor.compress(input: input, output: out, preset: preset) { _ in }
        return out
    }

    private func gif(_ name: String = "a.gif", frames: Int = 20, noisy: Bool = true, delay: Double = 0.1, loop: Int = 0) throws -> URL {
        try GIFFixtures.write(
            GIFFixtures.animation(frames: frames, noisy: noisy), to: dir.url.appendingPathComponent(name),
            delay: delay, loop: loop)
    }

    @Test func shrinksAnAnimationAndKeepsItLooking() async throws {
        let input = try gif()
        let out = try await compress(input, Preset(level: .high))

        #expect(Fixtures.size(out) < Fixtures.size(input) * 9 / 10, "\(Fixtures.size(out)) vs \(Fixtures.size(input))")
        let before = try GIFFixtures.decode(input)
        let after = try GIFFixtures.decode(out)
        #expect(after.frames.count == before.frames.count)
        #expect(after.frames[0].width == before.frames[0].width)
        for i in [0, 10, 19] {
            #expect(Fixtures.ssim(before.frames[i], after.frames[i]) > 0.8, "frame \(i)")
        }
    }

    @Test func fewColourAnimationIsLossless() async throws {
        let input = try gif(noisy: false)
        let out = try await compress(input, Preset(level: .highest))

        let before = try GIFFixtures.decode(input)
        let after = try GIFFixtures.decode(out)
        #expect(after.frames.count == before.frames.count)
        for i in 0..<before.frames.count {
            #expect(after.frames[i].pixels == before.frames[i].pixels, "frame \(i) differs")
        }
        #expect(Fixtures.size(out) <= Fixtures.size(input))
    }

    @Test func lowerLevelsGiveSmallerFiles() async throws {
        let input = try gif()
        var sizes: [Int] = []
        for level in QualityLevel.allCases { sizes.append(Fixtures.size(try await compress(input, Preset(level: level)))) }
        #expect(sizes == sizes.sorted(by: >), "sizes: \(sizes)")
    }

    @Test func keepsLoopCount() async throws {
        let once = try gif("once.gif", loop: 1)
        #expect(try GIFFixtures.decode(try await compress(once)).loopCount == 1)
        let thrice = try gif("thrice.gif", loop: 3)
        #expect(try GIFFixtures.decode(try await compress(thrice)).loopCount == 3)
        let forever = try gif("forever.gif", loop: 0)
        #expect(try GIFFixtures.decode(try await compress(forever)).loopCount == 0)
    }

    @Test func frameRateCapKeepsTotalDuration() async throws {
        let input = try gif(frames: 20, delay: 0.05)
        let out = try await compress(input, Preset(level: .high, maxFrameRate: 10))
        let after = try GIFFixtures.decode(out)
        #expect(after.frames.count <= 11 && after.frames.count >= 9, "frames: \(after.frames.count)")
        #expect(abs(after.delays.reduce(0, +) - 1.0) < 0.1)
    }

    @Test func resizes() async throws {
        let input = try gif()
        let out = try await compress(input, Preset(level: .high, maxDimension: 80))
        let frame = try #require(try GIFFixtures.decode(out).frames.first)
        #expect(frame.width == 80 && frame.height == 60)
    }

    @Test func keepsTransparency() async throws {
        let input = try GIFFixtures.write(
            GIFFixtures.transparentAnimation(frames: 8), to: dir.url.appendingPathComponent("t.gif"))
        let out = try await compress(input, Preset(level: .highest))
        let before = try GIFFixtures.decode(input)
        let after = try GIFFixtures.decode(out)
        #expect(after.frames.count == before.frames.count)
        for i in 0..<before.frames.count {
            for p in 0..<before.frames[i].width * before.frames[i].height {
                #expect((before.frames[i].pixels[p * 4 + 3] > 127) == (after.frames[i].pixels[p * 4 + 3] > 127),
                        "frame \(i) pixel \(p)")
                if (before.frames[i].pixels[p * 4 + 3] > 127) != (after.frames[i].pixels[p * 4 + 3] > 127) { return }
            }
        }
    }

    @Test func unchangedFramesAreMergedNotRepeated() async throws {
        let still = GIFFixtures.animation(frames: 1, noisy: false)[0]
        let input = try GIFFixtures.write(Array(repeating: still, count: 10), to: dir.url.appendingPathComponent("s.gif"), delay: 0.1)
        let out = try await compress(input, Preset(level: .highest))
        let after = try GIFFixtures.decode(out)
        #expect(after.frames.count == 1)
        #expect(abs(after.delays[0] - 1.0) < 0.05)
    }

    @Test func notAGIFFailsWithClearMessage() async throws {
        let input = try dir.file("fake.gif", bytes: 100)
        do {
            _ = try await compress(input)
            Issue.record("should have thrown")
        } catch let error as CompressionError {
            #expect(error.localizedDescription.contains("can't be read"))
        }
    }

    @Test func replacesOriginalThroughTheQueue() async throws {
        let input = try gif()
        let before = Fixtures.size(input)
        let queue = JobQueue(registry: CompressorRegistry([compressor]), maxConcurrent: 1)
        let id = await queue.enqueue(urls: [input], outputPolicy: .replaceOriginal).accepted[0]
        await queue.waitUntilIdle()
        guard case .completed(let result) = await queue.job(id)?.state else {
            Issue.record("job did not complete")
            return
        }
        #expect(result.outcome == .compressed)
        #expect(Fixtures.size(input) < before)
        #expect(try GIFFixtures.decode(input).frames.count == 20)
    }
}

extension AVTests {
@Suite struct VideoToGIFTests {
    let dir: Scratch
    init() throws { dir = try Scratch() }

    @Test func convertsVideoToGIF() async throws {
        let video = try await VideoFixtures.make(dir.url.appendingPathComponent("v.mp4"), .init(seconds: 1.5))
        let compressor = VideoCompressor()
        let preset = Preset(level: .medium, maxDimension: 240, maxFrameRate: 10, videoToGIF: true)
        #expect(compressor.outputExtension(for: video, preset: preset) == "gif")

        let out = dir.url.appendingPathComponent("v.gif")
        try await compressor.compress(input: video, output: out, preset: preset) { _ in }

        let gif = try GIFFixtures.decode(out)
        #expect(gif.frames[0].width == 240 && gif.frames[0].height == 136)
        #expect(gif.frames.count >= 13 && gif.frames.count <= 16, "frames: \(gif.frames.count)")
        #expect(abs(gif.delays.reduce(0, +) - 1.5) < 0.2)
        #expect(gif.loopCount == 0)
    }

    @Test func limitsLength() async throws {
        let video = try await VideoFixtures.make(dir.url.appendingPathComponent("v.mp4"), .init(seconds: 2))
        let out = dir.url.appendingPathComponent("v.gif")
        let preset = Preset(level: .low, maxDimension: 160, maxFrameRate: 10, videoToGIF: true, gifMaxSeconds: 0.5)
        try await VideoCompressor().compress(input: video, output: out, preset: preset) { _ in }
        let gif = try GIFFixtures.decode(out)
        #expect(abs(gif.delays.reduce(0, +) - 0.5) < 0.15)
    }
}
}
