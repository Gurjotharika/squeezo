import AVFoundation
import Foundation

/// Re-encodes audio files as AAC in an .m4a container.
public struct AudioCompressor: Compressor {
    public var kind: MediaKind { .audio }

    public init() {}

    public func outputExtension(for input: URL, preset: Preset) -> String { "m4a" }

    static func bitRate(for level: QualityLevel, channels: Int) -> Int {
        let stereo: Int
        switch level {
        case .highest: stereo = 192_000
        case .high: stereo = 128_000
        case .medium: stereo = 96_000
        case .low: stereo = 64_000
        }
        return channels == 1 ? stereo * 3 / 4 : stereo
    }

    public func compress(
        input: URL,
        output: URL,
        preset: Preset,
        progress: @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        let unreadable = CompressionError.failed("“\(input.lastPathComponent)” can't be read as audio.")
        let asset = AVURLAsset(url: input)
        let track: AVAssetTrack
        let duration: Double
        do {
            guard try await asset.load(.isReadable), let first = try await asset.loadTracks(withMediaType: .audio).first else {
                throw unreadable
            }
            track = first
            duration = try await asset.load(.duration).seconds
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw unreadable
        }

        guard let format = try await track.load(.formatDescriptions).first,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { throw unreadable }
        let channels = min(max(Int(description.mChannelsPerFrame), 1), 2)
        let sampleRate = min(description.mSampleRate, 48_000)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        if !preset.stripMetadata, let common = try? await asset.load(.commonMetadata) { writer.metadata = common }

        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: channels,
            AVSampleRateKey: sampleRate,
        ])
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: channels,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: Self.bitRate(for: preset.level, channels: channels),
        ])
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
