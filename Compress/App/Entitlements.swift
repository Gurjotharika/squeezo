import Foundation
import Observation

/// What the user may do for free, and whether they have unlocked everything.
@MainActor
@Observable
final class Entitlements {
    static let freeFilesPerDay = 5

    private let defaults: UserDefaults
    private let now: () -> Date
    let dailyLimit: Int

    /// Set by the store once it has checked the user's purchases.
    var isUnlocked: Bool {
        didSet { defaults.set(isUnlocked, forKey: "unlockedCache") }
    }

    private var day: String
    private var used: Int

    init(defaults: UserDefaults = .standard, dailyLimit: Int = Entitlements.freeFilesPerDay, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.dailyLimit = dailyLimit
        self.now = now
        // The last known state, so the app doesn't flash a paywall while the store is checked.
        #if DIRECT
        self.isUnlocked = false // set from the keychain by the license manager
        #else
        self.isUnlocked = defaults.bool(forKey: "unlockedCache")
        #endif
        self.day = defaults.string(forKey: "quotaDay") ?? ""
        self.used = defaults.integer(forKey: "quotaUsed")
    }

    private var today: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: now())
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    private func rollOverIfNeeded() {
        if day != today {
            day = today
            used = 0
            persist()
        }
    }

    private func persist() {
        defaults.set(day, forKey: "quotaDay")
        defaults.set(used, forKey: "quotaUsed")
    }

    /// Files that can still be compressed today for free.
    var remainingToday: Int {
        rollOverIfNeeded()
        return isUnlocked ? Int.max : max(0, dailyLimit - used)
    }

    /// Takes up to `requested` files from today's allowance and returns how many were granted.
    func reserve(_ requested: Int) -> Int {
        guard !isUnlocked else { return requested }
        rollOverIfNeeded()
        let granted = min(requested, max(0, dailyLimit - used))
        used += granted
        persist()
        return granted
    }

    /// Gives back files that were reserved but never compressed (failed or cancelled).
    func refund(_ count: Int) {
        guard !isUnlocked else { return }
        rollOverIfNeeded()
        used = max(0, used - count)
        persist()
    }
}
