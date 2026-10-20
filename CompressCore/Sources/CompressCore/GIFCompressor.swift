import AVFoundation
import Foundation

/// Shrinks animated GIFs by sharing one palette and storing only what changes between frames.
public struct GIFCompressor: Compressor {
    public var kind: MediaKind { .gif }

    public init() {}

    public func outputExtension(for input: URL, preset: Preset) -> String { "gif" }

    /// ImageIO reports how many times the animation plays (0 = forever). In the file, no extension means
    /// once and an extension with N means N repeats after the first play.
    static func encoderLoopCount(plays: Int) -> Int {
        switch plays {
        case ...0: 0
        case 1: -1
        default: plays - 1
        }
    }

    public func compress(
        input: URL,
        output: URL,
        preset: Preset,
        progress: @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        let source = try GIFFileSource(url: input, maxDimension: preset.maxDimension)
        let data = try GIFOptimizer.encode(
            source, level: preset.level, maxFrameRate: preset.maxFrameRate,
            loopCount: Self.encoderLoopCount(plays: source.loopCount), progress: progress)
        try Task.checkCancellation()
        try data.write(to: output)
    }
}

/// Turns a video into an animated GIF.
enum VideoToGIF {
    static func convert(
        input: URL,
        output: URL,
        preset: Preset,
        progress: @Sendable (Double) -> Void
    ) async throws {
        let unreadable = CompressionError.failed("“\(input.lastPathComponent)” can't be read as a video.")
        let asset = AVURLAsset(url: input)
        let duration: Double
        let size: CGSize
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw unreadable }
            duration = try await asset.load(.duration).seconds
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let rotated = natural.applying(transform)
            size = CGSize(width: abs(rotated.width), height: abs(rotated.height))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw unreadable
        }

        let fps = Double(preset.maxFrameRate ?? 12)
        let seconds = min(duration, preset.gifMaxSeconds ?? 15)
        // Keep memory in check: long clips at a high rate are thinned out.
        var frameCount = max(1, Int(seconds * fps))
        let limit = 400
        let effectiveFPS = frameCount > limit ? Double(limit) / seconds : fps
        frameCount = min(frameCount, limit)

        let longest = Double(preset.maxDimension ?? 480)
        let scale = min(1, longest / max(size.width, size.height))
        let width = max(2, Int((size.width * scale).rounded()))
        let height = max(2, Int((size.height * scale).rounded()))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: height)
        let tolerance = CMTime(seconds: 0.5 / effectiveFPS, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let times = (0..<frameCount).map { CMTime(seconds: Double($0) / effectiveFPS, preferredTimescale: 600) }
        var images: [CGImage] = []
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            if case .success(_, let image, _) = result { images.append(image) }
            progress(0.3 * Double(images.count) / Double(frameCount))
        }
        guard !images.isEmpty else { throw unreadable }

        let source = VideoFrameSource(
            images: images, width: width, height: height, interval: 1 / effectiveFPS)
        let data = try GIFOptimizer.encode(
            source, level: preset.level, maxFrameRate: nil, loopCount: 0,
            progress: { progress(0.3 + 0.7 * $0) })
        try Task.checkCancellation()
        try data.write(to: output)
    }
}
