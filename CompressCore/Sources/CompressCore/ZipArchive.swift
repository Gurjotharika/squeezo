import Foundation

/// Just enough of the ZIP format to rewrite a few entries and copy the rest byte for byte.
struct ZipArchive {
    struct Entry {
        var name: String
        var flags: Int
        var method: Int
        var crc: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var localOffset: Int
        /// The central directory record exactly as stored.
        var central: Data

        var isEncrypted: Bool { flags & 1 != 0 }
        var hasDataDescriptor: Bool { flags & 8 != 0 }
    }

    let data: Data
    private(set) var entries: [Entry] = []

    init(_ data: Data) throws {
        self.data = data
        try readCentralDirectory()
    }

    // MARK: Reading

    private func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
    private func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }

    private mutating func readCentralDirectory() throws {
        // The end-of-central-directory record is within the last 64 KB.
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let tail = data.suffix(65_557)
        guard let eocd = tail.lastRange(of: signature), eocd.lowerBound + 22 <= data.endIndex else {
            throw PDFError.malformed("no ZIP end record")
        }
        let count = u16(eocd.lowerBound + 10)
        let size = u32(eocd.lowerBound + 12)
        let offset = u32(eocd.lowerBound + 16)
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF { throw PDFError.unsupported("ZIP64") }
        guard offset + size <= data.count else { throw PDFError.malformed("bad central directory") }

        var position = offset
        for _ in 0..<count {
            guard position + 46 <= data.count, u32(position) == 0x0201_4B50 else { throw PDFError.malformed("bad central entry") }
            let nameLength = u16(position + 28), extraLength = u16(position + 30), commentLength = u16(position + 32)
            let total = 46 + nameLength + extraLength + commentLength
            guard position + total <= data.count else { throw PDFError.malformed("truncated central entry") }
            let name = String(decoding: data[position + 46..<position + 46 + nameLength], as: UTF8.self)
            let compressed = u32(position + 20), uncompressed = u32(position + 24), local = u32(position + 42)
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || local == 0xFFFF_FFFF { throw PDFError.unsupported("ZIP64") }
            entries.append(Entry(
                name: name, flags: u16(position + 8), method: u16(position + 10), crc: UInt32(u32(position + 16)),
                compressedSize: compressed, uncompressedSize: uncompressed, localOffset: local,
                central: Data(data[position..<position + total])))
            position += total
        }
    }

    /// The bytes of an entry's local header, data and data descriptor, exactly as they are in the file.
    func rawSpan(_ entry: Entry) throws -> Data {
        let start = entry.localOffset
        guard start + 30 <= data.count, u32(start) == 0x0403_4B50 else { throw PDFError.malformed("bad local header") }
        let dataStart = start + 30 + u16(start + 26) + u16(start + 28)
        var end = dataStart + entry.compressedSize
        if entry.hasDataDescriptor {
            end += (end + 4 <= data.count && u32(end) == 0x0807_4B50) ? 16 : 12
        }
        guard end <= data.count else { throw PDFError.malformed("entry runs past the end") }
        return Data(data[start..<end])
    }

    /// The uncompressed contents of an entry, or nil for methods other than stored and deflate.
    func contents(_ entry: Entry) throws -> Data? {
        let start = entry.localOffset
        guard start + 30 <= data.count, u32(start) == 0x0403_4B50 else { throw PDFError.malformed("bad local header") }
        let dataStart = start + 30 + u16(start + 26) + u16(start + 28)
        guard dataStart + entry.compressedSize <= data.count else { throw PDFError.malformed("entry runs past the end") }
        let raw = Data(data[dataStart..<dataStart + entry.compressedSize])
        switch entry.method {
        case 0: return raw
        case 8: return try (raw as NSData).decompressed(using: .zlib) as Data
        default: return nil
        }
    }

    // MARK: Writing

    /// Collects entries into a new archive.
    struct Writer {
        private(set) var out = Data()
        private var central = Data()
        private var count = 0

        /// Copies an entry unchanged.
        mutating func copy(_ entry: Entry, span: Data) {
            var record = entry.central
            record.replaceSubrange(42..<46, with: le32(out.count))
            central.append(record)
            out.append(span)
            count += 1
        }

        /// Writes an entry with new contents, stored without compression (images are already compressed).
        mutating func store(_ entry: Entry, contents: Data) {
            let crc = PNGEncoder.crc32(contents)
            let name = Data(entry.name.utf8)
            let offset = out.count

            var local = Data([0x50, 0x4B, 0x03, 0x04])
            local.append(le16(20)); local.append(le16(entry.flags & ~8 & ~1 | 0x800))  // no descriptor, UTF-8 name
            local.append(le16(0))  // stored
            local.append(entry.central[12..<16])  // time and date as before
            local.append(le32(Int(crc))); local.append(le32(contents.count)); local.append(le32(contents.count))
            local.append(le16(name.count)); local.append(le16(0))
            out.append(local); out.append(name); out.append(contents)

            var record = entry.central
            record.replaceSubrange(8..<10, with: le16(entry.flags & ~8 & ~1 | 0x800))
            record.replaceSubrange(10..<12, with: le16(0))
            record.replaceSubrange(16..<20, with: le32(Int(crc)))
            record.replaceSubrange(20..<24, with: le32(contents.count))
            record.replaceSubrange(24..<28, with: le32(contents.count))
            record.replaceSubrange(42..<46, with: le32(offset))
            central.append(record)
            count += 1
        }

        mutating func finish() -> Data {
            let centralOffset = out.count
            out.append(central)
            out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0])
            out.append(le16(count)); out.append(le16(count))
            out.append(le32(central.count)); out.append(le32(centralOffset)); out.append(le16(0))
            return out
        }

        private func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
        private func le32(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]) }
    }
}
