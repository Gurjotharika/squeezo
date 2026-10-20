import StoreKit
import SwiftUI

struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = Store.lifetimeID

    var body: some View {
        #if DIRECT
        LicenseView()
        #else
        storeBody
        #endif
    }

    @ViewBuilder
    private var storeBody: some View {
        let store = model.store
        ZStack {
            if let celebration = store.celebration {
                CelebrationView(kind: celebration) { dismiss() }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                ScrollView {
                    offer(store)
                }
                .scrollIndicators(.hidden)
                .transition(.opacity)
            }
        }
        .frame(width: 420)
        .frame(minHeight: 440, idealHeight: 660, maxHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topTrailing) {
            if store.celebration == nil {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
                    .padding(14)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
            }
        }
        .motion(value: store.celebration == nil)
        .disabled(store.isPurchasing)
        .overlay { if store.isPurchasing { ProgressView().controlSize(.large) } }
        .onDisappear { store.celebration = nil }
    }

    // MARK: The offer

    @ViewBuilder
    private func offer(_ store: Store) -> some View {
        VStack(spacing: 26) {
            VStack(spacing: 12) {
                AppMark(size: 72)
                VStack(spacing: 4) {
                    Text("\(AppInfo.name) Pro").display(30)
                    Text("No limits. Everything on your Mac.").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                Feature(icon: "infinity", title: "Unlimited files", detail: "No daily limit.")
                Feature(icon: "folder.badge.gearshape", title: "Watched folders", detail: "New screenshots and downloads shrink by themselves.")
                Feature(icon: "bolt", title: "Shortcuts and automation", detail: "Use \(AppInfo.name) from Shortcuts, Spotlight and scripts.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.entitlements.isUnlocked {
                Label("Everything is unlocked. Thank you.", systemImage: "checkmark.circle").font(.headline)
            } else {
                VStack(spacing: 10) {
                    if let lifetime = store.lifetime {
                        PlanRow(product: lifetime, title: "Lifetime", detail: "Pay once, keep it forever.",
                                isSelected: selectedID == lifetime.id) { selectedID = lifetime.id }
                    }
                    if let yearly = store.yearly {
                        PlanRow(product: yearly, title: "Yearly", detail: "Renews every year. Cancel anytime.",
                                isSelected: selectedID == yearly.id) { selectedID = yearly.id }
                    }
                    if store.products.isEmpty {
                        if store.isLoading { ProgressView().controlSize(.small).padding() } else {
                            Button("Load prices") { Task { await store.loadProducts() } }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
                Button {
                    if let product = store.products.first(where: { $0.id == selectedID }) { Task { await store.purchase(product) } }
                } label: {
                    Text(callToAction(store)).frame(maxWidth: .infinity).contentTransition(.interpolate)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(store.products.isEmpty)

                if selectedID == Store.yearlyID, let yearly = store.yearly {
                    Text("\(yearly.displayPrice) per year. The subscription renews automatically each year unless it is cancelled in your Apple Account settings at least 24 hours before the period ends. Payment is charged to your Apple Account at confirmation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
            }

            if let message = store.message {
                Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            HStack(spacing: 14) {
                Button("Restore Purchases") { Task { await store.restore() } }
                Link("Terms of Use", destination: AppInfo.termsOfUse)
                Link("Privacy Policy", destination: AppInfo.privacyPolicy)
            }
            .buttonStyle(.link)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .padding(.top, 40)
        .padding(.bottom, 26)
        .motion(value: selectedID)
    }

    private func callToAction(_ store: Store) -> String {
        guard let product = store.products.first(where: { $0.id == selectedID }) else { return "Unlock \(AppInfo.name) Pro" }
        return product.id == Store.lifetimeID ? "Unlock for \(product.displayPrice)" : "Subscribe for \(product.displayPrice) a year"
    }
}

/// The app's mark, drawn in code so it never depends on the icon cache.
struct AppMark: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
            .font(.system(size: size * 0.39, weight: .semibold))
            .rotationEffect(.degrees(45))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }
}

// MARK: - Thank you

/// Shown right after a purchase or a restore, so the sheet ends on something positive instead of staying on the offer.
private struct CelebrationView: View {
    let kind: Store.Celebration
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var burst = false

    private let unlocked: [(icon: String, text: String)] = [
        ("infinity", "Unlimited files, every day"),
        ("folder.badge.gearshape", "Watched folders"),
        ("bolt", "Shortcuts and automation"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 30)

            ZStack {
                if !reduceMotion { ConfettiBurst(go: burst) }
                Image(systemName: "checkmark")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(Theme.paper)
                    .frame(width: 96, height: 96)
                    .background(Theme.ink, in: Circle())
                    .scaleEffect(shown ? 1 : 0.4)
                    .symbolEffect(.bounce, value: shown)
            }
            .frame(height: 150)

            VStack(spacing: 8) {
                Text(kind == .purchased ? "You're all set" : "Welcome back")
                    .display(32)
                Text(kind == .purchased ? "Thank you for supporting \(AppInfo.name). Everything is unlocked."
                                        : "Your purchase has been restored. Everything is unlocked.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 36)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(unlocked.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ink)
                        Text(item.text).font(.system(.body, weight: .medium))
                    }
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 8)
                    .animation(.fluid.delay(0.25 + Double(index) * 0.1), value: shown)
                }
            }
            .padding(.top, 28)

            Spacer(minLength: 24)

            Button("Start Using \(AppInfo.name)") { done() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 34)
                .opacity(shown ? 1 : 0)
                .animation(.fluid.delay(0.55), value: shown)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.65)) { shown = true }
            burst = true
            // A soft tap on trackpads, to match the moment.
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A short burst of small shapes from the centre. They are all in the one ink colour, in different sizes.
private struct ConfettiBurst: View {
    let go: Bool

    private struct Piece: Identifiable {
        let id: Int
        let angle: Double
        let distance: Double
        let width: Double
        let height: Double
        let spin: Double
        let opacity: Double
    }

    private let pieces: [Piece] = (0..<30).map { i in
        var generator = SeededGenerator(seed: UInt64(i) &* 2654435761 &+ 7)
        return Piece(
            id: i, angle: Double(i) / 30 * 2 * .pi + Double.random(in: -0.2...0.2, using: &generator),
            distance: Double.random(in: 90...165, using: &generator), width: Double.random(in: 4...8, using: &generator),
            height: Double.random(in: 8...16, using: &generator), spin: Double.random(in: -300...300, using: &generator),
            opacity: Double.random(in: 0.35...0.9, using: &generator))
    }

    @State private var progress = 0.0

    var body: some View {
        ZStack {
            ForEach(pieces) { piece in
                Capsule()
                    .fill(Theme.ink.opacity(piece.opacity))
                    .frame(width: piece.width, height: piece.height)
                    .rotationEffect(.degrees(piece.spin * progress))
                    .offset(x: cos(piece.angle) * piece.distance * progress, y: sin(piece.angle) * piece.distance * progress + 28 * progress * progress)
                    .opacity(1 - progress)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: go) { _, now in
            guard now else { return }
            withAnimation(.easeOut(duration: 1.3)) { progress = 1 }
        }
        .onAppear { if go { withAnimation(.easeOut(duration: 1.3)) { progress = 1 } } }
        .accessibilityHidden(true)
    }
}

/// A repeatable random source, so the burst looks the same each time.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Pieces

struct Feature: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 24)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(.body, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PlanRow: View {
    let product: Product
    let title: String
    let detail: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Theme.ink : Color.secondary.opacity(0.6))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(.body, weight: .semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(product.displayPrice).font(.system(.body, weight: .semibold)).monospacedDigit()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? Theme.ink : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
