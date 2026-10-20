import Foundation
import Testing
@testable import CompressCore

@Suite struct FolderScannerTests {
    let dir: Scratch
    let start = Date(timeIntervalSince1970: 1_000_000)

    init() throws { dir = try Scratch() }

    private func scanner(minimumAge: TimeInterval = 2) -> FolderScanner {
        FolderScanner(folder: dir.url, minimumAge: minimumAge)
    }

    @Test func reportsNewFileOnlyOnceItHasSettled() throws {
        var scanner = scanner()
        try dir.file("a.jpg")
        #expect(scanner.poll(now: start).isEmpty, "first sighting: might still be written")
        #expect(scanner.poll(now: start + 1).isEmpty, "not old enough")
        #expect(scanner.poll(now: start + 3).map(\.lastPathComponent) == ["a.jpg"])
    }

    @Test func waitsWhileAFileIsStillGrowing() throws {
        var scanner = scanner()
        let file = try dir.file("a.jpg", bytes: 100)
        _ = scanner.poll(now: start)
        try Data(repeating: 1, count: 200).write(to: file)  // grew
        #expect(scanner.poll(now: start + 3).isEmpty)
        #expect(scanner.poll(now: start + 6).map(\.lastPathComponent) == ["a.jpg"])
    }

    @Test func ignoresFilesThatWereAlreadyThere() throws {
        try dir.file("old.jpg")
        var scanner = scanner()
        scanner.markExistingAsProcessed()
        try dir.file("new.jpg")
        _ = scanner.poll(now: start)
        #expect(scanner.poll(now: start + 3).map(\.lastPathComponent) == ["new.jpg"])
    }

    @Test func doesNotReportProcessedFilesAgain() throws {
        var scanner = scanner()
        let file = try dir.file("a.jpg")
        _ = scanner.poll(now: start)
        #expect(scanner.poll(now: start + 3).count == 1)

        scanner.markProcessed(try #require(FileSignature(url: file)))
        #expect(scanner.poll(now: start + 6).isEmpty)
    }

    @Test func reportsAProcessedFileAgainWhenItChanges() throws {
        var scanner = scanner()
        let file = try dir.file("a.jpg", bytes: 100)
        scanner.markProcessed(try #require(FileSignature(url: file)))
        try Data(repeating: 2, count: 300).write(to: file)
        _ = scanner.poll(now: start)
        #expect(scanner.poll(now: start + 3).count == 1)
    }

    @Test func skipsHiddenTemporaryAndUnsupportedFiles() throws {
        var scanner = scanner()
        try dir.file(".hidden.jpg")
        try dir.file("movie.mp4.crdownload")
        try dir.file("photo.jpg.download")
        try dir.file("notes.txt")
        try dir.file("ok.png")
        _ = scanner.poll(now: start)
        #expect(scanner.poll(now: start + 3).map(\.lastPathComponent) == ["ok.png"])
    }

    @Test func ignoresSubfolders() throws {
        var scanner = scanner()
        let sub = dir.url.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: sub.appendingPathComponent("a.jpg"))
        _ = scanner.poll(now: start)
        #expect(scanner.poll(now: start + 3).isEmpty)
    }

    @Test func forgetsFilesThatDisappeared() throws {
        var scanner = scanner()
        let file = try dir.file("a.jpg")
        _ = scanner.poll(now: start)
        try FileManager.default.removeItem(at: file)
        _ = scanner.poll(now: start + 3)
        try dir.file("a.jpg")  // a different file with the same name must wait again
        #expect(scanner.poll(now: start + 4).isEmpty)
    }
}
