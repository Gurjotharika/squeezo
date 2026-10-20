import CompressCore
import Foundation
import Observation

enum ToolGroup: String, CaseIterable {
    case optimize = "Optimize"
    case edit = "Edit"
    case convert = "Convert"
    case pdf = "PDF"
}

/// Everything the app can do to a file. Compression runs as soon as files are dropped; the others
/// wait until the options are set and the user presses the button.
enum Tool: String, CaseIterable, Identifiable {
    case compress, resize, crop, rotate, upscale, watermark, blurFaces, removeBackground
    case convert, extractText
    case mergePDF, splitPDF

    var id: String { rawValue }

    var group: ToolGroup {
        switch self {
        case .compress: .optimize
        case .resize, .crop, .rotate, .upscale, .watermark, .blurFaces, .removeBackground: .edit
        case .convert, .extractText: .convert
        case .mergePDF, .splitPDF: .pdf
        }
    }

    var title: String {
        switch self {
        case .compress: "Compress"
        case .resize: "Resize"
        case .crop: "Crop"
        case .rotate: "Rotate & Flip"
        case .upscale: "Enlarge"
        case .watermark: "Watermark"
        case .blurFaces: "Hide Faces"
        case .removeBackground: "Remove Background"
        case .convert: "Convert"
        case .extractText: "Text & Markdown"
        case .mergePDF: "Merge PDFs"
        case .splitPDF: "Split PDF"
        }
    }

    var symbol: String {
        switch self {
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .resize: "arrow.up.left.and.arrow.down.right"
        case .crop: "crop"
        case .rotate: "rotate.right"
        case .upscale: "arrow.up.backward.and.arrow.down.forward"
        case .watermark: "textformat"
        case .blurFaces: "person.crop.circle.badge.questionmark"
        case .removeBackground: "person.crop.square"
        case .convert: "arrow.triangle.2.circlepath"
        case .extractText: "doc.plaintext"
        case .mergePDF: "square.on.square"
        case .splitPDF: "square.split.2x1"
        }
    }

    var summary: String {
        switch self {
        case .compress: "Make files much smaller without visible loss."
        case .resize: "Scale pictures and videos to an exact size, a percentage, or a maximum."
        case .crop: "Cut pictures, videos, GIFs and PDF pages down to the part you want."
        case .rotate: "Turn or mirror pictures, videos and PDF pages."
        case .upscale: "Make pictures and videos larger while keeping edges crisp."
        case .watermark: "Stamp text or a logo on pictures, videos, GIFs and PDFs."
        case .blurFaces: "Find faces in pictures and videos and blur, pixelate or cover them."
        case .removeBackground: "Cut out the main subject and make the background transparent."
        case .convert: "Change the format: JPEG, PNG, HEIC, MP4, GIF, audio, PDF pages and more."
        case .extractText: "Turn PDFs and pictures into Markdown or plain text. Scans are read on your Mac."
        case .mergePDF: "Combine PDFs and pictures into one PDF, in the order you choose."
        case .splitPDF: "Cut a PDF into single pages, page ranges, or equal parts."
        }
    }

    /// What a dropped file is for, used in the empty state.
    var dropHint: String {
        switch self {
        case .compress: "Photos, video, GIFs, PDFs, audio and documents."
        case .resize, .upscale, .blurFaces: "Pictures and videos."
        case .crop, .watermark, .rotate: "Pictures, videos, GIFs and PDFs."
        case .removeBackground: "Pictures."
        case .convert: "Pictures, videos, GIFs, audio and PDFs."
        case .extractText: "PDFs and pictures."
        case .mergePDF: "PDFs and pictures."
        case .splitPDF: "A PDF."
        }
    }

    var family: OperationFamily {
        switch self {
        case .compress: .compress
        case .resize: .resize
        case .crop: .crop
        case .rotate: .rotate
        case .upscale: .upscale
        case .watermark: .watermark
        case .blurFaces: .blurFaces
        case .removeBackground: .removeBackground
        case .convert: .convert
        case .extractText: .extractText
        case .mergePDF: .merge
        case .splitPDF: .split
        }
    }

    var accepts: Set<MediaKind> {
        switch self {
        case .compress: Set(MediaKind.allCases)
        case .resize: [.image, .video, .gif]
        case .crop, .rotate, .watermark: [.image, .video, .gif, .pdf]
        case .upscale, .blurFaces: [.image, .video]
        case .removeBackground: [.image]
        case .convert: [.image, .video, .gif, .audio, .pdf]
        case .extractText, .mergePDF: [.pdf, .image]
        case .splitPDF: [.pdf]
        }
    }

    /// Compression starts the moment files arrive; everything else waits for a button.
    var runsOnDrop: Bool { self == .compress }
    /// Whether the files together make one result.
    var combinesFiles: Bool { self == .mergePDF }
    /// Tools whose result is a folder or several files, which can't replace the original.
    var cannotReplaceOriginal: Bool { self == .mergePDF || self == .splitPDF || self == .extractText }
    /// Whether previews let the user see the effect of the options.
    var hasVisualOptions: Bool { [.crop, .rotate, .watermark, .blurFaces].contains(self) }

    var runVerb: String {
        switch self {
        case .compress: "Compress"
        case .resize: "Resize"
        case .crop: "Crop"
        case .rotate: "Rotate"
        case .upscale: "Enlarge"
        case .watermark: "Add Watermark"
        case .blurFaces: "Hide Faces"
        case .removeBackground: "Remove Background"
        case .convert: "Convert"
        case .extractText: "Extract Text"
        case .mergePDF: "Merge"
        case .splitPDF: "Split"
        }
    }
}

/// A file waiting in a tool for the user to press the button.
struct StagedFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let kind: MediaKind
}

enum ResizeKind: String, CaseIterable, Identifiable {
    case fit = "Fit"
    case percent = "Percent"
    case exact = "Exact"
    var id: String { rawValue }
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free", original = "Original", square = "1:1", fourThree = "4:3", threeTwo = "3:2", sixteenNine = "16:9"
    case threeFour = "3:4", twoThree = "2:3", nineSixteen = "9:16"
    var id: String { rawValue }

    /// Width divided by height, or nil for a free crop. `original` needs the picture's own ratio.
    func ratio(original: Double) -> Double? {
        switch self {
        case .free: nil
        case .original: original
        case .square: 1
        case .fourThree: 4.0 / 3
        case .threeTwo: 3.0 / 2
        case .sixteenNine: 16.0 / 9
        case .threeFour: 3.0 / 4
        case .twoThree: 2.0 / 3
        case .nineSixteen: 9.0 / 16
        }
    }
}

enum VideoTarget: String, CaseIterable, Identifiable {
    case mp4 = "MP4", mov = "MOV", gif = "GIF", audio = "Audio only"
    var id: String { rawValue }
}

enum PDFPageTarget: String, CaseIterable, Identifiable {
    case png = "PNG", jpeg = "JPEG"
    var id: String { rawValue }
}

enum SplitKind: String, CaseIterable, Identifiable {
    case everyPage = "Every page", ranges = "Page ranges", everyN = "Every N pages"
    var id: String { rawValue }
}

/// The options of every tool. They live here, rather than in each view, so the preview, the inspector and the run button agree.
@MainActor
@Observable
final class ToolSettings {
    // Resize
    var resizeKind: ResizeKind = .fit
    var resizeMaxSide = 1920
    var resizePercent = 50.0
    var resizeWidth = 1280
    var resizeHeight = 720
    var resizeFill = false
    var allowEnlarge = false

    // Crop
    var crop = NormalizedRect.full
    var cropAspect: CropAspect = .free

    // Rotate
    var rotate = RotateSpec(quarterTurns: 0)

    // Upscale
    var upscaleFactor = 2
    var upscaleSharpness = 0.5

    // Convert
    var imageTarget: ImageFormat = .jpeg
    var imageToPDF = false
    var videoTarget: VideoTarget = .mp4
    var videoAudioFormat: AudioFormat = .aac
    var audioTarget: AudioFormat = .aac
    var gifTarget: VideoFormat = .mp4
    var pdfPageTarget: PDFPageTarget = .png
    var pdfDPI = 150
    var convertQuality = 0.85

    // Watermark
    var watermarkUsesImage = false
    var watermarkText = ""
    var watermarkImagePath: String?
    var watermarkPosition: WatermarkPosition = .bottomRight
    var watermarkScale = 0.25
    var watermarkOpacity = 0.6
    var watermarkDark = false
    var watermarkRotation = 0.0

    // Faces
    var blur = BlurSpec()

    // Text
    var text = TextSpec()

    // Split
    var splitKind: SplitKind = .everyPage
    var splitRanges = "1-3"
    var splitEvery = 2

    var watermarkSpec: WatermarkSpec {
        let content: WatermarkContent = watermarkUsesImage && watermarkImagePath != nil
            ? .image(path: watermarkImagePath!) : .text(watermarkText)
        return WatermarkSpec(content: content, position: watermarkPosition, scale: watermarkScale, opacity: watermarkOpacity,
                             darkText: watermarkDark, rotationDegrees: watermarkRotation)
    }

    var resizeSpec: ResizeSpec {
        switch resizeKind {
        case .fit: ResizeSpec(mode: .fit(maxSide: max(16, resizeMaxSide)), allowEnlarge: allowEnlarge)
        case .percent: ResizeSpec(mode: .percent(max(1, resizePercent)), allowEnlarge: allowEnlarge)
        case .exact: ResizeSpec(mode: .exact(width: max(16, resizeWidth), height: max(16, resizeHeight), crop: resizeFill), allowEnlarge: allowEnlarge)
        }
    }

    var splitSpec: SplitSpec {
        switch splitKind {
        case .everyPage: SplitSpec(mode: .everyPage)
        case .ranges: SplitSpec(mode: .ranges(splitRanges))
        case .everyN: SplitSpec(mode: .everyN(max(1, splitEvery)))
        }
    }

    /// The conversion that applies to a file of this kind.
    func convertSpec(for kind: MediaKind) -> ConvertSpec {
        let target: ConvertTarget
        switch kind {
        case .image: target = imageToPDF ? .imageToPDF : .image(imageTarget)
        case .video:
            switch videoTarget {
            case .mp4: target = .video(.mp4)
            case .mov: target = .video(.mov)
            case .gif: target = .video(.gif)
            case .audio: target = .videoToAudio(videoAudioFormat)
            }
        case .audio: target = .audio(audioTarget)
        case .gif: target = .video(gifTarget)
        case .pdf: target = .pdfToImages(pdfPageTarget == .png ? .png : .jpeg, dpi: pdfDPI)
        case .document: target = .image(.png)
        }
        return ConvertSpec(target: target, quality: convertQuality)
    }

    /// What to do to a file of this kind with the current options.
    func action(for tool: Tool, kind: MediaKind, sources: [URL] = []) -> ToolAction {
        switch tool {
        case .compress: .compress
        case .resize: .resize(resizeSpec)
        case .crop: .crop(crop)
        case .rotate: .rotate(rotate)
        case .upscale: .upscale(UpscaleSpec(factor: upscaleFactor, sharpness: upscaleSharpness))
        case .watermark: .watermark(watermarkSpec)
        case .blurFaces: .blurFaces(blur)
        case .removeBackground: .removeBackground
        case .convert: .convert(convertSpec(for: kind))
        case .extractText: .extractText(text)
        case .mergePDF: .merge(MergeSpec(sources: sources))
        case .splitPDF: .split(splitSpec)
        }
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case details = "Details"
    case options = "Options"
    var id: String { rawValue }
}

extension Tool {
    func accepts(_ kind: MediaKind) -> Bool { accepts.contains(kind) }
}

extension OperationFamily {
    /// What a finished result is called in the list, e.g. "Resized".
    var pastTense: String {
        switch self {
        case .compress: "Compressed"
        case .resize: "Resized"
        case .crop: "Cropped"
        case .rotate: "Rotated"
        case .convert: "Converted"
        case .upscale: "Enlarged"
        case .watermark: "Watermarked"
        case .blurFaces: "Faces hidden"
        case .removeBackground: "Background removed"
        case .extractText: "Text extracted"
        case .merge: "Merged"
        case .split: "Split"
        }
    }
}
