import CompressCore
import SwiftUI

/// The middle of the window: files waiting, files finished, and the bar to run them.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        @Bindable var model = model

        ZStack(alignment: .bottom) {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            // Content runs the full height, so the control bar floats over it and rows scroll underneath.
            Group {
                if model.toolJobs.isEmpty && model.staged.isEmpty {
                    EmptyStateView(isTargeted: isTargeted)
                } else {
                    VStack(spacing: 0) {
                        WorkspaceHeader()
                        FileList()
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 8)

            VStack(spacing: 10) {
                if let notice = model.notice {
                    NoticeBar(text: notice) { model.notice = nil }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                ControlBar()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)

            if isTargeted && !(model.toolJobs.isEmpty && model.staged.isEmpty) { DropOverlay().transition(.opacity) }
        }
        .frame(minWidth: 520, minHeight: 600)
        .motion(value: model.toolJobs.isEmpty && model.staged.isEmpty)
        .motion(value: model.notice)
        .motion(value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.add(urls: urls) }
            return true
        } isTargeted: { isTargeted = $0 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.chooseFiles() } } label: { Label("Add Files", systemImage: "plus") }
                    .help("Add files or folders")
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task { await model.run() }
        .sheet(isPresented: $model.showPaywall) { PaywallView() }
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                Image(systemName: model.tool.symbol)
                    .font(.system(size: 26, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isTargeted)
                    .frame(width: 68, height: 68)
                    .background(Color.primary.opacity(0.06), in: Circle())

                VStack(spacing: 6) {
                    Text(isTargeted ? "Release to add" : model.tool.title)
                        .display(26)
                        .contentTransition(.interpolate)
                    Text(model.tool.summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Drop \(model.tool.dropHint.prefix(1).lowercased() + model.tool.dropHint.dropFirst()) Nothing leaves your Mac.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 380)

                Button("Choose Files") { Task { await model.chooseFiles() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 4)
            }
            .padding(.horizontal, 52)
            .padding(.vertical, 44)
            .background {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.14)),
                                  style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [] : [6, 6]))
            }
            .scaleEffect(isTargeted ? 1.015 : 1)
            .motion(.flick, value: isTargeted)
            Spacer()
            Spacer().frame(height: 120)  // leaves room for the control bar so the card sits in the visual centre
        }
        .padding(.horizontal, 28)
        .motion(value: model.tool)
    }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.accentColor.opacity(0.06)))
            .padding(10)
            .allowsHitTesting(false)
    }
}

// MARK: - Header and list

private struct WorkspaceHeader: View {
    @Environment(AppModel.self) private var model

    private var finished: Int { model.toolJobs.filter { $0.state.isFinished }.count }
    private var active: Bool { model.toolJobs.contains { !$0.state.isFinished } }
    private var saved: Int64 {
        model.toolJobs.reduce(0) { total, job in
            if case .completed(let result) = job.state { total + result.savedBytes } else { total }
        }
    }

    private var headline: String {
        if model.tool == .compress {
            if saved > 0 { return "Saved \(formatBytes(saved))" }
            return active ? "Compressing" : "Done"
        }
        if !model.staged.isEmpty { return model.tool.title }
        return active ? "Working" : "Done"
    }

    private var detail: String {
        if !model.staged.isEmpty {
            let n = model.staged.count
            return "\(n) \(n == 1 ? "file" : "files") ready"
        }
        let total = model.toolJobs.count
        return "\(finished) of \(total) \(total == 1 ? "file" : "files") done"
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).display(36).contentTransition(.numericText())
                Text(detail).font(.callout).foregroundStyle(.secondary).contentTransition(.numericText())
            }
            Spacer()
            HStack(spacing: 8) {
                if !model.staged.isEmpty { Button("Remove All") { model.clearStaged() }.buttonStyle(SecondaryButtonStyle()) }
                if active { Button("Cancel All") { model.cancelAll() }.buttonStyle(SecondaryButtonStyle()) }
                if finished > 0 { Button("Clear") { model.clearFinished() }.buttonStyle(SecondaryButtonStyle()) }
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .motion(value: saved)
        .motion(value: finished)
        .motion(value: model.staged.count)
    }
}

private struct FileList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2, pinnedViews: []) {
                if !model.staged.isEmpty {
                    SectionLabel(title: model.tool.combinesFiles ? "In this order" : "Ready")
                    ForEach(Array(model.staged.enumerated()), id: \.element.id) { index, file in
                        StagedRowView(file: file, index: index, count: model.staged.count)
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    }
                }
                if !model.toolJobs.isEmpty {
                    if !model.staged.isEmpty { SectionLabel(title: "Results") }
                    ForEach(model.toolJobs) { job in
                        JobRowView(job: job)
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 170)  // so the last row can scroll clear of the control bar
            .motion(value: model.toolJobs.map(\.id))
            .motion(value: model.staged.map(\.id))
        }
        .scrollIndicators(.hidden)
    }
}

private struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

private struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text).font(.callout)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 7)
        .surface(radius: 14)
    }
}
