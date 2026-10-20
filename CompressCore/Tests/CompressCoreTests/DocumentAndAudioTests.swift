import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import CompressCore

private func run(_ tool: String, _ args: [String], in directory: URL? = nil) throws -> (status: Int32, output: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    process.currentDirectoryURL = directory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, output)
}

@Suite struct DocumentCompressorTests {
    let dir: Scratch
    let compressor = DocumentCompressor()

    init() throws { dir = try Scratch() }

    /// Builds a zip with the system `zip` tool, so the fixture is made by something other than our own writer.
    private func makeArchive(_ name: String, files: [(String, Data)], storedFirst: String? = nil) throws -> URL {
        let work = dir.url.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        for (path, data) in files {
            let url = work.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let archive = dir.url.appendingPathComponent(name)
        if let first = storedFirst {
            _ = try run("/usr/bin/zip", ["-X0q", archive.path, first], in: work)
        }
        _ = try run("/usr/bin/zip", ["-Xqr", archive.path, "."] + (storedFirst.map { ["-x", $0] } ?? []), in: work)
        return archive
    }

    private func jpegData(width: Int = 1800, height: Int = 1200) throws -> Data {
        let url = dir.url.appendingPathComponent("tmp-\(UUID().uuidString).jpg")
        try Fixtures.write(Fixtures.photoLike(width: width, height: height, seed: 4), type: "public.jpeg", to: url, quality: 1.0)
        return try Data(contentsOf: url)
    }

    private func pngData() throws -> Data {
        let url = dir.url.appendingPathComponent("tmp-\(UUID().uuidString).png")
        try Fixtures.write(Fixtures.photoLike(width: 600, height: 400, seed: 6), type: "public.png", to: url, quality: nil)
        return try Data(contentsOf: url)
    }

    private func compress(_ input: URL, _ preset: Preset = Preset(level: .medium)) async throws -> URL {
        let out = dir.url.appendingPathComponent("out-\(UUID().uuidString).\(input.pathExtension)")
        try await compressor.compress(input: input, output: out, preset: preset) { _ in }
        return out
    }

    private func extract(_ archive: URL, _ entry: String) throws -> Data {
        try run("/usr/bin/unzip", ["-p", archive.path, entry]).output
    }

    private func names(_ archive: URL) throws -> [String] {
        let listing = String(decoding: try run("/usr/bin/unzip", ["-Z1", archive.path]).output, as: UTF8.self)
        return listing.split(separator: "\n").map(String.init)
    }

    @Test func shrinksEmbeddedImagesAndKeepsEverythingElse() async throws {
        let xml = Data(String(repeating: "<w:p>Hello</w:p>", count: 500).utf8)
        let input = try makeArchive("report.docx", files: [
            ("[Content_Types].xml", Data("<Types/>".utf8)),
            ("word/document.xml", xml),
            ("word/media/image1.jpg", try jpegData()),
            ("word/media/image2.png", try pngData()),
            ("docProps/core.xml", Data("<cp/>".utf8)),
        ])
        let out = try await compress(input)

        #expect(Fixtures.size(out) < Fixtures.size(input) / 2, "\(Fixtures.size(out)) vs \(Fixtures.size(input))")
        #expect(try run("/usr/bin/unzip", ["-t", out.path]).status == 0, "output must be a valid zip")
        #expect(try names(out).sorted() == names(input).sorted())
        #expect(try extract(out, "word/document.xml") == xml)
        #expect(try extract(out, "docProps/core.xml") == Data("<cp/>".utf8))

        let image = try extract(out, "word/media/image1.jpg")
        let source = try #require(CGImageSourceCreateWithData(image as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 1800 && decoded.height == 1200)
        #expect(image.count < (try extract(input, "word/media/image1.jpg")).count / 2)
    }

    @Test func keepsEntryOrderAndAnUncompressedMimetypeForEPUB() async throws {
        let input = try makeArchive("book.epub", files: [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data("<container/>".utf8)),
            ("OEBPS/images/cover.jpg", try jpegData()),
            ("OEBPS/content.xhtml", Data("<html/>".utf8)),
        ], storedFirst: "mimetype")
        let out = try await compress(input)

        #expect(try names(out).first == "mimetype")
        #expect(try names(out) == names(input))
        #expect(try run("/usr/bin/unzip", ["-t", out.path]).status == 0)
        // Stored, not deflated: readers look for the plain text at a fixed position.
        let bytes = try Data(contentsOf: out)
        #expect(bytes.firstRange(of: Array("application/epub+zip".utf8)) != nil)
        #expect(Fixtures.size(out) < Fixtures.size(input))
    }

    @Test func lowerLevelsGiveSmallerFiles() async throws {
        let input = try makeArchive("deck.pptx", files: [("ppt/media/image1.jpg", try jpegData()), ("ppt/slides/slide1.xml", Data("<s/>".utf8))])
        var sizes: [Int] = []
        for level in QualityLevel.allCases { sizes.append(Fixtures.size(try await compress(input, Preset(level: level)))) }
        #expect(sizes == sizes.sorted(by: >), "sizes: \(sizes)")
    }

    @Test func documentWithoutImagesComesBackUnchanged() async throws {
        let input = try makeArchive("plain.docx", files: [("word/document.xml", Data(String(repeating: "x", count: 4000).utf8))])
        let out = try await compress(input)
        #expect(try Data(contentsOf: out) == Data(contentsOf: input))
    }

    @Test func notAZipFailsWithClearMessage() async throws {
        let input = try dir.file("fake.docx", bytes: 300)
        do {
            _ = try await compress(input)
            Issue.record("should have thrown")
        } catch let error as CompressionError {
            #expect(error.localizedDescription.contains("can't be read"))
        }
    }

    @Test func detectsDocumentKinds() {
        for ext in ["docx", "pptx", "xlsx", "epub"] {
            #expect(MediaKind(url: URL(fileURLWithPath: "/x/a.\(ext)")) == .document, "\(ext)")
        }
        #expect(MediaKind(url: URL(fileURLWithPath: "/x/a.m4a")) == .audio)
        #expect(MediaKind(url: URL(fileURLWithPath: "/x/a.mp3")) == .audio)
        #expect(MediaKind(url: URL(fileURLWithPath: "/x/a.wav")) == .audio)
        #expect(MediaKind(url: URL(fileURLWithPath: "/x/a.mp4")) == .video)
    }

    @Test func replacesOriginalThroughTheQueue() async throws {
        let input = try makeArchive("q.docx", files: [("word/media/i.jpg", try jpegData()), ("word/document.xml", Data("<d/>".utf8))])
        let before = Fixtures.size(input)
        let queue = JobQueue(registry: CompressorRegistry([compressor]), maxConcurrent: 1)
        let id = await queue.enqueue(urls: [input], preset: Preset(level: .medium), outputPolicy: .replaceOriginal).accepted[0]
        await queue.waitUntilIdle()
        guard case .completed(let result) = await queue.job(id)?.state else {
            Issue.record("job did not complete: \(String(describing: await queue.job(id)?.state))")
            return
        }
        #expect(result.outcome == .compressed)
        #expect(Fixtures.size(input) < before)
        #expect(try run("/usr/bin/unzip", ["-t", input.path]).status == 0)
    }
}

extension AVTests {
@Suite struct AudioCompressorTests {
    let dir: Scratch
    init() throws { dir = try Scratch() }

    private func makeWAV(seconds: Double = 3) async throws -> URL {
        // A stereo-ish noisy tone, written as uncompressed PCM.
        let url = dir.url.appendingPathComponent("tone.wav")
        let writer = try AVAssetWriter(outputURL: url, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var description = AudioStreamBasicDescription(
            mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var rng = Fixtures.SeededRandom(state: 11)
        let chunk = 4096
        var frame = 0
        while Double(frame) / 44100 < seconds {
            let samples: [Int16] = (0..<chunk * 2).map { i in
                let t = Double(frame + i / 2) / 44100
                return Int16(sin(t * 2 * .pi * 440) * 6000 + sin(t * 2 * .pi * 1320) * 2500) &+ Int16(truncatingIfNeeded: Int(rng.next() % 600) - 300)
            }
            var block: CMBlockBuffer?
            let length = samples.count * 2
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block)
            samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: chunk,
                presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 44100), packetDescriptions: nil, sampleBufferOut: &sample)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            input.append(sample!)
            frame += chunk
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    private func compress(_ input: URL, _ level: QualityLevel) async throws -> URL {
        let out = dir.url.appendingPathComponent("out-\(UUID().uuidString).m4a")
        try await AudioCompressor().compress(input: input, output: out, preset: Preset(level: level)) { _ in }
        return out
    }

    @Test func turnsPCMIntoSmallAAC() async throws {
        let input = try await makeWAV()
        let out = try await compress(input, .medium)

        #expect(Fixtures.size(out) < Fixtures.size(input) / 8)
        let asset = AVURLAsset(url: out)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC)
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.2)
        #expect(AudioCompressor().outputExtension(for: input, preset: .default) == "m4a")
    }

    @Test func lowerLevelsGiveSmallerFiles() async throws {
        let input = try await makeWAV()
        var sizes: [Int] = []
        for level in QualityLevel.allCases { sizes.append(Fixtures.size(try await compress(input, level))) }
        #expect(sizes == sizes.sorted(by: >), "sizes: \(sizes)")
    }

    @Test func notAudioFailsWithClearMessage() async throws {
        let input = try dir.file("fake.wav", bytes: 400)
        do {
            _ = try await compress(input, .high)
            Issue.record("should have thrown")
        } catch let error as CompressionError {
            #expect(error.localizedDescription.contains("can't be read"))
        }
    }
}
}
