import AppKit
import SwiftUI

/// A small floating target you can drop files on from anywhere, without opening the main window.
@MainActor
final class DropZoneController {
    static let shared = DropZoneController()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(model: AppModel) {
        if isVisible { panel?.orderOut(nil) } else { show(model: model) }
    }

    func show(model: AppModel) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 168, height: 168),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: DropZoneView(close: { [weak self] in self?.panel?.orderOut(nil) }).environment(model))
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: frame.maxX - 188, y: frame.minY + 24))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }
}

private struct DropZoneView: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false
    let close: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)
        ZStack {
            shape.fill(.ultraThickMaterial)
            shape.strokeBorder(isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.14)),
                               style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [] : [6, 6]))
                .padding(8)

            VStack(spacing: 8) {
                if model.hasActive {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(.system(size: 28, weight: .medium))
                        .symbolEffect(.bounce, value: isTargeted)
                }
                Text(model.hasActive ? "Compressing" : (isTargeted ? "Release" : "Drop files"))
                    .font(.system(.callout, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle())
                .scaleEffect(0.8)
                .padding(10)
                .opacity(isTargeted ? 0 : 1)
                .accessibilityLabel("Close drop zone")
        }
        .scaleEffect(isTargeted ? 1.04 : 1)
        .motion(.flick, value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.add(urls: urls) }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
