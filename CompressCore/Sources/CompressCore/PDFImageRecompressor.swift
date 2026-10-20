import CoreGraphics
import Foundation
import ImageIO

/// Re-encodes the larger images in a PDF as smaller JPEGs. Anything it can't handle with certainty
/// (masks, odd colour spaces, unusual filters) is left exactly as it was.
struct PDFImageRecompressor {
    let file: PDFFile
    let level: QualityLevel
    let maxDimension: Int?

    /// Images smaller than this aren't worth the trouble.
    private let minimumBytes = 16 * 1024

    /// Returns the replacement dictionary and stream data, or nil to keep the image unchanged.
    func recompress(_ object: PDFIndirectObject) -> (dict: PDFDict, data: Data)? {
        guard var dict = object.dict, dict["Subtype"]?.nameValue == "Image",
              let range = object.stream, range.count >= minimumBytes,
              dict["ImageMask"] != .bool(true), dict["Mask"] == nil, dict["Decode"] == nil,
              let width = dict["Width"]?.intValue, let height = dict["Height"]?.intValue,
              width > 0, height > 0,
              let components = componentCount(dict["ColorSpace"])
        else { return nil }

        let filters = PDFFile.filterNames(dict["Filter"])
        let raw = Data(file.data[range])
        let source: CGImage

        if filters == ["DCTDecode"] || filters == ["DCT"] {
            guard let image = CGImageSourceCreateWithData(raw as CFData, nil)
                .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }),
                  image.colorSpace?.numberOfComponents == components,
                  image.width == width, image.height == height
            else { return nil }
            source = image
        } else if filters.isEmpty || filters == ["FlateDecode"] || filters == ["Fl"] {
            guard (dict["BitsPerComponent"]?.intValue ?? 8) == 8,
                  let samples = try? file.decodeStream(dict: dict, raw: raw),
                  samples.count >= width * height * components,
                  let provider = CGDataProvider(data: samples as CFData),
                  let image = CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * components,
                    bytesPerRow: width * components,
                    space: components == 3 ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { return nil }
            source = image
        } else {
            return nil
        }

        var maxSide = level.pdfMaxImageSide
        if let cap = maxDimension, cap > 0 { maxSide = min(maxSide, cap) }
        let scale = min(1, Double(maxSide) / Double(max(width, height)))
        let newWidth = max(1, Int((Double(width) * scale).rounded()))
        let newHeight = max(1, Int((Double(height) * scale).rounded()))

        guard let jpeg = encodeJPEG(source, width: newWidth, height: newHeight, components: components) else { return nil }
        // Keep the original unless the new one is clearly smaller.
        guard Double(jpeg.count) < Double(raw.count) * 0.9 else { return nil }

        dict["Filter"] = .name("DCTDecode")
        dict["DecodeParms"] = nil
        dict["DP"] = nil
        dict["Width"] = .int(newWidth)
        dict["Height"] = .int(newHeight)
        dict["BitsPerComponent"] = .int(8)
        return (dict, jpeg)
    }

    private func encodeJPEG(_ image: CGImage, width: Int, height: Int, components: Int) -> Data? {
        let space = components == 3 ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray()
        let info = components == 3 ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.none.rawValue
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [
            kCGImageDestinationLossyCompressionQuality: level.pdfJPEGQuality,
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// 1 or 3 for the colour spaces whose samples we can carry over unchanged, otherwise nil.
    private func componentCount(_ value: PDFObject?) -> Int? {
        switch file.resolve(value) {
        case .name("DeviceRGB")?, .name("RGB")?, .name("CalRGB")?: return 3
        case .name("DeviceGray")?, .name("G")?, .name("CalGray")?: return 1
        case .array(let items)?:
            guard let kind = items.first?.nameValue else { return nil }
            switch kind {
            case "CalRGB": return 3
            case "CalGray": return 1
            case "ICCBased":
                guard items.count > 1, case .ref(let n, _) = items[1], let profile = file.object(n),
                      let channels = profile.dict?["N"]?.intValue, channels == 1 || channels == 3
                else { return nil }
                return channels
            default: return nil
            }
        default: return nil
        }
    }
}
