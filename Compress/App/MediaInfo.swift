import AVFoundation
import CompressCore
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// The facts about a file shown in the inspector, read without changing anything.
struct MediaInfo {
    struct Row: Identifiable {
        let id = UUID()
        let label: String
        let value: String
    }

    var rows: [Row] = []

    mutating func add(_ label: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        rows.append(Row(label: label, value: value))
    }

    static func load(_ url: URL, kind: MediaKind) async -> MediaInfo {
        var info = MediaInfo()
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey])
        info.add("Format", values?.contentType?.localizedDescription ?? url.pathExtension.uppercased())
        info.add("Size", values?.fileSize.map { Int64($0).formatted(.byteCount(style: .file)) })

        switch kind {
        case .image, .gif: info.addImage(url, isGIF: kind == .gif)
        case .video, .audio: await info.addAV(url, isVideo: kind == .video)
        case .pdf: info.addPDF(url)
        case .document: break
        }
        info.add("Created", values?.creationDate?.formatted(date: .abbreviated, time: .shortened))
        info.add("Modified", values?.contentModificationDate?.formatted(date: .abbreviated, time: .shortened))
        return info
    }

    private mutating func addImage(_ url: URL, isGIF: Bool) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return }
        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            add("Dimensions", "\(w) × \(h) px")
        }
        if isGIF {
            let count = CGImageSourceGetCount(source)
            add("Frames", "\(count)")
            var seconds = 0.0
            for index in 0..<count {
                let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                seconds += ((frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            }
            add("Duration", String(format: "%.1f s", seconds))
        }
        add("Color", props[kCGImagePropertyColorModel] as? String)
        if let depth = props[kCGImagePropertyDepth] as? Int { add("Bit depth", "\(depth)-bit") }
        if let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 0 { add("Resolution", "\(Int(dpi)) dpi") }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let camera = [tiff?[kCGImagePropertyTIFFMake], tiff?[kCGImagePropertyTIFFModel]].compactMap { $0 as? String }.joined(separator: " ")
        add("Camera", camera)
        if props[kCGImagePropertyGPSDictionary] != nil { add("Location", "Included in the file") }
    }

    private mutating func addAV(_ url: URL, isVideo: Bool) async {
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration).seconds, duration.isFinite {
            let minutes = Int(duration) / 60, seconds = Int(duration) % 60
            add("Duration", String(format: "%d:%02d", minutes, seconds))
        }
        if isVideo, let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let shown = size.applying(transform)
                add("Dimensions", "\(Int(abs(shown.width))) × \(Int(abs(shown.height))) px")
            }
            if let fps = try? await track.load(.nominalFrameRate), fps > 0 { add("Frame rate", "\(Int(fps.rounded())) fps") }
            if let format = try? await track.load(.formatDescriptions).first { add("Video codec", Self.fourCC(CMFormatDescriptionGetMediaSubType(format))) }
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 { add("Video bitrate", String(format: "%.1f Mbit/s", Double(rate) / 1_000_000)) }
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let format = try? await track.load(.formatDescriptions).first {
            add("Audio codec", Self.fourCC(CMFormatDescriptionGetMediaSubType(format)))
            if let d = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                add("Channels", d.mChannelsPerFrame == 1 ? "Mono" : (d.mChannelsPerFrame == 2 ? "Stereo" : "\(d.mChannelsPerFrame)"))
                add("Sample rate", String(format: "%.1f kHz", d.mSampleRate / 1000))
            }
        }
    }

    private mutating func addPDF(_ url: URL) {
        guard let document = PDFDocument(url: url) else { return }
        add("Pages", "\(document.pageCount)")
        if let page = document.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            add("Page size", "\(Int(box.width)) × \(Int(box.height)) pt")
        }
        add("Title", document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
        add("Author", document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String)
        if document.isEncrypted { add("Protection", "Password protected") }
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8(code >> 24 & 255), UInt8(code >> 16 & 255), UInt8(code >> 8 & 255), UInt8(code & 255)]
        let text = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
        switch text {
        case "hvc1", "hev1": return "HEVC"
        case "avc1": return "H.264"
        case "aac", "mp4a": return "AAC"
        case "lpcm": return "PCM"
        case "alac": return "Apple Lossless"
        default: return text.uppercased()
        }
    }
}

/// Loads a picture to show for a file: the first frame of a video, the first page of a PDF, and so on.
enum PreviewLoader {
    static func image(for url: URL, kind: MediaKind, maxSide: Int = 900) async -> CGImage? {
        switch kind {
        case .image, .gif:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide, kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxSide, height: maxSide)
            return try? await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        case .pdf:
            guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { return nil }
            let box = page.getBoxRect(.cropBox)
            return PDFEditor.renderPage(page, dpi: max(20, min(144, Int(Double(maxSide) / max(box.width, box.height) * 72))))
        case .audio, .document:
            return nil
        }
    }
}
