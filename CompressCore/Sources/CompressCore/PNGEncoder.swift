import Foundation

struct RGBA8: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8
}

/// Writes indexed-colour PNG files. ImageIO can't write PNG palettes with transparency,
/// and palettes are where most of the savings on screenshots and graphics come from.
enum PNGEncoder {
    enum ColorInfo {
        case none
        case srgb
        case icc(name: String, profile: Data)
    }

    static func encodeIndexed(
        width: Int,
        height: Int,
        indices: [UInt8],
        palette: [RGBA8],
        colorInfo: ColorInfo
    ) throws -> Data {
        precondition(!palette.isEmpty && palette.count <= 256)
        precondition(indices.count == width * height)

        let depth = bitDepth(forPaletteSize: palette.count)
        let rows = packedRows(indices: indices, width: width, height: height, depth: depth)
        let rowBytes = (width * depth + 7) / 8
        let filtered = filterRows(rows, rowBytes: rowBytes, height: height)

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        var ihdr = Data()
        ihdr.appendBigEndian(UInt32(width))
        ihdr.appendBigEndian(UInt32(height))
        ihdr.append(contentsOf: [UInt8(depth), 3, 0, 0, 0])  // depth, palette colour type, deflate, filter 0, no interlace
        append(chunk: "IHDR", ihdr, to: &png)

        switch colorInfo {
        case .none:
            break
        case .srgb:
            append(chunk: "sRGB", Data([0]), to: &png)
        case .icc(let name, let profile):
            var body = Data(name.utf8.prefix(79))
            body.append(contentsOf: [0, 0])  // name terminator, deflate method
            body.append(try zlib(profile))
            append(chunk: "iCCP", body, to: &png)
        }

        var plte = Data()
        for color in palette { plte.append(contentsOf: [color.r, color.g, color.b]) }
        append(chunk: "PLTE", plte, to: &png)

        // tRNS only needs entries up to the last non-opaque colour.
        if let last = palette.lastIndex(where: { $0.a != 255 }) {
            append(chunk: "tRNS", Data(palette[...last].map(\.a)), to: &png)
        }

        append(chunk: "IDAT", try zlib(filtered), to: &png)
        append(chunk: "IEND", Data(), to: &png)
        return png
    }

    // MARK: Pixel packing and filtering

    static func bitDepth(forPaletteSize count: Int) -> Int {
        switch count {
        case ...2: 1
        case ...4: 2
        case ...16: 4
        default: 8
        }
    }

    private static func packedRows(indices: [UInt8], width: Int, height: Int, depth: Int) -> [UInt8] {
        guard depth < 8 else { return indices }
        let rowBytes = (width * depth + 7) / 8
        var out = [UInt8](repeating: 0, count: rowBytes * height)
        let perByte = 8 / depth
        for y in 0..<height {
            for x in 0..<width {
                let shift = 8 - depth * (x % perByte + 1)
                out[y * rowBytes + x / perByte] |= indices[y * width + x] << UInt8(shift)
            }
        }
        return out
    }

    /// Picks, per row, the PNG filter with the smallest sum of absolute values.
    private static func filterRows(_ rows: [UInt8], rowBytes: Int, height: Int) -> Data {
        var out = Data(capacity: (rowBytes + 1) * height)
        let zeros = [UInt8](repeating: 0, count: rowBytes)
        var candidate = [[UInt8]](repeating: [UInt8](repeating: 0, count: rowBytes), count: 5)

        for y in 0..<height {
            let start = y * rowBytes
            let cur = rows[start..<start + rowBytes]
            let prev = y == 0 ? zeros[...] : rows[start - rowBytes..<start]

            for i in 0..<rowBytes {
                let x = cur[start + i]
                let left: UInt8 = i > 0 ? cur[start + i - 1] : 0
                let up = prev[prev.startIndex + i]
                let upLeft: UInt8 = i > 0 ? prev[prev.startIndex + i - 1] : 0
                candidate[0][i] = x
                candidate[1][i] = x &- left
                candidate[2][i] = x &- up
                candidate[3][i] = x &- UInt8((Int(left) + Int(up)) / 2)
                candidate[4][i] = x &- paeth(left, up, upLeft)
            }

            var best = 0
            var bestScore = Int.max
            for (type, bytes) in candidate.enumerated() {
                var score = 0
                for byte in bytes { score += Int(Int8(bitPattern: byte).magnitude) }
                if score < bestScore {
                    bestScore = score
                    best = type
                }
            }
            out.append(UInt8(best))
            out.append(contentsOf: candidate[best])
        }
        return out
    }

    private static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let p = Int(a) + Int(b) - Int(c)
        let pa = abs(p - Int(a))
        let pb = abs(p - Int(b))
        let pc = abs(p - Int(c))
        if pa <= pb && pa <= pc { return a }
        return pb <= pc ? b : c
    }

    // MARK: Container format

    private static func append(chunk type: String, _ body: Data, to png: inout Data) {
        png.appendBigEndian(UInt32(body.count))
        var typed = Data(type.utf8)
        typed.append(body)
        png.append(typed)
        png.appendBigEndian(crc32(typed))
    }

    /// zlib stream: header, raw deflate data, Adler-32 checksum.
    static func zlib(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x78, 0xDA])
        out.append(deflated)
        out.appendBigEndian(adler32(data))
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
