import Foundation

/// Converts between formats. One engine per kind of file, which hands the work to the right specialist.
public struct ConvertEngine: Compressor {
    public let kind: MediaKind
    public var family: OperationFamily { .convert }

    public init(kind: MediaKind) { self.kind = kind }

    private func specialist(for preset: Preset) -> any Compressor {
        let target: ConvertTarget? = { if case .convert(let spec) = preset.operation { spec.target } else { nil } }()
        switch kind {
        case .image: return ImageEditor(.convert)
        case .gif: return GIFEditor(.convert)
        case .pdf: return PDFEditor(.convert)
        case .audio: return AudioEditor(kind: .audio)
        case .video:
            if case .videoToAudio? = target { return AudioEditor(kind: .video) }
            return VideoCompressor(family: .convert)
        case .document: return ImageEditor(.convert)  // never registered; documents can't be converted
        }
    }

    public func outputExtension(for input: URL, preset: Preset) -> String {
        specialist(for: preset).outputExtension(for: input, preset: preset)
    }

    public func compress(input: URL, output: URL, preset: Preset, progress: @Sendable (Double) -> Void) async throws {
        try await specialist(for: preset).compress(input: input, output: output, preset: preset, progress: progress)
    }
}

public enum Engines {
    /// Every engine in the app. The registry knows which kind of work each can do on which kind of file.
    public static func all() -> [any Compressor] {
        var engines: [any Compressor] = [
            // Shrinking files.
            ImageCompressor(), VideoCompressor(), GIFCompressor(), PDFCompressor(), DocumentCompressor(), AudioCompressor(),
            // Converting.
            ConvertEngine(kind: .image), ConvertEngine(kind: .video), ConvertEngine(kind: .gif),
            ConvertEngine(kind: .pdf), ConvertEngine(kind: .audio),
            // Reading text.
            TextEditor(kind: .pdf), TextEditor(kind: .image),
            // PDF pages.
            PDFEditor(.split), PDFEditor(.merge), PDFEditor(.merge, kind: .image),
            PDFEditor(.rotate), PDFEditor(.crop), PDFEditor(.watermark),
            ImageEditor(.removeBackground),
        ]
        for family in [OperationFamily.resize, .crop, .rotate, .upscale, .watermark, .blurFaces] {
            engines.append(ImageEditor(family))
            engines.append(VideoEditor(family))
        }
        for family in [OperationFamily.resize, .crop, .rotate, .watermark] { engines.append(GIFEditor(family)) }
        return engines
    }

    public static func registry() -> CompressorRegistry { CompressorRegistry(all()) }
}
