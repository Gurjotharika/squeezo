import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CompressCore

@Suite struct PNGEncoderTests {
    private func decode(_ data: Data) -> RGBAImage? {
        CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            .flatMap(RGBAImage.init)
    }

    @Test(arguments: [2, 3, 4, 10, 16, 17, 200, 256])
    func roundTripsEveryBitDepth(paletteSize: Int) throws {
        let width = 37, height = 11  // odd sizes exercise row padding
        var rng = Fixtures.SeededRandom(state: UInt64(paletteSize))
        let palette = (0..<paletteSize).map { i in
            RGBA8(r: UInt8(i * 7 % 256), g: UInt8(i * 13 % 256), b: UInt8(i * 29 % 256), a: 255)
        }
        let indices = (0..<width * height).map { _ in UInt8(rng.next() % UInt64(paletteSize)) }

        let png = try PNGEncoder.encodeIndexed(
            width: width, height: height, indices: indices, palette: palette, colorInfo: .srgb)
        let image = try #require(decode(png))

        #expect(image.width == width && image.height == height)
        for (i, index) in indices.enumerated() {
            let expected = palette[Int(index)]
            #expect(image.pixels[i * 4] == expected.r)
            #expect(image.pixels[i * 4 + 1] == expected.g)
            #expect(image.pixels[i * 4 + 2] == expected.b)
            #expect(image.pixels[i * 4 + 3] == 255)
        }
    }

    @Test func writesTransparency() throws {
        let palette = [RGBA8(r: 0, g: 0, b: 0, a: 0), RGBA8(r: 255, g: 0, b: 0, a: 255), RGBA8(r: 0, g: 0, b: 255, a: 128)]
        let png = try PNGEncoder.encodeIndexed(
            width: 3, height: 1, indices: [0, 1, 2], palette: palette, colorInfo: .none)
        let image = try #require(decode(png))
        #expect(image.pixels[3] == 0)
        #expect(image.pixels[7] == 255)
        #expect(abs(Int(image.pixels[11]) - 128) <= 1)
    }

    @Test func checksumsMatchKnownValues() {
        #expect(PNGEncoder.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(PNGEncoder.adler32(Data("Wikipedia".utf8)) == 0x11E6_0398)
    }
}

@Suite struct ColorQuantizerTests {
    @Test func exactPaletteRejectsTooManyColours() {
        var pixels: [UInt8] = []
        for i in 0..<257 { pixels += [UInt8(i % 256), UInt8(i / 256), 0, 255] }
        #expect(ColorQuantizer.exactPalette(pixels: pixels) == nil)
        pixels.removeLast(4)
        #expect(ColorQuantizer.exactPalette(pixels: pixels)?.palette.count == 256)
    }

    @Test func quantizingRespectsPaletteLimitAndKeepsTransparency() {
        let width = 64, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<width * height {
            let transparent = i % 5 == 0
            pixels[i * 4] = UInt8(i % 251)
            pixels[i * 4 + 1] = UInt8(i * 3 % 251)
            pixels[i * 4 + 2] = UInt8(i * 7 % 251)
            pixels[i * 4 + 3] = transparent ? 0 : 255
        }
        let result = ColorQuantizer.quantize(pixels: pixels, width: width, height: height, maxColors: 16, ditherStrength: 0.5)

        #expect(result.palette.count <= 16)
        for i in 0..<width * height where i % 5 == 0 {
            #expect(result.palette[Int(result.indices[i])].a == 0)
        }
        for i in 0..<width * height where i % 5 != 0 {
            #expect(result.palette[Int(result.indices[i])].a > 200)
        }
    }
}
