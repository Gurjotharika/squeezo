import UniformTypeIdentifiers

/// The categories of file the app can compress.
public enum MediaKind: String, Sendable, CaseIterable {
    case image
    case video
    case gif
    case pdf
    /// Zip-based documents whose embedded images can be recompressed: EPUB and Office files.
    case document
    case audio

    static let documentExtensions: Set<String> = ["epub", "docx", "pptx", "xlsx"]

    /// Detects the kind from a file's content type, or nil if unsupported.
    public init?(contentType: UTType) {
        if contentType.preferredFilenameExtension.map({ Self.documentExtensions.contains($0) }) == true
            || ["org.idpf.epub-container", "org.openxmlformats.wordprocessingml.document",
                "org.openxmlformats.presentationml.presentation", "org.openxmlformats.spreadsheetml.sheet"]
                .contains(contentType.identifier) {
            self = .document
        } else if contentType.conforms(to: .gif) {
            self = .gif
        } else if contentType.conforms(to: .pdf) {
            self = .pdf
        } else if contentType.conforms(to: .image) {
            self = .image
        } else if contentType.conforms(to: .movie) {
            self = .video
        } else if contentType.conforms(to: .audio) {
            self = .audio
        } else {
            return nil
        }
    }

    /// Detects the kind of a file, preferring its on-disk type and falling back to the extension.
    public init?(url: URL) {
        if Self.documentExtensions.contains(url.pathExtension.lowercased()) {
            self = .document
            return
        }
        let onDisk = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        guard let type = onDisk ?? UTType(filenameExtension: url.pathExtension) else { return nil }
        self.init(contentType: type)
    }
}
