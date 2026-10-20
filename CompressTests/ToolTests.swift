import CompressCore
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import Compress

@MainActor
@Suite struct ToolTests {
    private func makeModel() -> AppModel {
        let store = UserDefaults(suiteName: "ToolTests-\(UUID().uuidString)")!
        return AppModel(defaults: store, registry: Engines.registry(), entitlements: Entitlements(defaults: store, dailyLimit: 1000))
    }

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func picture(_ name: String, in dir: URL, width: Int = 200, height: Int = 100) throws -> URL {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    private func pdf(_ name: String, pages: Int, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for _ in 0..<pages { ctx.beginPDFPage(nil); ctx.endPDFPage() }
        ctx.closePDF()
        return url
    }

    private func waitForJobs(_ model: AppModel, count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if model.jobs.count == count, model.jobs.allSatisfy({ $0.state.isFinished }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test func filesAreStagedNotRunWhenAToolIsChosen() async throws {
        let model = makeModel()
        model.tool = .resize
        let dir = try folder()
        await model.add(urls: [try picture("a.png", in: dir), try picture("b.png", in: dir)])
        #expect(model.staged.count == 2)
        #expect(model.jobs.isEmpty, "nothing runs until the button is pressed")
        #expect(model.selection == model.staged.first?.id, "the first file is selected so the inspector has something to show")
    }

    @Test func compressionStillStartsAtOnce() async throws {
        let model = makeModel()
        let observer = Task { await model.run() }
        defer { observer.cancel() }
        let dir = try folder()
        await model.add(urls: [try picture("a.png", in: dir)])
        #expect(model.staged.isEmpty)
        #expect(await waitForJobs(model, count: 1))
    }

    @Test func toolsOnlyTakeFilesTheyCanHandle() async throws {
        let model = makeModel()
        model.tool = .splitPDF
        let dir = try folder()
        await model.add(urls: [try picture("a.png", in: dir), try pdf("a.pdf", pages: 2, in: dir)])
        #expect(model.staged.map(\.url.lastPathComponent) == ["a.pdf"])
        #expect(model.notice?.contains("skipped") == true)
    }

    @Test func stagedFilesBelongToTheirTool() async throws {
        let model = makeModel()
        let dir = try folder()
        model.tool = .resize
        await model.add(urls: [try picture("a.png", in: dir)])
        model.tool = .crop
        #expect(model.staged.isEmpty)
        #expect(model.stagedCount(.resize) == 1)
        model.tool = .resize
        #expect(model.staged.count == 1)
    }

    @Test func runningResizeMakesAResizedCopy() async throws {
        let model = makeModel()
        let observer = Task { await model.run() }
        defer { observer.cancel() }
        let dir = try folder()
        let source = try picture("a.png", in: dir, width: 400, height: 200)
        model.tool = .resize
        model.settings.resizeKind = .fit
        model.settings.resizeMaxSide = 100
        await model.add(urls: [source])
        await model.runStaged()

        #expect(await waitForJobs(model, count: 1))
        #expect(model.staged.isEmpty)
        guard case .completed(let result) = model.jobs.first?.state else {
            Issue.record("job did not complete: \(String(describing: model.jobs.first?.state))")
            return
        }
        #expect(result.outcome == .processed)
        #expect(result.outputURL.lastPathComponent == "a-resized.png")
        let image = CGImageSourceCreateWithURL(result.outputURL as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        #expect(image?.width == 100 && image?.height == 50)
        #expect(FileManager.default.fileExists(atPath: source.path), "the original is untouched")
    }

    @Test func toolsExplainWhatIsMissingBeforeRunning() async throws {
        let model = makeModel()
        let dir = try folder()
        model.tool = .crop
        await model.add(urls: [try picture("a.png", in: dir)])
        #expect(model.runBlocker != nil, "a full-frame crop does nothing")
        model.settings.crop = NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)
        #expect(model.runBlocker == nil)

        model.tool = .rotate
        await model.add(urls: [try picture("b.png", in: dir)])
        #expect(model.runBlocker != nil)
        model.settings.rotate = RotateSpec(quarterTurns: 1)
        #expect(model.runBlocker == nil)

        model.tool = .mergePDF
        await model.add(urls: [try pdf("one.pdf", pages: 1, in: dir)])
        #expect(model.runBlocker?.contains("two") == true)

        model.tool = .watermark
        model.settings.watermarkText = "  "
        await model.add(urls: [try picture("c.png", in: dir)])
        #expect(model.runBlocker != nil)

        model.tool = .splitPDF
        model.settings.splitKind = .ranges
        model.settings.splitRanges = ""
        await model.add(urls: [try pdf("two.pdf", pages: 3, in: dir)])
        #expect(model.runBlocker != nil)
    }

    @Test func mergeRunsAsOneJobInTheChosenOrder() async throws {
        let model = makeModel()
        let observer = Task { await model.run() }
        defer { observer.cancel() }
        let dir = try folder()
        let first = try pdf("first.pdf", pages: 2, in: dir), second = try pdf("second.pdf", pages: 3, in: dir)
        model.tool = .mergePDF
        await model.add(urls: [first, second])
        // Move the second file to the front.
        model.moveStaged(model.staged[1].id, by: -1)
        #expect(model.staged.map(\.url.lastPathComponent) == ["second.pdf", "first.pdf"])
        await model.runStaged()

        #expect(await waitForJobs(model, count: 1))
        guard case .completed(let result) = model.jobs.first?.state else {
            Issue.record("merge did not complete: \(String(describing: model.jobs.first?.state))")
            return
        }
        #expect(result.outputURL.lastPathComponent == "second-merged.pdf", "named after the first file in the list")
        #expect(PDFDocument(url: result.outputURL)?.pageCount == 5)
    }

    @Test func splitMakesAFolderOfPages() async throws {
        let model = makeModel()
        let observer = Task { await model.run() }
        defer { observer.cancel() }
        let dir = try folder()
        model.tool = .splitPDF
        model.settings.splitKind = .everyPage
        await model.add(urls: [try pdf("doc.pdf", pages: 3, in: dir)])
        await model.runStaged()

        #expect(await waitForJobs(model, count: 1))
        guard case .completed(let result) = model.jobs.first?.state else {
            Issue.record("split did not complete: \(String(describing: model.jobs.first?.state))")
            return
        }
        #expect(result.outputURL.lastPathComponent == "doc-split")
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.outputURL.path).count == 3)
    }

    @Test func toolsThatMakeNewDocumentsNeverReplaceTheOriginal() async throws {
        let model = makeModel()
        let observer = Task { await model.run() }
        defer { observer.cancel() }
        model.outputMode = .replace
        let dir = try folder()
        let doc = try pdf("doc.pdf", pages: 2, in: dir)
        model.tool = .splitPDF
        await model.add(urls: [doc])
        await model.runStaged()

        #expect(await waitForJobs(model, count: 1))
        #expect(FileManager.default.fileExists(atPath: doc.path), "the PDF is still where it was")
    }

    @Test func visualToolsOpenOnTheirOptions() async throws {
        let model = makeModel()
        let dir = try folder()
        model.tool = .crop
        await model.add(urls: [try picture("a.png", in: dir)])
        #expect(model.inspectorTab == .options)
        model.tool = .resize
        await model.add(urls: [try picture("b.png", in: dir)])
        #expect(model.inspectorTab == .details)
    }

    @Test func theDailyLimitCoversEveryTool() async throws {
        let store = UserDefaults(suiteName: "ToolTests-\(UUID().uuidString)")!
        let model = AppModel(defaults: store, registry: Engines.registry(), entitlements: Entitlements(defaults: store, dailyLimit: 1))
        let observer = Task { await model.run() }
        defer { observer.cancel() }
        let dir = try folder()
        model.tool = .rotate
        model.settings.rotate = RotateSpec(quarterTurns: 1)
        await model.add(urls: [try picture("a.png", in: dir), try picture("b.png", in: dir)])
        await model.runStaged()
        #expect(await waitForJobs(model, count: 1), "only one of two files is allowed today")
        #expect(model.showPaywall)
    }

    @Test func everyToolHasAnEngineForEveryFileItAccepts() {
        let registry = Engines.registry()
        for tool in Tool.allCases {
            for kind in tool.accepts {
                #expect(registry.supports(tool.family, on: kind), "\(tool.title) on \(kind)")
            }
        }
    }
}
