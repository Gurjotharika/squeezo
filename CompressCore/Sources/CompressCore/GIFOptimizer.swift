import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// A sequence of frames to turn into one small GIF.
protocol GIFFrameSource {
    var width: Int { get }
    var height: Int { get }
    var count: Int { get }
    /// Seconds this frame stays on screen.
    func delay(at index: Int) -> Double
    /// Straight RGBA at `width`×`height`.
    func pixels(at index: Int) throws -> [UInt8]
}

enum GIFOptimizer {
    /// Encodes `source` using the level's palette size, tolerance and dither.
    /// - Parameter maxFrameRate: frames beyond this rate are dropped and their time given to the previous frame.
    static func encode(
        _ source: any GIFFrameSource,
        level: QualityLevel,
        maxFrameRate: Int?,
        loopCount: Int,
        progress: @Sendable (Double) -> Void
    ) throws -> Data {
        let width = source.width, height = source.height
        let kept = selectFrames(source, maxFrameRate: maxFrameRate)
        guard !kept.isEmpty else { throw CompressionError.failed("The GIF has no frames.") }

        // Pass 1: find out which colours the animation uses, and whether it has transparency.
        var sample: [UInt8] = []
        var unique = Set<UInt32>()
        var exactFits = true
        var hasTransparency = false
        let sampleEvery = max(1, kept.count * width * height / 400_000)
        for (n, frame) in kept.enumerated() {
            try Task.checkCancellation()
            let px = try source.pixels(at: frame.index)
            for i in 0..<width * height {
                if px[i * 4 + 3] < 128 {
                    hasTransparency = true
                    continue
                }
                let key = UInt32(px[i * 4]) << 16 | UInt32(px[i * 4 + 1]) << 8 | UInt32(px[i * 4 + 2])
                if exactFits {
                    unique.insert(key)
                    if unique.count > 255 { exactFits = false }
                }
                if i % sampleEvery == 0 {
                    sample.append(contentsOf: [px[i * 4], px[i * 4 + 1], px[i * 4 + 2], 255])
                }
            }
            progress(0.3 * Double(n + 1) / Double(kept.count))
        }

        // Palette: exact if the animation has few enough colours, otherwise reduced.
        let size = level.gifPaletteSize
        var palette: [RGBA8]
        if exactFits, unique.count <= size - 1 {
            palette = unique.sorted().map {
                RGBA8(r: UInt8($0 >> 16 & 0xFF), g: UInt8($0 >> 8 & 0xFF), b: UInt8($0 & 0xFF), a: 255)
            }
        } else if sample.isEmpty {
            palette = [RGBA8(r: 0, g: 0, b: 0, a: 255)]
        } else {
            palette = ColorQuantizer.buildPalette(pixels: sample, maxColors: size - 1).palette
        }
        let exact = exactFits && unique.count <= size - 1
        let transparentIndex = UInt8(palette.count)
        palette.append(RGBA8(r: 0, g: 0, b: 0, a: 0))

        var matcher = PaletteMatcher(palette: Array(palette.dropLast()))
        // With an exact palette every colour must map to itself, so look it up instead of searching.
        var exactIndex: [UInt32: UInt8] = [:]
        if exact {
            for (i, c) in palette.dropLast().enumerated() {
                exactIndex[UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b)] = UInt8(i)
            }
        }
        let tolerance = exact ? 0 : level.gifTolerance
        let dither = exact ? 0 : level.gifDither
        let diffing = !hasTransparency

        // Pass 2: code each frame, keeping only what changed since the last one.
        var displayed = [Int16](repeating: -1, count: width * height)
        var frames: [GIFEncoder.Frame] = []
        var remainder = 0.0

        for (n, entry) in kept.enumerated() {
            try Task.checkCancellation()
            let px = try source.pixels(at: entry.index)
            var out = [UInt8](repeating: transparentIndex, count: width * height)
            var minX = width, minY = height, maxX = -1, maxY = -1

            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    if px[i * 4 + 3] < 128 { continue }  // stays transparent
                    let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])

                    if diffing, displayed[i] >= 0 {
                        let shown = palette[Int(displayed[i])]
                        if abs(r - Int(shown.r)) <= tolerance, abs(g - Int(shown.g)) <= tolerance,
                           abs(b - Int(shown.b)) <= tolerance { continue }
                    }
                    // The pattern depends only on position, so a still pixel maps to the same colour every frame.
                    let bias = dither == 0 ? 0 : (bayer[(y & 3) << 2 | (x & 3)] - 7.5) * dither / 7.5
                    let index = exact
                        ? exactIndex[UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)]!
                        : matcher.nearest(Float(r) + bias, Float(g) + bias, Float(b) + bias)
                    if diffing {
                        if displayed[i] == Int16(index) { continue }
                        displayed[i] = Int16(index)
                    }
                    out[i] = index
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }

            // Delay in hundredths of a second, carrying the rounding error forward.
            let exactDelay = entry.delay * 100 + remainder
            let delay = max(2, Int(exactDelay.rounded()))
            remainder = exactDelay - Double(delay)

            if diffing, maxX < 0, !frames.isEmpty {
                frames[frames.count - 1].delay += delay  // nothing changed: just stay longer
                continue
            }
            if maxX < 0 { minX = 0; minY = 0; maxX = 0; maxY = 0 }  // blank first frame

            let w = maxX - minX + 1, h = maxY - minY + 1
            var cropped = [UInt8]()
            cropped.reserveCapacity(w * h)
            for y in minY...maxY {
                cropped.append(contentsOf: out[y * width + minX...y * width + maxX])
            }
            frames.append(GIFEncoder.Frame(
                x: minX, y: minY, width: w, height: h, indices: cropped, delay: delay,
                transparentIndex: transparentIndex, disposal: diffing ? 1 : 2))
            progress(0.3 + 0.65 * Double(n + 1) / Double(kept.count))
        }
        return GIFEncoder.encode(width: width, height: height, palette: palette, frames: frames, loopCount: loopCount)
    }

    private static let bayer: [Float] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

    /// Frames to keep, each with the time it should stay up (dropped frames add theirs to the previous one).
    private static func selectFrames(_ source: any GIFFrameSource, maxFrameRate: Int?) -> [(index: Int, delay: Double)] {
        var kept: [(index: Int, delay: Double)] = []
        let minInterval = maxFrameRate.map { 1 / Double($0) } ?? 0
        var sinceKept = Double.infinity
        for i in 0..<source.count {
            let d = max(source.delay(at: i), 0.02)
            if minInterval > 0, !kept.isEmpty, sinceKept + 1e-6 < minInterval {
                kept[kept.count - 1].delay += d
                sinceKept += d
            } else {
                kept.append((i, d))
                sinceKept = d
            }
        }
        return kept
    }
}

/// Finds the closest palette colour, remembering answers per 5-5-5 bit bucket.
struct PaletteMatcher {
    private let palette: [(Float, Float, Float)]
    private var cache = [Int16](repeating: -1, count: 1 << 15)

    init(palette: [RGBA8]) {
        self.palette = palette.map { (Float($0.r), Float($0.g), Float($0.b)) }
    }

    mutating func nearest(_ r: Float, _ g: Float, _ b: Float) -> UInt8 {
        let cr = max(0, min(255, r)), cg = max(0, min(255, g)), cb = max(0, min(255, b))
        let ir = Int(cr) >> 3, ig = Int(cg) >> 3, ib = Int(cb) >> 3
        let key = (ir << 10) | (ig << 5) | ib
        if cache[key] >= 0 { return UInt8(cache[key]) }
        // Search from the bucket's centre so every pixel in it gets the same answer.
        let r = Float(ir * 8 + 4), g = Float(ig * 8 + 4), b = Float(ib * 8 + 4)
        var best = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (i, p) in palette.enumerated() {
            let dr = r - p.0, dg = g - p.1, db = b - p.2
            let d = 0.64 * dr * dr + dg * dg + 0.36 * db * db
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        cache[key] = Int16(best)
        return UInt8(best)
    }
}

// MARK: - Frame sources

/// Renders a CGImage into straight sRGB RGBA at the given size.
func renderRGBA(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let base = context.data
    else { throw CompressionError.failed("A frame couldn't be decoded.") }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let source = base.bindMemory(to: UInt8.self, capacity: width * height * 4)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for i in 0..<width * height {
        let a = Int(source[i * 4 + 3])
        for k in 0..<3 {
            let c = Int(source[i * 4 + k])
            pixels[i * 4 + k] = a == 0 || a == 255 ? UInt8(c) : UInt8(min(255, (c * 255 + a / 2) / a))
        }
        pixels[i * 4 + 3] = UInt8(a)
    }
    return pixels
}

/// The frames of an existing GIF, optionally scaled down.
struct GIFFileSource: GIFFrameSource {
    let source: CGImageSource
    let width: Int
    let height: Int
    let count: Int
    private let delays: [Double]

    init(url: URL, maxDimension: Int?) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw CompressionError.failed("“\(url.lastPathComponent)” can't be read as a GIF.")
        }
        self.source = source
        count = CGImageSourceGetCount(source)

        let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = first?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = first?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0 else { throw CompressionError.failed("“\(url.lastPathComponent)” can't be read as a GIF.") }

        var scale = 1.0
        if let maxSide = maxDimension, maxSide > 0 { scale = min(1, Double(maxSide) / Double(max(w, h))) }
        width = max(1, Int((Double(w) * scale).rounded()))
        height = max(1, Int((Double(h) * scale).rounded()))

        delays = (0..<count).map { index in
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        }
    }

    var loopCount: Int {
        let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        return gif?[kCGImagePropertyGIFLoopCount] as? Int ?? 0
    }

    func delay(at index: Int) -> Double { delays[index] }

    func pixels(at index: Int) throws -> [UInt8] {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
            throw CompressionError.failed("Frame \(index + 1) couldn't be decoded.")
        }
        return try renderRGBA(image, width: width, height: height)
    }
}

/// Frames pulled from a video at a fixed rate.
struct VideoFrameSource: GIFFrameSource {
    let images: [CGImage]
    let width: Int
    let height: Int
    let interval: Double

    var count: Int { images.count }
    func delay(at index: Int) -> Double { interval }
    func pixels(at index: Int) throws -> [UInt8] { try renderRGBA(images[index], width: width, height: height) }
}
