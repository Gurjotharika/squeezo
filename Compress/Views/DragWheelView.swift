import SwiftUI
import UniformTypeIdentifiers

/// A ring segment between two radii, from `start` to `end` degrees clockwise from the top.
private struct RingSegment: Shape {
    var inner: CGFloat
    var outer: CGFloat
    var start: Double
    var end: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // Shape angles run clockwise from 3 o'clock in a flipped space; shift to start at the top.
        let a = Angle.degrees(start - 90), b = Angle.degrees(end - 90)
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: a, endAngle: b, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: b, endAngle: a, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// The radial menu: tools in a ring, and a second ring of choices for the one under the pointer.
struct DragWheelView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let state: DragWheelState
    let drop: (WheelCommand?, [NSItemProvider]) -> Void

    private let center = CGPoint(x: WheelGeometry.size / 2, y: WheelGeometry.size / 2)
    /// Visible gap between segments, in degrees at the middle of the ring.
    private let seam = 2.5

    var body: some View {
        ZStack {
            ForEach(Array(state.slices.enumerated()), id: \.element.id) { index, slice in
                let span = WheelGeometry.sliceSpan(count: state.slices.count)
                let mid = WheelGeometry.center(of: index, count: state.slices.count)
                segment(inner: WheelGeometry.hole + 6, outer: WheelGeometry.innerRing, start: mid - span / 2 + seam, end: mid + span / 2 - seam,
                        title: slice.title, symbol: slice.symbol, mid: mid, radius: (WheelGeometry.hole + WheelGeometry.innerRing) / 2 + 4,
                        active: state.hit == .slice(index) || (state.expanded == index && isChild(of: index)), compact: false)
            }
            if let parent = state.expanded, state.slices.indices.contains(parent) {
                let children = state.slices[parent].children
                let start = WheelGeometry.childStart(parent: parent, parentCount: state.slices.count, childCount: children.count)
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    let from = start + Double(index) * WheelGeometry.childSpan
                    let mid = from + WheelGeometry.childSpan / 2
                    segment(inner: WheelGeometry.innerRing + WheelGeometry.gap, outer: WheelGeometry.outerRing,
                            start: from + 1.2, end: from + WheelGeometry.childSpan - 1.2,
                            title: child.title, symbol: child.symbol, mid: mid,
                            radius: (WheelGeometry.innerRing + WheelGeometry.outerRing) / 2 + 3,
                            active: state.hit == .child(parent: parent, index: index), compact: true)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            hub
        }
        .frame(width: WheelGeometry.size, height: WheelGeometry.size)
        .animation(.flick, value: state.expanded)
        .animation(.press, value: state.hit)
        .onDrop(of: [.fileURL], delegate: WheelDropDelegate(state: state, center: center, drop: drop))
    }

    private func isChild(of parent: Int) -> Bool {
        if case .child(let p, _) = state.hit { p == parent } else { false }
    }

    private func segment(inner: CGFloat, outer: CGFloat, start: Double, end: Double, title: String, symbol: String,
                         mid: Double, radius: CGFloat, active: Bool, compact: Bool) -> some View {
        let shape = RingSegment(inner: inner, outer: outer, start: start, end: end)
        let radians = (mid - 90) * .pi / 180
        return ZStack {
            shape.fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.ultraThickMaterial))
            shape.fill(Color.accentColor.opacity(active ? 0.85 : 0))
            shape.stroke(.primary.opacity(0.10), lineWidth: 1)
            VStack(spacing: 4) {
                if !symbol.isEmpty { Image(systemName: symbol).font(.system(size: 20, weight: .medium)) }
                Text(title)
                    .font(.system(size: compact ? 11 : 10.5, weight: .semibold))
                    .textCase(compact ? nil : .uppercase)
                    .tracking(compact ? 0 : 0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: compact ? 74 : 84)
            .position(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .scaleEffect(active ? 1.03 : 1, anchor: UnitPoint(x: 0.5, y: 0.5))
        .accessibilityElement()
        .accessibilityLabel(title)
    }

    private var hub: some View {
        VStack(spacing: 3) {
            if let message = state.message {
                Text(message).font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center)
            } else if let title = state.hoveredTitle {
                Text(title).font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center)
            } else {
                Image(systemName: "hand.point.down").font(.system(size: 20, weight: .medium))
                Text(state.fileCount == 1 ? "1 file" : "\(state.fileCount) files").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .frame(width: (WheelGeometry.hole - 8) * 2)
        .frame(width: WheelGeometry.hole * 2, height: WheelGeometry.hole * 2)
        .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.thickMaterial), in: Circle())
        .overlay(Circle().strokeBorder(.primary.opacity(0.10)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .contentTransition(.interpolate)
    }
}

/// Tracks the pointer through the drag, which hover modifiers don't see, and hands the drop to the controller.
@MainActor
private struct WheelDropDelegate: DropDelegate {
    let state: DragWheelState
    let center: CGPoint
    let drop: (WheelCommand?, [NSItemProvider]) -> Void

    private func track(_ location: CGPoint) {
        state.update(dx: location.x - center.x, dy: location.y - center.y)
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { track(info.location) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        track(info.location)
        return DropProposal(operation: state.command == nil ? .forbidden : .copy)
    }
    func dropExited(info: DropInfo) { state.hit = .none }

    func performDrop(info: DropInfo) -> Bool {
        track(info.location)
        guard let command = state.command else {
            drop(nil, [])
            return false
        }
        drop(command, info.itemProviders(for: [.fileURL]))
        return true
    }
}
