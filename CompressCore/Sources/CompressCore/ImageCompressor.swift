import CoreGraphics
import Foundation
import ImageIO

/// Compresses still images with ImageIO. PNG gets an extra palette path for graphics and screenshots.
///
/// Formats ImageIO can't write (WebP, for now) and multi-frame files other than TIFF are copied
/// unchanged, so the queue reports them as already optimal rather than failing.
public struct ImageCompressor: Compressor {
    public var kind: MediaKind { .image }

    public init() {}

    public func outputExtension(for input: URL, preset: Preset) -> String {
        input.pathExtension.lowercased() == "bmp" ? "png" : input.pathExtension
    }

    public func compress(
        input: URL,
        output: URL,
        preset: Preset,
        progress: @Sendable (Double) -> Void
    ) async throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let typeID = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0
        else {
            throw CompressionError.failed("“\(input.lastPathComponent)” can't be read as an image.")
        }
        let frames = CGImageSourceGetCount(source)
        progress(0.05)

        let format = Format(typeIdentifier: typeID, frames: frames)
        let data: Data
        switch format {
        case .passthrough:
            try FileManager.default.copyItem(at: input, to: output)
            return
        case .unsupported:
            throw CompressionError.failed("\(input.pathExtension.uppercased()) images aren't supported yet.")
        case .jpeg:
            data = try encode(source, frames: frames, type: "public.jpeg", quality: preset.level.quality, preset: preset)
        case .heic:
            data = try encode(source, frames: frames, type: "public.heic", quality: preset.level.quality, preset: preset)
        case .avif:
            data = try encode(source, frames: frames, type: "public.avif", quality: preset.level.quality, preset: preset)
        case .tiff:
            data = try encode(source, frames: frames, type: "public.tiff", quality: nil, preset: preset, lzw: true)
        case .png:
            data = try compressPNG(source, preset: preset, progress: progress)
        }
        try Task.checkCancellation()
        progress(0.95)
        try data.write(to: output)
    }

    // MARK: Format selection

    private enum Format {
        case jpeg, heic, avif, tiff, png, passthrough, unsupported

        init(typeIdentifier: String, frames: Int) {
            switch typeIdentifier {
            case "public.tiff": self = .tiff
            case _ where frames > 1: self = .passthrough
            case "public.jpeg": self = .jpeg
            case "public.heic", "public.heif": self = .heic
            case "public.avif": self = .avif
            case "public.png", "com.microsoft.bmp": self = .png
            case "org.webmproject.webp": self = .passthrough
            default: self = .unsupported
            }
        }
    }

    // MARK: ImageIO encoding (JPEG, HEIC, AVIF, TIFF)

    private func encode(
        _ source: CGImageSource,
        frames: Int,
        type: String,
        quality: Double?,
        preset: Preset,
        lzw: Bool = false
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, frames, nil) else {
            throw CompressionError.failed("This Mac can't write \(type) images.")
        }

        for index in 0..<frames {
            try Task.checkCancellation()
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1

            var options: [CFString: Any] = [:]
            if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
            if #available(macOS 15.0, *) { options[kCGImageDestinationPreserveGainMap] = true }

            if preset.stripMetadata {
                options[kCGImageMetadataShouldExcludeGPS] = true
                options[kCGImageMetadataShouldExcludeXMP] = true
                for key in Self.strippedDictionaries { options[key] = kCFNull }
                options[kCGImagePropertyOrientation] = orientation
            }
            if lzw {
                // 5 = LZW. Lossless, and supported everywhere TIFF is.
                options[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
            }

            if let maxSide = preset.maxDimension, needsResize(properties, maxSide: maxSide) {
                guard let image = scaledImage(source, index: index, maxSide: maxSide) else {
                    throw CompressionError.failed("The image couldn't be resized.")
                }
                // The thumbnail already has its orientation applied.
                options[kCGImagePropertyOrientation] = 1
                if !preset.stripMetadata { Self.carryMetadata(from: properties, into: &options, size: image) }
                CGImageDestinationAddImage(destination, image, options as CFDictionary)
            } else {
                CGImageDestinationAddImageFromSource(destination, source, index, options as CFDictionary)
            }
        }

        guard CGImageDestinationFinalize(destination) else {
            throw CompressionError.failed("The compressed image couldn't be written.")
        }
        return data as Data
    }

    private static var strippedDictionaries: [CFString] { [
        kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary,
        kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyMakerAppleDictionary,
        kCGImagePropertyMakerCanonDictionary, kCGImagePropertyMakerNikonDictionary,
    ] }

    /// Copies the descriptive metadata of the source to a resized image.
    static func carryMetadata(from properties: [CFString: Any], into options: inout [CFString: Any], size: CGImage) {
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
            guard var dictionary = properties[key] as? [CFString: Any] else { continue }
            if key == kCGImagePropertyExifDictionary {
                dictionary[kCGImagePropertyExifPixelXDimension] = size.width
                dictionary[kCGImagePropertyExifPixelYDimension] = size.height
            }
            if key == kCGImagePropertyTIFFDictionary { dictionary[kCGImagePropertyTIFFOrientation] = 1 }
            options[key] = dictionary
        }
    }

    private func needsResize(_ properties: [CFString: Any], maxSide: Int) -> Bool {
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return max(width, height) > maxSide
    }

    private func scaledImage(_ source: CGImageSource, index: Int, maxSide: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ] as CFDictionary)
    }

    // MARK: PNG

    private func compressPNG(
        _ source: CGImageSource,
        preset: Preset,
        progress: @Sendable (Double) -> Void
    ) throws -> Data {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let depth = properties[kCGImagePropertyDepth] as? Int ?? 8

        let image: CGImage?
        if let maxSide = preset.maxDimension, needsResize(properties, maxSide: maxSide) {
            image = scaledImage(source, index: 0, maxSide: maxSide)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let image else { throw CompressionError.failed("The image couldn't be decoded.") }
        progress(0.2)
        try Task.checkCancellation()

        // Candidate 1: lossless ImageIO re-encode.
        let lossless = try encodePNGWithImageIO(image, properties: properties, preset: preset)
        progress(0.4)

        // Candidate 2: palette. Exact (lossless) when the image has few colours, reduced otherwise.
        // 16-bit images are never reduced silently at the lossless levels.
        var best = lossless
        if let candidate = try paletteCandidate(image, preset: preset, sourceDepth: depth, progress: progress),
           candidate.count < best.count {
            best = candidate
        }
        return best
    }

    private func encodePNGWithImageIO(_ image: CGImage, properties: [CFString: Any], preset: Preset) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw CompressionError.failed("This Mac can't write PNG images.")
        }
        var options: [CFString: Any] = [:]
        if !preset.stripMetadata {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary,
                        kCGImagePropertyPNGDictionary] {
                if let value = properties[key] { options[key] = value }
            }
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CompressionError.failed("The compressed image couldn't be written.")
        }
        return data as Data
    }

    private func paletteCandidate(
        _ image: CGImage,
        preset: Preset,
        sourceDepth: Int,
        progress: @Sendable (Double) -> Void
    ) throws -> Data? {
        guard let rgba = RGBAImage(image) else { return nil }
        try Task.checkCancellation()

        let result: ColorQuantizer.Result
        if sourceDepth <= 8, let exact = ColorQuantizer.exactPalette(pixels: rgba.pixels) {
            result = exact
        } else if let colors = preset.level.pngPaletteSize {
            progress(0.6)
            // Dithering helps photos but adds noise to flat graphics, so keep it light.
            result = ColorQuantizer.quantize(
                pixels: rgba.pixels, width: rgba.width, height: rgba.height,
                maxColors: colors, ditherStrength: 0.5)
        } else {
            return nil
        }
        try Task.checkCancellation()
        progress(0.85)
        return try PNGEncoder.encodeIndexed(
            width: rgba.width, height: rgba.height, indices: result.indices,
            palette: result.palette, colorInfo: rgba.colorInfo)
    }
}

// MARK: - Pixel access

/// An image as straight (non-premultiplied) 8-bit RGBA.
struct RGBAImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]
    let colorInfo: PNGEncoder.ColorInfo

    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        // Draw in the image's own RGB space so colours aren't shifted; anything else goes to sRGB.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        var space = sRGB
        if let own = image.colorSpace, own.model == .rgb { space = own }

        func makeContext(_ space: CGColorSpace) -> CGContext? {
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        var context = makeContext(space)
        if context == nil {
            space = sRGB
            context = makeContext(sRGB)
        }
        guard let context, let base = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let source = base.bindMemory(to: UInt8.self, capacity: pixels.count)
        for i in 0..<width * height {
            let a = Int(source[i * 4 + 3])
            for k in 0..<3 {
                let c = Int(source[i * 4 + k])
                pixels[i * 4 + k] = a == 0 || a == 255 ? UInt8(c) : UInt8(min(255, (c * 255 + a / 2) / a))
            }
            pixels[i * 4 + 3] = UInt8(a)
        }

        self.width = width
        self.height = height
        self.pixels = pixels
        if space.name as String? == CGColorSpace.sRGB as String {
            colorInfo = .srgb
        } else if let profile = space.copyICCData() as Data? {
            colorInfo = .icc(name: "ICC profile", profile: profile)
        } else {
            colorInfo = .none
        }
    }
}
