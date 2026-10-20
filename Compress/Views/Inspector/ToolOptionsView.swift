import CompressCore
import SwiftUI
import UniformTypeIdentifiers

/// The options of the current tool, shown in the inspector.
struct ToolOptionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ToolHeader(tool: model.tool)
            Group {
                switch model.tool {
                case .compress: CompressOptions()
                case .resize: ResizeOptions()
                case .crop: CropOptions()
                case .rotate: RotateOptions()
                case .upscale: UpscaleOptions()
                case .watermark: WatermarkOptions()
                case .blurFaces: FaceOptions()
                case .removeBackground: RemoveBackgroundOptions()
                case .convert: ConvertOptions()
                case .extractText: TextOptions()
                case .mergePDF: MergeOptions()
                case .splitPDF: SplitOptions()
                }
            }
        }
        .id(model.tool)
        .transition(.opacity.combined(with: .offset(y: 8)))
        .motion(value: model.tool)
    }
}

/// The tool's icon, name and a line about it.
private struct ToolHeader: View {
    let tool: Tool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tool.symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
                .background(Theme.ink.opacity(0.9), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .foregroundStyle(Theme.paper)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title).display(18)
                Text(tool.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Compress

struct CompressOptions: View {
    @Environment(AppModel.self) private var model
    private let sizes = [4096, 2560, 1920, 1280, 800]

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 22) {
            OptionGroup(title: "Quality", footnote: model.level.summary) {
                SegmentedControl(selection: $model.level, options: QualityLevel.allCases.map { ($0, $0.displayName) })
            }
            OptionGroup(title: "Size", card: true) {
                PickerRow(title: "Resize to", selection: $model.maxDimension) {
                    Text("Original size").tag(Int?.none)
                    ForEach(sizes, id: \.self) { Text("Up to \($0) px").tag(Int?.some($0)) }
                }
                RowDivider()
                ToggleRow(title: "Remove location and camera info", isOn: $model.stripMetadata)
            }
            OptionGroup(title: "Video", card: true) {
                PickerRow(title: "Codec", selection: $model.videoCodec) {
                    ForEach(VideoCodec.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                RowDivider()
                PickerRow(title: "Frame rate", selection: $model.maxFrameRate) {
                    Text("Original").tag(Int?.none)
                    ForEach([60, 30, 24], id: \.self) { Text("Up to \($0) fps").tag(Int?.some($0)) }
                }
            }
            OptionGroup(title: "GIF", card: true) {
                ToggleRow(title: "Turn videos into GIFs", isOn: $model.videoToGIF)
                RowDivider()
                PickerRow(title: "Length", selection: $model.gifSeconds) {
                    ForEach([5.0, 10, 15], id: \.self) { Text("First \(Int($0)) seconds").tag($0) }
                }
                .disabled(!model.videoToGIF)
                .opacity(model.videoToGIF ? 1 : 0.5)
            }
        }
    }
}

// MARK: - Resize

private struct ResizeOptions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 22) {
            OptionGroup(title: "Resize by") {
                SegmentedChoice(selection: $settings.resizeKind, values: ResizeKind.allCases)
            }
            OptionGroup(title: "Size", card: true) {
                switch settings.resizeKind {
                case .fit:
                    NumberRow(title: "Longest side", value: $settings.resizeMaxSide)
                    RowDivider()
                    HStack(spacing: 6) {
                        ForEach([3840, 2560, 1920, 1280, 800], id: \.self) { value in
                            Button("\(value)") { settings.resizeMaxSide = value }
                                .buttonStyle(ChipButtonStyle(selected: value == settings.resizeMaxSide))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                case .percent:
                    SliderRow(title: "Scale", value: $settings.resizePercent, range: 5...200) { "\(Int($0))%" }
                case .exact:
                    NumberRow(title: "Width", value: $settings.resizeWidth)
                    RowDivider()
                    NumberRow(title: "Height", value: $settings.resizeHeight)
                    RowDivider()
                    ToggleRow(title: "Fill the frame", isOn: $settings.resizeFill, detail: "Crops the edges instead of squeezing the picture")
                }
            }
            if let size = model.targetSize {
                let result = PreviewTools.resizedSize(width: Int(size.width), height: Int(size.height), settings.resizeSpec)
                Readout(icon: "arrow.right", text: "\(Int(size.width)) × \(Int(size.height))  →  \(result.width) × \(result.height) px")
            }
            OptionGroup(title: "Options", footnote: "PDF pages aren't resized here. To make a PDF smaller, use Compress.", card: true) {
                ToggleRow(title: "Allow making things bigger", isOn: $settings.allowEnlarge)
            }
        }
    }
}

struct ChipButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.caption, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(selected ? Theme.paper : Color(nsColor: .secondaryLabelColor))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(selected ? Theme.ink : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.press, value: configuration.isPressed)
    }
}

// MARK: - Upscale

private struct UpscaleOptions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 22) {
            OptionGroup(title: "Enlarge by") {
                SegmentedControl(selection: $settings.upscaleFactor, options: [2, 3, 4].map { ($0, "\($0)×") })
            }
            if let size = model.targetSize {
                Readout(icon: "arrow.up.left.and.arrow.down.right",
                        text: "\(Int(size.width)) × \(Int(size.height))  →  \(Int(size.width) * settings.upscaleFactor) × \(Int(size.height) * settings.upscaleFactor) px")
            }
            OptionGroup(
                title: "Detail",
                footnote: "This uses careful resampling and sharpening. It makes things larger and crisper, but it can't add detail that was never there.",
                card: true) {
                SliderRow(title: "Sharpness", value: $settings.upscaleSharpness, range: 0...1) { "\(Int($0 * 100))%" }
            }
        }
    }
}

// MARK: - Background, text, merge, split

private struct RemoveBackgroundOptions: View {
    var body: some View {
        OptionGroup(
            title: "How it works",
            footnote: "Your Mac finds the main subject and makes everything else transparent. Results are saved as PNG. Pictures with no clear subject are reported instead of guessed.") {
            Readout(icon: "lock", text: "Runs entirely on your Mac")
        }
    }
}

private struct TextOptions: View {
    @Environment(AppModel.self) private var model

    private enum Choice: String, CaseIterable, Identifiable {
        case markdown = "Markdown", plain = "Plain text"
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 22) {
            OptionGroup(title: "Save as") {
                SegmentedChoice(selection: Binding(
                    get: { settings.text.format == .markdown ? Choice.markdown : .plain },
                    set: { settings.text.format = $0 == .markdown ? .markdown : .plain }), values: Choice.allCases)
            }
            OptionGroup(
                title: "Scans and pictures",
                footnote: "Text in scans and photos is read with your Mac's text recognition. It can take a few seconds per page.",
                card: true) {
                ToggleRow(title: "Recognize text in pictures", isOn: $settings.text.recognizeText)
            }
            OptionGroup(title: "What you get", footnote: "Headings, lists and paragraphs are rebuilt from the type size and weight. Tables and columns are read as plain lines.") {
                Readout(icon: "doc.plaintext", text: settings.text.format == .markdown ? "A .md file per document" : "A .txt file per document")
            }
        }
    }
}

private struct MergeOptions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        OptionGroup(
            title: "Order",
            footnote: "Pages follow the order of the list. Use the arrows on a file to move it up or down. Pictures become one page each.") {
            Readout(icon: "square.on.square",
                    text: model.staged.isEmpty ? "Add two or more PDFs or pictures" : "\(model.staged.count) files become one PDF")
        }
    }
}

private struct SplitOptions: View {
    @Environment(AppModel.self) private var model
    @State private var pageCount: Int?

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 22) {
            OptionGroup(title: "Split") {
                SegmentedChoice(selection: $settings.splitKind, values: SplitKind.allCases)
            }
            OptionGroup(title: "Pages", card: true) {
                switch settings.splitKind {
                case .everyPage:
                    Text("One file per page").font(.callout).foregroundStyle(.secondary).padding(12)
                case .ranges:
                    TextField("1-3, 5, 8-10", text: $settings.splitRanges)
                        .textFieldStyle(.plain)
                        .padding(12)
                case .everyN:
                    HStack {
                        Text("Pages per file").font(.callout)
                        Spacer()
                        Stepper("\(settings.splitEvery)", value: $settings.splitEvery, in: 1...200).monospacedDigit()
                    }
                    .padding(12)
                }
            }
            if let pageCount {
                Readout(icon: "doc", text: "\(pageCount) \(pageCount == 1 ? "page" : "pages") in this PDF")
            }
            Text("The pieces are saved together in a new folder.").font(.caption).foregroundStyle(.secondary)
        }
        .task(id: model.previewTarget?.url) {
            guard let target = model.previewTarget, target.kind == .pdf else { pageCount = nil; return }
            pageCount = CGPDFDocument(target.url as CFURL)?.numberOfPages
        }
    }
}

// MARK: - Convert

private struct ConvertOptions: View {
    @Environment(AppModel.self) private var model

    /// The kinds to show choices for: those waiting, or all of them when nothing is yet.
    private var kinds: [MediaKind] {
        let present = Set(model.staged.map(\.kind))
        let all: [MediaKind] = [.image, .video, .gif, .audio, .pdf]
        return present.isEmpty ? all : all.filter(present.contains)
    }

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 22) {
            ForEach(kinds, id: \.self) { kind in
                switch kind {
                case .image:
                    OptionGroup(title: "Pictures to") {
                        SegmentedControl(
                            selection: Binding(
                                get: { settings.imageToPDF ? "pdf" : settings.imageTarget.rawValue },
                                set: { value in
                                    if value == "pdf" { settings.imageToPDF = true } else {
                                        settings.imageToPDF = false
                                        settings.imageTarget = ImageFormat(rawValue: value) ?? .jpeg
                                    }
                                }),
                            options: ImageFormat.allCases.map { ($0.rawValue, $0.displayName) } + [("pdf", "PDF")])
                    }
                case .video:
                    OptionGroup(title: "Videos to", footnote: settings.videoTarget == .gif
                        ? "Uses the first \(Int(model.gifSeconds)) seconds at up to 12 frames a second. Change the length in Compress options." : nil) {
                        SegmentedChoice(selection: $settings.videoTarget, values: VideoTarget.allCases)
                    }
                    if settings.videoTarget == .audio {
                        OptionGroup(title: "Audio format", card: true) {
                            PickerRow(title: "Format", selection: $settings.videoAudioFormat) {
                                ForEach(AudioFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }
                        }
                    }
                case .gif:
                    OptionGroup(title: "GIFs to") {
                        SegmentedControl(selection: $settings.gifTarget, options: [(VideoFormat.mp4, "MP4"), (VideoFormat.mov, "MOV")])
                    }
                case .audio:
                    OptionGroup(title: "Audio to", card: true) {
                        PickerRow(title: "Format", selection: $settings.audioTarget) {
                            ForEach(AudioFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                case .pdf:
                    OptionGroup(title: "PDF pages to", footnote: "Every page becomes a picture, saved together in a new folder.") {
                        SegmentedChoice(selection: $settings.pdfPageTarget, values: PDFPageTarget.allCases)
                    }
                    OptionGroup(title: "Resolution", card: true) {
                        PickerRow(title: "Pages at", selection: $settings.pdfDPI) {
                            ForEach([72, 150, 220, 300], id: \.self) { Text("\($0) dpi").tag($0) }
                        }
                    }
                case .document:
                    EmptyView()
                }
            }
            OptionGroup(title: "Quality", footnote: "Applies to JPEG, HEIC, AVIF and AAC.", card: true) {
                SliderRow(title: "Quality", value: $settings.convertQuality, range: 0.3...1) { "\(Int($0 * 100))%" }
            }
        }
    }
}
