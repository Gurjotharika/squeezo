import AppKit
import CompressCore
import Observation
import SwiftUI

// MARK: - What the wheel offers

/// A target format on the Convert slice.
enum ConvertChoice: Hashable {
    case image(ImageFormat), imageToPDF
    case mp4, mov, gif
    case m4a, wav, aiff
    case pagesPNG, pagesJPEG

    var title: String {
        switch self {
        case .image(let format): format.displayName
        case .imageToPDF: "PDF"
        case .mp4: "MP4"
        case .mov: "MOV"
        case .gif: "GIF"
        case .m4a: "M4A"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .pagesPNG: "PNG pages"
        case .pagesJPEG: "JPEG pages"
        }
    }

    /// The conversion for a file of this kind, or nil when this target makes no sense for it.
    func spec(for kind: MediaKind) -> ConvertSpec? {
        let target: ConvertTarget
        switch (self, kind) {
        case (.image(let format), .image): target = .image(format)
        case (.imageToPDF, .image): target = .imageToPDF
        case (.mp4, .video), (.mp4, .gif): target = .video(.mp4)
        case (.mov, .video), (.mov, .gif): target = .video(.mov)
        case (.gif, .video): target = .video(.gif)
        case (.m4a, .video): target = .videoToAudio(.aac)
        case (.wav, .video): target = .videoToAudio(.wav)
        case (.aiff, .video): target = .videoToAudio(.aiff)
        case (.m4a, .audio): target = .audio(.aac)
        case (.wav, .audio): target = .audio(.wav)
        case (.aiff, .audio): target = .audio(.aiff)
        case (.pagesPNG, .pdf): target = .pdfToImages(.png, dpi: 150)
        case (.pagesJPEG, .pdf): target = .pdfToImages(.jpeg, dpi: 150)
        default: return nil
        }
        return ConvertSpec(target: target)
    }

    /// Targets worth offering for files of these kinds, in a stable order.
    static func choices(for kinds: Set<MediaKind>) -> [ConvertChoice] {
        let all: [ConvertChoice] = ImageFormat.allCases.map { .image($0) } + [.imageToPDF, .mp4, .mov, .gif, .m4a, .wav, .aiff, .pagesPNG, .pagesJPEG]
        return all.filter { choice in kinds.contains { choice.spec(for: $0) != nil } }
    }
}

/// What happens when files are dropped on a slice.
enum WheelCommand: Hashable {
    case compress
    case convert(ConvertChoice)
    case resize(ResizeSpec)
    case rotate(RotateSpec)
    case upscale(Int)
    case blurFaces
    case removeBackground
    case extractText(TextFormat)
    /// Tools that need options: open the main window on this tool with the files waiting.
    case open(Tool)
}

struct WheelSlice: Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// Nil on a slice that only opens a ring of choices.
    var command: WheelCommand?
    var children: [WheelSlice] = []

    static func leaf(_ title: String, _ symbol: String, _ command: WheelCommand) -> WheelSlice {
        WheelSlice(id: title, title: title, symbol: symbol, command: command)
    }

    /// The slices that make sense for files of these kinds.
    static func slices(for kinds: Set<MediaKind>, fileCount: Int) -> [WheelSlice] {
        func group(_ tool: Tool, _ title: String, _ children: [WheelSlice]) -> WheelSlice {
            WheelSlice(id: tool.id, title: title, symbol: tool.symbol, command: nil, children: children)
        }
        var result: [WheelSlice] = []
        for tool in Tool.allCases where kinds.contains(where: { tool.accepts($0) }) {
            switch tool {
            case .compress:
                result.append(.leaf("Compress", tool.symbol, .compress))
            case .convert:
                result.append(group(tool, "Convert", ConvertChoice.choices(for: kinds).map { .leaf($0.title, "", .convert($0)) }))
            case .resize:
                result.append(group(tool, "Resize", [
                    .leaf("1920 px", "", .resize(ResizeSpec(mode: .fit(maxSide: 1920)))),
                    .leaf("1280 px", "", .resize(ResizeSpec(mode: .fit(maxSide: 1280)))),
                    .leaf("50%", "", .resize(ResizeSpec(mode: .percent(50)))),
                    .leaf("Custom…", "", .open(.resize)),
                ]))
            case .rotate:
                result.append(group(tool, "Rotate", [
                    .leaf("Right", "", .rotate(RotateSpec(quarterTurns: 1))),
                    .leaf("Left", "", .rotate(RotateSpec(quarterTurns: 3))),
                    .leaf("Flip ↔", "", .rotate(RotateSpec(quarterTurns: 0, flipHorizontal: true))),
                    .leaf("Flip ↕", "", .rotate(RotateSpec(quarterTurns: 0, flipVertical: true))),
                ]))
            case .upscale:
                result.append(group(tool, "Enlarge", [2, 3, 4].map { .leaf("\($0)×", "", .upscale($0)) }))
            case .blurFaces:
                result.append(.leaf("Faces", tool.symbol, .blurFaces))
            case .removeBackground:
                result.append(.leaf("No BG", tool.symbol, .removeBackground))
            case .extractText:
                result.append(group(tool, "Text", [.leaf("Markdown", "", .extractText(.markdown)), .leaf("Plain", "", .extractText(.plain))]))
            case .mergePDF:
                if fileCount > 1 { result.append(.leaf("Merge", tool.symbol, .open(tool))) }
            case .splitPDF:
                if fileCount == 1 { result.append(.leaf("Split", tool.symbol, .open(tool))) }
            case .crop:
                result.append(.leaf("Crop", tool.symbol, .open(tool)))
            case .watermark:
                result.append(.leaf("Mark", tool.symbol, .open(tool)))
            }
        }
        return result
    }
}

// MARK: - Geometry

enum WheelHit: Equatable {
    case none
    case center
    case slice(Int)
    case child(parent: Int, index: Int)
}

/// Where the rings are, and which part of them a point falls on. Angles run clockwise from the top.
enum WheelGeometry {
    static let hole: CGFloat = 64
    static let innerRing: CGFloat = 172
    static let gap: CGFloat = 6
    static let outerRing: CGFloat = 252
    static let size = outerRing * 2 + 16
    static let childSpan = 26.0

    static func sliceSpan(count: Int) -> Double { 360 / Double(max(count, 1)) }

    /// Clockwise angle in degrees from the top, 0..<360, of a point relative to the wheel's center (y grows downward).
    static func angle(dx: CGFloat, dy: CGFloat) -> Double {
        let degrees = atan2(Double(dx), Double(-dy)) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// The angle at the middle of slice `index`. Slice 0 sits at the top.
    static func center(of index: Int, count: Int) -> Double { Double(index) * sliceSpan(count: count) }

    /// Start angle of the first of `childCount` children, centered on their parent.
    static func childStart(parent: Int, parentCount: Int, childCount: Int) -> Double {
        center(of: parent, count: parentCount) - Double(childCount) * childSpan / 2
    }

    static func hit(dx: CGFloat, dy: CGFloat, slices: [WheelSlice], expanded: Int?) -> WheelHit {
        let radius = hypot(dx, dy)
        if radius < hole { return .center }
        let theta = angle(dx: dx, dy: dy)

        if radius <= innerRing, !slices.isEmpty {
            let span = sliceSpan(count: slices.count)
            let shifted = (theta + span / 2).truncatingRemainder(dividingBy: 360)
            return .slice(min(Int(shifted / span), slices.count - 1))
        }

        if radius >= innerRing + gap, radius <= outerRing, let parent = expanded, slices.indices.contains(parent) {
            let count = slices[parent].children.count
            let start = childStart(parent: parent, parentCount: slices.count, childCount: count)
            var offset = (theta - start).truncatingRemainder(dividingBy: 360)
            if offset < 0 { offset += 360 }
            let index = Int(offset / childSpan)
            if index < count { return .child(parent: parent, index: index) }
        }
        return .none
    }
}

// MARK: - State

@MainActor
@Observable
final class DragWheelState {
    var slices: [WheelSlice] = []
    var fileCount = 0
    var hit: WheelHit = .none
    /// The slice whose choices are showing. Stays put while the pointer crosses the gaps.
    var expanded: Int?
    /// Shown in the middle after a drop, just before the wheel goes away.
    var message: String?

    func reset(slices: [WheelSlice], fileCount: Int) {
        self.slices = slices
        self.fileCount = fileCount
        hit = .none
        expanded = nil
        message = nil
    }

    func update(dx: CGFloat, dy: CGFloat) {
        let next = WheelGeometry.hit(dx: dx, dy: dy, slices: slices, expanded: expanded)
        if case .slice(let index) = next {
            expanded = slices[index].children.isEmpty ? nil : index
        }
        if next != hit { hit = next }
    }

    /// What dropping right now would do, if anything.
    var command: WheelCommand? {
        switch hit {
        case .slice(let index): slices[index].command
        case .child(let parent, let index): slices[parent].children[index].command
        default: nil
        }
    }

    var hoveredTitle: String? {
        switch hit {
        case .slice(let index): slices[index].title
        case .child(let parent, let index): "\(slices[parent].title) · \(slices[parent].children[index].title)"
        default: nil
        }
    }
}

// MARK: - Showing the wheel

/// Shows the wheel when files are dragged with Shift held, anywhere on the Mac, and runs whatever they are dropped on.
///
/// Mouse events from other apps are visible to a global monitor without any extra permission, and
/// `NSEvent.modifierFlags` can be read at any time, so nothing here needs Accessibility access.
@MainActor
final class DragWheelController {
    static let shared = DragWheelController()

    private var monitors: [Any] = []
    private var panel: NSPanel?
    private var watchdog: Timer?
    private var dragCountAtMouseDown = 0
    private weak var model: AppModel?
    /// Keeps the wheel up with no button held, for screenshots.
    var isPinned = false
    let state = DragWheelState()

    var isVisible: Bool { panel?.isVisible == true }

    func setEnabled(_ enabled: Bool, model: AppModel) {
        self.model = model
        if enabled, monitors.isEmpty {
            let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                MainActor.assumeIsolated { self?.dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount }
            }
            let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseDragged() }
            }
            monitors = [down, drag].compactMap { $0 }
        } else if !enabled {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            hide()
        }
    }

    private func mouseDragged() {
        #if DEBUG
        NSLog("WHEEL drag visible=%d shift=%d changeCount=%d base=%d", isVisible, NSEvent.modifierFlags.contains(.shift), NSPasteboard(name: .drag).changeCount, dragCountAtMouseDown)
        #endif
        guard !isVisible, NSEvent.modifierFlags.contains(.shift) else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != dragCountAtMouseDown else { return }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        show(for: urls)
    }

    func show(for urls: [URL]) {
        var kinds = Set(urls.compactMap { MediaKind(url: $0) })
        // A folder holds anything; what is inside is sorted out on drop.
        if urls.contains(where: { $0.hasDirectoryPath }) { kinds.formUnion([.image, .video, .gif, .pdf, .audio]) }
        let slices = WheelSlice.slices(for: kinds, fileCount: urls.count)
        guard !slices.isEmpty else { return }
        state.reset(slices: slices, fileCount: urls.count)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = WheelGeometry.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x - size / 2, y: mouse.y - size / 2)
        if let frame = screen?.visibleFrame {
            origin.x = min(max(origin.x, frame.minX), frame.maxX - size)
            origin.y = min(max(origin.y, frame.minY), frame.maxY - size)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: size, height: size)), display: false)
        panel.orderFrontRegardless()

        // The drag has ended once the button is up, whether or not anything was dropped.
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isPinned, self.state.message == nil, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.hide()
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        let view = DragWheelView(state: state) { [weak self] command, providers in self?.drop(command, providers: providers) }
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }

    func hide() {
        watchdog?.invalidate()
        watchdog = nil
        panel?.orderOut(nil)
    }

    // MARK: Dropping

    private func drop(_ command: WheelCommand?, providers: [NSItemProvider]) {
        guard let command, let model else { hide(); return }
        state.message = "Working…"
        URLLoader.load(providers) { [weak self] urls in
            Task { @MainActor in
                guard let self else { return }
                let summary = await model.perform(command, on: urls)
                self.state.message = summary
                try? await Task.sleep(for: .milliseconds(700))
                self.hide()
            }
        }
    }
}

/// Loads the file URLs out of a drop. The sandbox grants access to them as part of the drop.
enum URLLoader {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func add(_ url: URL?) { lock.lock(); if let url { urls.append(url) }; lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    static func load(_ providers: [NSItemProvider], completion: @escaping @Sendable ([URL]) -> Void) {
        let box = Box()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                box.add(url)
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(box.all) }
    }
}
