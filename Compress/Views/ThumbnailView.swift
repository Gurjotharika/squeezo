import CompressCore
import QuickLookThumbnailing
import SwiftUI

struct ThumbnailView: View {
    let url: URL
    let kind: MediaKind
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let image {
                Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
            } else {
                Image(systemName: kind.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .motion(value: image != nil)
        .task(id: url) { image = await Self.load(url) }
    }

    private static func load(_ url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 44, height: 44), scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
