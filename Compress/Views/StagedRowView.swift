import CompressCore
import SwiftUI

/// A file waiting in a tool. Selecting it shows its details and a preview on the right.
struct StagedRowView: View {
    @Environment(AppModel.self) private var model
    let file: StagedFile
    let index: Int
    let count: Int
    @State private var size: Int64?
    @State private var hovering = false

    private var isSelected: Bool { model.selection == file.id }

    var body: some View {
        HStack(spacing: 14) {
            if model.tool.combinesFiles {
                Text("\(index + 1)")
                    .font(.system(.callout, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
            }
            ThumbnailView(url: file.url, kind: file.kind)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(file.kind.label)
                    if let size { Text("·").foregroundStyle(.tertiary); Text(formatBytes(size)) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer(minLength: 12)

            HStack(spacing: 6) {
                if model.tool.combinesFiles {
                    Button { model.moveStaged(file.id, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(IconButtonStyle()).disabled(index == 0).accessibilityLabel("Move up")
                    Button { model.moveStaged(file.id, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(IconButtonStyle()).disabled(index == count - 1).accessibilityLabel("Move down")
                }
                Button { model.unstage(file.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle()).help("Remove").accessibilityLabel("Remove")
            }
            .opacity(hovering || isSelected ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RowBackground(selected: isSelected, hovering: hovering))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = file.id }
        .onHover { hovering = $0 }
        .motion(value: hovering)
        .motion(value: isSelected)
        .task(id: file.url) { size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The soft highlight behind a row that is hovered or selected.
struct RowBackground: View {
    let selected: Bool
    let hovering: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(selected ? 0.08 : (hovering ? 0.04 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(selected ? 0.10 : 0)))
    }
}
