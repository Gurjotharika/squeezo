import Foundation
import Testing
@testable import CompressCore

@Suite struct FileCollectorTests {
    @Test func keepsPlainFilesInOrder() throws {
        let dir = try Scratch()
        let b = try dir.file("b.jpg")
        let a = try dir.file("a.jpg")
        #expect(FileCollector.collect([b, a]) == [b, a])
    }

    @Test func searchesFoldersRecursivelyAndSkipsHidden() throws {
        let dir = try Scratch()
        let sub = dir.url.appendingPathComponent("sub/deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try dir.file("top.jpg")
        try Data([1]).write(to: sub.appendingPathComponent("deep.png"))
        try Data([1]).write(to: dir.url.appendingPathComponent(".hidden.jpg"))

        let names = FileCollector.collect([dir.url]).map(\.lastPathComponent)
        #expect(names.sorted() == ["deep.png", "top.jpg"])
    }

    @Test func removesDuplicates() throws {
        let dir = try Scratch()
        let a = try dir.file("a.jpg")
        #expect(FileCollector.collect([a, dir.url, a]).count == 1)
    }

    @Test func treatsPackagesAsSingleItems() throws {
        let dir = try Scratch()
        let pkg = dir.url.appendingPathComponent("Thing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data([1]).write(to: pkg.appendingPathComponent("inner.jpg"))
        #expect(FileCollector.collect([pkg]) == [pkg])
    }
}
