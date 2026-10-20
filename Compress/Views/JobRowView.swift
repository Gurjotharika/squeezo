import CompressCore
import SwiftUI

struct JobRowView: View {
    @Environment(AppModel.self) private var model
    let job: CompressionJob
    @State private var originalBytes: Int64?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            ThumbnailView(url: job.sourceURL, kind: job.kind)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.sourceURL.lastPathComponent)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitle
            }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                actions
                    .opacity(hovering || model.selection == job.id ? 1 : 0)
                    .offset(x: hovering ? 0 : 6)
                status
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RowBackground(selected: model.selection == job.id, hovering: hovering))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = job.id }
        .onHover { hovering = $0 }
        .motion(value: model.selection)
        .motion(value: hovering)
        .motion(value: job.state)
        .task(id: job.sourceURL) {
            originalBytes = (try? job.sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Pieces

    private var subtitle: some View {
        HStack(spacing: 5) {
            Text(job.preset.operation.family == .compress ? job.kind.label : job.preset.operation.family.pastTense)
            Text("·").foregroundStyle(.tertiary)
            switch job.state {
            case .completed(let result) where result.outcome == .processed:
                Text(job.sourceURL.lastPathComponent == result.outputURL.lastPathComponent ? "" : result.outputURL.lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                Text("·").foregroundStyle(.tertiary)
                Text(formatBytes(result.outputBytes))
            case .completed(let result) where result.outcome == .compressed:
                Text(formatBytes(result.originalBytes)).strikethrough(true, color: .secondary.opacity(0.5))
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                Text(formatBytes(result.outputBytes)).foregroundStyle(.primary)
            case .running(let progress):
                Text(progress.formatted(.percent.precision(.fractionLength(0)))).contentTransition(.numericText())
            case .failed(let message):
                Text(message).lineLimit(1)
            default:
                if let originalBytes { Text(formatBytes(originalBytes)) }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    @ViewBuilder
    private var status: some View {
        Group {
            switch job.state {
            case .queued:
                Image(systemName: "clock").foregroundStyle(.tertiary)
            case .running(let progress):
                ProgressRing(value: progress)
            case .completed(let result):
                switch result.outcome {
                case .compressed:
                    Text("−\(result.savingsRatio.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.system(.body, weight: .semibold))
                        .monospacedDigit()
                case .processed:
                    Label("Done", systemImage: "checkmark")
                        .font(.system(.body, weight: .medium))
                case .keptOriginal:
                    Label("Already small", systemImage: "checkmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Compressing wouldn't make this file smaller, so it was left as it is.")
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).help(message)
            case .cancelled:
                Image(systemName: "slash.circle").foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 28, alignment: .trailing)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch job.state {
            case .queued, .running:
                Button { model.cancel(job.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle()).help("Cancel").accessibilityLabel("Cancel")
            case .failed, .cancelled:
                Button { model.retry(job.id) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle()).help("Try again").accessibilityLabel("Try again")
            case .completed(let result):
                if model.canUndo(job) {
                    Button { model.undo(job) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(IconButtonStyle())
                        .help(result.backupURL != nil ? "Put the original back" : "Move the compressed copy to the Trash")
                        .accessibilityLabel("Undo")
                }
                Button { model.reveal(result.outputURL) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(IconButtonStyle()).help("Show in Finder").accessibilityLabel("Show in Finder")
            }
        }
    }
}

/// A ring that fills as work completes. It uses the system accent, the only colour in the app.
private struct ProgressRing: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.03, value))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: value)
        }
        .frame(width: 20, height: 20)
        .accessibilityLabel("Progress")
        .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
    }
}
