import CompressCore
import SwiftUI

/// What the user decides before compressing: how much, and where to save. Everything else is one step deeper.
struct ControlBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.tool == .compress { CompressBar() } else { ToolBar() }
    }
}

/// Where to save, and the button that runs a tool. The tool's own options are in the inspector.
private struct ToolBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            SaveToMenu()
            Spacer(minLength: 8)
            if let blocker = model.runBlocker, !model.staged.isEmpty {
                Text(blocker)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Button {
                Task { await model.runStaged() }
            } label: {
                Text(runLabel).contentTransition(.interpolate)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.staged.isEmpty || model.runBlocker != nil)
            .opacity(model.staged.isEmpty || model.runBlocker != nil ? 0.4 : 1)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(12)
        .surface(radius: 22, elevated: true)
        .motion(value: model.runBlocker)
        .motion(value: model.staged.count)
    }

    private var runLabel: String {
        let n = model.staged.count
        if n == 0 { return model.tool.runVerb }
        if model.tool.combinesFiles { return "Merge \(n) files" }
        return "\(model.tool.runVerb) \(n) \(n == 1 ? "file" : "files")"
    }
}

private struct CompressBar: View {
    @Environment(AppModel.self) private var model
    @State private var showingOptions = false

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 10) {
            HStack(spacing: 12) {
                QualitySelector(level: $model.level)
                Spacer(minLength: 8)
                SaveToMenu()
                Button { showingOptions.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(showingOptions ? 0.14 : 0.07), in: Circle())
                }
                .buttonStyle(PressableStyle())
                .help("More options")
                .accessibilityLabel("More options")
                .popover(isPresented: $showingOptions, arrowEdge: .top) {
                    ScrollView { CompressOptions().padding(16) }.frame(width: 330, height: 420)
                }
            }

            HStack(spacing: 6) {
                Text(model.level.summary)
                    .contentTransition(.interpolate)
                Spacer()
                if !model.entitlements.isUnlocked {
                    Text("\(model.entitlements.remainingToday) free today")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Button("Unlock") { model.showPaywall = true }
                        .buttonStyle(.plain)
                        .underline()
                        .foregroundStyle(.primary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .padding(12)
        .surface(radius: 22, elevated: true)
        .motion(value: model.level)
        .motion(value: model.entitlements.remainingToday)
    }
}

/// A segmented control whose thumb is one solid shape that slides, rather than four buttons that swap.
private struct QualitySelector: View {
    @Binding var level: QualityLevel
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(QualityLevel.allCases, id: \.self) { option in
                Button { level = option } label: {
                    Text(option.displayName)
                        .font(.system(.callout, weight: .medium))
                        .foregroundStyle(level == option ? Theme.paper : Color(nsColor: .secondaryLabelColor))
                        .frame(minWidth: 64)
                        .padding(.vertical, 7)
                        .background {
                            if level == option {
                                Capsule().fill(Theme.ink).matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .accessibilityAddTraits(level == option ? .isSelected : [])
                .help(option.summary)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .motion(.flick, value: level)
    }
}

private struct SaveToMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Picker("Save", selection: Binding(get: { model.outputMode }, set: { model.requestOutputMode($0) })) {
                ForEach(OutputMode.allCases.filter { !($0 == .replace && model.tool.cannotReplaceOriginal) }) {
                    Label($0.title, systemImage: $0.symbol).tag($0)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Choose Output Folder…") { model.chooseOutputFolder() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: model.outputMode.symbol)
                    .contentTransition(.symbolEffect(.replace))
                Text(label).contentTransition(.interpolate)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .font(.system(.callout, weight: .medium))
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .motion(value: model.outputMode)
        .help("Where compressed files are saved")
    }

    private var label: String {
        switch model.outputMode {
        case .suffix: "Next to original"
        case .folder: model.outputFolder?.lastPathComponent ?? "Chosen folder"
        case .replace: model.tool.cannotReplaceOriginal ? "Next to original" : "Replace original"
        }
    }
}
