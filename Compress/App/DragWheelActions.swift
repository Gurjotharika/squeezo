import CompressCore
import Foundation

extension AppModel {
    /// Runs what the drag wheel was dropped on. Returns a few words for the wheel to show while it closes.
    func perform(_ command: WheelCommand, on urls: [URL]) async -> String {
        guard !urls.isEmpty else { return "No files" }

        if case .open(let tool) = command {
            self.tool = tool
            stage(urls)
            showMainWindow()
            return "Opening \(tool.title)"
        }
        if case .compress = command {
            await compressFiles(urls)
            if showPaywall { showMainWindow() }
            return urls.count == 1 ? "Compressing" : "Compressing \(urls.count) files"
        }

        let tool: Tool
        switch command {
        case .convert: tool = .convert
        case .resize: tool = .resize
        case .rotate: tool = .rotate
        case .upscale: tool = .upscale
        case .blurFaces: tool = .blurFaces
        case .removeBackground: tool = .removeBackground
        case .extractText: tool = .extractText
        case .compress, .open: return ""
        }

        let files = FileCollector.collect(urls).compactMap { url -> StagedFile? in
            guard let kind = MediaKind(url: url), tool.accepts(kind) else { return nil }
            if case .convert(let choice) = command, choice.spec(for: kind) == nil { return nil }
            return StagedFile(url: url, kind: kind)
        }
        guard !files.isEmpty else { return "Nothing to do for these files" }

        let queued = await run(tool, on: files) { kind, _ in
            switch command {
            case .convert(let choice): .convert(choice.spec(for: kind) ?? ConvertSpec(target: .image(.png)))
            case .resize(let spec): .resize(spec)
            case .rotate(let spec): .rotate(spec)
            case .upscale(let factor): .upscale(UpscaleSpec(factor: factor))
            case .blurFaces: .blurFaces(BlurSpec())
            case .extractText(let format): .extractText(TextSpec(format: format))
            default: .removeBackground
            }
        }
        if showPaywall { showMainWindow() }
        guard queued else { return notice ?? "Couldn't start" }
        return "\(tool.runVerb) · \(files.count) \(files.count == 1 ? "file" : "files")"
    }
}
