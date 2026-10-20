import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Re-encodes video with AVFoundation, using the hardware HEVC/H.264 encoders.
public struct VideoCompressor: Compressor {
    public var kind: MediaKind { .video }
    public let family: OperationFamily

    /// `.compress` shrinks files; `.convert` re-encodes into another container.
    public init(family: OperationFamily = .compress) { self.family = family }

    public func outputExtension(for input: URL, preset: Preset) -> String {
        if preset.videoToGIF { return "gif" }
        if case .convert(let spec) = preset.operation, case .video(let format) = spec.target {
            return format == .gif ? "gif" : format.rawValue
        }
        let ext = input.pathExtension.lowercased()
        return ["mp4", "mov", "m4v"].contains(ext) ? ext : "mp4"
    }

    public func compress(
        input: URL,
        output: URL,
        preset: Preset,
        progress: @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        var preset = preset
        if case .convert(let spec) = preset.operation, case .video(.gif) = spec.target { preset.videoToGIF = true }
        if preset.videoToGIF {
            try await VideoToGIF.convert(input: input, output: output, preset: preset, progress: progress)
            return
        }
        let unreadable = CompressionError.failed("“\(input.lastPathComponent)” can't be read as a video.")

        let asset = AVURLAsset(url: input)
        let video: AVAssetTrack
        let audioTracks: [AVAssetTrack]
        let duration: Double
        do {
            guard try await asset.load(.isReadable),
                  let first = try await asset.loadTracks(withMediaType: .video).first
            else { throw unreadable }
            video = first
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration).seconds
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw unreadable
        }

        let (size, transform, nominalFPS, formats, range) = try await video.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions, .timeRange)
        let colors = Self.colorProperties(formats.first)
        let source = VideoSourceInfo(
            size: size, frameRate: Double(nominalFPS), isHDR: Self.isHDR(colors))
        let plan = VideoPlan.make(source: source, preset: preset)

        let fileType: AVFileType = switch output.pathExtension.lowercased() {
        case "mov": .mov
        case "m4v": .m4v
        default: .mp4
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true
        if !preset.stripMetadata, let metadata = try? await asset.load(.metadata) {
            writer.metadata = metadata
        }

        var lanes: [Transcoder.Lane] = []

        // Video lane.
        let readerOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: plan.isHDR
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        readerOutput.alwaysCopiesSampleData = false
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(plan, colors: colors))
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = transform
        guard reader.canAdd(readerOutput), writer.canAdd(writerInput) else { throw unreadable }
        reader.add(readerOutput)
        writer.add(writerInput)
        lanes.append(.init(output: readerOutput, input: writerInput, frameInterval: plan.dropsFrames ? 1 / plan.frameRate : nil))

        // Audio lanes.
        for track in audioTracks {
            if let lane = try await Self.audioLane(track, preset: preset, isMOV: fileType == .mov, reader: reader, writer: writer) {
                lanes.append(lane)
            }
        }

        // `run` finishes before this function returns, so the callback never outlives its scope.
        try await withoutActuallyEscaping(progress) { escapable in
            let transcoder = Transcoder(
                reader: reader, writer: writer, lanes: lanes,
                start: range.start, duration: duration, progress: escapable)
            try await transcoder.run()
        }
    }

    // MARK: Settings

    static func videoSettings(_ plan: VideoPlan, colors: [String: String]?) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoQualityKey: plan.quality,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: true,
            AVVideoExpectedSourceFrameRateKey: min(Int(plan.frameRate.rounded()), 60),
        ]
        switch plan.codec {
        case .hevc:
            compression[AVVideoProfileLevelKey] = plan.isHDR
                ? kVTProfileLevel_HEVC_Main10_AutoLevel as String
                : kVTProfileLevel_HEVC_Main_AutoLevel as String
        case .h264:
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        var settings: [String: Any] = [
            AVVideoCodecKey: plan.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let colors { settings[AVVideoColorPropertiesKey] = colors }
        return settings
    }

    /// The colour tags of the source, which must be copied or colours shift. Nil if any is missing.
    /// Cameras write the `CVImageBuffer…` keys; AVFoundation's own writer uses the `CMFormatDescription…` ones.
    static func colorProperties(_ format: CMFormatDescription?) -> [String: String]? {
        guard let format, let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] else { return nil }

        func value(_ keys: [CFString]) -> String? {
            keys.lazy.compactMap { extensions[$0 as String] as? String }.first
        }
        guard let primaries = value([kCVImageBufferColorPrimariesKey, kCMFormatDescriptionExtension_ColorPrimaries]),
              let transfer = value([kCVImageBufferTransferFunctionKey, kCMFormatDescriptionExtension_TransferFunction]),
              let matrix = value([kCVImageBufferYCbCrMatrixKey, kCMFormatDescriptionExtension_YCbCrMatrix])
        else { return nil }
        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix,
        ]
    }

    static func isHDR(_ colors: [String: String]?) -> Bool {
        guard let transfer = colors?[AVVideoTransferFunctionKey] else { return false }
        return transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ || transfer == AVVideoTransferFunction_ITU_R_2100_HLG
    }

    static func audioLane(
        _ track: AVAssetTrack,
        preset: Preset,
        isMOV: Bool,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws -> Transcoder.Lane? {
        let (formats, dataRate) = try await track.load(.formatDescriptions, .estimatedDataRate)
        guard let format = formats.first,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return nil }

        let plan = AudioPlan.make(
            formatID: description.mFormatID, bitRate: Double(dataRate),
            channels: Int(description.mChannelsPerFrame), level: preset.level, isMOV: isMOV)

        func passthroughLane() -> Transcoder.Lane? {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            guard reader.canAdd(output), writer.canAdd(input) else { return nil }
            input.expectsMediaDataInRealTime = false
            reader.add(output)
            writer.add(input)
            return .init(output: output, input: input, frameInterval: nil)
        }

        func reencodeLane(bitRate: Int, channels: Int) -> Transcoder.Lane? {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: channels,
                AVSampleRateKey: description.mSampleRate,
            ])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: channels,
                AVSampleRateKey: description.mSampleRate,
                AVEncoderBitRateKey: bitRate,
            ])
            guard reader.canAdd(output), writer.canAdd(input) else { return nil }
            input.expectsMediaDataInRealTime = false
            reader.add(output)
            writer.add(input)
            return .init(output: output, input: input, frameInterval: nil)
        }

        switch plan {
        case .passthrough:
            // If the container refuses the original audio, convert it instead.
            return passthroughLane() ?? reencodeLane(bitRate: 128_000, channels: min(Int(description.mChannelsPerFrame), 2))
        case .reencode(let bitRate, let channels):
            return reencodeLane(bitRate: bitRate, channels: channels)
        }
    }
}

// MARK: - Transcoding loop

/// Moves samples from the reader to the writer. AVFoundation objects aren't Sendable, so all work
/// happens on one serial queue and this class is the only thing that touches them.
final class Transcoder: @unchecked Sendable {
    struct Lane: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        /// For video: minimum spacing between frames, used to reduce the frame rate.
        let frameInterval: Double?
    }

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let lanes: [Lane]
    private let start: CMTime
    private let duration: Double
    private var progress: @Sendable (Double) -> Void
    /// Which kind of track drives the progress value.
    private let progressType: AVMediaType
    private let queue = DispatchQueue(label: "compress.video.transcode")
    private let lock = NSLock()
    private var cancelled = false
    private var stalled = false
    private var lastActivity = Date()

    init(
        reader: AVAssetReader, writer: AVAssetWriter, lanes: [Lane],
        start: CMTime, duration: Double, progress: @escaping @Sendable (Double) -> Void,
        tracksProgress: AVMediaType = .video
    ) {
        self.progressType = tracksProgress
        self.reader = reader
        self.writer = writer
        self.lanes = lanes
        self.start = start
        self.duration = duration
        self.progress = progress
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func noteActivity() {
        lock.lock()
        lastActivity = Date()
        lock.unlock()
    }

    private var isStalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stalled
    }

    /// If no sample moves for this long, the system's decoder or encoder is assumed to be stuck.
    private static let stallLimit: TimeInterval = 45

    /// Checks every few seconds that samples are still flowing. A blocked read is released by cancelling the reader.
    private func startWatchdog() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "compress.video.watchdog"))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [self] in
            lock.lock()
            let idle = Date().timeIntervalSince(lastActivity)
            if idle > Self.stallLimit { stalled = true }
            let shouldAbort = stalled
            lock.unlock()
            if shouldAbort {
                reader.cancelReading()
                writer.cancelWriting()
            }
        }
        timer.resume()
        return timer
    }

    /// Only raises a flag. The lanes notice it on their next callback and finish themselves; cancelling
    /// the writer here would stop those callbacks, and the loop would then never complete.
    private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func run() async throws {
        try Task.checkCancellation()
        guard reader.startReading() else { throw Self.failure(reader.error, "The video couldn't be read.") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw Self.failure(writer.error, "The compressed video couldn't be created.")
        }
        writer.startSession(atSourceTime: start)
        noteActivity()
        let watchdog = startWatchdog()
        // The timer and the lanes keep this object alive a little longer than `run`. The caller's progress
        // closure must not be among the things that linger, so drop it as soon as work is over.
        defer {
            watchdog.cancel()
            progress = { _ in }
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                for lane in lanes {
                    group.enter()
                    pump(lane, group: group)
                }
                group.notify(queue: queue) { continuation.resume() }
            }
        } onCancel: {
            cancel()
        }

        if isStalled {
            reader.cancelReading()
            writer.cancelWriting()
            throw CompressionError.failed("The video stopped responding and was skipped.")
        }
        if isCancelled || Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw Self.failure(reader.error, "The video couldn't be read.")
        }
        await writer.finishWriting()
        if writer.status == .failed {
            throw Self.failure(writer.error, "The compressed video couldn't be written.")
        }
    }

    /// Per-lane state, only touched on `queue`.
    private final class LaneState: @unchecked Sendable {
        var finished = false
        var nextDue = -Double.infinity
    }

    private func pump(_ lane: Lane, group: DispatchGroup) {
        let state = LaneState()
        let reportsProgress = lane.input.mediaType == progressType

        lane.input.requestMediaDataWhenReady(on: queue) { [self] in
            guard !state.finished else { return }
            while lane.input.isReadyForMoreMediaData {
                guard !isCancelled, let sample = lane.output.copyNextSampleBuffer() else {
                    state.finished = true
                    lane.input.markAsFinished()
                    group.leave()
                    return
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds

                if let interval = lane.frameInterval {
                    guard time + 0.0001 >= state.nextDue else { continue }
                    state.nextDue += interval
                    if state.nextDue <= time { state.nextDue = time + interval }
                }

                noteActivity()
                if !lane.input.append(sample) {
                    state.finished = true
                    lane.input.markAsFinished()
                    group.leave()
                    return
                }
                if reportsProgress, duration > 0 {
                    progress(min(max((time - start.seconds) / duration, 0), 1))
                }
            }
        }
    }

    /// AVFoundation's own messages are terse ("Cannot Save"), so add the reason and code when there is one.
    private static func failure(_ error: Error?, _ fallback: String) -> CompressionError {
        guard let error = error as NSError? else { return .failed(fallback) }
        var parts = [error.localizedDescription]
        if let reason = error.localizedFailureReason { parts.append(reason) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("\(underlying.localizedDescription) (\(underlying.domain) \(underlying.code))")
        } else {
            parts.append("(\(error.domain) \(error.code))")
        }
        return .failed(parts.joined(separator: " — "))
    }
}
