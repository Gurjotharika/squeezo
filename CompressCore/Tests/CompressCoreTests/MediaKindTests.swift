import Testing
import UniformTypeIdentifiers
@testable import CompressCore

@Suite struct MediaKindTests {
    @Test func detectsKinds() {
        #expect(MediaKind(contentType: .jpeg) == .image)
        #expect(MediaKind(contentType: .png) == .image)
        #expect(MediaKind(contentType: .heic) == .image)
        #expect(MediaKind(contentType: .gif) == .gif)
        #expect(MediaKind(contentType: .pdf) == .pdf)
        #expect(MediaKind(contentType: .mpeg4Movie) == .video)
        #expect(MediaKind(contentType: .quickTimeMovie) == .video)
    }

    @Test func rejectsUnsupported() {
        #expect(MediaKind(contentType: .plainText) == nil)
    }

    @Test func detectsFromExtensionWhenFileIsMissing() {
        #expect(MediaKind(url: URL(fileURLWithPath: "/nowhere/a.jpg")) == .image)
        #expect(MediaKind(url: URL(fileURLWithPath: "/nowhere/a.mp4")) == .video)
        #expect(MediaKind(url: URL(fileURLWithPath: "/nowhere/a.txt")) == nil)
    }
}
