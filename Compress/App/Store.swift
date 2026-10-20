import Foundation
import Observation
import StoreKit

/// Purchases through StoreKit 2: a one-time unlock, or a yearly subscription.
@MainActor
@Observable
final class Store {
    static let lifetimeID = "com.squeezo.lifetime"
    static let yearlyID = "com.squeezo.yearly"
    private static let productIDs = [lifetimeID, yearlyID]

    let entitlements: Entitlements
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    var message: String?

    enum Celebration { case purchased, restored }
    /// Set when the user has just unlocked everything, so the paywall can say thank you instead of staying on the offer.
    var celebration: Celebration?

    @ObservationIgnored private var updates: Task<Void, Never>?

    init(entitlements: Entitlements) {
        self.entitlements = entitlements
    }

    var lifetime: Product? { products.first { $0.id == Self.lifetimeID } }
    var yearly: Product? { products.first { $0.id == Self.yearlyID } }

    /// Loads products, checks what the user owns, and keeps listening for changes (renewals, refunds, family sharing).
    func start() async {
        if updates == nil {
            updates = Task { [weak self] in
                for await result in Transaction.updates {
                    await self?.handle(result)
                }
            }
        }
        await loadProducts()
        await refreshEntitlements()
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: Self.productIDs).sorted { $0.price > $1.price }
        } catch {
            message = "The store couldn't be reached. Check your connection and try again."
        }
    }

    func refreshEntitlements() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, Self.grantsAccess(transaction) { unlocked = true }
        }
        entitlements.isUnlocked = unlocked
    }

    func purchase(_ product: Product) async {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                await handle(result)
                if entitlements.isUnlocked { celebration = .purchased }
            case .pending:
                message = "The purchase is waiting for approval."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = "The purchase didn't go through: \(error.localizedDescription)"
        }
    }

    /// Asks the App Store to re-send the user's purchases, e.g. after reinstalling or on a new Mac.
    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if entitlements.isUnlocked {
                celebration = .restored
                message = nil
            } else {
                message = "No earlier purchase was found for this Apple ID."
            }
        } catch {
            message = "Purchases couldn't be restored: \(error.localizedDescription)"
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            message = "The purchase couldn't be verified."
            return
        }
        await transaction.finish()
        await refreshEntitlements()
    }

    private static func grantsAccess(_ transaction: Transaction) -> Bool {
        guard productIDs.contains(transaction.productID), transaction.revocationDate == nil else { return false }
        if let expiry = transaction.expirationDate { return expiry > Date() }
        return true
    }
}
