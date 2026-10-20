import CompressCore
import SwiftUI

/// The whole visual system: neutral surfaces, system type, one accent (the user's own), and springs.
/// There are no custom colours or gradients. Hierarchy comes from weight, size, space and material.
enum Theme {
    static let radius: CGFloat = 14
    /// Solid "ink" and "paper": the text colour and the window colour. Used for the strong, filled controls so they
    /// stay crisp inside translucent panels, where `Color.primary` can look washed out.
    static let ink = Color(nsColor: .labelColor)
    static let paper = Color(nsColor: .windowBackgroundColor)
}

// MARK: - Motion

extension Animation {
    /// Critically damped: settles without overshoot. The default for anything the user can touch.
    static let fluid = Animation.spring(response: 0.4, dampingFraction: 1)
    /// A little overshoot, for things that carry momentum (a selection thumb sliding to a new place).
    static let flick = Animation.spring(response: 0.4, dampingFraction: 0.8)
    /// Press feedback: quick and never bouncy.
    static let press = Animation.spring(response: 0.22, dampingFraction: 1)
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        // Reduced motion keeps the feedback but swaps travel for a short cross-fade.
        content.animation(reduceMotion ? .easeOut(duration: 0.15) : animation, value: value)
    }
}

extension View {
    func motion<Value: Equatable>(_ animation: Animation = .fluid, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

// MARK: - Surfaces

private struct SurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let radius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(Color(nsColor: .controlBackgroundColor))
                } else {
                    shape.fill(.regularMaterial)
                }
            }
            // A hairline catches the light along the edge, the way glass does.
            .overlay(shape.strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(elevated ? 0.14 : 0), radius: elevated ? 18 : 0, y: elevated ? 6 : 0)
    }
}

extension View {
    /// A translucent layer for chrome that floats above content.
    func surface(radius: CGFloat = Theme.radius, elevated: Bool = false) -> some View {
        modifier(SurfaceModifier(radius: radius, elevated: elevated))
    }
}

// MARK: - Buttons

/// Responds on press, not on release.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.press, value: configuration.isPressed)
    }
}

/// The one strong action on a screen: solid, high contrast, no colour.
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(compact ? .callout : .body, weight: .semibold))
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, compact ? 14 : 22)
            .padding(.vertical, compact ? 7 : 11)
            .background(Theme.ink, in: Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.press, value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, weight: .medium))
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: Capsule())
            .animation(.press, value: configuration.isPressed)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: Circle())
            .contentShape(Circle())
            .animation(.press, value: configuration.isPressed)
    }
}

// MARK: - Type

extension View {
    /// Large text gets tighter letter-spacing; small text keeps its default.
    func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        font(.system(size: size, weight: weight)).tracking(-size * 0.022)
    }
}

// MARK: - Content kinds

extension QualityLevel {
    var summary: String {
        switch self {
        case .highest: "Looks identical. Smallest savings."
        case .high: "Looks the same to the eye. Big savings."
        case .medium: "A little softer. Much smaller files."
        case .low: "Visibly reduced. The smallest files."
        }
    }
}

extension MediaKind {
    var label: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .gif: "GIF"
        case .pdf: "PDF"
        case .document: "Document"
        case .audio: "Audio"
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .gif: "livephoto"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .audio: "waveform"
        }
    }
}

func formatBytes(_ value: Int64) -> String { value.formatted(.byteCount(style: .file)) }


// MARK: - Segmented control

/// A segmented control whose thumb is one solid shape that slides, rather than buttons that swap.
struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(.callout, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(selection == option.value ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .secondaryLabelColor))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if selection == option.value {
                                Capsule().fill(Color(nsColor: .labelColor)).matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .accessibilityAddTraits(selection == option.value ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .motion(.flick, value: selection)
    }
}
