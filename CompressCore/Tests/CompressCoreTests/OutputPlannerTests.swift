import Foundation
import Testing
@testable import CompressCore

@Suite struct OutputPlannerTests {
    @Test func uniqueURLAddsCounterWhenTaken() throws {
        let dir = try Scratch()
        try dir.file("a.jpg")
        try dir.file("a 2.jpg")

        let url = OutputPlanner.uniqueURL(dir: dir.url, name: "a", ext: "jpg", fileManager: .default)
        #expect(url.lastPathComponent == "a 3.jpg")
    }

    @Test func uniqueURLKeepsNameWhenFree() throws {
        let dir = try Scratch()
        let url = OutputPlanner.uniqueURL(dir: dir.url, name: "a", ext: "jpg", fileManager: .default)
        #expect(url.lastPathComponent == "a.jpg")
    }
}
