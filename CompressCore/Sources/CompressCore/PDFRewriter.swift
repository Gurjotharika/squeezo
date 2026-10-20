import Foundation

/// Writes a smaller copy of a PDF: live objects only, with large images re-encoded.
/// Everything else is copied byte for byte, so text, fonts, links and forms are untouched.
enum PDFRewriter {
    static func rewrite(
        _ file: PDFFile,
        preset: Preset,
        progress: @Sendable (Double) -> Void
    ) throws -> Data {
        if file.trailer["Encrypt"] != nil { throw PDFError.unsupported("encrypted") }

        let recompressor = PDFImageRecompressor(file: file, level: preset.level, maxDimension: preset.maxDimension)
        let numbers = file.entries.keys.sorted()

        // Parse every stored object once; find soft masks, which must stay lossless.
        var objects: [Int: PDFIndirectObject] = [:]
        var maskNumbers = Set<Int>()
        for number in numbers {
            guard case .inUse(let offset, _)? = file.entries[number] else { continue }
            guard let object = try file.parseIndirect(at: offset), object.number == number else {
                throw PDFError.malformed("object \(number) not at its offset")
            }
            objects[number] = object
            if case .ref(let m, _)? = object.dict?["SMask"] { maskNumbers.insert(m) }
        }

        // Objects to leave out: old cross-reference streams, the linearization header, the Info dictionary.
        var dropped = Set<Int>()
        for (number, object) in objects {
            let type = object.dict?["Type"]?.nameValue
            if type == "XRef" || object.dict?["Linearized"] != nil { dropped.insert(number) }
        }
        var trailerInfo = file.trailer["Info"]
        if preset.stripMetadata {
            if case .ref(let n, _)? = trailerInfo { dropped.insert(n) }
            trailerInfo = nil
        }
        var catalogNumber: Int?
        if case .ref(let n, _)? = file.trailer["Root"] { catalogNumber = n }

        var out = Data()
        out.append(contentsOf: Array((file.version + "\n").utf8))
        out.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])  // binary marker comment

        var newEntries: [Int: XRefEntry] = [:]
        var done = 0
        for number in numbers {
            try Task.checkCancellation()
            defer {
                done += 1
                progress(Double(done) / Double(max(numbers.count, 1)))
            }
            switch file.entries[number] {
            case .compressed(let stream, let index)?:
                if !dropped.contains(stream) { newEntries[number] = .compressed(stream: stream, index: index) }
            case .inUse(_, let generation)?:
                guard let object = objects[number], !dropped.contains(number) else { continue }
                newEntries[number] = .inUse(offset: out.count, generation: generation)

                if let (dict, data) = recompressor.recompress(object), !maskNumbers.contains(number) {
                    write(number, generation, dict: dict, stream: data, into: &out)
                } else if number == catalogNumber, preset.stripMetadata, var catalog = object.dict, object.stream == nil {
                    catalog["Metadata"] = nil
                    catalog["PieceInfo"] = nil
                    write(number, generation, dict: catalog, stream: nil, into: &out)
                } else {
                    out.append(file.data[object.startOffset(in: file)..<object.end])
                    out.append(0x0A)
                }
            default:
                break
            }
        }

        // Cross-reference section and trailer.
        let size = file.size
        var trailer = PDFDict()
        trailer["Size"] = .int(size)
        trailer["Root"] = file.trailer["Root"]
        trailer["Info"] = trailerInfo
        trailer["ID"] = file.trailer["ID"]

        let hasCompressed = newEntries.values.contains { if case .compressed = $0 { true } else { false } }
        let xrefOffset = out.count
        if hasCompressed {
            let number = size
            trailer["Size"] = .int(size + 1)
            newEntries[number] = .inUse(offset: xrefOffset, generation: 0)
            var rows = Data()
            for n in 0...number {
                switch newEntries[n] {
                case .inUse(let offset, let generation)?:
                    rows.append(1); rows.appendBigEndian(UInt32(offset)); rows.append(contentsOf: [UInt8(generation >> 8 & 0xFF), UInt8(generation & 0xFF)])
                case .compressed(let stream, let index)?:
                    rows.append(2); rows.appendBigEndian(UInt32(stream)); rows.append(contentsOf: [UInt8(index >> 8 & 0xFF), UInt8(index & 0xFF)])
                default:
                    rows.append(0); rows.appendBigEndian(0); rows.append(contentsOf: [0xFF, 0xFF])
                }
            }
            var dict = trailer
            dict["Type"] = .name("XRef")
            dict["W"] = .array([.int(1), .int(4), .int(2)])
            write(number, 0, dict: dict, stream: rows, into: &out)
        } else {
            out.append(contentsOf: Array("xref\n0 \(size)\n".utf8))
            for n in 0..<size {
                if case .inUse(let offset, let generation)? = newEntries[n] {
                    out.append(contentsOf: Array(String(format: "%010d %05d n \n", offset, generation).utf8))
                } else {
                    out.append(contentsOf: Array("0000000000 65535 f \n".utf8))
                }
            }
            out.append(contentsOf: Array("trailer\n".utf8))
            PDFObject.dict(trailer).serialize(into: &out)
            out.append(0x0A)
        }
        out.append(contentsOf: Array("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return out
    }

    private static func write(_ number: Int, _ generation: Int, dict: PDFDict, stream: Data?, into out: inout Data) {
        var dict = dict
        if let stream { dict["Length"] = .int(stream.count) }
        out.append(contentsOf: Array("\(number) \(generation) obj\n".utf8))
        PDFObject.dict(dict).serialize(into: &out)
        if let stream {
            out.append(contentsOf: Array("\nstream\n".utf8))
            out.append(stream)
            out.append(contentsOf: Array("\nendstream".utf8))
        }
        out.append(contentsOf: Array("\nendobj\n".utf8))
    }
}

extension PDFIndirectObject {
    /// Where `n g obj` starts in the file.
    func startOffset(in file: PDFFile) -> Int {
        if case .inUse(let offset, _)? = file.entries[number] { return offset }
        return 0
    }
}
