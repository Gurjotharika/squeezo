import CoreGraphics
import Foundation

/// What the options panel needs to show the effect of a tool on a small preview before anything is saved.
public enum PreviewTools {
    public static func rotated(_ image: CGImage, _ spec: RotateSpec) -> CGImage? {
        try? ImageTools.rotate(image, spec: spec)
    }

    public static func watermarked(_ image: CGImage, _ spec: WatermarkSpec) -> CGImage? {
        try? ImageTools.watermark(image, spec: spec)
    }

    /// The picture with faces hidden, and how many were found.
    public static func hidingFaces(_ image: CGImage, _ spec: BlurSpec) -> (image: CGImage, faces: Int) {
        let faces = ImageTools.detectFaces(in: image)
        guard !faces.isEmpty, let result = try? ImageTools.obscure(image, regions: faces, spec: spec) else { return (image, 0) }
        return (result, faces.count)
    }

    public static func resized(_ image: CGImage, _ spec: ResizeSpec) -> CGImage? {
        try? ImageTools.resize(image, spec: spec)
    }

    /// The size a picture or video of this size ends up at after a resize.
    public static func resizedSize(width: Int, height: Int, _ spec: ResizeSpec) -> (width: Int, height: Int) {
        let size = ImageTools.resizedSize(CGSize(width: width, height: height), spec: spec)
        return (Int(size.width), Int(size.height))
    }
}
