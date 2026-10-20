import AVFoundation
import Foundation

/// Converts audio between formats, or pulls the sound out of a video.
public struct AudioEditor: Compressor {
    public let kind: MediaKind
    public var family: OperationFamily { .convert }

    public init(kind: MediaKind) { self.kind = kind }

    private func format(_ preset: Preset) -> AudioFormat {
        guard case .convert(let spec) = preset.operation else { return .aac }
        switch spec.target {
        case .audio(let f), .videoToAudio(let f): return f
        default: return .aac
        }
    }

    public func outputExtension(for input: URL, preset: Preset) -> String { format(preset).fileExtension }

    public func compress(input: URL, output: URL, preset: Preset, progress: @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        let unreadable = CompressionError.failed("“\(input.lastPathComponent)” has no sound that can be read.")
        let asset = AVURLAsset(url: input)
        let track: AVAssetTrack, duration: Double
        do {
            guard try await asset.load(.isReadable), let first = try await asset.loadTracks(withMediaType: .audio).first else { throw unreadable }
            track = first
            duration = try await asset.load(.duration).seconds
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw unreadable
        }
        guard let description = try await track.load(.formatDescriptions).first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { throw unreadable }

        let target = format(preset)
        let channels = min(max(Int(asbd.mChannelsPerFrame), 1), 2)
        let rate = min(asbd.mSampleRate, 48_000)
        var quality = 0.85
        if case .convert(let spec) = preset.operation { quality = spec.quality }

        let writerSettings: [String: Any]
        let fileType: AVFileType
        switch target {
        case .aac:
            fileType = .m4a
            let stereo = Int(64_000 + quality * 192_000)
            writerSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: channels, AVSampleRateKey: rate,
                              AVEncoderBitRateKey: channels == 1 ? stereo * 3 / 4 : stereo]
        case .alac:
            fileType = .m4a
            writerSettings = [AVFormatIDKey: kAudioFormatAppleLossless, AVNumberOfChannelsKey: channels, AVSampleRateKey: rate,
                              AVEncoderBitDepthHintKey: 16]
        case .wav, .aiff, .caf:
            fileType = target == .wav ? .wav : (target == .aiff ? .aiff : .caf)
            writerSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: channels, AVSampleRateKey: asbd.mSampleRate,
                              AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: target == .aiff,
                              AVLinearPCMIsNonInterleaved: false]
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        if !preset.stripMetadata, let common = try? await asset.load(.commonMetadata), target != .wav { writer.metadata = common }

        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: channels, AVSampleRateKey: target == .aac || target == .alac ? rate : asbd.mSampleRate,
        ])
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(readerOutput), writer.canAdd(writerInput) else { throw unreadable }
        reader.add(readerOutput)
        writer.add(writerInput)

        try await withoutActuallyEscaping(progress) { escapable in
            let transcoder = Transcoder(
                reader: reader, writer: writer, lanes: [.init(output: readerOutput, input: writerInput, frameInterval: nil)],
                start: .zero, duration: duration, progress: escapable, tracksProgress: .audio)
            try await transcoder.run()
        }
    }
}
