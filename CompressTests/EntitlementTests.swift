import CompressCore
import Foundation
import Testing
@testable import Compress

@MainActor
@Suite struct EntitlementTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "EntitlementTests-\(UUID().uuidString)")! }

    @Test func freeAllowanceIsSpentAndRefunded() {
        let e = Entitlements(defaults: defaults(), dailyLimit: 5)
        #expect(e.remainingToday == 5)
        #expect(e.reserve(3) == 3)
        #expect(e.reserve(4) == 2, "only what is left")
        #expect(e.remainingToday == 0)
        #expect(e.reserve(1) == 0)
        e.refund(2)
        #expect(e.remainingToday == 2)
    }

    @Test func allowanceResetsOnANewDay() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let e = Entitlements(defaults: defaults(), dailyLimit: 3, now: { clock })
        #expect(e.reserve(3) == 3)
        #expect(e.remainingToday == 0)
        clock += 60 * 60  // an hour later, same day (unless the test runs at midnight)
        let sameDay = Calendar.current.isDate(clock, inSameDayAs: Date(timeIntervalSince1970: 1_800_000_000))
        if sameDay { #expect(e.remainingToday == 0) }
        clock += 60 * 60 * 24
        #expect(e.remainingToday == 3)
    }

    @Test func allowanceSurvivesRelaunch() {
        let store = defaults()
        let first = Entitlements(defaults: store, dailyLimit: 5)
        _ = first.reserve(4)
        let second = Entitlements(defaults: store, dailyLimit: 5)
        #expect(second.remainingToday == 1)
    }

    @Test func unlockedMeansUnlimited() {
        let e = Entitlements(defaults: defaults(), dailyLimit: 2)
        e.isUnlocked = true
        #expect(e.reserve(1000) == 1000)
        #expect(e.remainingToday == Int.max)
    }

    @Test func unlockedStateIsRememberedForNextLaunch() {
        let store = defaults()
        Entitlements(defaults: store).isUnlocked = true
        #expect(Entitlements(defaults: store).isUnlocked)
    }

    // MARK: Gating in the model

    private func makeModel(limit: Int, failing: Set<String> = []) -> AppModel {
        let store = defaults()
        let registry = CompressorRegistry(MediaKind.allCases.map {
            FakeCompressor(kind: $0, steps: 2, stepDelay: .milliseconds(1), failingFileNames: failing)
        })
        return AppModel(defaults: store, registry: registry, entitlements: Entitlements(defaults: store, dailyLimit: limit))
    }

    private func files(_ names: [String]) throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try names.map { name in
            let url = dir.appendingPathComponent(name)
            try Data(repeating: 1, count: 1000).write(to: url)
            return url
        }
    }

    private func waitForIdle(_ model: AppModel) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.hasActive || model.jobs.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func stopsAtTheDailyLimitAndOffersTheUnlock() async throws {
        let model = makeModel(limit: 2)
        let observer = Task { await model.run() }
        defer { observer.cancel() }

        await model.add(urls: try files(["a.jpg", "b.jpg", "c.jpg"]))
        await waitForIdle(model)

        #expect(model.jobs.count == 2)
        #expect(model.showPaywall)
        #expect(model.notice?.contains("Daily limit reached: 1 file not compressed") == true)
        #expect(model.entitlements.remainingToday == 0)

        model.showPaywall = false
        await model.add(urls: try files(["d.jpg"]))
        #expect(model.jobs.count == 2, "nothing more runs today")
        #expect(model.showPaywall)
    }

    @Test func failedFilesDoNotUseTheAllowance() async throws {
        let model = makeModel(limit: 3, failing: ["bad.jpg"])
        let observer = Task { await model.run() }
        defer { observer.cancel() }

        await model.add(urls: try files(["bad.jpg", "good.jpg"]))
        await waitForIdle(model)
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.entitlements.remainingToday == 2, "only the file that worked counts")
    }

    @Test func unlockedUsersAreNeverLimited() async throws {
        let model = makeModel(limit: 1)
        model.entitlements.isUnlocked = true
        let observer = Task { await model.run() }
        defer { observer.cancel() }

        await model.add(urls: try files(["a.jpg", "b.jpg", "c.jpg"]))
        await waitForIdle(model)

        #expect(model.jobs.count == 3)
        #expect(!model.showPaywall)
    }
}
