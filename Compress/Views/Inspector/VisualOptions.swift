import CompressCore
import SwiftUI
import UniformTypeIdentifiers

/// A picture with a caption underneath, or a hint when there is nothing to show yet.
private struct PreviewFrame: View {
    let image: CGImage?
    let hint: String
    var height: CGFloat = 220

    var body: some View {
        ZStack {
            Color.primary.opacity(0.05)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().transition(.opacity)
            } else {
                Text(hint).font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding()
            }
        }
        .frame(maxWidth: .infinity).frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .motion(value: image != nil)
    }
}

// MARK: - Crop

struct CropOptions: View {
    @Environment(AppModel.self) private var model
    @State private var image: CGImage?

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 22) {
            OptionGroup(title: "Area", footnote: "Drag the corners or edges. Drag inside to move. The same area is used for every file, as a share of its size.") {
                if let image {
                    CropCanvas(image: image, rect: $settings.crop, aspect: settings.cropAspect)
                        .frame(height: 250)
                } else {
                    PreviewFrame(image: nil, hint: "Add a file to choose the area to keep.", height: 160)
                }
            }
            OptionGroup(title: "Shape") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(CropAspect.allCases) { option in
                        Button(option.rawValue) {
                            settings.cropAspect = option
                            applyAspect(option)
                        }
                        .buttonStyle(ChipButtonStyle(selected: settings.cropAspect == option))
                    }
                }
                HStack(spacing: 8) {
                    Readout(
                        icon: "crop",
                        text: model.targetSize.map { "\(Int(($0.width * settings.crop.width).rounded())) × \(Int(($0.height * settings.crop.height).rounded())) px" }
                            ?? "\(Int((settings.crop.width * 100).rounded()))% × \(Int((settings.crop.height * 100).rounded()))%")
                    Button("Reset") { settings.crop = .full; settings.cropAspect = .free }
                        .buttonStyle(SecondaryButtonStyle()).disabled(settings.crop.isFull)
                }
            }
        }
        .task(id: model.previewTarget?.url) { image = await model.loadPreview() }
    }

    /// Re-shapes the current area to the chosen ratio, keeping its centre.
    private func applyAspect(_ aspect: CropAspect) {
        guard let image, let ratio = aspect.ratio(original: Double(image.width) / Double(image.height)) else { return }
        let imageRatio = Double(image.width) / Double(image.height)
        let rect = model.settings.crop
        let wideness = ratio / imageRatio  // width ÷ height, as shares of the picture
        var w = rect.width, h = w / wideness
        if h > 1 { h = 1; w = h * wideness }
        if h > rect.height * 1.0001 && rect.isFull == false { h = min(h, 1); w = h * wideness }
        w = min(w, 1); h = w / wideness
        model.settings.crop = NormalizedRect(x: rect.x + rect.width / 2 - w / 2, y: rect.y + rect.height / 2 - h / 2, width: w, height: h).clamped
    }
}

private struct CropCanvas: View {
    let image: CGImage
    @Binding var rect: NormalizedRect
    let aspect: CropAspect

    private enum Handle { case move, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, fresh }
    @State private var active: (handle: Handle, start: NormalizedRect, origin: CGPoint)?

    private var imageRatio: Double { Double(image.width) / Double(image.height) }

    var body: some View {
        GeometryReader { geo in
            let fit = fittedFrame(in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)

                let box = viewRect(fit)
                // Dim everything outside the area that stays.
                Path { path in
                    path.addRect(fit)
                    path.addRect(box)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                CropFrame(box: box).allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in change(value, fit: fit) }
                    .onEnded { _ in active = nil }
            )
        }
    }

    // MARK: Geometry

    private func fittedFrame(in size: CGSize) -> CGRect {
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func viewRect(_ fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + rect.x * fit.width, y: fit.minY + rect.y * fit.height, width: rect.width * fit.width, height: rect.height * fit.height)
    }

    private func normalized(_ point: CGPoint, in fit: CGRect) -> CGPoint {
        CGPoint(x: min(max((point.x - fit.minX) / fit.width, 0), 1), y: min(max((point.y - fit.minY) / fit.height, 0), 1))
    }

    // MARK: Gesture

    private func handle(at point: CGPoint, fit: CGRect) -> Handle {
        let box = viewRect(fit)
        let tolerance: CGFloat = 16
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }
        let l = near(point.x, box.minX), r = near(point.x, box.maxX), t = near(point.y, box.minY), b = near(point.y, box.maxY)
        let withinX = point.x > box.minX - tolerance && point.x < box.maxX + tolerance
        let withinY = point.y > box.minY - tolerance && point.y < box.maxY + tolerance
        if l && t { return .topLeft }
        if r && t { return .topRight }
        if l && b { return .bottomLeft }
        if r && b { return .bottomRight }
        if t && withinX { return .top }
        if b && withinX { return .bottom }
        if l && withinY { return .left }
        if r && withinY { return .right }
        if box.contains(point) { return .move }
        return .fresh
    }

    private func change(_ value: DragGesture.Value, fit: CGRect) {
        if active == nil {
            let handle = handle(at: value.startLocation, fit: fit)
            guard handle != .fresh || fit.contains(value.startLocation) else { return }
            active = (handle, rect, normalized(value.startLocation, in: fit))
        }
        guard let active else { return }
        let dx = Double(value.translation.width / fit.width), dy = Double(value.translation.height / fit.height)
        let ratio = aspect.ratio(original: imageRatio).map { $0 / imageRatio }  // width ÷ height as shares of the picture
        let s = active.start

        switch active.handle {
        case .move:
            rect = NormalizedRect(x: min(max(s.x + dx, 0), 1 - s.width), y: min(max(s.y + dy, 0), 1 - s.height), width: s.width, height: s.height)

        case .fresh:
            let p0 = active.origin
            let p1 = normalized(value.location, in: fit)
            if let ratio {
                let sx = p1.x >= p0.x ? 1.0 : -1.0, sy = p1.y >= p0.y ? 1.0 : -1.0
                rect = locked(anchor: p0, sx: sx, sy: sy, desiredWidth: abs(p1.x - p0.x), ratio: ratio)
            } else {
                rect = NormalizedRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y)).clamped
            }

        default:
            resize(active.handle, from: s, dx: dx, dy: dy, ratio: ratio)
        }
    }

    private func resize(_ handle: Handle, from s: NormalizedRect, dx: Double, dy: Double, ratio: Double?) {
        let minSize = 0.04
        var l = s.x, t = s.y, r = s.x + s.width, b = s.y + s.height

        if let ratio {
            // With a fixed shape, the width decides and the opposite corner or edge stays put.
            switch handle {
            case .topLeft: rect = locked(anchor: CGPoint(x: r, y: b), sx: -1, sy: -1, desiredWidth: r - (l + dx), ratio: ratio)
            case .topRight: rect = locked(anchor: CGPoint(x: l, y: b), sx: 1, sy: -1, desiredWidth: (r + dx) - l, ratio: ratio)
            case .bottomLeft: rect = locked(anchor: CGPoint(x: r, y: t), sx: -1, sy: 1, desiredWidth: r - (l + dx), ratio: ratio)
            case .bottomRight: rect = locked(anchor: CGPoint(x: l, y: t), sx: 1, sy: 1, desiredWidth: (r + dx) - l, ratio: ratio)
            case .left, .right:
                let width = handle == .right ? (r + dx) - l : r - (l + dx)
                let anchor = CGPoint(x: handle == .right ? l : r, y: s.y + s.height / 2)
                rect = centeredVertically(anchor: anchor, sx: handle == .right ? 1 : -1, desiredWidth: width, ratio: ratio)
            case .top, .bottom:
                let height = handle == .bottom ? (b + dy) - t : b - (t + dy)
                let anchor = CGPoint(x: s.x + s.width / 2, y: handle == .bottom ? t : b)
                rect = centeredHorizontally(anchor: anchor, sy: handle == .bottom ? 1 : -1, desiredHeight: height, ratio: ratio)
            default: break
            }
            return
        }

        switch handle {
        case .topLeft: l += dx; t += dy
        case .top: t += dy
        case .topRight: r += dx; t += dy
        case .right: r += dx
        case .bottomRight: r += dx; b += dy
        case .bottom: b += dy
        case .bottomLeft: l += dx; b += dy
        case .left: l += dx
        default: break
        }
        l = min(max(l, 0), r - minSize); r = max(min(r, 1), l + minSize)
        t = min(max(t, 0), b - minSize); b = max(min(b, 1), t + minSize)
        rect = NormalizedRect(x: l, y: t, width: r - l, height: b - t)
    }

    /// A rectangle of the chosen shape that grows from `anchor` in the directions `sx`, `sy`, kept inside the picture.
    private func locked(anchor: CGPoint, sx: Double, sy: Double, desiredWidth: Double, ratio: Double) -> NormalizedRect {
        let room = min(sx > 0 ? 1 - anchor.x : anchor.x, (sy > 0 ? 1 - anchor.y : anchor.y) * ratio)
        let w = max(0.04, min(desiredWidth, room)), h = w / ratio
        return NormalizedRect(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h).clamped
    }

    private func centeredVertically(anchor: CGPoint, sx: Double, desiredWidth: Double, ratio: Double) -> NormalizedRect {
        let room = min(sx > 0 ? 1 - anchor.x : anchor.x, 2 * min(anchor.y, 1 - anchor.y) * ratio)
        let w = max(0.04, min(desiredWidth, room)), h = w / ratio
        return NormalizedRect(x: sx > 0 ? anchor.x : anchor.x - w, y: anchor.y - h / 2, width: w, height: h).clamped
    }

    private func centeredHorizontally(anchor: CGPoint, sy: Double, desiredHeight: Double, ratio: Double) -> NormalizedRect {
        let room = min(sy > 0 ? 1 - anchor.y : anchor.y, 2 * min(anchor.x, 1 - anchor.x) / ratio)
        let h = max(0.04 / ratio, min(desiredHeight, room)), w = h * ratio
        return NormalizedRect(x: anchor.x - w / 2, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h).clamped
    }
}

/// The frame, thirds and corner handles drawn over the kept area.
private struct CropFrame: View {
    let box: CGRect

    var body: some View {
        ZStack {
            Path { path in
                for i in 1...2 {
                    let x = box.minX + box.width * CGFloat(i) / 3, y = box.minY + box.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: box.minY)); path.addLine(to: CGPoint(x: x, y: box.maxY))
                    path.move(to: CGPoint(x: box.minX, y: y)); path.addLine(to: CGPoint(x: box.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)

            Rectangle().path(in: box).stroke(Color.white, lineWidth: 1.5)

            // Short, thick corner marks show where to grab.
            Path { path in
                let len = min(18, box.width / 3, box.height / 3)
                for (corner, dx, dy) in [(CGPoint(x: box.minX, y: box.minY), 1.0, 1.0), (CGPoint(x: box.maxX, y: box.minY), -1.0, 1.0),
                                         (CGPoint(x: box.minX, y: box.maxY), 1.0, -1.0), (CGPoint(x: box.maxX, y: box.maxY), -1.0, -1.0)] {
                    path.move(to: CGPoint(x: corner.x, y: corner.y + dy * len)); path.addLine(to: corner)
                    path.addLine(to: CGPoint(x: corner.x + dx * len, y: corner.y))
                }
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
    }
}

// MARK: - Rotate

struct RotateOptions: View {
    @Environment(AppModel.self) private var model
    @State private var base: CGImage?
    @State private var shown: CGImage?

    private var hasPDF: Bool { model.staged.contains { $0.kind == .pdf } || model.previewTarget?.kind == .pdf }

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 22) {
            OptionGroup(title: "Preview") {
                PreviewFrame(image: shown ?? base, hint: "Add a file to see the result.", height: 200)
            }
            OptionGroup(title: "Turn") {
                HStack(spacing: 8) {
                    Button { turn(-1) } label: { Label("Left", systemImage: "rotate.left") }
                    Button { turn(1) } label: { Label("Right", systemImage: "rotate.right") }
                    Button { turn(2) } label: { Label("180°", systemImage: "arrow.triangle.2.circlepath") }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            OptionGroup(title: "Flip", footnote: hasPDF ? "PDF pages can be turned but not mirrored." : nil, card: true) {
                ToggleRow(title: "Horizontally", isOn: $settings.rotate.flipHorizontal)
                RowDivider()
                ToggleRow(title: "Vertically", isOn: $settings.rotate.flipVertical)
            }
            if !settings.rotate.isIdentity {
                Button("Reset") { settings.rotate = RotateSpec(quarterTurns: 0) }.buttonStyle(SecondaryButtonStyle())
            }
        }
        .task(id: model.previewTarget?.url) { base = await model.loadPreview(); updatePreview() }
        .onChange(of: model.settings.rotate) { updatePreview() }
    }

    private func turn(_ quarters: Int) {
        let r = model.settings.rotate
        model.settings.rotate = RotateSpec(quarterTurns: r.quarterTurns + quarters, flipHorizontal: r.flipHorizontal, flipVertical: r.flipVertical)
    }

    private func updatePreview() {
        guard let base else { shown = nil; return }
        shown = PreviewTools.rotated(base, model.settings.rotate)
    }
}

// MARK: - Watermark

struct WatermarkOptions: View {
    @Environment(AppModel.self) private var model
    @State private var base: CGImage?
    @State private var shown: CGImage?

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 22) {
            OptionGroup(title: "Preview") {
                PreviewFrame(image: shown ?? base, hint: "Add a file to see the watermark on it.", height: 200)
            }
            OptionGroup(title: "Mark") {
                SegmentedControl(selection: $settings.watermarkUsesImage, options: [(false, "Text"), (true, "Logo")])

                if settings.watermarkUsesImage {
                    HStack {
                        Text(settings.watermarkImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No logo chosen")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseLogo() }.buttonStyle(SecondaryButtonStyle())
                    }
                } else {
                    TextField("Watermark text", text: $settings.watermarkText, prompt: Text("Type the text to stamp, e.g. © Your Name"))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    SegmentedControl(selection: $settings.watermarkDark, options: [(false, "Light"), (true, "Dark")])
                }
            }
            OptionGroup(title: "Position") {
                PositionGrid(position: $settings.watermarkPosition)
            }
            OptionGroup(title: "Look", card: true) {
                SliderRow(title: "Size", value: $settings.watermarkScale, range: 0.05...0.8) { "\(Int($0 * 100))%" }
                RowDivider()
                SliderRow(title: "Opacity", value: $settings.watermarkOpacity, range: 0.1...1) { "\(Int($0 * 100))%" }
                RowDivider()
                SliderRow(title: "Angle", value: $settings.watermarkRotation, range: -60...60) { "\(Int($0))°" }
            }
        }
        .task(id: model.previewTarget?.url) { base = await model.loadPreview(); updatePreview() }
        .onChange(of: model.settings.watermarkSpec) { updatePreview() }
    }

    private func updatePreview() {
        guard let base else { shown = nil; return }
        shown = PreviewTools.watermarked(base, model.settings.watermarkSpec)
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Watermark"
        if panel.runModal() == .OK, let url = panel.url { model.settings.watermarkImagePath = url.path }
    }
}

private struct PositionGrid: View {
    @Binding var position: WatermarkPosition
    private let grid: [[WatermarkPosition]] = [[.topLeft, .top, .topRight], [.left, .center, .right], [.bottomLeft, .bottom, .bottomRight]]

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 4) {
                ForEach(grid, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(row, id: \.self) { cell in
                            Button { position = cell } label: {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(position == cell ? Theme.ink : Color.primary.opacity(0.10))
                                    .frame(width: 30, height: 22)
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel(cell.rawValue)
                            .accessibilityAddTraits(position == cell ? .isSelected : [])
                        }
                    }
                }
            }
            .opacity(position == .tiled ? 0.4 : 1)
            Toggle("Repeat across the whole picture", isOn: Binding(
                get: { position == .tiled },
                set: { position = $0 ? .tiled : .bottomRight }))
                .font(.callout)
        }
    }
}

// MARK: - Faces

struct FaceOptions: View {
    @Environment(AppModel.self) private var model
    @State private var base: CGImage?
    @State private var result: (image: CGImage, faces: Int)?

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 22) {
            OptionGroup(title: "Preview", footnote: faceNote) {
                PreviewFrame(image: result?.image ?? base, hint: "Add a picture or video to find faces in it.", height: 200)
            }
            OptionGroup(title: "Style") {
                SegmentedControl(selection: $settings.blur.style, options: BlurStyle.allCases.map { ($0, $0.displayName) })
            }
            if settings.blur.style != .solid {
                OptionGroup(title: "Strength", card: true) {
                    SliderRow(title: "Strength", value: $settings.blur.strength, range: 0...1) { "\(Int($0 * 100))%" }
                }
            }
            OptionGroup(title: "How it works", footnote: "Faces are found on your Mac, in every frame of a video. A face that no one can make out isn't hidden, so check the result before sharing.") {
                EmptyView()
            }
        }
        .task(id: model.previewTarget?.url) { base = await model.loadPreview(); update() }
        .onChange(of: model.settings.blur) { update() }
    }

    private var faceNote: String? {
        guard let result else { return nil }
        return result.faces == 0 ? "No faces were found in the preview." : "\(result.faces) \(result.faces == 1 ? "face" : "faces") found."
    }

    private func update() {
        guard let base else { result = nil; return }
        result = PreviewTools.hidingFaces(base, model.settings.blur)
    }
}
