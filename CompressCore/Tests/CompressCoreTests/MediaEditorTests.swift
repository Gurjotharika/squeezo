import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CompressCore

extension AVTests {
@Suite struct VideoEditorTests {
    let dir: Scratch
    init() throws { dir = try Scratch() }

    private func video(_ name: String = "v.mp4", _ spec: VideoFixtures.Spec = .init()) async throws -> URL {
        try await VideoFixtures.make(dir.url.appendingPathComponent(name), spec)
    }

    private func edit(_ family: OperationFamily, _ action: ToolAction, input: URL) async throws -> URL {
        let editor = VideoEditor(family)
        let preset = Preset(operation: action)
        let out = dir.url.appendingPathComponent("out-\(UUID().uuidString).\(editor.outputExtension(for: input, preset: preset))")
        try await editor.compress(input: input, output: out, preset: preset) { _ in }
        return out
    }

    private func frame(_ url: URL, at seconds: Double = 0.5) async throws -> RGBAImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return try #require(RGBAImage(image))
    }

    @Test func resizeScalesTheWholeVideo() async throws {
        let input = try await video("a.mp4", .init(width: 640, height: 360))
        let out = try await edit(.resize, .resize(ResizeSpec(mode: .fit(maxSide: 320))), input: input)
        let info = try await VideoInfo.read(out)
        #expect(info.size == CGSize(width: 320, height: 180))
        let before = try await VideoInfo.read(input)
        #expect(abs(info.duration - before.duration) < 0.1)
        #expect(info.frameCount == before.frameCount)
    }

    @Test func exactSizeWithCropFillsTheFrame() async throws {
        let input = try await video("a.mp4", .init(width: 640, height: 360))
        let out = try await edit(.resize, .resize(ResizeSpec(mode: .exact(width: 200, height: 200, crop: true))), input: input)
        #expect(try await VideoInfo.read(out).size == CGSize(width: 200, height: 200))
    }

    @Test func cropKeepsTheChosenArea() async throws {
        let input = try await video("a.mp4", .init(width: 640, height: 360))
        let out = try await edit(.crop, .crop(NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)), input: input)
        let info = try await VideoInfo.read(out)
        #expect(info.size == CGSize(width: 320, height: 360))
        // The right half of the source is brighter (the fixture is a left-to-right gradient).
        let cropped = try await frame(out), original = try await frame(input)
        func brightness(_ image: RGBAImage, _ x: Range<Int>) -> Double {
            var total = 0.0, n = 0.0
            for y in 100..<200 { for xx in x { total += Double(image.pixels[(y * image.width + xx) * 4]); n += 1 } }
            return total / n
        }
        #expect(abs(brightness(cropped, 10..<100) - brightness(original, 330..<420)) < 40)
    }

    @Test func rotateTurnsTheVideoOnItsSide() async throws {
        let input = try await video("a.mp4", .init(width: 480, height: 272))
        let out = try await edit(.rotate, .rotate(RotateSpec(quarterTurns: 1)), input: input)
        let info = try await VideoInfo.read(out)
        #expect(info.size == CGSize(width: 272, height: 480))
        #expect(abs(info.transform.b) < 0.01 && abs(info.transform.c) < 0.01, "the turn is in the pixels, not a flag")
    }

    @Test func editingStartsFromHowTheVideoIsShown() async throws {
        // A clip stored sideways and marked "turn 90°" is shown as 272×480.
        let input = try await video("p.mov", .init(width: 480, height: 272, transform: CGAffineTransform(rotationAngle: .pi / 2), fileType: .mov))
        let out = try await edit(.resize, .resize(ResizeSpec(mode: .fit(maxSide: 240))), input: input)
        #expect(try await VideoInfo.read(out).size == CGSize(width: 136, height: 240))
    }

    @Test func upscaleEnlargesFrames() async throws {
        let input = try await video("a.mp4", .init(width: 320, height: 180))
        let out = try await edit(.upscale, .upscale(UpscaleSpec(factor: 2)), input: input)
        #expect(try await VideoInfo.read(out).size == CGSize(width: 640, height: 360))
    }

    @Test func upscaleRefusesHugeResults() async throws {
        let input = try await video("a.mp4", .init(width: 480, height: 272))
        do {
            _ = try VideoEditor.plan(for: .upscale(UpscaleSpec(factor: 4)), display: CGSize(width: 3840, height: 2160))
            Issue.record("should have thrown")
            _ = input
        } catch let error as CompressionError {
            #expect(error.localizedDescription.contains("too big"))
        }
    }

    @Test func watermarkMarksEveryFrame() async throws {
        let input = try await video("a.mp4", .init(width: 640, height: 360))
        let spec = WatermarkSpec(content: .text("DRAFT"), position: .bottomRight, scale: 0.3, opacity: 1)
        let out = try await edit(.watermark, .watermark(spec), input: input)
        // The mark is white text, so count nearly white pixels where it should and shouldn't be.
        let after = try await frame(out)
        func white(_ x: Range<Int>, _ y: Range<Int>) -> Int {
            var count = 0
            for yy in y { for xx in x {
                let i = (yy * 640 + xx) * 4
                if after.pixels[i] > 235, after.pixels[i + 1] > 235, after.pixels[i + 2] > 235 { count += 1 }
            } }
            return count
        }
        #expect(white(430..<620, 290..<350) > 600, "the mark is bottom right")
        #expect(white(10..<200, 10..<70) < 100, "the top-left corner has none")
    }

    @Test func hidingFacesOnAVideoWithoutFacesStillProducesAVideo() async throws {
        let input = try await video("a.mp4", .init(width: 320, height: 180))
        let out = try await edit(.blurFaces, .blurFaces(BlurSpec()), input: input)
        let info = try await VideoInfo.read(out)
        #expect(info.size == CGSize(width: 320, height: 180) && info.frameCount > 20)
    }

    @Test func soundIsKept() async throws {
        let input = try await video("a.mp4", .init(audio: .aac))
        let out = try await edit(.resize, .resize(ResizeSpec(mode: .percent(50))), input: input)
        let info = try await VideoInfo.read(out)
        #expect(info.audioTrackCount == 1)
        #expect(abs(info.duration - 1.5) < 0.25)
    }

    @Test func convertsContainer() async throws {
        let input = try await video("a.mp4")
        let compressor = VideoCompressor(family: .convert)
        let preset = Preset(level: .highest, operation: .convert(ConvertSpec(target: .video(.mov))))
        #expect(compressor.outputExtension(for: input, preset: preset) == "mov")
        let out = dir.url.appendingPathComponent("c.mov")
        try await compressor.compress(input: input, output: out, preset: preset) { _ in }
        #expect(try await VideoInfo.read(out).frameCount == (try await VideoInfo.read(input)).frameCount)
    }

    @Test func convertsToGIF() async throws {
        let input = try await video("a.mp4", .init(width: 320, height: 180, seconds: 1))
        let compressor = VideoCompressor(family: .convert)
        let preset = Preset(operation: .convert(ConvertSpec(target: .video(.gif))))
        #expect(compressor.outputExtension(for: input, preset: preset) == "gif")
        let out = dir.url.appendingPathComponent("c.gif")
        try await compressor.compress(input: input, output: out, preset: preset) { _ in }
        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        #expect(CGImageSourceGetCount(source) > 5)
    }
}

@Suite struct AudioConversionTests {
    let dir: Scratch
    init() throws { dir = try Scratch() }

    private func convert(_ input: URL, kind: MediaKind, _ target: ConvertTarget) async throws -> URL {
        let editor = AudioEditor(kind: kind)
        let preset = Preset(operation: .convert(ConvertSpec(target: target)))
        let out = dir.url.appendingPathComponent("out-\(UUID().uuidString).\(editor.outputExtension(for: input, preset: preset))")
        try await editor.compress(input: input, output: out, preset: preset) { _ in }
        return out
    }

    private func audioFormat(_ url: URL) async throws -> FourCharCode? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first, let f = try await track.load(.formatDescriptions).first else { return nil }
        return CMFormatDescriptionGetMediaSubType(f)
    }

    @Test(arguments: [AudioFormat.aac, .alac, .wav, .aiff, .caf])
    func convertsAudioToEveryFormat(format: AudioFormat) async throws {
        let wav = try await VideoFixtures.make(dir.url.appendingPathComponent("src.mov"), .init(seconds: 1, audio: .pcm, fileType: .mov))
        let out = try await convert(wav, kind: .video, .videoToAudio(format))
        #expect(out.pathExtension == format.fileExtension)
        let expected: FourCharCode = switch format {
        case .aac: kAudioFormatMPEG4AAC
        case .alac: kAudioFormatAppleLossless
        default: kAudioFormatLinearPCM
        }
        #expect(try await audioFormat(out) == expected)
        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        #expect(abs(duration - 1) < 0.2)
    }

    @Test func videoWithoutSoundSaysSo() async throws {
        let silent = try await VideoFixtures.make(dir.url.appendingPathComponent("s.mp4"), .init(seconds: 1))
        do {
            _ = try await convert(silent, kind: .video, .videoToAudio(.aac))
            Issue.record("should have thrown")
        } catch let error as CompressionError {
            #expect(error.localizedDescription.contains("no sound"))
        }
    }
}
}

@Suite struct GIFEditorTests {
    let dir: Scratch
    init() throws { dir = try Scratch() }

    private func gif(frames: Int = 6) throws -> URL {
        let images = (0..<frames).map { i -> CGImage in
            let ctx = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: Fixtures.sRGB,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.5, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: i * 10, y: 30, width: 20, height: 20))
            return ctx.makeImage()!
        }
        let url = dir.url.appendingPathComponent("a.gif")
        let d = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, images.count, nil)!
        CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for image in images {
            CGImageDestinationAddImage(d, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        CGImageDestinationFinalize(d)
        return url
    }

    private func edit(_ family: OperationFamily, _ action: ToolAction, input: URL) async throws -> URL {
        let editor = GIFEditor(family)
        let preset = Preset(operation: action)
        let out = dir.url.appendingPathComponent("out-\(UUID().uuidString).\(editor.outputExtension(for: input, preset: preset))")
        try await editor.compress(input: input, output: out, preset: preset) { _ in }
        return out
    }

    private func decoded(_ url: URL) throws -> [RGBAImage] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try (0..<CGImageSourceGetCount(source)).map { try #require(CGImageSourceCreateImageAtIndex(source, $0, nil).flatMap(RGBAImage.init)) }
    }

    @Test func resizeKeepsEveryFrame() async throws {
        let out = try await edit(.resize, .resize(ResizeSpec(mode: .fit(maxSide: 60))), input: try gif())
        let frames = try decoded(out)
        #expect(frames.count == 6)
        #expect(frames[0].width == 60 && frames[0].height == 40)
    }

    @Test func cropCutsEveryFrame() async throws {
        let out = try await edit(.crop, .crop(NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)), input: try gif())
        let frames = try decoded(out)
        #expect(frames.count == 6 && frames[0].width == 60 && frames[0].height == 80)
    }

    @Test func rotateTurnsEveryFrame() async throws {
        let out = try await edit(.rotate, .rotate(RotateSpec(quarterTurns: 1)), input: try gif())
        let frames = try decoded(out)
        #expect(frames.count == 6 && frames[0].width == 80 && frames[0].height == 120)
    }

    @Test func watermarkIsOnEveryFrame() async throws {
        let spec = WatermarkSpec(content: .text("GIF"), position: .center, scale: 0.4, opacity: 1)
        let input = try gif()
        let out = try await edit(.watermark, .watermark(spec), input: input)
        let before = try decoded(input), after = try decoded(out)
        for i in [0, 5] {
            var changed = 0
            for y in 20..<60 { for x in 30..<90 where before[i].pixels[(y * 120 + x) * 4 + 1] != after[i].pixels[(y * 120 + x) * 4 + 1] { changed += 1 } }
            #expect(changed > 30, "frame \(i)")
        }
    }

    @Test func turnsIntoVideo() async throws {
        let compressor = GIFEditor(.convert)
        let preset = Preset(operation: .convert(ConvertSpec(target: .video(.mp4))))
        let input = try gif()
        #expect(compressor.outputExtension(for: input, preset: preset) == "mp4")
        let out = dir.url.appendingPathComponent("a.mp4")
        try await compressor.compress(input: input, output: out, preset: preset) { _ in }
        let asset = AVURLAsset(url: out)
        #expect(abs(try await asset.load(.duration).seconds - 0.6) < 0.15)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 120, height: 80))
    }
}
