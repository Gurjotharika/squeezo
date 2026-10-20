import CoreGraphics
import Foundation
import ImageIO

/// Resize, crop, rotate, convert, enlarge, watermark and privacy tools for still pictures.
/// One instance handles one kind of work; the app registers one per tool.
public struct ImageEditor: Compressor {
    public let family: OperationFamily
    public var kind: MediaKind { .image }

    public init(_ family: OperationFamily) { self.family = family }

    /// Formats this Mac can write. Anything else is saved as PNG so nothing is lost.
    private static func writableType(for source: String) -> ImageFormat {
        switch source {
        case "public.jpeg": .jpeg
        case "public.heic", "public.heif": .heic
        case "public.tiff": .tiff
        case "public.avif": .avif
        default: .png
        }
    }

    private func targetFormat(for input: URL, preset: Preset) -> ImageFormat? {
        switch preset.operation {
        case .convert(let spec):
            if case .image(let format) = spec.target { return format }
            return nil
        case .removeBackground:
            return .png
        default:
            guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), let type = CGImageSourceGetType(source) as String? else {
                return .png
            }
            return Self.writableType(for: type)
        }
    }

    public func outputExtension(for input: URL, preset: Preset) -> String {
        if case .convert(let spec) = preset.operation, case .imageToPDF = spec.target { return "pdf" }
        guard let format = targetFormat(for: input, preset: preset) else { return input.pathExtension }
        // Keep the original spelling of the extension when the format doesn't change.
        let original = input.pathExtension.lowercased()
        if (format == .jpeg && ["jpg", "jpeg"].contains(original)) || (format == .tiff && ["tif", "tiff"].contains(original)) {
            return input.pathExtension
        }
        return format.fileExtension
    }

    public func compress(
        input: URL, output: URL, preset: Preset, progress: @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        let loaded = try ImageTools.load(input)
        progress(0.2)
        var image = loaded.image

        switch preset.operation {
        case .resize(let spec): image = try ImageTools.resize(image, spec: spec)
        case .crop(let rect): image = try ImageTools.crop(image, to: rect)
        case .rotate(let spec): image = try ImageTools.rotate(image, spec: spec)
        case .upscale(let spec): image = try ImageTools.upscale(image, spec: spec)
        case .watermark(let spec): image = try ImageTools.watermark(image, spec: spec)
        case .blurFaces(let spec):
            let faces = ImageTools.detectFaces(in: image)
            if faces.isEmpty { throw CompressionError.failed("No faces were found in “\(input.lastPathComponent)”.") }
            image = try ImageTools.obscure(image, regions: faces, spec: spec)
        case .removeBackground: image = try ImageTools.removeBackground(image)
        case .convert(let spec):
            if case .imageToPDF = spec.target {
                try Self.writePDF(image, to: output)
                progress(1)
                return
            }
        default:
            throw CompressionError.failed("This tool doesn't work on images.")
        }
        try Task.checkCancellation()
        progress(0.7)

        let format = targetFormat(for: input, preset: preset) ?? .png
        var quality: Double?
        if format.isLossy {
            if case .convert(let spec) = preset.operation { quality = spec.quality } else { quality = 0.92 }
        }
        let data = try ImageTools.encode(
            image, type: format.typeIdentifier, quality: quality, properties: loaded.properties, stripMetadata: preset.stripMetadata)
        try data.write(to: output)
    }

    /// A one-page PDF whose page is the picture at about 150 pixels per inch.
    static func writePDF(_ image: CGImage, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / 150, height: Double(image.height) * 72 / 150)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CompressionError.failed("The PDF couldn't be created.")
        }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
    }
}
