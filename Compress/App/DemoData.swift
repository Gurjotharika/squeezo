#if DEBUG
import AppKit
import CompressCore
import CoreGraphics
import ImageIO

/// Sample rows for screenshots and design work. Launch the Debug build with `-demo`.
extension AppModel {
    func loadDemoJobs() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CompressDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func picture(_ name: String, _ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat)) -> URL {
            let url = dir.appendingPathComponent(name)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: 240, height: 240, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let gradient = CGGradient(colorsSpace: space, colors: [
                CGColor(red: a.0, green: a.1, blue: a.2, alpha: 1), CGColor(red: b.0, green: b.1, blue: b.2, alpha: 1),
            ] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 240, y: 240), options: [])
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.25))
            ctx.fillEllipse(in: CGRect(x: 60, y: 70, width: 130, height: 130))
            let type = name.hasSuffix("png") ? "public.png" : "public.jpeg"
            let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            CGImageDestinationFinalize(dest)
            return url
        }

        let preset = Preset(level: .high)
        func job(_ url: URL, _ kind: MediaKind, _ state: JobState) -> CompressionJob {
            CompressionJob(sourceURL: url, kind: kind, preset: preset, outputPolicy: .suffix("-compressed"), state: state)
        }
        func done(_ url: URL, _ before: Int64, _ after: Int64) -> JobState {
            .completed(JobResult(outputURL: url, originalBytes: before, outputBytes: after, outcome: .compressed))
        }

        let sunset = picture("Sunset over the bay.jpg", (0.98, 0.55, 0.30), (0.45, 0.20, 0.70))
        let forest = picture("Forest trail 0231.jpg", (0.20, 0.65, 0.40), (0.05, 0.25, 0.30))
        let logo = picture("Brand logo@2x.png", (0.30, 0.55, 1.0), (0.55, 0.30, 0.95))
        let dir2 = URL(fileURLWithPath: "/Users/demo/Documents", isDirectory: true)

        if ProcessInfo.processInfo.arguments.contains("-demoStage") {
            demoStage([sunset, forest, logo].filter { _ in true })
            return
        }

        if ProcessInfo.processInfo.arguments.contains("-demoMarketing") {
            let docs = URL(fileURLWithPath: "/Users/demo/Documents", isDirectory: true)
            setDemo([
                job(sunset, .image, done(sunset, 8_420_000, 1_960_000)),
                job(docs.appendingPathComponent("Holiday in Lisbon.mov"), .video, done(docs, 1_820_000_000, 412_000_000)),
                job(docs.appendingPathComponent("Signed contract (scan).pdf"), .pdf, done(docs, 48_000_000, 6_100_000)),
                job(forest, .image, done(forest, 5_400_000, 1_300_000)),
                job(docs.appendingPathComponent("Product demo.gif"), .gif, done(docs, 22_600_000, 7_900_000)),
                job(docs.appendingPathComponent("Podcast episode 14.wav"), .audio, done(docs, 96_000_000, 11_800_000)),
                job(logo, .image, done(logo, 2_900_000, 740_000)),
                job(docs.appendingPathComponent("Team offsite.pptx"), .document, done(docs, 64_000_000, 21_500_000)),
            ])
            return
        }

        let demo: [CompressionJob] = [
            job(sunset, .image, done(sunset, 8_420_000, 1_960_000)),
            job(dir2.appendingPathComponent("Product launch.mp4"), .video, done(dir2, 482_000_000, 96_400_000)),
            job(dir2.appendingPathComponent("Q3 report (scan).pdf"), .pdf, done(dir2, 31_800_000, 4_200_000)),
            job(forest, .image, .running(progress: 0.62)),
            job(dir2.appendingPathComponent("Podcast episode 14.wav"), .audio, .running(progress: 0.18)),
            job(logo, .image, .queued),
            job(dir2.appendingPathComponent("Team offsite.pptx"), .document, .queued),
            job(dir2.appendingPathComponent("already-small.jpg"), .image,
                .completed(JobResult(outputURL: dir2, originalBytes: 90_000, outputBytes: 90_000, outcome: .keptOriginal))),
            job(dir2.appendingPathComponent("broken.mov"), .video, .failed("“broken.mov” can't be read as a video.")),
        ]
        setDemo(demo)
    }
}
#endif
