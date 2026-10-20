import AVFoundation
import Foundation
import Testing
@testable import CompressCore

@Suite struct VideoPlanTests {
    private func source(_ w: Double = 1920, _ h: Double = 1080, fps: Double = 30, hdr: Bool = false) -> VideoSourceInfo {
        VideoSourceInfo(size: CGSize(width: w, height: h), frameRate: fps, isHDR: hdr)
    }

    @Test func qualityFollowsLevel() {
        let qualities = QualityLevel.allCases.map { VideoPlan.make(source: source(), preset: Preset(level: $0)).quality }
        #expect(qualities == qualities.sorted(by: >))
        #expect(Set(qualities).count == 4)
        #expect(qualities.allSatisfy { (0...1).contains($0) })
    }

    @Test func resizeKeepsAspectRatioAndEvenSizes() {
        let plan = VideoPlan.make(source: source(1920, 1080), preset: Preset(maxDimension: 1000))
        #expect(plan.width == 1000 && plan.height == 562)
        #expect(plan.width % 2 == 0 && plan.height % 2 == 0)
    }

    @Test func neverEnlarges() {
        let plan = VideoPlan.make(source: source(640, 360), preset: Preset(maxDimension: 4000))
        #expect(plan.width == 640 && plan.height == 360)
    }

    @Test func frameRateCap() {
        let capped = VideoPlan.make(source: source(fps: 60), preset: Preset(maxFrameRate: 30))
        #expect(capped.frameRate == 30 && capped.dropsFrames)
        let untouched = VideoPlan.make(source: source(fps: 24), preset: Preset(maxFrameRate: 30))
        #expect(untouched.frameRate == 24 && !untouched.dropsFrames)
    }

    @Test func h264NeedsMoreBitsAndHDRForcesHEVC() {
        let hevc = VideoPlan.make(source: source(), preset: Preset(videoCodec: .hevc))
        let h264 = VideoPlan.make(source: source(), preset: Preset(videoCodec: .h264))
        #expect(h264.codec == .h264 && hevc.codec == .hevc)
        let hdr = VideoPlan.make(source: source(hdr: true), preset: Preset(videoCodec: .h264))
        #expect(hdr.codec == .hevc && hdr.isHDR)
    }

    @Test func audioPlans() {
        let aac: UInt32 = 0x6161_6320, pcm: UInt32 = 0x6C70_636D
        #expect(AudioPlan.make(formatID: aac, bitRate: 128_000, channels: 2, level: .high, isMOV: false) == .passthrough)
        #expect(AudioPlan.make(formatID: aac, bitRate: 256_000, channels: 2, level: .low, isMOV: false) == .reencode(bitRate: 96_000, channels: 2))
        #expect(AudioPlan.make(formatID: aac, bitRate: 96_000, channels: 2, level: .low, isMOV: false) == .passthrough)
        #expect(AudioPlan.make(formatID: pcm, bitRate: 0, channels: 6, level: .high, isMOV: true) == .reencode(bitRate: 192_000, channels: 2))
    }
}

@Suite struct VideoColorTests {
    private func format(_ extensions: [String: Any]) throws -> CMFormatDescription {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_HEVC, width: 64, height: 64,
            extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        return try #require(format)
    }

    @Test func readsCameraStyleKeys() throws {
        let f = try format([
            kCVImageBufferColorPrimariesKey as String: "ITU_R_2020",
            kCVImageBufferTransferFunctionKey as String: "ITU_R_2100_HLG",
            kCVImageBufferYCbCrMatrixKey as String: "ITU_R_2020",
        ])
        let colors = VideoCompressor.colorProperties(f)
        #expect(colors?[AVVideoTransferFunctionKey] == "ITU_R_2100_HLG")
        #expect(VideoCompressor.isHDR(colors))
    }

    @Test func readsAVFoundationStyleKeys() throws {
        let f = try format([
            kCMFormatDescriptionExtension_ColorPrimaries as String: "ITU_R_709_2",
            kCMFormatDescriptionExtension_TransferFunction as String: "ITU_R_709_2",
            kCMFormatDescriptionExtension_YCbCrMatrix as String: "ITU_R_709_2",
        ])
        let colors = VideoCompressor.colorProperties(f)
        #expect(colors?[AVVideoColorPrimariesKey] == "ITU_R_709_2")
        #expect(!VideoCompressor.isHDR(colors))
    }

    @Test func missingTagsGiveNil() throws {
        #expect(VideoCompressor.colorProperties(try format([:])) == nil)
        #expect(!VideoCompressor.isHDR(nil))
    }

    @Test func detectsPQ() throws {
        let f = try format([
            kCVImageBufferColorPrimariesKey as String: "ITU_R_2020",
            kCVImageBufferTransferFunctionKey as String: "SMPTE_ST_2084_PQ",
            kCVImageBufferYCbCrMatrixKey as String: "ITU_R_2020",
        ])
        #expect(VideoCompressor.isHDR(VideoCompressor.colorProperties(f)))
    }
}

/// Hardware encoders and decoders can stall when many sessions run at once, so tests that use them take turns.
@Suite(.serialized) enum AVTests {}

extension AVTests {
@Suite struct VideoCompressorTests {
    let dir: Scratch
    let compressor = VideoCompressor()

    init() throws { dir = try Scratch() }

    private func source(_ name: String = "a.mp4", _ spec: VideoFixtures.Spec = .init()) async throws -> URL {
        try await VideoFixtures.make(dir.url.appendingPathComponent(name), spec)
    }

    private func compress(_ input: URL, _ preset: Preset = .default) async throws -> URL {
        let out = dir.url.appendingPathComponent("out-\(UUID().uuidString)")
            .appendingPathExtension(compressor.outputExtension(for: input, preset: preset))
        try await compressor.compress(input: input, output: out, preset: preset) { _ in }
        return out
    }

    @Test func shrinksAndKeepsDurationAndFrames() async throws {
        let input = try await source()
        let out = try await compress(input, Preset(level: .high))

        #expect(Fixtures.size(out) < Fixtures.size(input) / 2)
        let before = try await VideoInfo.read(input)
        let after = try await VideoInfo.read(out)
        #expect(abs(after.duration - before.duration) < 0.1)
        #expect(after.size == before.size)
        #expect(after.codec == kCMVideoCodecType_HEVC)
        #expect(after.frameCount == before.frameCount)
    }

    @Test func lowerLevelsGiveSmallerFiles() async throws {
        let input = try await source()
        var sizes: [Int] = []
        for level in QualityLevel.allCases {
            sizes.append(Fixtures.size(try await compress(input, Preset(level: level))))
        }
        #expect(sizes == sizes.sorted(by: >), "sizes should shrink with level: \(sizes)")
    }

    @Test func h264Option() async throws {
        let input = try await source()
        let out = try await compress(input, Preset(videoCodec: .h264))
        #expect(try await VideoInfo.read(out).codec == kCMVideoCodecType_H264)
    }

    @Test func resizesVideo() async throws {
        let input = try await source("a.mp4", .init(width: 640, height: 360))
        let out = try await compress(input, Preset(maxDimension: 320))
        let info = try await VideoInfo.read(out)
        #expect(info.size == CGSize(width: 320, height: 180))
    }

    @Test func keepsRotation() async throws {
        let rotated = CGAffineTransform(rotationAngle: .pi / 2)
        let input = try await source("a.mov", .init(transform: rotated, fileType: .mov))
        let out = try await compress(input)
        let info = try await VideoInfo.read(out)
        #expect(abs(info.transform.b - rotated.b) < 0.01 && abs(info.transform.c - rotated.c) < 0.01)
    }

    @Test func capsFrameRateWithoutChangingDuration() async throws {
        let input = try await source("a.mp4", .init(fps: 30, seconds: 2))
        let out = try await compress(input, Preset(maxFrameRate: 15))
        let info = try await VideoInfo.read(out)
        #expect(abs(info.duration - 2) < 0.2)
        #expect(abs(info.frameCount - 30) <= 3, "frames: \(info.frameCount)")
    }

    @Test func keepsAACAudioAsIs() async throws {
        let input = try await source("a.mp4", .init(audio: .aac))
        let out = try await compress(input, Preset(level: .high))
        let info = try await VideoInfo.read(out)
        #expect(info.audioTrackCount == 1)
        #expect(info.audioFormat == kAudioFormatMPEG4AAC)
        #expect(abs(info.duration - 1.5) < 0.2)
    }

    @Test func convertsPCMAudioToAAC() async throws {
        let input = try await source("a.mov", .init(audio: .pcm, fileType: .mov))
        let out = try await compress(input)
        let info = try await VideoInfo.read(out)
        #expect(info.audioFormat == kAudioFormatMPEG4AAC)
    }

    @Test func keepsHDRAsTenBitHEVC() async throws {
        let input = try await source("a.mov", .init(codec: .hevc, hdr: true, fileType: .mov))
        let out = try await compress(input, Preset(videoCodec: .h264))
        let info = try await VideoInfo.read(out)
        #expect(info.codec == kCMVideoCodecType_HEVC, "HDR can't be carried by H.264")
        #expect(info.transfer == AVVideoTransferFunction_ITU_R_2100_HLG)
    }

    @Test func stripRemovesMetadata() async throws {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataLocationISO6709
        item.value = "+12.5000+077.5000/" as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        let input = try await source("a.mov", .init(fileType: .mov, metadata: [item]))

        let kept = try await VideoInfo.read(try await compress(input, Preset(stripMetadata: false)))
        let stripped = try await VideoInfo.read(try await compress(input, Preset(stripMetadata: true)))
        #expect(kept.metadataCount > 0)
        #expect(stripped.metadataCount == 0)
    }

    @Test func notAVideoFailsWithClearMessage() async throws {
        let input = try dir.file("fake.mp4", bytes: 500)
        do {
            _ = try await compress(input)
            Issue.record("should have thrown")
        } catch let error as CompressionError {
            #expect(error.localizedDescription.contains("can't be read"))
        }
    }

    @Test func cancellationStopsAndLeavesNothingBehind() async throws {
        let input = try await source("a.mp4", .init(width: 640, height: 360, seconds: 3))
        let out = dir.url.appendingPathComponent("cancelled.mp4")

        final class Box: @unchecked Sendable { var task: Task<Void, Error>? }
        let box = Box()
        let task = Task {
            try await compressor.compress(input: input, output: out, preset: .default) { fraction in
                if fraction > 0.05 { box.task?.cancel() }
            }
        }
        box.task = task
        do {
            try await task.value
            Issue.record("should have been cancelled")
        } catch is CancellationError {
            #expect(!FileManager.default.fileExists(atPath: out.path))
        }
    }

    @Test func reportsProgressUpToTheEnd() async throws {
        let input = try await source()
        final class Log: @unchecked Sendable { var values: [Double] = []; let lock = NSLock() }
        let log = Log()
        let out = dir.url.appendingPathComponent("p.mp4")
        try await compressor.compress(input: input, output: out, preset: .default) { value in
            log.lock.lock(); log.values.append(value); log.lock.unlock()
        }
        #expect(log.values.count > 5)
        #expect(log.values == log.values.sorted())
        #expect((log.values.last ?? 0) > 0.9)
    }

    @Test func replacesOriginalThroughTheQueue() async throws {
        let input = try await source()
        let before = Fixtures.size(input)
        let queue = JobQueue(registry: CompressorRegistry([compressor]), maxConcurrent: 1)

        let id = await queue.enqueue(urls: [input], outputPolicy: .replaceOriginal).accepted[0]
        await queue.waitUntilIdle()

        guard case .completed(let result) = await queue.job(id)?.state else {
            Issue.record("job did not complete: \(String(describing: await queue.job(id)?.state))")
            return
        }
        #expect(result.outcome == .compressed)
        #expect(Fixtures.size(input) < before)
        #expect(try await VideoInfo.read(input).frameCount > 0)
        #expect(try dir.contents() == ["a.mp4"])
    }
}
}
