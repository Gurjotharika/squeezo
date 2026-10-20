import CompressCore
import SwiftUI

/// Tools on the left, files in the middle, details and options on the right.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 218, max: 250)
        } detail: {
            ContentView()
                .inspector(isPresented: $model.showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.primary)
        // The toggle stays in the top-right corner whether the inspector is open or not.
        .overlay(alignment: .topTrailing) { InspectorToggle().padding(.top, 9).padding(.trailing, 14) }
    }
}

private struct InspectorToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.showInspector.toggle() } label: {
            Image(systemName: "sidebar.trailing")
                .symbolVariant(model.showInspector ? .fill : .none)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(IconButtonStyle())
        .help(model.showInspector ? "Hide the inspector" : "Show the inspector")
        .accessibilityLabel(model.showInspector ? "Hide inspector" : "Show inspector")
        .keyboardShortcut("i", modifiers: [.command, .option])
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(ToolGroup.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                        ForEach(Tool.allCases.filter { $0.group == group }) { tool in
                            SidebarRow(tool: tool)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .background(.regularMaterial)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
    }
}

private struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let tool: Tool
    @State private var hovering = false

    private var isSelected: Bool { model.tool == tool }

    var body: some View {
        Button { model.tool = tool } label: {
            HStack(spacing: 10) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Text(tool.title)
                    .font(.system(.body, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer()
                if model.stagedCount(tool) > 0 {
                    Text("\(model.stagedCount(tool))")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(isSelected ? 0.10 : (hovering ? 0.05 : 0)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .motion(value: isSelected)
        .motion(value: hovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.entitlements.isUnlocked {
                Label("Pro", systemImage: "checkmark.seal")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.entitlements.remainingToday) free files left today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Button("Unlock everything") { model.showPaywall = true }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .motion(value: model.entitlements.remainingToday)
    }
}
