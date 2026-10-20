import Foundation

/// A PDF value. Strings and names keep their original spelling so they can be written back unchanged.
indirect enum PDFObject: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case real(String)
    case name(String)  // without the leading slash, escapes intact
    case string(Data)  // including the ( ) or < > delimiters
    case array([PDFObject])
    case dict(PDFDict)
    case ref(Int, Int)

    var intValue: Int? {
        switch self {
        case .int(let n): n
        case .real(let s): Double(s).map { Int($0) }
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let n): Double(n)
        case .real(let s): Double(s)
        default: nil
        }
    }

    var nameValue: String? {
        if case .name(let n) = self { n } else { nil }
    }

    var dictValue: PDFDict? {
        if case .dict(let d) = self { d } else { nil }
    }

    var arrayValue: [PDFObject]? {
        if case .array(let a) = self { a } else { nil }
    }
}

/// A dictionary that remembers the order of its keys.
struct PDFDict: Equatable {
    private(set) var entries: [(key: String, value: PDFObject)] = []

    init(_ entries: [(key: String, value: PDFObject)] = []) { self.entries = entries }

    subscript(key: String) -> PDFObject? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
            } else if let newValue {
                entries.append((key, newValue))
            }
        }
    }

    static func == (a: PDFDict, b: PDFDict) -> Bool {
        a.entries.count == b.entries.count && zip(a.entries, b.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }
}

// MARK: - Writing

extension PDFObject {
    func serialize(into out: inout Data) {
        switch self {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .int(let n): out.append(contentsOf: Array(String(n).utf8))
        case .real(let s): out.append(contentsOf: Array(s.utf8))
        case .name(let n): out.append(contentsOf: Array("/\(n)".utf8))
        case .string(let d): out.append(d)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: " ")) }
                item.serialize(into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .dict(let d):
            out.append(contentsOf: Array("<<".utf8))
            for (key, value) in d.entries {
                out.append(contentsOf: Array("/\(key) ".utf8))
                value.serialize(into: &out)
                out.append(UInt8(ascii: " "))
            }
            out.append(contentsOf: Array(">>".utf8))
        case .ref(let n, let g): out.append(contentsOf: Array("\(n) \(g) R".utf8))
        }
    }
}

// MARK: - Parsing

struct PDFParser {
    let data: Data
    var position: Int

    init(_ data: Data, at position: Int = 0) {
        self.data = data
        self.position = position
    }

    static func isWhitespace(_ b: UInt8) -> Bool { b == 0 || b == 9 || b == 10 || b == 12 || b == 13 || b == 32 }
    static func isDelimiter(_ b: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(b) }

    var atEnd: Bool { position >= data.endIndex }

    mutating func skipWhitespace() {
        while position < data.endIndex {
            let b = data[position]
            if Self.isWhitespace(b) {
                position += 1
            } else if b == UInt8(ascii: "%") {
                while position < data.endIndex, data[position] != 10, data[position] != 13 { position += 1 }
            } else {
                break
            }
        }
    }

    /// Reads a bare word such as `obj`, `R`, `stream` or a number.
    mutating func readToken() -> String? {
        skipWhitespace()
        let start = position
        while position < data.endIndex, !Self.isWhitespace(data[position]), !Self.isDelimiter(data[position]) { position += 1 }
        guard position > start else { return nil }
        return String(decoding: data[start..<position], as: UTF8.self)
    }

    mutating func expect(keyword: String) -> Bool {
        let saved = position
        if readToken() == keyword { return true }
        position = saved
        return false
    }

    mutating func parseObject() -> PDFObject? {
        skipWhitespace()
        guard position < data.endIndex else { return nil }
        let b = data[position]

        switch b {
        case UInt8(ascii: "/"):
            position += 1
            let start = position
            while position < data.endIndex, !Self.isWhitespace(data[position]), !Self.isDelimiter(data[position]) { position += 1 }
            return .name(String(decoding: data[start..<position], as: UTF8.self))

        case UInt8(ascii: "("):
            let start = position
            var depth = 0
            while position < data.endIndex {
                let c = data[position]
                if c == UInt8(ascii: "\\") {
                    position += 2
                    continue
                }
                if c == UInt8(ascii: "(") { depth += 1 }
                if c == UInt8(ascii: ")") {
                    depth -= 1
                    if depth == 0 {
                        position += 1
                        return .string(Data(data[start..<position]))
                    }
                }
                position += 1
            }
            return nil

        case UInt8(ascii: "<"):
            if position + 1 < data.endIndex, data[position + 1] == UInt8(ascii: "<") {
                position += 2
                var dict = PDFDict()
                while true {
                    skipWhitespace()
                    guard position < data.endIndex else { return nil }
                    if data[position] == UInt8(ascii: ">") {
                        guard position + 1 < data.endIndex, data[position + 1] == UInt8(ascii: ">") else { return nil }
                        position += 2
                        return .dict(dict)
                    }
                    guard case .name(let key)? = parseObject(), let value = parseObject() else { return nil }
                    dict[key] = value
                }
            }
            let start = position
            while position < data.endIndex, data[position] != UInt8(ascii: ">") { position += 1 }
            guard position < data.endIndex else { return nil }
            position += 1
            return .string(Data(data[start..<position]))

        case UInt8(ascii: "["):
            position += 1
            var items: [PDFObject] = []
            while true {
                skipWhitespace()
                guard position < data.endIndex else { return nil }
                if data[position] == UInt8(ascii: "]") {
                    position += 1
                    return .array(items)
                }
                guard let item = parseObject() else { return nil }
                items.append(item)
            }

        default:
            guard let token = readToken() else { return nil }
            if token == "true" { return .bool(true) }
            if token == "false" { return .bool(false) }
            if token == "null" { return .null }
            if let n = Int(token) {
                // `12 0 R` is a reference; otherwise this is just the number.
                let saved = position
                if n >= 0, let g = readToken().flatMap(Int.init), g >= 0, readToken() == "R" { return .ref(n, g) }
                position = saved
                return .int(n)
            }
            if Double(token) != nil { return .real(token) }
            return nil
        }
    }
}
