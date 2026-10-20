import Testing
import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Builds small synthetic videos for tests.
/// Feeding progress shared by the writer callbacks, which all run on one serial queue.
private final class Feed: @unchecked Sendable {
    var frame = 0
    var audioTime = 0.0
    var error: Error?
}

enum VideoFixtures {
    enum Audio { case aac, pcm }

    struct Spec {
        var width = 480
        var height = 272
        var fps = 30
        var seconds = 1.5
        var codec: AVVideoCodecType = .h264
        var bitRate = 6_000_000
        var hdr = false
        var transform: CGAffineTransform = .identity
        var audio: Audio?
        var fileType: AVFileType = .mp4
        var metadata: [AVMetadataItem] = []
    }

    @discardableResult
    static func make(_ url: URL, _ spec: Spec = Spec()) async throws -> URL {
        let writer = try AVAssetWriter(outputURL: url, fileType: spec.fileType)
        writer.metadata = spec.metadata

        var settings: [String: Any] = [
            AVVideoCodecKey: spec.codec,
            AVVideoWidthKey: spec.width,
            AVVideoHeightKey: spec.height,
        ]
        var compression: [String: Any] = [AVVideoAverageBitRateKey: spec.bitRate]
        if spec.hdr {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        }
        settings[AVVideoCompressionPropertiesKey] = compression

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.transform = spec.transform
        videoInput.expectsMediaDataInRealTime = false
        let pixelFormat = spec.hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: spec.width,
            kCVPixelBufferHeightKey as String: spec.height,
        ])
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audio = spec.audio {
            let outputSettings: [String: Any] = switch audio {
            case .aac: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44100, AVEncoderBitRateKey: 192_000]
            case .pcm: [AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44100,
                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false]
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let base = baseFrame(width: spec.width, height: spec.height, hdr: spec.hdr)
        let frames = Int(Double(spec.fps) * spec.seconds)
        let feed = Feed()
        let queue = DispatchQueue(label: "fixture.feed")

        // Each input is fed from its own callback, which is how AVAssetWriter expects to be driven.
        // Feeding one input in a loop can deadlock, because the writer holds samples back to interleave.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            videoInput.requestMediaDataWhenReady(on: queue) {
                while videoInput.isReadyForMoreMediaData {
                    if feed.frame >= frames || feed.error != nil {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    do {
                        let buffer = try pixelBuffer(adaptor, base: base, shift: feed.frame * 3, width: spec.width, height: spec.height, hdr: spec.hdr)
                        let time = CMTime(value: CMTimeValue(feed.frame), timescale: CMTimeScale(spec.fps))
                        if !adaptor.append(buffer, withPresentationTime: time) { feed.error = writer.error }
                    } catch {
                        feed.error = error
                    }
                    feed.frame += 1
                }
            }
            if let audioInput {
                group.enter()
                audioInput.requestMediaDataWhenReady(on: queue) {
                    while audioInput.isReadyForMoreMediaData {
                        if feed.audioTime >= spec.seconds || feed.error != nil {
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        do {
                            if !audioInput.append(try tone(startingAt: feed.audioTime, frames: 4096)) { feed.error = writer.error }
                        } catch {
                            feed.error = error
                        }
                        feed.audioTime += 4096.0 / 44100
                    }
                }
            }
            group.notify(queue: queue) { done.resume() }
        }
        if let error = feed.error { throw error }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    // MARK: Pixels

    /// A noisy gradient, twice as wide as needed, so shifting a window over it looks like motion.
    private static func baseFrame(width: Int, height: Int, hdr: Bool) -> [UInt16] {
        var rng = Fixtures.SeededRandom(state: 7)
        let wide = width * 2
        return (0..<wide * height).map { i in
            let x = i % wide, y = i / wide
            let value = (x * 200 / wide + y * 40 / height) + Int(rng.next() % 40)
            return UInt16(min(value, 255))
        }
    }

    private static func pixelBuffer(
        _ adaptor: AVAssetWriterInputPixelBufferAdaptor, base: [UInt16],
        shift: Int, width: Int, height: Int, hdr: Bool
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
            nil, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let wide = width * 2
        let offset = shift % width

        if hdr {
            let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.bindMemory(to: UInt16.self, capacity: width * height)
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
            for y in 0..<height {
                for x in 0..<width { luma[y * lumaStride + x] = (16 + base[y * wide + x + offset] * 220 / 255) << 6 }
            }
            let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.bindMemory(to: UInt16.self, capacity: width * height / 2)
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
            for y in 0..<height / 2 {
                for x in 0..<width { chroma[y * chromaStride + x] = 512 << 6 }
            }
        } else {
            let pixels = CVPixelBufferGetBaseAddress(buffer)!.bindMemory(to: UInt8.self, capacity: width * height * 4)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                let row = pixels + y * rowBytes
                for x in 0..<width {
                    let v = UInt8(base[y * wide + x + offset])
                    row[x * 4] = v
                    row[x * 4 + 1] = UInt8(255 - Int(v) / 2)
                    row[x * 4 + 2] = UInt8((Int(v) + y) % 256)
                    row[x * 4 + 3] = 255
                }
            }
        }
        return buffer
    }

    // MARK: Audio

    private static func tone(startingAt start: Double, frames: Int) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)

        let first = Int(start * 44100)
        let samples: [Int16] = (0..<frames).map { Int16(sin(Double(first + $0) * 2 * .pi * 440 / 44100) * 8000) }
        let length = samples.count * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block)
        samples.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length)
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 44100),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample else { throw CocoaError(.fileWriteUnknown) }
        return sample
    }
}

/// What a finished video looks like, for assertions.
struct VideoInfo {
    var duration: Double
    var size: CGSize
    var transform: CGAffineTransform
    var frameRate: Float
    var codec: FourCharCode
    var transfer: String?
    var audioFormat: FourCharCode?
    var audioTrackCount: Int
    var metadataCount: Int
    var frameCount: Int

    static func read(_ url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let (size, transform, fps, formats) = try await video.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
        let format = try #require(formats.first)
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any]

        var audioFormat: FourCharCode?
        if let track = audio.first, let f = try await track.load(.formatDescriptions).first {
            audioFormat = CMFormatDescriptionGetMediaSubType(f)
        }

        // Decode every frame to prove the file plays end to end.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { frames += 1 }
        }

        return VideoInfo(
            duration: try await asset.load(.duration).seconds, size: size, transform: transform, frameRate: fps,
            codec: CMFormatDescriptionGetMediaSubType(format),
            transfer: (extensions?[kCVImageBufferTransferFunctionKey as String] ?? extensions?[kCMFormatDescriptionExtension_TransferFunction as String]) as? String,
            audioFormat: audioFormat, audioTrackCount: audio.count,
            metadataCount: try await asset.load(.metadata).count, frameCount: frames)
    }
}
