import AVFoundation
import CoreImage
import Foundation
import Vision

/// Resize, crop, rotate, enlarge, watermark and hide faces in video. Each frame goes through a Core Image
/// filter; sound is copied across untouched.
public struct VideoEditor: Compressor {
    public let family: OperationFamily
    public var kind: MediaKind { .video }

    public init(_ family: OperationFamily) { self.family = family }

    public func outputExtension(for input: URL, preset: Preset) -> String {
        let ext = input.pathExtension.lowercased()
        return ["mp4", "mov", "m4v"].contains(ext) ? ext : "mp4"
    }

    /// What one operation does to the picture of a video.
    struct FramePlan {
        var outputSize: CGSize
        /// Takes a frame (origin bottom left, display orientation) and returns the finished frame.
        var transform: @Sendable (CIImage, CMTime) -> CIImage
    }

    private static func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded(.down) * 2) }

    static func plan(for action: ToolAction, display: CGSize) throws -> FramePlan {
        switch action {
        case .resize(let spec):
            var size = ImageTools.resizedSize(display, spec: spec)
            var crop = CGRect(origin: .zero, size: display)
            if case .exact(let w, let h, true) = spec.mode {
                // Fill the frame, then trim what overflows.
                let target = Double(w) / Double(h), ratio = display.width / display.height
                if ratio > target { crop.size.width = display.height * target; crop.origin.x = (display.width - crop.width) / 2 }
                else { crop.size.height = display.width / target; crop.origin.y = (display.height - crop.height) / 2 }
                size = ImageTools.resizedSize(crop.size, spec: spec)
            }
            let out = CGSize(width: even(size.width), height: even(size.height))
            let area = crop
            return FramePlan(outputSize: out) { image, _ in
                let scaled = image.cropped(to: area).transformed(by: CGAffineTransform(translationX: -area.minX, y: -area.minY))
                    .transformed(by: CGAffineTransform(scaleX: out.width / area.width, y: out.height / area.height))
                return scaled.cropped(to: CGRect(origin: .zero, size: out))
            }

        case .crop(let rect):
            let r = rect.clamped
            let pixels = CGRect(x: (r.x * display.width).rounded(), y: 0, width: even(r.width * display.width), height: even(r.height * display.height))
            let flippedY = display.height - (r.y * display.height).rounded() - pixels.height  // to bottom-left origin
            let area = CGRect(x: pixels.minX, y: max(0, flippedY), width: pixels.width, height: pixels.height)
            return FramePlan(outputSize: area.size) { image, _ in
                image.cropped(to: area).transformed(by: CGAffineTransform(translationX: -area.minX, y: -area.minY))
            }

        case .rotate(let spec):
            let swap = spec.quarterTurns % 2 == 1
            let out = swap ? CGSize(width: display.height, height: display.width) : display
            return FramePlan(outputSize: out) { image, _ in
                var t = CGAffineTransform(translationX: -display.width / 2, y: -display.height / 2)
                t = t.scaledBy(x: spec.flipHorizontal ? -1 : 1, y: spec.flipVertical ? -1 : 1)
                t = t.rotated(by: -CGFloat(spec.quarterTurns) * .pi / 2)
                t = t.translatedBy(x: 0, y: 0).concatenating(CGAffineTransform(translationX: out.width / 2, y: out.height / 2))
                return image.transformed(by: t).cropped(to: CGRect(origin: .zero, size: out))
            }

        case .upscale(let spec):
            let out = CGSize(width: display.width * CGFloat(spec.factor), height: display.height * CGFloat(spec.factor))
            guard out.width <= 7680, out.height <= 7680 else {
                throw CompressionError.failed("The enlarged video would be too big (\(Int(out.width))×\(Int(out.height))). Try a smaller factor.")
            }
            return FramePlan(outputSize: out) { image, _ in
                let lanczos = CIFilter(name: "CILanczosScaleTransform")!
                lanczos.setValue(image, forKey: kCIInputImageKey)
                lanczos.setValue(spec.factor, forKey: kCIInputScaleKey)
                lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
                var result = lanczos.outputImage ?? image
                if spec.sharpness > 0, let sharpen = CIFilter(name: "CISharpenLuminance") {
                    sharpen.setValue(result, forKey: kCIInputImageKey)
                    sharpen.setValue(spec.sharpness * 1.2, forKey: kCIInputSharpnessKey)
                    result = sharpen.outputImage ?? result
                }
                return result.cropped(to: CGRect(origin: .zero, size: out))
            }

        case .watermark(let spec):
            let size = display
            // The mark is the same on every frame, so draw it once.
            guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw CompressionError.failed("There isn't enough memory to add a watermark.") }
            ImageTools.drawWatermark(spec, in: context, size: size)
            let overlay = context.makeImage().map { CIImage(cgImage: $0) }
            return FramePlan(outputSize: size) { image, _ in overlay.map { $0.composited(over: image) } ?? image }

        case .blurFaces(let spec):
            let tracker = FaceTracker()
            return FramePlan(outputSize: display) { image, time in
                let regions = tracker.faces(in: image, at: time)
                return ImageTools.obscure(image, extent: image.extent, regions: regions, spec: spec)
            }

        default:
            throw CompressionError.failed("This tool doesn't work on video.")
        }
    }

    public func compress(input: URL, output: URL, preset: Preset, progress: @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        let unreadable = CompressionError.failed("“\(input.lastPathComponent)” can't be read as a video.")
        let asset = AVURLAsset(url: input)
        let video: AVAssetTrack, audioTracks: [AVAssetTrack], duration: Double
        do {
            guard try await asset.load(.isReadable), let first = try await asset.loadTracks(withMediaType: .video).first else { throw unreadable }
            video = first
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration).seconds
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw unreadable
        }

        let (natural, transform, nominalFPS, formats, range) = try await video.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions, .timeRange)
        let rotated = natural.applying(transform)
        let display = CGSize(width: abs(rotated.width), height: abs(rotated.height))
        let colors = VideoCompressor.colorProperties(formats.first)
        let hdr = VideoCompressor.isHDR(colors)

        let framePlan = try Self.plan(for: preset.operation, display: display)
        let handlerPlan = framePlan

        let composition = AVMutableVideoComposition(asset: asset) { request in
            let frame = handlerPlan.transform(request.sourceImage, request.compositionTime)
            request.finish(with: frame, context: nil)
        }
        composition.renderSize = framePlan.outputSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, nominalFPS > 0 ? nominalFPS.rounded() : 30)))

        let fileType: AVFileType = switch output.pathExtension.lowercased() {
        case "mov": .mov
        case "m4v": .m4v
        default: .mp4
        }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true
        if !preset.stripMetadata, let metadata = try? await asset.load(.metadata) { writer.metadata = metadata }

        let readerOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: hdr
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        readerOutput.videoComposition = composition
        readerOutput.alwaysCopiesSampleData = false

        // Edited video is re-encoded once, so it is kept at high quality.
        var plan = VideoPlan.make(source: VideoSourceInfo(size: framePlan.outputSize, frameRate: Double(nominalFPS), isHDR: hdr),
                                  preset: Preset(level: .highest, videoCodec: preset.videoCodec))
        plan.width = Int(framePlan.outputSize.width)
        plan.height = Int(framePlan.outputSize.height)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: VideoCompressor.videoSettings(plan, colors: colors))
        writerInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(readerOutput), writer.canAdd(writerInput) else { throw unreadable }
        reader.add(readerOutput)
        writer.add(writerInput)

        var lanes: [Transcoder.Lane] = [.init(output: readerOutput, input: writerInput, frameInterval: nil)]
        for track in audioTracks {
            if let lane = try await VideoCompressor.audioLane(track, preset: Preset(level: .highest), isMOV: fileType == .mov, reader: reader, writer: writer) {
                lanes.append(lane)
            }
        }

        try await withoutActuallyEscaping(progress) { escapable in
            let transcoder = Transcoder(reader: reader, writer: writer, lanes: lanes, start: range.start, duration: duration, progress: escapable)
            try await transcoder.run()
        }
    }
}

/// Finds faces in each frame, and keeps the last known positions for a moment so the cover doesn't flicker.
final class FaceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var recent: [(rect: CGRect, expires: Double)] = []

    func faces(in image: CIImage, at time: CMTime) -> [CGRect] {
        let now = time.seconds
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try? handler.perform([request])
        let size = image.extent.size
        let found = (request.results ?? []).map { face -> CGRect in
            let box = face.boundingBox
            return CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
        }

        lock.lock()
        defer { lock.unlock() }
        recent.removeAll { $0.expires < now || abs($0.expires - now) > 5 }
        // A face seen a few frames ago still counts, unless a new detection is already covering that spot.
        var result = found
        for old in recent where !found.contains(where: { $0.intersects(old.rect) }) { result.append(old.rect) }
        recent = found.map { ($0, now + 0.15) } + recent.filter { old in !found.contains { $0.intersects(old.rect) } }
        return result
    }
}
