import CompressCore
import SwiftUI

/// A titled group of controls, the building block of every tool's options.
/// With `card` the content sits in a rounded panel and is made of rows (`ToggleRow`, `PickerRow`, `SliderRow`, `NumberRow`).
struct OptionGroup<Content: View>: View {
    let title: String
    var footnote: String?
    var card = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.6)
                .padding(.leading, 2)
            if card {
                VStack(spacing: 0) { content }
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.07)))
            } else {
                content
            }
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// The hairline between rows of a card.
struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 12).opacity(0.7) }
}

private extension View {
    func rowPadding() -> some View { padding(.horizontal, 12).padding(.vertical, 9) }
}

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var detail: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .rowPadding()
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(value))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Slider(value: $value, in: range).controlSize(.small)
        }
        .rowPadding()
    }
}

/// A row with a label on the left and a menu on the right.
struct PickerRow<Value: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Value
    @ViewBuilder var options: Options

    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Picker(title, selection: $selection) { options }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
        }
        .rowPadding()
    }
}

/// A number with a unit, for pixel sizes and percentages.
struct NumberRow: View {
    let title: String
    @Binding var value: Int
    var suffix = "px"

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.callout)
            Spacer()
            TextField("", value: $value, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 64)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            if !suffix.isEmpty { Text(suffix).font(.callout).foregroundStyle(.tertiary).frame(width: 18, alignment: .leading) }
        }
        .rowPadding()
    }
}

struct SegmentedChoice<Value: Hashable & Identifiable>: View where Value: RawRepresentable, Value.RawValue == String {
    @Binding var selection: Value
    let values: [Value]

    var body: some View {
        SegmentedControl(selection: $selection, options: values.map { ($0, $0.rawValue) })
    }
}

/// A line of text explaining what will happen, such as "1920 × 1080 → 1280 × 720 px".
struct Readout: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text(text).font(.callout).monospacedDigit().contentTransition(.numericText())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .motion(value: text)
    }
}

extension AppModel {
    /// A small picture of the file the options apply to, or nil when there is none yet.
    func loadPreview() async -> CGImage? {
        guard let target = previewTarget else { return nil }
        return await PreviewLoader.image(for: target.url, kind: target.kind, maxSide: 700)
    }
}
