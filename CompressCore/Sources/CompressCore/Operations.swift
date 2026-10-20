import Foundation

/// The kinds of work the app can do on a file. Compression is one of many.
public enum OperationFamily: String, Sendable, Hashable, CaseIterable, Codable {
    case compress, resize, crop, rotate, convert, upscale, watermark, blurFaces, removeBackground, extractText, merge, split
}

/// A rectangle as fractions of the whole image, with the origin at the top left.
/// Because it is relative, one crop works for files of different sizes.
public struct NormalizedRect: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    /// The rectangle clamped so it stays inside the image and is at least a few pixels wide.
    public var clamped: NormalizedRect {
        let w = min(max(width, 0.01), 1), h = min(max(height, 0.01), 1)
        return NormalizedRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
    }

    public var isFull: Bool { x <= 0.0001 && y <= 0.0001 && width >= 0.9999 && height >= 0.9999 }
}

public enum ResizeMode: Sendable, Hashable, Codable {
    /// Scale down so the longest side is at most this many pixels.
    case fit(maxSide: Int)
    case percent(Double)
    /// Exactly this size. With `crop` the picture fills it and the overflow is cut off; otherwise it is stretched to fit inside.
    case exact(width: Int, height: Int, crop: Bool)
}

public struct ResizeSpec: Sendable, Hashable, Codable {
    public var mode: ResizeMode
    /// Allow making the picture bigger than it is.
    public var allowEnlarge: Bool

    public init(mode: ResizeMode = .fit(maxSide: 1920), allowEnlarge: Bool = false) {
        self.mode = mode
        self.allowEnlarge = allowEnlarge
    }
}

public struct RotateSpec: Sendable, Hashable, Codable {
    /// Clockwise quarter turns, 0...3.
    public var quarterTurns: Int
    public var flipHorizontal: Bool
    public var flipVertical: Bool

    public init(quarterTurns: Int = 1, flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }

    public var isIdentity: Bool { quarterTurns == 0 && !flipHorizontal && !flipVertical }
}

public enum ImageFormat: String, Sendable, Hashable, Codable, CaseIterable {
    case jpeg, png, heic, tiff, avif

    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    public var typeIdentifier: String {
        switch self {
        case .jpeg: "public.jpeg"
        case .png: "public.png"
        case .heic: "public.heic"
        case .tiff: "public.tiff"
        case .avif: "public.avif"
        }
    }
    public var displayName: String { self == .jpeg ? "JPEG" : rawValue.uppercased() }
    public var isLossy: Bool { self == .jpeg || self == .heic || self == .avif }
}

public enum AudioFormat: String, Sendable, Hashable, Codable, CaseIterable {
    case aac, alac, wav, aiff, caf

    public var fileExtension: String {
        switch self {
        case .aac, .alac: "m4a"
        default: rawValue
        }
    }
    public var displayName: String {
        switch self {
        case .aac: "M4A (AAC)"
        case .alac: "M4A (Lossless)"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .caf: "CAF"
        }
    }
}

public enum VideoFormat: String, Sendable, Hashable, Codable, CaseIterable {
    case mp4, mov, gif

    public var displayName: String { rawValue == "gif" ? "GIF" : rawValue.uppercased() }
}

/// What to turn a file into.
public enum ConvertTarget: Sendable, Hashable, Codable {
    case image(ImageFormat)
    case video(VideoFormat)
    case audio(AudioFormat)
    /// The sound track of a video.
    case videoToAudio(AudioFormat)
    /// Every page of a PDF as a picture.
    case pdfToImages(ImageFormat, dpi: Int)
    /// A picture as a one-page PDF.
    case imageToPDF
}

public struct ConvertSpec: Sendable, Hashable, Codable {
    public var target: ConvertTarget
    /// 0...1 for lossy formats.
    public var quality: Double

    public init(target: ConvertTarget, quality: Double = 0.85) {
        self.target = target
        self.quality = quality
    }
}

public struct UpscaleSpec: Sendable, Hashable, Codable {
    public var factor: Int
    /// How much to sharpen detail after enlarging, 0...1.
    public var sharpness: Double

    public init(factor: Int = 2, sharpness: Double = 0.5) {
        self.factor = min(max(factor, 2), 4)
        self.sharpness = min(max(sharpness, 0), 1)
    }
}

public enum WatermarkPosition: String, Sendable, Hashable, Codable, CaseIterable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight, tiled
}

public enum WatermarkContent: Sendable, Hashable, Codable {
    case text(String)
    /// A logo or picture, by file path.
    case image(path: String)
}

public struct WatermarkSpec: Sendable, Hashable, Codable {
    public var content: WatermarkContent
    public var position: WatermarkPosition
    /// Width of the mark as a fraction of the picture's width.
    public var scale: Double
    public var opacity: Double
    /// Text is drawn in white or black.
    public var darkText: Bool
    public var rotationDegrees: Double

    public init(
        content: WatermarkContent = .text("© Your Name"), position: WatermarkPosition = .bottomRight,
        scale: Double = 0.25, opacity: Double = 0.6, darkText: Bool = false, rotationDegrees: Double = 0
    ) {
        self.content = content
        self.position = position
        self.scale = min(max(scale, 0.03), 1)
        self.opacity = min(max(opacity, 0.05), 1)
        self.darkText = darkText
        self.rotationDegrees = rotationDegrees
    }
}

public enum BlurStyle: String, Sendable, Hashable, Codable, CaseIterable {
    case blur, pixelate, solid

    public var displayName: String {
        switch self {
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        case .solid: "Solid"
        }
    }
}

public struct BlurSpec: Sendable, Hashable, Codable {
    public var style: BlurStyle
    /// 0...1, how strong the effect is.
    public var strength: Double

    public init(style: BlurStyle = .blur, strength: Double = 0.7) {
        self.style = style
        self.strength = min(max(strength, 0), 1)
    }
}

public enum TextFormat: String, Sendable, Hashable, Codable, CaseIterable {
    case markdown, plain

    public var fileExtension: String { self == .markdown ? "md" : "txt" }
    public var displayName: String { self == .markdown ? "Markdown" : "Plain text" }
}

public struct TextSpec: Sendable, Hashable, Codable {
    public var format: TextFormat
    /// Read text from pictures and scanned pages with on-device text recognition.
    public var recognizeText: Bool

    public init(format: TextFormat = .markdown, recognizeText: Bool = true) {
        self.format = format
        self.recognizeText = recognizeText
    }
}

public enum SplitMode: Sendable, Hashable, Codable {
    case everyPage
    /// Page ranges such as `1-3, 5, 8-10`.
    case ranges(String)
    case everyN(Int)
}

public struct SplitSpec: Sendable, Hashable, Codable {
    public var mode: SplitMode

    public init(mode: SplitMode = .everyPage) { self.mode = mode }
}

public struct MergeSpec: Sendable, Hashable, Codable {
    /// Every file to combine, in order. PDFs and pictures.
    public var sources: [URL]

    public init(sources: [URL]) { self.sources = sources }
}

public enum ToolAction: Sendable, Hashable, Codable {
    case compress
    case resize(ResizeSpec)
    case crop(NormalizedRect)
    case rotate(RotateSpec)
    case convert(ConvertSpec)
    case upscale(UpscaleSpec)
    case watermark(WatermarkSpec)
    case blurFaces(BlurSpec)
    case removeBackground
    case extractText(TextSpec)
    case merge(MergeSpec)
    case split(SplitSpec)

    public var family: OperationFamily {
        switch self {
        case .compress: .compress
        case .resize: .resize
        case .crop: .crop
        case .rotate: .rotate
        case .convert: .convert
        case .upscale: .upscale
        case .watermark: .watermark
        case .blurFaces: .blurFaces
        case .removeBackground: .removeBackground
        case .extractText: .extractText
        case .merge: .merge
        case .split: .split
        }
    }
}

public extension OperationFamily {
    /// Added to the file name of the result, e.g. `photo-resized.jpg`.
    var suffix: String {
        switch self {
        case .compress: "-compressed"
        case .resize: "-resized"
        case .crop: "-cropped"
        case .rotate: "-rotated"
        case .convert: "-converted"
        case .upscale: "-upscaled"
        case .watermark: "-watermarked"
        case .blurFaces: "-blurred"
        case .removeBackground: "-nobg"
        case .extractText: ""
        case .merge: "-merged"
        case .split: "-split"
        }
    }
}
