import CoreGraphics
import Foundation
import ImageIO
@testable import CompressCore

/// Synthetic test images and measurements, so tests don't depend on files on disk.
enum Fixtures {
    struct SeededRandom {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func context(_ width: Int, _ height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// Smooth gradients, a few shapes and light noise: compresses like a photo does.
    static func photoLike(width: Int, height: Int, seed: UInt64 = 1) -> CGImage {
        let ctx = context(width, height)
        let gradient = CGGradient(
            colorsSpace: sRGB,
            colors: [CGColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1), CGColor(red: 0.9, green: 0.6, blue: 0.2, alpha: 1)] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        for i in 0..<6 {
            ctx.setFillColor(CGColor(red: CGFloat(i) / 6, green: 0.8 - CGFloat(i) / 9, blue: 0.4, alpha: 0.8))
            ctx.fillEllipse(in: CGRect(x: width / 8 * i, y: height / 5 * (i % 3), width: width / 3, height: height / 3))
        }
        var rng = SeededRandom(state: seed)
        let bytes = ctx.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for i in 0..<width * height {
            for k in 0..<3 {
                let noise = Int(rng.next() % 13) - 6
                bytes[i * 4 + k] = UInt8(max(0, min(255, Int(bytes[i * 4 + k]) + noise)))
            }
        }
        return ctx.makeImage()!
    }

    /// Flat shapes on a transparent background: few colours, like a UI graphic.
    static func graphic(width: Int, height: Int) -> CGImage {
        let ctx = context(width, height)
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let colors: [CGColor] = [
            CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0.6, blue: 0.2, alpha: 1),
            CGColor(red: 0, green: 0.2, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 0, alpha: 0.5),
        ]
        for (i, color) in colors.enumerated() {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: i * width / 5, y: i * height / 6, width: width / 3, height: height / 2))
        }
        return ctx.makeImage()!
    }

    @discardableResult
    static func write(
        _ image: CGImage, type: String, to url: URL,
        quality: Double? = 1.0, properties: [CFString: Any] = [:]
    ) throws -> URL {
        var options = properties
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    static func cgImage(at url: URL) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    static func rgba(at url: URL) -> RGBAImage? {
        cgImage(at: url).flatMap(RGBAImage.init)
    }

    static func properties(at url: URL) -> [CFString: Any] {
        CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
    }

    static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Mean structural similarity of the luma channel over 8×8 blocks, 1.0 = identical.
    static func ssim(_ a: RGBAImage, _ b: RGBAImage) -> Double {
        precondition(a.width == b.width && a.height == b.height)
        func luma(_ img: RGBAImage, _ i: Int) -> Double {
            0.299 * Double(img.pixels[i * 4]) + 0.587 * Double(img.pixels[i * 4 + 1]) + 0.114 * Double(img.pixels[i * 4 + 2])
        }
        let c1: Double = 6.5025, c2: Double = 58.5225  // (0.01·255)², (0.03·255)²
        var total = 0.0
        var blocks = 0
        for by in stride(from: 0, to: a.height - 7, by: 8) {
            for bx in stride(from: 0, to: a.width - 7, by: 8) {
                var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
                for y in 0..<8 {
                    for x in 0..<8 {
                        let i = (by + y) * a.width + bx + x
                        let la = luma(a, i), lb = luma(b, i)
                        sa += la; sb += lb; saa += la * la; sbb += lb * lb; sab += la * lb
                    }
                }
                let n = 64.0
                let ma = sa / n, mb = sb / n
                let va = saa / n - ma * ma, vb = sbb / n - mb * mb, cov = sab / n - ma * mb
                total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                blocks += 1
            }
        }
        return total / Double(max(blocks, 1))
    }
}
