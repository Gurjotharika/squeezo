import CompressCore
import SwiftUI

/// The right-hand panel: facts about the selected file, or the options of the current tool.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            SegmentedControl(selection: $model.inspectorTab, options: InspectorTab.allCases.map { ($0, $0.rawValue) })
                .padding(.horizontal, 16)
                .padding(.top, 44)  // below the window's top edge, where the inspector toggle sits
                .padding(.bottom, 12)

            ScrollView {
                ZStack(alignment: .top) {
                    switch model.inspectorTab {
                    case .details:
                        DetailsView()
                            .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
                    case .options:
                        ToolOptionsView()
                            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .top) { Divider().opacity(0.6) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.inspectorTab == .options, model.tool != .compress { InspectorFooter() }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: model.previewTarget?.url) { await model.refreshTargetSize() }
        .motion(.fluid, value: model.inspectorTab)
    }
}

/// The tool's button, repeated at the bottom of the options so changing a setting and running it are one place.
private struct InspectorFooter: View {
    @Environment(AppModel.self) private var model

    private var label: String {
        let n = model.staged.count
        if n == 0 { return model.tool.runVerb }
        if model.tool.combinesFiles { return "Merge \(n) files" }
        return "\(model.tool.runVerb) \(n) \(n == 1 ? "file" : "files")"
    }

    var body: some View {
        let blocked = model.staged.isEmpty || model.runBlocker != nil
        VStack(spacing: 8) {
            if let blocker = model.runBlocker, !model.staged.isEmpty {
                Text(blocker).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).transition(.opacity)
            } else if model.staged.isEmpty {
                Text("Add files to get started.").font(.caption).foregroundStyle(.secondary).transition(.opacity)
            }
            Button { Task { await model.runStaged() } } label: {
                Text(label).frame(maxWidth: .infinity).contentTransition(.interpolate)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(blocked)
            .opacity(blocked ? 0.4 : 1)
        }
        .padding(16)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
        .motion(value: model.runBlocker)
        .motion(value: model.staged.count)
    }
}

// MARK: - Details

struct DetailsView: View {
    @Environment(AppModel.self) private var model

    /// The file being inspected, whether it is waiting or finished.
    private var item: (url: URL, kind: MediaKind, job: CompressionJob?)? {
        if let file = model.selectedStaged { return (file.url, file.kind, nil) }
        if let job = model.selectedJob { return (job.sourceURL, job.kind, job) }
        return nil
    }

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 18) {
                PreviewBox(url: item.url, kind: item.kind)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.url.lastPathComponent)
                        .display(18)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(item.kind.label).font(.callout).foregroundStyle(.secondary)
                }

                if let job = item.job { ResultSection(job: job) }

                InfoTable(url: item.url, kind: item.kind)

                HStack(spacing: 8) {
                    Button("Show in Finder") { model.reveal(item.url) }.buttonStyle(SecondaryButtonStyle())
                    Button("Open") { NSWorkspace.shared.open(item.url) }.buttonStyle(SecondaryButtonStyle())
                }
            }
            .id(item.url)
            .transition(.opacity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "sidebar.right").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                Text("No file selected").font(.headline)
                Text("Select a file in the list to see a preview, its details and what happened to it.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        }
    }
}

/// A large preview: the picture itself, a video's first frame, or a PDF's first page.
struct PreviewBox: View {
    let url: URL
    let kind: MediaKind
    @State private var image: CGImage?
    @State private var loaded = false

    var body: some View {
        ZStack {
            Color.primary.opacity(0.05)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            } else if loaded {
                Image(systemName: kind.symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .motion(value: image != nil)
        .task(id: url) {
            loaded = false
            image = await PreviewLoader.image(for: url, kind: kind)
            loaded = true
        }
    }
}

private struct ResultSection: View {
    @Environment(AppModel.self) private var model
    let job: CompressionJob

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch job.state {
            case .queued:
                Label("Waiting in line", systemImage: "clock").foregroundStyle(.secondary)
            case .running(let progress):
                HStack(spacing: 10) {
                    ProgressView(value: progress).tint(.accentColor)
                    Text(progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().foregroundStyle(.secondary)
                }
            case .completed(let result):
                completed(result)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label("This didn't work", systemImage: "exclamationmark.circle").font(.headline)
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Try Again") { model.retry(job.id) }.buttonStyle(SecondaryButtonStyle())
                }
            case .cancelled:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Cancelled", systemImage: "slash.circle").font(.headline)
                    Button("Try Again") { model.retry(job.id) }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func completed(_ result: JobResult) -> some View {
        switch result.outcome {
        case .compressed:
            VStack(alignment: .leading, spacing: 12) {
                Text("−\(result.savingsRatio.formatted(.percent.precision(.fractionLength(0))))")
                    .display(34)
                SizeBars(before: result.originalBytes, after: result.outputBytes)
                Text("Saved \(formatBytes(result.savedBytes))")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        case .keptOriginal:
            VStack(alignment: .leading, spacing: 4) {
                Label("Already small", systemImage: "checkmark").font(.headline)
                Text("Compressing wouldn't make this file smaller, so it was left as it is.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .processed:
            VStack(alignment: .leading, spacing: 4) {
                Label("Done", systemImage: "checkmark").font(.headline)
                Text("\(result.outputURL.lastPathComponent) · \(formatBytes(result.outputBytes))")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        HStack(spacing: 8) {
            if result.outcome != .keptOriginal {
                Button("Show Result") { model.reveal(result.outputURL) }.buttonStyle(SecondaryButtonStyle())
            }
            if model.canUndo(job) { Button("Undo") { model.undo(job) }.buttonStyle(SecondaryButtonStyle()) }
        }
    }
}

private struct InfoTable: View {
    let url: URL
    let kind: MediaKind
    @State private var info: MediaInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let info {
                ForEach(Array(info.rows.enumerated()), id: \.element.id) { index, row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(row.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                    .font(.callout)
                    .padding(.vertical, 7)
                    if index < info.rows.count - 1 { Divider() }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
        .task(id: url) { info = await MediaInfo.load(url, kind: kind) }
    }
}


/// Two bars drawn to the same scale, so the saving can be seen at a glance.
private struct SizeBars: View {
    let before: Int64
    let after: Int64
    @State private var shown = false

    var body: some View {
        VStack(spacing: 8) {
            bar("Before", value: before, fraction: 1, strong: false)
            bar("After", value: after, fraction: before > 0 ? Double(after) / Double(before) : 1, strong: true)
        }
        .onAppear { withAnimation(.fluid.delay(0.1)) { shown = true } }
    }

    private func bar(_ label: String, value: Int64, fraction: Double, strong: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(formatBytes(value)).font(.caption.weight(.medium)).monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(strong ? Theme.ink : Color.primary.opacity(0.3))
                        .frame(width: max(6, proxy.size.width * (shown ? fraction : 0)))
                }
            }
            .frame(height: 6)
        }
    }
}
