#if DIRECT
import CompressCore
import Foundation
import Observation
import Security

/// Unlocks the app with a Dodo Payments license key. The key is checked once when it is entered and again
/// in the background every day; a Mac that stays offline keeps working for a grace period.
@MainActor
@Observable
final class LicenseManager {
    /// Where customers buy a key.
    static let checkoutURL = URL(string: "https://checkout.dodopayments.com/buy/pdt_0Nq7iqf57XHZr2iLWV9JP?quantity=1")!
    static let recheckInterval: TimeInterval = 24 * 3600
    static let offlineGrace: TimeInterval = 14 * 24 * 3600

    struct Stored: Codable, Equatable {
        var key: String
        var instanceID: String
        var lastValidated: Date
    }

    private let entitlements: Entitlements
    private let client: LicenseClient
    private let keychain: LicenseKeychain
    private let now: () -> Date

    private(set) var stored: Stored?
    private(set) var isWorking = false
    var message: String?
    var celebration: Store.Celebration?

    init(entitlements: Entitlements, client: LicenseClient? = nil, keychain: LicenseKeychain = LicenseKeychain(), now: @escaping () -> Date = Date.init) {
        self.entitlements = entitlements
        self.keychain = keychain
        self.now = now
        let environment = (Bundle.main.object(forInfoDictionaryKey: "DodoEnvironment") as? String).flatMap(LicenseClient.Environment.init) ?? .live
        self.client = client ?? LicenseClient(environment: environment)
        self.stored = keychain.load()
        entitlements.isUnlocked = isCovered
    }

    /// The key as shown in Settings, with the middle hidden.
    var maskedKey: String? {
        guard let key = stored?.key else { return nil }
        return key.count > 8 ? "\(key.prefix(4))••••\(key.suffix(4))" : "••••"
    }

    private var isCovered: Bool {
        guard let stored else { return false }
        return now().timeIntervalSince(stored.lastValidated) < Self.offlineGrace
    }

    /// Re-checks the stored key if it hasn't been checked lately. Call at launch.
    func start() async {
        guard var current = stored else { return }
        entitlements.isUnlocked = isCovered
        guard now().timeIntervalSince(current.lastValidated) >= Self.recheckInterval else { return }
        do {
            if try await client.validate(key: current.key, instanceID: current.instanceID) {
                current.lastValidated = now()
                save(current)
            } else {
                clear()
                message = "Your license is no longer active."
            }
        } catch {
            // Offline or a server hiccup: keep working until the grace period runs out.
        }
    }

    func activate(key rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { message = "Paste your license key first."; return }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            let instance = try await client.activate(key: key, deviceName: Host.current().localizedName ?? "Mac")
            save(Stored(key: key, instanceID: instance, lastValidated: now()))
            celebration = .purchased
        } catch {
            message = error.localizedDescription
        }
    }

    /// Frees this Mac's activation so the key can go on another Mac.
    func deactivate() async {
        guard let current = stored else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.deactivate(key: current.key, instanceID: current.instanceID)
            clear()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func save(_ value: Stored) {
        stored = value
        keychain.save(value)
        entitlements.isUnlocked = true
    }

    private func clear() {
        stored = nil
        keychain.delete()
        entitlements.isUnlocked = false
    }
}

/// Keeps the license in the user's keychain, so it survives reinstalls and can't be unlocked by editing a preferences file.
struct LicenseKeychain {
    var service = "license"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "app").\(service)",
         kSecAttrAccount as String: "dodo"]
    }

    func load() -> LicenseManager.Stored? {
        var request = query
        request[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(LicenseManager.Stored.self, from: data)
    }

    func save(_ value: LicenseManager.Stored) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func delete() { SecItemDelete(query as CFDictionary) }
}
#endif
