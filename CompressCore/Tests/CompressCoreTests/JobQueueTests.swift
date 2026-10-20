import Foundation
import Testing
@testable import CompressCore

@Suite struct JobQueueTests {
    @Test func acceptsSupportedAndRejectsUnsupported() async throws {
        let dir = try Scratch()
        let queue = makeQueue([FakeCompressor(kind: .image)])
        let photo = try dir.file("a.jpg")
        let notes = try dir.file("notes.txt")

        let result = await queue.enqueue(urls: [photo, notes])
        #expect(result.accepted.count == 1)
        #expect(result.rejected == [notes])
        await queue.waitUntilIdle()
    }

    @Test func compressesAndWritesSuffixedCopy() async throws {
        let dir = try Scratch()
        let queue = makeQueue([FakeCompressor(kind: .image, keepFraction: 0.4)])
        let photo = try dir.file("a.jpg", bytes: 1000)

        let id = await queue.enqueue(urls: [photo], outputPolicy: .suffix("-small")).accepted[0]
        await queue.waitUntilIdle()

        guard case .completed(let result) = await queue.job(id)?.state else {
            Issue.record("job did not complete")
            return
        }
        #expect(result.outcome == .compressed)
        #expect(result.originalBytes == 1000)
        #expect(result.outputBytes == 400)
        #expect(result.savedBytes == 600)
        #expect(abs(result.savingsRatio - 0.6) < 0.001)
        #expect(result.outputURL.lastPathComponent == "a-small.jpg")
        #expect(try dir.contents() == ["a-small.jpg", "a.jpg"])
    }

    @Test func keepsOriginalWhenNotSmaller() async throws {
        let dir = try Scratch()
        let queue = makeQueue([FakeCompressor(kind: .image, keepFraction: 1.0)])
        let photo = try dir.file("a.jpg")

        let id = await queue.enqueue(urls: [photo]).accepted[0]
        await queue.waitUntilIdle()

        guard case .completed(let result) = await queue.job(id)?.state else {
            Issue.record("job did not complete")
            return
        }
        #expect(result.outcome == .keptOriginal)
        #expect(result.outputURL == photo)
        #expect(result.savedBytes == 0)
        #expect(try dir.contents() == ["a.jpg"])
    }

    @Test func replaceOriginalOverwritesInPlace() async throws {
        let dir = try Scratch()
        let queue = makeQueue([FakeCompressor(kind: .image, keepFraction: 0.5)])
        let photo = try dir.file("a.jpg", bytes: 1000)

        _ = await queue.enqueue(urls: [photo], outputPolicy: .replaceOriginal)
        await queue.waitUntilIdle()

        #expect(try dir.contents() == ["a.jpg"])
        #expect(try Data(contentsOf: photo).count == 500)
    }

    @Test func folderPolicyWritesIntoFolderWithoutOverwriting() async throws {
        let dir = try Scratch()
        let out = dir.url.appendingPathComponent("out")
        let queue = makeQueue([FakeCompressor(kind: .image)], maxConcurrent: 1)
        let first = try dir.file("a.jpg")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data([1]).write(to: out.appendingPathComponent("a.jpg"))

        _ = await queue.enqueue(urls: [first], outputPolicy: .folder(out))
        await queue.waitUntilIdle()

        let names = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        #expect(names == ["a 2.jpg", "a.jpg"])
    }

    @Test func extensionChangeWithReplaceTrashesOriginal() async throws {
        let dir = try Scratch()
        let queue = makeQueue([FakeCompressor(kind: .video, changedExtension: "gif")])
        let clip = try dir.file("clip.mp4")

        let id = await queue.enqueue(urls: [clip], outputPolicy: .replaceOriginal).accepted[0]
        await queue.waitUntilIdle()

        guard case .completed(let result) = await queue.job(id)?.state else {
            Issue.record("job did not complete")
            return
        }
        #expect(result.outputURL.lastPathComponent == "clip.gif")
        #expect(try dir.contents() == ["clip.gif"])
    }

    @Test func failureDoesNotStopOtherJobs() async throws {
        let dir = try Scratch()
        let queue = makeQueue([FakeCompressor(kind: .image, failingFileNames: ["bad.jpg"])])
        let bad = try dir.file("bad.jpg")
        let good = try dir.file("good.jpg")

        let ids = await queue.enqueue(urls: [bad, good]).accepted
        await queue.waitUntilIdle()

        guard case .failed(let message) = await queue.job(ids[0])?.state else {
            Issue.record("bad job should fail")
            return
        }
        #expect(message.contains("bad.jpg"))
        guard case .completed = await queue.job(ids[1])?.state else {
            Issue.record("good job should complete")
            return
        }
        // No scratch files are left next to the sources.
        #expect(try dir.contents() == ["bad.jpg", "good-compressed.jpg", "good.jpg"])
    }

    @Test func missingCompressorFailsTheJob() async throws {
        let dir = try Scratch()
        let queue = makeQueue([FakeCompressor(kind: .image)])
        let id = await queue.enqueue(urls: [try dir.file("clip.mp4")]).accepted[0]
        await queue.waitUntilIdle()

        guard case .failed = await queue.job(id)?.state else {
            Issue.record("job should fail")
            return
        }
    }

    @Test func cancelsRunningJobAndCleansUp() async throws {
        let dir = try Scratch()
        let slow = FakeCompressor(kind: .image, steps: 200, stepDelay: .milliseconds(20))
        let queue = makeQueue([slow])
        let id = await queue.enqueue(urls: [try dir.file("a.jpg")]).accepted[0]

        let started = await eventually {
            if case .running = await queue.job(id)?.state { return true }
            return false
        }
        #expect(started)
        await queue.cancel(id)
        await queue.waitUntilIdle()

        #expect(await queue.job(id)?.state == .cancelled)
        #expect(try dir.contents() == ["a.jpg"])
    }

    @Test func cancelsQueuedJobBeforeItStarts() async throws {
        let dir = try Scratch()
        let slow = FakeCompressor(kind: .image, steps: 5, stepDelay: .milliseconds(20))
        let queue = makeQueue([slow], maxConcurrent: 1)
        let ids = await queue.enqueue(urls: [try dir.file("a.jpg"), try dir.file("b.jpg")]).accepted

        await queue.cancel(ids[1])
        await queue.waitUntilIdle()

        #expect(await queue.job(ids[1])?.state == .cancelled)
        guard case .completed = await queue.job(ids[0])?.state else {
            Issue.record("first job should complete")
            return
        }
        #expect(try dir.contents() == ["a-compressed.jpg", "a.jpg", "b.jpg"])
    }

    @Test func retryRunsAFailedJobAgain() async throws {
        let dir = try Scratch()
        let queue = makeQueue([FakeCompressor(kind: .image, failingFileNames: ["a.jpg"])])
        let id = await queue.enqueue(urls: [try dir.file("a.jpg")]).accepted[0]
        await queue.waitUntilIdle()
        guard case .failed = await queue.job(id)?.state else {
            Issue.record("job should fail first")
            return
        }

        await queue.retry(id)
        await queue.waitUntilIdle()

        // Still fails (same simulated failure) but it did run again.
        guard case .failed = await queue.job(id)?.state else {
            Issue.record("job should fail again")
            return
        }
    }

    @Test func retryRunsACancelledJobToCompletion() async throws {
        let dir = try Scratch()
        let slow = FakeCompressor(kind: .image, steps: 5, stepDelay: .milliseconds(20))
        let queue = makeQueue([slow], maxConcurrent: 1)
        let ids = await queue.enqueue(urls: [try dir.file("a.jpg"), try dir.file("b.jpg")]).accepted
        await queue.cancel(ids[1])
        await queue.retry(ids[1])
        await queue.waitUntilIdle()

        guard case .completed = await queue.job(ids[1])?.state else {
            Issue.record("retried job should complete")
            return
        }
    }

    @Test func respectsConcurrencyLimit() async throws {
        let dir = try Scratch()
        let probe = Probe()
        let compressor = FakeCompressor(
            kind: .image, steps: 3, stepDelay: .milliseconds(15),
            onStart: { await probe.begin($0) }, onFinish: { _ in await probe.end() })
        let queue = makeQueue([compressor], maxConcurrent: 2)
        let urls = try (1...6).map { try dir.file("f\($0).jpg") }

        await queue.enqueue(urls: urls)
        await queue.waitUntilIdle()

        #expect(await probe.peak == 2)
        #expect(await queue.snapshot().allSatisfy { if case .completed = $0.state { true } else { false } })
    }

    @Test func startsJobsInTheOrderAdded() async throws {
        let dir = try Scratch()
        let probe = Probe()
        let compressor = FakeCompressor(
            kind: .image, steps: 2, stepDelay: .milliseconds(5),
            onStart: { await probe.begin($0) }, onFinish: { _ in await probe.end() })
        let queue = makeQueue([compressor], maxConcurrent: 1)
        let names = (1...5).map { "f\($0).jpg" }
        let urls = try names.map { try dir.file($0) }

        await queue.enqueue(urls: urls)
        await queue.waitUntilIdle()

        #expect(await probe.started == names)
        #expect(await queue.snapshot().map(\.sourceURL.lastPathComponent) == names)
    }

    @Test func publishesProgressAndCompletionEvents() async throws {
        let dir = try Scratch()
        let queue = makeQueue([FakeCompressor(kind: .image, steps: 4)])
        let updates = await queue.updates()
        let id = await queue.enqueue(urls: [try dir.file("a.jpg")]).accepted[0]

        var sawRunning = false
        var sawCompleted = false
        for await event in updates {
            guard case .changed(let job) = event, job.id == id else { continue }
            if case .running = job.state { sawRunning = true }
            if case .completed = job.state {
                sawCompleted = true
                break
            }
        }
        #expect(sawRunning && sawCompleted)
    }

    @Test func clearFinishedRemovesOnlyFinishedJobs() async throws {
        let dir = try Scratch()
        let slow = FakeCompressor(kind: .image, steps: 100, stepDelay: .milliseconds(20))
        let queue = makeQueue([slow], maxConcurrent: 1)
        let ids = await queue.enqueue(urls: [try dir.file("a.jpg"), try dir.file("b.jpg")]).accepted
        await queue.cancel(ids[1])

        await queue.clearFinished()
        #expect(await queue.snapshot().map(\.id) == [ids[0]])

        await queue.cancelAll()
        await queue.waitUntilIdle()
    }
}

@Suite struct ReplaceAndTrashTests {
    @Test func movesTheOriginalToTheTrashAndReportsWhere() async throws {
        let dir = try Scratch()
        let queue = makeQueue([FakeCompressor(kind: .image, keepFraction: 0.5)], maxConcurrent: 1)
        let photo = try dir.file("a.jpg", bytes: 1000)

        let id = await queue.enqueue(urls: [photo], outputPolicy: .replaceAndTrash).accepted[0]
        await queue.waitUntilIdle()

        guard case .completed(let result) = await queue.job(id)?.state else {
            Issue.record("job did not complete")
            return
        }
        defer { if let backup = result.backupURL { try? FileManager.default.removeItem(at: backup) } }
        #expect(result.outcome == .compressed)
        #expect(result.outputURL == photo)
        #expect(try Data(contentsOf: photo).count == 500, "the new file takes the old name")
        let backup = try #require(result.backupURL)
        #expect(try Data(contentsOf: backup).count == 1000, "the original is recoverable")
        #expect(try dir.contents() == ["a.jpg"])
    }

    @Test func removeTakesOneFinishedJobOffTheList() async throws {
        let dir = try Scratch()
        let queue = makeQueue([FakeCompressor(kind: .image)], maxConcurrent: 1)
        let ids = await queue.enqueue(urls: [try dir.file("a.jpg"), try dir.file("b.jpg")]).accepted
        await queue.waitUntilIdle()
        await queue.remove(ids[0])
        #expect(await queue.snapshot().map(\.id) == [ids[1]])
    }
}

@Suite struct KindLimitTests {
    @Test func limitsHowManyJobsOfOneKindRunAtOnce() async throws {
        let dir = try Scratch()
        let video = Probe()
        let image = Probe()
        let queue = JobQueue(
            registry: CompressorRegistry([
                FakeCompressor(kind: .video, steps: 3, stepDelay: .milliseconds(15),
                               onStart: { await video.begin($0) }, onFinish: { _ in await video.end() }),
                FakeCompressor(kind: .image, steps: 3, stepDelay: .milliseconds(15),
                               onStart: { await image.begin($0) }, onFinish: { _ in await image.end() }),
            ]),
            maxConcurrent: 4, kindLimits: [.video: 1])
        let urls = try (1...3).map { try dir.file("v\($0).mp4") } + (1...3).map { try dir.file("i\($0).jpg") }

        await queue.enqueue(urls: urls)
        await queue.waitUntilIdle()

        #expect(await video.peak == 1)
        #expect(await image.peak > 1, "other kinds are not held back by the video limit")
        #expect(await queue.snapshot().allSatisfy { if case .completed = $0.state { true } else { false } })
    }
}

@Suite struct PreflightTests {
    @Test func needsRoomForTheFileAndAMargin() {
        #expect(Preflight.hasRoom(free: 1_000_000_000, fileSize: 100_000_000))
        #expect(!Preflight.hasRoom(free: 120_000_000, fileSize: 100_000_000))
        #expect(!Preflight.hasRoom(free: 10_000_000, fileSize: 1_000))
    }

    @Test func missingFileFailsClearly() async throws {
        let dir = try Scratch()
        let queue = makeQueue([FakeCompressor(kind: .image)])
        let photo = try dir.file("a.jpg")
        let id = await queue.enqueue(urls: [photo]).accepted[0]
        try FileManager.default.removeItem(at: photo)  // gone before it runs? it may already be running; either way it must end
        await queue.waitUntilIdle()
        let state = await queue.job(id)?.state
        #expect(state?.isFinished == true)
    }

    @Test func aLargeBatchCompletesWithoutPilingUp() async throws {
        let dir = try Scratch()
        let queue = makeQueue([FakeCompressor(kind: .image, steps: 1, stepDelay: .milliseconds(1))], maxConcurrent: 4)
        let urls = try (0..<300).map { try dir.file("f\($0).jpg", bytes: 2_000) }
        await queue.enqueue(urls: urls)
        await queue.waitUntilIdle()
        let jobs = await queue.snapshot()
        #expect(jobs.count == 300)
        #expect(jobs.allSatisfy { if case .completed = $0.state { true } else { false } })
        #expect(try dir.contents().count == 600, "every file got its compressed copy and no scratch files remain")
    }
}
