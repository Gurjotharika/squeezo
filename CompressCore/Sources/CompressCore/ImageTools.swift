import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import Vision

/// Picture operations shared by images, GIF frames, video frames and PDF pages.
enum ImageTools {
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: Loading and drawing

    struct Loaded {
        var image: CGImage
        var properties: [CFString: Any]
        var typeIdentifier: String
    }

    /// Reads the first picture with its rotation already applied.
    static func load(_ url: URL) throws -> Loaded {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String? else {
            throw CompressionError.failed("“\(url.lastPathComponent)” can't be read as an image.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
        ] as CFDictionary)
        guard let image else { throw CompressionError.failed("“\(url.lastPathComponent)” couldn't be decoded.") }
        return Loaded(image: image, properties: properties, typeIdentifier: type)
    }

    /// A bitmap context in the picture's own colour space (or sRGB), with room for transparency if it has any.
    static func makeContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        var space = sRGB
        if let own = image.colorSpace, own.model == .rgb { space = own }
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let info = hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: info)
    }

    // MARK: Geometry

    static func resizedSize(_ size: CGSize, spec: ResizeSpec) -> CGSize {
        var target: CGSize
        switch spec.mode {
        case .fit(let maxSide):
            let scale = Double(maxSide) / Double(max(size.width, size.height))
            target = CGSize(width: size.width * scale, height: size.height * scale)
        case .percent(let percent):
            target = CGSize(width: size.width * percent / 100, height: size.height * percent / 100)
        case .exact(let w, let h, _):
            target = CGSize(width: w, height: h)
        }
        if !spec.allowEnlarge, case .exact = spec.mode {
            // An exact size may enlarge only if allowed; otherwise keep what we have.
            if target.width > size.width || target.height > size.height { target = size }
        } else if !spec.allowEnlarge, target.width > size.width || target.height > size.height {
            target = size
        }
        return CGSize(width: max(1, target.width.rounded()), height: max(1, target.height.rounded()))
    }

    static func resize(_ image: CGImage, spec: ResizeSpec) throws -> CGImage {
        let source = CGSize(width: image.width, height: image.height)
        var working = image
        if case .exact(let w, let h, let crop) = spec.mode, crop {
            // Fill the target shape, then cut off what overflows.
            let targetRatio = Double(w) / Double(h)
            let ratio = source.width / source.height
            var rect = CGRect(origin: .zero, size: source)
            if ratio > targetRatio {
                rect.size.width = source.height * targetRatio
                rect.origin.x = (source.width - rect.width) / 2
            } else {
                rect.size.height = source.width / targetRatio
                rect.origin.y = (source.height - rect.height) / 2
            }
            working = image.cropping(to: rect.integral) ?? image
        }
        let size = resizedSize(CGSize(width: working.width, height: working.height), spec: spec)
        if Int(size.width) == working.width, Int(size.height) == working.height { return working }
        return try draw(working, size: size, interpolation: .high)
    }

    static func draw(_ image: CGImage, size: CGSize, interpolation: CGInterpolationQuality) throws -> CGImage {
        guard let context = makeContext(width: Int(size.width), height: Int(size.height), like: image) else {
            throw CompressionError.failed("There isn't enough memory to resize this image.")
        }
        context.interpolationQuality = interpolation
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let result = context.makeImage() else { throw CompressionError.failed("The image couldn't be resized.") }
        return result
    }

    static func crop(_ image: CGImage, to rect: NormalizedRect) throws -> CGImage {
        let r = rect.clamped
        let w = Double(image.width), h = Double(image.height)
        let pixels = CGRect(x: (r.x * w).rounded(), y: (r.y * h).rounded(), width: max(1, (r.width * w).rounded()), height: max(1, (r.height * h).rounded()))
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let cropped = image.cropping(to: pixels) else { throw CompressionError.failed("The crop area is outside the image.") }
        return cropped
    }

    static func rotate(_ image: CGImage, spec: RotateSpec) throws -> CGImage {
        if spec.isIdentity { return image }
        let swap = spec.quarterTurns % 2 == 1
        let w = image.width, h = image.height
        let size = CGSize(width: swap ? h : w, height: swap ? w : h)
        guard let context = makeContext(width: Int(size.width), height: Int(size.height), like: image) else {
            throw CompressionError.failed("There isn't enough memory to rotate this image.")
        }
        context.interpolationQuality = .high
        // Move the origin to the middle, turn clockwise (CG's positive angle is counter-clockwise), flip, draw centred.
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: -CGFloat(spec.quarterTurns) * .pi / 2)
        context.scaleBy(x: spec.flipHorizontal ? -1 : 1, y: spec.flipVertical ? -1 : 1)
        context.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        guard let result = context.makeImage() else { throw CompressionError.failed("The image couldn't be rotated.") }
        return result
    }

    // MARK: Upscaling

    /// Enlarges with a Lanczos filter and then sharpens, which keeps edges crisp without inventing detail.
    static func upscale(_ image: CGImage, spec: UpscaleSpec) throws -> CGImage {
        let outW = image.width * spec.factor, outH = image.height * spec.factor
        guard outW <= 16_384, outH <= 16_384, outW * outH <= 120_000_000 else {
            throw CompressionError.failed("The enlarged picture would be too big (\(outW)×\(outH) pixels). Try a smaller factor.")
        }
        var ci = CIImage(cgImage: image)
        let lanczos = CIFilter(name: "CILanczosScaleTransform")!
        lanczos.setValue(ci, forKey: kCIInputImageKey)
        lanczos.setValue(spec.factor, forKey: kCIInputScaleKey)
        lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
        ci = lanczos.outputImage ?? ci
        if spec.sharpness > 0 {
            let sharpen = CIFilter(name: "CISharpenLuminance")!
            sharpen.setValue(ci, forKey: kCIInputImageKey)
            sharpen.setValue(spec.sharpness * 1.4, forKey: kCIInputSharpnessKey)
            sharpen.setValue(1.0 + Double(spec.factor) * 0.4, forKey: kCIInputRadiusKey)
            ci = sharpen.outputImage ?? ci
        }
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let result = ciContext.createCGImage(
            ci, from: CGRect(x: 0, y: 0, width: outW, height: outH), format: .RGBA8, colorSpace: space) else {
            throw CompressionError.failed("The image couldn't be enlarged.")
        }
        return result
    }

    // MARK: Watermark

    static func watermark(_ image: CGImage, spec: WatermarkSpec) throws -> CGImage {
        guard let context = makeContext(width: image.width, height: image.height, like: image) else {
            throw CompressionError.failed("There isn't enough memory to add a watermark.")
        }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        drawWatermark(spec, in: context, size: CGSize(width: w, height: h))
        guard let result = context.makeImage() else { throw CompressionError.failed("The watermark couldn't be added.") }
        return result
    }

    /// Draws the mark into a context whose origin is the bottom left. Used for pictures, frames and PDF pages.
    static func drawWatermark(_ spec: WatermarkSpec, in context: CGContext, size: CGSize) {
        // Measure the mark at its natural size, then scale it to the requested width.
        var markSize: CGSize
        var draw: (CGContext) -> Void

        switch spec.content {
        case .text(let string):
            let text = string.isEmpty ? " " : string
            let base = CTFontCreateWithName("Helvetica-Bold" as CFString, 100, nil)
            let color = CGColor(gray: spec.darkText ? 0 : 1, alpha: spec.opacity)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): base,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, [])
            markSize = CGSize(width: bounds.width, height: bounds.height)
            draw = { ctx in
                // A faint shadow in the opposite tone keeps the mark readable on any background.
                ctx.setShadow(offset: .zero, blur: 6, color: CGColor(gray: spec.darkText ? 1 : 0, alpha: spec.opacity * 0.35))
                ctx.textPosition = CGPoint(x: -bounds.minX, y: -bounds.minY)
                CTLineDraw(line, ctx)
            }
        case .image(let path):
            guard let logo = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
                .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else { return }
            markSize = CGSize(width: logo.width, height: logo.height)
            draw = { ctx in
                ctx.setAlpha(spec.opacity)
                ctx.draw(logo, in: CGRect(origin: .zero, size: markSize))
            }
        }
        guard markSize.width > 0, markSize.height > 0 else { return }

        let scale = size.width * spec.scale / markSize.width
        let scaled = CGSize(width: markSize.width * scale, height: markSize.height * scale)
        let margin = size.width * 0.03

        func place(at origin: CGPoint) {
            context.saveGState()
            context.translateBy(x: origin.x + scaled.width / 2, y: origin.y + scaled.height / 2)
            context.rotate(by: spec.rotationDegrees * .pi / 180)
            context.translateBy(x: -scaled.width / 2, y: -scaled.height / 2)
            context.scaleBy(x: scale, y: scale)
            draw(context)
            context.restoreGState()
        }

        if spec.position == .tiled {
            let stepX = scaled.width * 1.8, stepY = scaled.height * 3.2
            var row = 0
            var y = -scaled.height
            while y < size.height + scaled.height {
                var x = -scaled.width + (row % 2 == 0 ? 0 : stepX / 2)
                while x < size.width + scaled.width {
                    place(at: CGPoint(x: x, y: y))
                    x += stepX
                }
                y += stepY
                row += 1
            }
            return
        }

        let x: CGFloat, y: CGFloat
        switch spec.position {
        case .topLeft, .left, .bottomLeft: x = margin
        case .top, .center, .bottom: x = (size.width - scaled.width) / 2
        default: x = size.width - scaled.width - margin
        }
        switch spec.position {
        case .bottomLeft, .bottom, .bottomRight: y = margin
        case .left, .center, .right: y = (size.height - scaled.height) / 2
        default: y = size.height - scaled.height - margin
        }
        place(at: CGPoint(x: x, y: y))
    }

    // MARK: Faces and backgrounds

    /// Faces found in the picture, as rectangles in `0...1` with the origin at the top left.
    static func detectFaces(in image: CGImage) -> [NormalizedRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).map { face in
            let box = face.boundingBox  // origin bottom left
            return NormalizedRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }
    }

    /// Covers each rectangle with a blur, pixelation or solid block. Rectangles are grown a little so hair and ears are included.
    static func obscure(_ image: CGImage, regions: [NormalizedRect], spec: BlurSpec) throws -> CGImage {
        guard !regions.isEmpty else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        // Normalised rectangles run down from the top; Core Image runs up from the bottom.
        let pixelRects = regions.map {
            CGRect(x: $0.x * w, y: (1 - $0.y - $0.height) * h, width: $0.width * w, height: $0.height * h)
        }
        let output = obscure(CIImage(cgImage: image), extent: extent, regions: pixelRects, spec: spec)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let result = ciContext.createCGImage(output, from: extent, format: .RGBA8, colorSpace: space) else {
            throw CompressionError.failed("The faces couldn't be hidden.")
        }
        return result
    }

    /// The Core Image version, used for single pictures and for every frame of a video.
    /// `regions` are in pixels with the origin at the bottom left.
    static func obscure(_ input: CIImage, extent: CGRect, regions: [CGRect], spec: BlurSpec) -> CIImage {
        guard !regions.isEmpty else { return input }
        var largest: CGFloat = 0

        // A soft white disc over black for each region: white shows the effect, black shows the original.
        var mask = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        for region in regions {
            let radius = max(region.width, region.height) / 2 * 1.35
            largest = max(largest, radius * 2)
            let disc = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: region.midX, y: region.midY),
                "inputRadius0": radius * 0.8, "inputRadius1": radius,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
            ])!.outputImage!.cropped(to: extent)
            mask = disc.composited(over: mask)
        }

        let effect: CIImage
        switch spec.style {
        case .blur:
            effect = input.clampedToExtent().applyingGaussianBlur(sigma: Double(largest) * (0.05 + 0.18 * spec.strength)).cropped(to: extent)
        case .pixelate:
            let filter = CIFilter(name: "CIPixellate")!
            filter.setValue(input, forKey: kCIInputImageKey)
            filter.setValue(max(6, Double(largest) * (0.04 + 0.12 * spec.strength)), forKey: kCIInputScaleKey)
            filter.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: kCIInputCenterKey)
            effect = (filter.outputImage ?? input).cropped(to: extent)
        case .solid:
            effect = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        }

        let blend = CIFilter(name: "CIBlendWithMask")!
        blend.setValue(effect, forKey: kCIInputImageKey)
        blend.setValue(input, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return blend.outputImage?.cropped(to: extent) ?? input
    }

    /// Cuts out the main subject, leaving a transparent background.
    static func removeBackground(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw CompressionError.failed("No clear subject was found in this picture.")
        }
        let buffer = try observation.generateMaskedImage(
            ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let result = ciContext.createCGImage(
            ci, from: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA8, colorSpace: space) else {
            throw CompressionError.failed("The background couldn't be removed.")
        }
        return result
    }

    // MARK: Writing

    static func encode(
        _ image: CGImage, type: String, quality: Double?, properties: [CFString: Any], stripMetadata: Bool
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw CompressionError.failed("This Mac can't write \(type) images.")
        }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        if !stripMetadata { ImageCompressor.carryMetadata(from: properties, into: &options, size: image) }
        options[kCGImagePropertyOrientation] = 1  // rotation is already applied to the pixels
        if (type == "public.jpeg" || type == "public.heic"), image.alphaInfo != .none, image.alphaInfo != .noneSkipLast,
           image.alphaInfo != .noneSkipFirst {
            // Formats without transparency get a white background rather than black.
            return try encode(flatten(image), type: type, quality: quality, properties: properties, stripMetadata: stripMetadata)
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CompressionError.failed("The image couldn't be written.") }
        return data as Data
    }

    static func flatten(_ image: CGImage) -> CGImage {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}
