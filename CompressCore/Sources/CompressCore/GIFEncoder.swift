import Foundation

/// Writes GIF89a files: a global palette, optional sub-rectangle frames and transparency.
enum GIFEncoder {
    struct Frame {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        var indices: [UInt8]
        var delay: Int  // hundredths of a second
        var transparentIndex: UInt8?
        /// 1 = leave in place (for frames drawn on top of the previous one), 2 = clear to background.
        var disposal: Int
    }

    static func encode(width: Int, height: Int, palette: [RGBA8], frames: [Frame], loopCount: Int) -> Data {
        precondition(!palette.isEmpty && palette.count <= 256)
        var out = Data()
        out.append(contentsOf: Array("GIF89a".utf8))

        // Palette sizes in GIF are powers of two.
        var tableBits = 1
        while (1 << tableBits) < palette.count { tableBits += 1 }

        out.appendLE16(width)
        out.appendLE16(height)
        out.append(UInt8(0x80 | ((tableBits - 1) << 4) | (tableBits - 1)))  // global table, colour resolution, size
        out.append(0)  // background colour index
        out.append(0)  // pixel aspect ratio

        for i in 0..<(1 << tableBits) {
            let c = i < palette.count ? palette[i] : RGBA8(r: 0, g: 0, b: 0, a: 255)
            out.append(contentsOf: [c.r, c.g, c.b])
        }

        // Looping: 0 repeats forever. Skipped for one-shot animations (loopCount < 0).
        if loopCount >= 0 {
            out.append(contentsOf: [0x21, 0xFF, 0x0B])
            out.append(contentsOf: Array("NETSCAPE2.0".utf8))
            out.append(contentsOf: [0x03, 0x01])
            out.appendLE16(loopCount)
            out.append(0)
        }

        let minCodeSize = max(2, tableBits)
        for frame in frames {
            out.append(contentsOf: [0x21, 0xF9, 0x04])
            out.append(UInt8((frame.disposal << 2) | (frame.transparentIndex == nil ? 0 : 1)))
            out.appendLE16(frame.delay)
            out.append(frame.transparentIndex ?? 0)
            out.append(0)

            out.append(0x2C)
            out.appendLE16(frame.x)
            out.appendLE16(frame.y)
            out.appendLE16(frame.width)
            out.appendLE16(frame.height)
            out.append(0)  // no local table, not interlaced

            out.append(UInt8(minCodeSize))
            appendSubBlocks(lzw(frame.indices, minCodeSize: minCodeSize), to: &out)
        }
        out.append(0x3B)
        return out
    }

    private static func appendSubBlocks(_ bytes: [UInt8], to out: inout Data) {
        var i = 0
        while i < bytes.count {
            let n = min(255, bytes.count - i)
            out.append(UInt8(n))
            out.append(contentsOf: bytes[i..<i + n])
            i += n
        }
        out.append(0)
    }

    // MARK: LZW

    static func lzw(_ indices: [UInt8], minCodeSize: Int) -> [UInt8] {
        let clear = 1 << minCodeSize
        let eoi = clear + 1
        var codeSize = minCodeSize + 1
        var next = eoi + 1
        var table: [Int: Int] = [:]
        table.reserveCapacity(4096)

        var out: [UInt8] = []
        out.reserveCapacity(indices.count / 2)
        var buffer: UInt32 = 0
        var bits = 0

        func emit(_ code: Int) {
            buffer |= UInt32(code) << UInt32(bits)
            bits += codeSize
            while bits >= 8 {
                out.append(UInt8(buffer & 0xFF))
                buffer >>= 8
                bits -= 8
            }
        }

        emit(clear)
        guard var prefix = indices.first.map(Int.init) else {
            emit(eoi)
            if bits > 0 { out.append(UInt8(buffer & 0xFF)) }
            return out
        }

        for byte in indices.dropFirst() {
            let k = Int(byte)
            let key = prefix << 8 | k
            if let code = table[key] {
                prefix = code
                continue
            }
            emit(prefix)
            if next == 4096 {
                emit(clear)
                next = eoi + 1
                codeSize = minCodeSize + 1
                table.removeAll(keepingCapacity: true)
            } else {
                if next >= (1 << codeSize) { codeSize += 1 }
                table[key] = next
                next += 1
            }
            prefix = k
        }
        emit(prefix)
        emit(eoi)
        if bits > 0 { out.append(UInt8(buffer & 0xFF)) }
        return out
    }
}

extension Data {
    mutating func appendLE16(_ value: Int) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
}
