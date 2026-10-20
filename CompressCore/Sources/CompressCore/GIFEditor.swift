import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Resize, crop, rotate and watermark animated GIFs, or turn them into video.
public struct GIFEditor: Compressor {
    public let family: OperationFamily
    public var kind: MediaKind { .gif }

    public init(_ family: OperationFamily) { self.family = family }

    public func outputExtension(for input: URL, preset: Preset) -> String {
        if case .convert(let spec) = preset.operation, case .video(let format) = spec.target, format != .gif { return format.rawValue }
        return "gif"
    }

    /// Frames of a GIF with a picture operation applied to each one.
    private struct EditedSource: GIFFrameSource {
        let base: GIFFileSource
        let width: Int
        let height: Int
        let edit: @Sendable (CGImage) throws -> CGImage

        var count: Int { base.count }
        func delay(at index: Int) -> Double { base.delay(at: index) }
        func pixels(at index: Int) throws -> [UInt8] {
            guard let image = CGImageSourceCreateImageAtIndex(base.source, index, nil) else {
                throw CompressionError.failed("Frame \(index + 1) couldn't be decoded.")
            }
            let edited = try edit(image)
            return try renderRGBA(edited, width: width, height: height)
        }
    }

    public func compress(input: URL, output: URL, preset: Preset, progress: @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        let base = try GIFFileSource(url: input, maxDimension: nil)

        if case .convert(let spec) = preset.operation, case .video(let format) = spec.target, format != .gif {
            try await Self.toVideo(base, output: output, format: format, progress: progress)
            return
        }

        let edit: @Sendable (CGImage) throws -> CGImage
        switch preset.operation {
        case .resize(let spec): edit = { try ImageTools.resize($0, spec: spec) }
        case .crop(let rect): edit = { try ImageTools.crop($0, to: rect) }
        case .rotate(let spec): edit = { try ImageTools.rotate($0, spec: spec) }
        case .watermark(let spec): edit = { try ImageTools.watermark($0, spec: spec) }
        default: throw CompressionError.failed("This tool doesn't work on GIFs.")
        }
        // Find the output size from the first frame; every frame goes through the same change.
        guard let first = CGImageSourceCreateImageAtIndex(base.source, 0, nil) else {
            throw CompressionError.failed("“\(input.lastPathComponent)” can't be read as a GIF.")
        }
        let probe = try edit(first)
        let source = EditedSource(base: base, width: probe.width, height: probe.height, edit: edit)
        // Edits keep the palette as rich as possible; compress afterwards if the file should be smaller.
        let data = try GIFOptimizer.encode(
            source, level: .highest, maxFrameRate: nil, loopCount: GIFCompressor.encoderLoopCount(plays: base.loopCount), progress: progress)
        try Task.checkCancellation()
        try data.write(to: output)
    }

    private static func toVideo(_ base: GIFFileSource, output: URL, format: VideoFormat, progress: @Sendable (Double) -> Void) async throws {
        let width = base.width - base.width % 2, height = base.height - base.height % 2
        let writer = try AVAssetWriter(outputURL: output, fileType: format == .mov ? .mov : .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.8],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw CompressionError.failed("The video couldn't be created.") }
        writer.add(input)
        guard writer.startWriting() else { throw CompressionError.failed(writer.error?.localizedDescription ?? "The video couldn't be created.") }
        writer.startSession(atSourceTime: .zero)

        var time = 0.0
        for index in 0..<base.count {
            try Task.checkCancellation()
            let rgba = try base.pixels(at: index)
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CompressionError.failed("There isn't enough memory to build the video.") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let dst = CVPixelBufferGetBaseAddress(buffer)!.bindMemory(to: UInt8.self, capacity: height * CVPixelBufferGetBytesPerRow(buffer))
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let s = (y * base.width + x) * 4, d = y * stride + x * 4
                    let a = Int(rgba[s + 3])
                    // Transparent pixels become white, since video has no transparency.
                    dst[d] = UInt8((Int(rgba[s + 2]) * a + 255 * (255 - a)) / 255)
                    dst[d + 1] = UInt8((Int(rgba[s + 1]) * a + 255 * (255 - a)) / 255)
                    dst[d + 2] = UInt8((Int(rgba[s]) * a + 255 * (255 - a)) / 255)
                    dst[d + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600))
            time += max(base.delay(at: index), 0.02)
            progress(Double(index + 1) / Double(base.count))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed { throw CompressionError.failed(writer.error?.localizedDescription ?? "The video couldn't be written.") }
    }
}
