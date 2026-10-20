import Foundation

enum PDFError: Error {
    case malformed(String)
    case unsupported(String)
}

enum XRefEntry: Equatable {
    case free
    case inUse(offset: Int, generation: Int)
    case compressed(stream: Int, index: Int)
}

/// An indirect object as it sits in the file.
struct PDFIndirectObject {
    var number: Int
    var generation: Int
    var value: PDFObject
    /// Where the stream data is, if this object is a stream.
    var stream: Range<Int>?
    /// One past the last byte of `endobj`.
    var end: Int

    var dict: PDFDict? { value.dictValue }
}

/// A PDF read just far enough to find its objects and copy them elsewhere.
struct PDFFile {
    let data: Data
    private(set) var entries: [Int: XRefEntry] = [:]
    private(set) var trailer = PDFDict()
    private(set) var usesXRefStreams = false

    init(_ data: Data) throws {
        self.data = data
        try loadXRef()
    }

    var size: Int {
        max((trailer["Size"]?.intValue ?? 0), (entries.keys.max() ?? 0) + 1)
    }

    var version: String {
        let head = data.prefix(16)
        if head.starts(with: Array("%PDF-".utf8)) {
            let text = String(decoding: head, as: UTF8.self)
            if let range = text.range(of: #"%PDF-\d\.\d"#, options: .regularExpression) { return String(text[range]) }
        }
        return "%PDF-1.7"
    }

    // MARK: Cross-reference data

    private mutating func loadXRef() throws {
        guard let startxref = findStartXRef() else { throw PDFError.malformed("no startxref") }
        var next: Int? = startxref
        var visited = Set<Int>()
        var first = true

        while let offset = next, visited.insert(offset).inserted {
            guard offset >= 0, offset < data.count else { throw PDFError.malformed("bad xref offset") }
            var parser = PDFParser(data, at: offset)
            parser.skipWhitespace()

            let sectionTrailer: PDFDict
            if parser.expect(keyword: "xref") {
                sectionTrailer = try readClassicSection(&parser)
            } else {
                usesXRefStreams = true
                sectionTrailer = try readStreamSection(at: offset)
            }
            if first {
                trailer = sectionTrailer
                first = false
            }
            next = sectionTrailer["Prev"]?.intValue
        }
        guard trailer["Root"] != nil else { throw PDFError.malformed("no Root") }
    }

    private func findStartXRef() -> Int? {
        let key = Array("startxref".utf8)
        let tail = data.suffix(2048)
        guard let range = tail.lastRange(of: key) else { return nil }
        var parser = PDFParser(data, at: range.upperBound)
        return parser.readToken().flatMap(Int.init)
    }

    private mutating func readClassicSection(_ parser: inout PDFParser) throws -> PDFDict {
        var section: [Int: XRefEntry] = [:]
        while true {
            let saved = parser.position
            guard let token = parser.readToken() else { throw PDFError.malformed("truncated xref") }
            if token == "trailer" { break }
            guard let start = Int(token), let count = parser.readToken().flatMap(Int.init) else {
                parser.position = saved
                throw PDFError.malformed("bad xref subsection")
            }
            for i in 0..<count {
                guard let offset = parser.readToken().flatMap(Int.init),
                      let generation = parser.readToken().flatMap(Int.init),
                      let flag = parser.readToken() else { throw PDFError.malformed("bad xref entry") }
                section[start + i] = flag == "n" ? .inUse(offset: offset, generation: generation) : .free
            }
        }
        guard case .dict(let trailer)? = parser.parseObject() else { throw PDFError.malformed("bad trailer") }

        // Hybrid files keep some objects in a stream that the table marks as free.
        if let stm = trailer["XRefStm"]?.intValue {
            usesXRefStreams = true
            _ = try? readStreamSection(at: stm)
        }
        for (number, entry) in section where entries[number] == nil { entries[number] = entry }
        return trailer
    }

    private mutating func readStreamSection(at offset: Int) throws -> PDFDict {
        guard let object = try parseIndirect(at: offset), let dict = object.dict, let range = object.stream,
              let w = dict["W"]?.arrayValue?.compactMap(\.intValue), w.count == 3,
              let size = dict["Size"]?.intValue
        else { throw PDFError.malformed("bad xref stream") }

        let decoded = try decodeStream(dict: dict, raw: data[range])
        let index = dict["Index"]?.arrayValue?.compactMap(\.intValue) ?? [0, size]
        let rowLength = w[0] + w[1] + w[2]
        guard rowLength > 0 else { throw PDFError.malformed("empty xref stream") }

        func field(_ row: Int, _ start: Int, _ width: Int, default fallback: Int) -> Int {
            guard width > 0 else { return fallback }
            var value = 0
            for i in 0..<width { value = value << 8 | Int(decoded[decoded.startIndex + row * rowLength + start + i]) }
            return value
        }

        var row = 0
        var i = 0
        while i + 1 < index.count {
            for number in index[i]..<index[i] + index[i + 1] {
                guard (row + 1) * rowLength <= decoded.count else { throw PDFError.malformed("short xref stream") }
                let type = field(row, 0, w[0], default: 1)
                let second = field(row, w[0], w[1], default: 0)
                let third = field(row, w[0] + w[1], w[2], default: 0)
                let entry: XRefEntry = switch type {
                case 0: .free
                case 1: .inUse(offset: second, generation: third)
                default: .compressed(stream: second, index: third)
                }
                if entries[number] == nil { entries[number] = entry }
                row += 1
            }
            i += 2
        }
        return dict
    }

    // MARK: Objects

    /// Parses `n g obj … endobj` at `offset`.
    func parseIndirect(at offset: Int) throws -> PDFIndirectObject? {
        guard offset >= 0, offset < data.count else { return nil }
        var parser = PDFParser(data, at: offset)
        guard let number = parser.readToken().flatMap(Int.init),
              let generation = parser.readToken().flatMap(Int.init),
              parser.expect(keyword: "obj"),
              let value = parser.parseObject()
        else { return nil }

        var streamRange: Range<Int>?
        let afterValue = parser.position
        if case .dict(let dict) = value, parser.expect(keyword: "stream") {
            var start = parser.position
            if start < data.endIndex, data[start] == 13 { start += 1 }
            if start < data.endIndex, data[start] == 10 { start += 1 }

            var length: Int?
            switch dict["Length"] {
            case .int(let n)?: length = n
            case .ref(let n, _)?: length = resolveInt(n)
            default: break
            }
            var end: Int?
            if let length, start + length <= data.count {
                var check = PDFParser(data, at: start + length)
                if check.expect(keyword: "endstream") { end = start + length }
            }
            if end == nil {
                // Length was wrong or missing: find the keyword instead.
                guard let found = data[start...].firstRange(of: Array("endstream".utf8)) else { return nil }
                var e = found.lowerBound
                if e > start, data[e - 1] == 10 { e -= 1 }
                if e > start, data[e - 1] == 13 { e -= 1 }
                end = e
            }
            streamRange = start..<end!
            var tail = PDFParser(data, at: end!)
            _ = tail.expect(keyword: "endstream")
            parser.position = tail.position
        } else {
            parser.position = afterValue
        }

        let saved = parser.position
        let endObj = parser.expect(keyword: "endobj")
        return PDFIndirectObject(
            number: number, generation: generation, value: value, stream: streamRange,
            end: endObj ? parser.position : saved)
    }

    /// The object with this number, if it is stored directly in the file (not inside an object stream).
    func object(_ number: Int) -> PDFIndirectObject? {
        guard case .inUse(let offset, _)? = entries[number] else { return nil }
        return try? parseIndirect(at: offset)
    }

    func resolveInt(_ number: Int) -> Int? {
        object(number)?.value.intValue
    }

    /// Follows a reference; other values are returned unchanged.
    func resolve(_ value: PDFObject?) -> PDFObject? {
        if case .ref(let n, _)? = value { return object(n)?.value }
        return value
    }

    // MARK: Stream data

    func rawStream(_ object: PDFIndirectObject) -> Data? {
        object.stream.map { Data(data[$0]) }
    }

    /// Undoes a single FlateDecode filter and its predictor, or returns the data unchanged if there is no filter.
    func decodeStream(dict: PDFDict, raw: Data) throws -> Data {
        let filters = Self.filterNames(dict["Filter"])
        guard filters.count <= 1 else { throw PDFError.unsupported("filter chain") }
        guard let filter = filters.first else { return raw }
        guard filter == "FlateDecode" || filter == "Fl" else { throw PDFError.unsupported(filter) }

        guard let inflated = Inflate.decode(raw) else { throw PDFError.malformed("bad deflate data") }
        let parms = resolve(dict["DecodeParms"] ?? dict["DP"])?.dictValue
        return try Predictor.undo(inflated, parms: parms.map { PredictorParams($0, file: self) })
    }

    static func filterNames(_ value: PDFObject?) -> [String] {
        switch value {
        case .name(let n)?: [n]
        case .array(let a)?: a.compactMap(\.nameValue)
        default: []
        }
    }
}

extension Data {
    func lastRange(of pattern: [UInt8]) -> Range<Int>? {
        guard count >= pattern.count else { return nil }
        var i = endIndex - pattern.count
        while i >= startIndex {
            if self[i] == pattern[0], self[i..<i + pattern.count].elementsEqual(pattern) { return i..<i + pattern.count }
            i -= 1
        }
        return nil
    }

    func firstRange(of pattern: [UInt8]) -> Range<Int>? {
        guard count >= pattern.count, let first = pattern.first else { return nil }
        var i = startIndex
        let last = endIndex - pattern.count
        while i <= last {
            if self[i] == first, self[i..<i + pattern.count].elementsEqual(pattern) { return i..<i + pattern.count }
            i += 1
        }
        return nil
    }
}

// MARK: - Deflate and predictors

enum Inflate {
    /// Decodes a zlib stream (header, deflate data, checksum).
    static func decode(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let cmf = data[data.startIndex], flg = data[data.startIndex + 1]
        guard cmf & 0x0F == 8, (Int(cmf) << 8 | Int(flg)) % 31 == 0 else { return nil }
        let skip = flg & 0x20 != 0 ? 6 : 2
        let body = Data(data.dropFirst(skip))
        return try? (body as NSData).decompressed(using: .zlib) as Data
    }
}

struct PredictorParams {
    var predictor = 1
    var colors = 1
    var bitsPerComponent = 8
    var columns = 1

    init(_ dict: PDFDict, file: PDFFile) {
        predictor = dict["Predictor"]?.intValue ?? 1
        colors = dict["Colors"]?.intValue ?? 1
        bitsPerComponent = dict["BitsPerComponent"]?.intValue ?? 8
        columns = dict["Columns"]?.intValue ?? 1
    }
}

enum Predictor {
    static func undo(_ data: Data, parms: PredictorParams?) throws -> Data {
        guard let p = parms, p.predictor > 1 else { return data }
        let bytesPerPixel = max(1, p.colors * p.bitsPerComponent / 8)
        let rowBytes = (p.columns * p.colors * p.bitsPerComponent + 7) / 8

        if p.predictor == 2 {
            guard p.bitsPerComponent == 8 else { throw PDFError.unsupported("TIFF predictor depth") }
            var out = [UInt8](data)
            for row in stride(from: 0, to: out.count - rowBytes + 1, by: rowBytes) {
                for i in bytesPerPixel..<rowBytes { out[row + i] = out[row + i] &+ out[row + i - bytesPerPixel] }
            }
            return Data(out)
        }
        guard p.predictor >= 10 else { throw PDFError.unsupported("predictor \(p.predictor)") }

        let stride = rowBytes + 1
        let rows = data.count / stride
        var out = [UInt8](repeating: 0, count: rows * rowBytes)
        let input = [UInt8](data)
        for y in 0..<rows {
            let type = input[y * stride]
            for i in 0..<rowBytes {
                let x = input[y * stride + 1 + i]
                let left = i >= bytesPerPixel ? out[y * rowBytes + i - bytesPerPixel] : 0
                let up = y > 0 ? out[(y - 1) * rowBytes + i] : 0
                let upLeft = (y > 0 && i >= bytesPerPixel) ? out[(y - 1) * rowBytes + i - bytesPerPixel] : 0
                let value: UInt8
                switch type {
                case 0: value = x
                case 1: value = x &+ left
                case 2: value = x &+ up
                case 3: value = x &+ UInt8((Int(left) + Int(up)) / 2)
                case 4: value = x &+ paeth(left, up, upLeft)
                default: throw PDFError.malformed("bad PNG filter")
                }
                out[y * rowBytes + i] = value
            }
        }
        return Data(out)
    }

    private static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let p = Int(a) + Int(b) - Int(c)
        let pa = abs(p - Int(a)), pb = abs(p - Int(b)), pc = abs(p - Int(c))
        if pa <= pb && pa <= pc { return a }
        return pb <= pc ? b : c
    }
}
