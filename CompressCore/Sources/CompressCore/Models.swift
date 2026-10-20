import Foundation

public typealias JobID = UUID

/// How hard to compress. Higher levels keep more quality and save less space.
public enum QualityLevel: String, Sendable, CaseIterable, Codable {
    case highest, high, medium, low

    /// Normalised quality in 0...1 that compressors map to their own scale.
    public var quality: Double {
        switch self {
        case .highest: 0.95
        case .high: 0.85
        case .medium: 0.65
        case .low: 0.40
        }
    }

    /// Palette size for lossy PNG, or nil to keep PNG lossless.
    public var pngPaletteSize: Int? {
        switch self {
        case .highest, .high: nil
        case .medium: 256
        case .low: 64
        }
    }

    /// Constant-quality setting for the video encoder, 0...1. Unlike a fixed bitrate this spends
    /// bits only where the picture needs them, so static or simple footage shrinks the most.
    public var videoQuality: Double {
        switch self {
        case .highest: 0.70
        case .high: 0.55
        case .medium: 0.45
        case .low: 0.30
        }
    }

    /// Longest side, in pixels, that images inside a PDF are scaled down to.
    public var pdfMaxImageSide: Int {
        switch self {
        case .highest: 3000
        case .high: 2200
        case .medium: 1600
        case .low: 1100
        }
    }

    public var pdfJPEGQuality: Double {
        switch self {
        case .highest: 0.85
        case .high: 0.70
        case .medium: 0.55
        case .low: 0.40
        }
    }

    /// GIF palette size, transparent entry included.
    public var gifPaletteSize: Int {
        switch self {
        case .highest: 256
        case .high: 128
        case .medium: 64
        case .low: 32
        }
    }

    /// How far (per colour channel, 0–255) a pixel may drift from the previous frame before it is
    /// re-coded. Larger values make animations much smaller and slightly noisier.
    public var gifTolerance: Int {
        switch self {
        case .highest: 0
        case .high: 3
        case .medium: 8
        case .low: 16
        }
    }

    /// Strength of the ordered dither used to hide banding in GIFs.
    public var gifDither: Float {
        switch self {
        case .highest: 10
        case .high: 8
        case .medium: 5
        case .low: 0
        }
    }

    public var displayName: String {
        switch self {
        case .highest: "Highest"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }
}

public enum VideoCodec: String, Sendable, CaseIterable, Codable {
    /// Smaller files. Plays on every Mac and iPhone from the last several years.
    case hevc
    /// Larger files, plays everywhere.
    case h264

    public var displayName: String {
        switch self {
        case .hevc: "HEVC (smaller)"
        case .h264: "H.264 (most compatible)"
        }
    }
}

public struct Preset: Sendable, Hashable, Codable {
    public var level: QualityLevel
    public var stripMetadata: Bool
    /// Longest side in pixels that images and videos are scaled down to. Nil keeps the original size.
    public var maxDimension: Int?
    public var videoCodec: VideoCodec
    /// Frame rate videos and GIFs are capped at. Nil keeps the original (12 when making a GIF from video).
    public var maxFrameRate: Int?
    /// Turns videos into animated GIFs instead of compressing them as video.
    public var videoToGIF: Bool
    /// Longest stretch of video, in seconds, that goes into a GIF. Nil means 15.
    public var gifMaxSeconds: Double?
    /// What to do with the file. Compression unless the user picked another tool.
    public var operation: ToolAction

    public init(
        level: QualityLevel = .high,
        stripMetadata: Bool = false,
        maxDimension: Int? = nil,
        videoCodec: VideoCodec = .hevc,
        maxFrameRate: Int? = nil,
        videoToGIF: Bool = false,
        gifMaxSeconds: Double? = nil,
        operation: ToolAction = .compress
    ) {
        self.level = level
        self.stripMetadata = stripMetadata
        self.maxDimension = maxDimension
        self.videoCodec = videoCodec
        self.maxFrameRate = maxFrameRate
        self.videoToGIF = videoToGIF
        self.gifMaxSeconds = gifMaxSeconds
        self.operation = operation
    }

    public static let `default` = Preset()
}

/// Where the compressed file ends up.
public enum OutputPolicy: Sendable, Hashable {
    /// Overwrite the original. If the extension changes, the original goes to the Trash.
    case replaceOriginal
    /// Replace the original, but move it to the Trash first so it can be recovered.
    case replaceAndTrash
    /// Save next to the original with a suffix added to the name, e.g. `photo-compressed.jpg`.
    case suffix(String)
    /// Save into a chosen folder, keeping the file name.
    case folder(URL)
}

public struct JobResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case compressed
        /// The compressed file was not smaller, so the original was left untouched.
        case keptOriginal
        /// A non-compression operation finished; the result is a new file, not a smaller one.
        case processed
    }

    public var outputURL: URL
    public var originalBytes: Int64
    public var outputBytes: Int64
    public var outcome: Outcome
    /// Where the original went when it was moved to the Trash, so the change can be undone.
    public var backupURL: URL?

    public init(outputURL: URL, originalBytes: Int64, outputBytes: Int64, outcome: Outcome, backupURL: URL? = nil) {
        self.outputURL = outputURL
        self.originalBytes = originalBytes
        self.outputBytes = outputBytes
        self.outcome = outcome
        self.backupURL = backupURL
    }

    public var savedBytes: Int64 { max(0, originalBytes - outputBytes) }

    /// Fraction of the original size that was saved, 0...1.
    public var savingsRatio: Double {
        originalBytes > 0 ? Double(savedBytes) / Double(originalBytes) : 0
    }
}

public enum JobState: Sendable, Equatable {
    case queued
    case running(progress: Double)
    case completed(JobResult)
    case failed(String)
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .queued, .running: false
        }
    }
}

public struct CompressionJob: Sendable, Identifiable, Equatable {
    public let id: JobID
    public let sourceURL: URL
    public let kind: MediaKind
    public var preset: Preset
    public var outputPolicy: OutputPolicy
    public var state: JobState

    public init(
        id: JobID = JobID(),
        sourceURL: URL,
        kind: MediaKind,
        preset: Preset,
        outputPolicy: OutputPolicy,
        state: JobState = .queued
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.kind = kind
        self.preset = preset
        self.outputPolicy = outputPolicy
        self.state = state
    }
}

public enum JobEvent: Sendable {
    case changed(CompressionJob)
    case removed(JobID)
}

public enum CompressionError: LocalizedError, Equatable {
    case noCompressor(MediaKind)
    case outputMissing
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noCompressor(let kind): "No compressor is available for \(kind.rawValue) files."
        case .outputMissing: "The compressor did not produce an output file."
        case .failed(let message): message
        }
    }
}
