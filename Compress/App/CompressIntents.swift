import AppIntents
import CompressCore
import Foundation
import UniformTypeIdentifiers

enum QualityOption: String, AppEnum {
    case highest, high, medium, low

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Quality"
    static let caseDisplayRepresentations: [QualityOption: DisplayRepresentation] = [
        .highest: "Highest", .high: "High", .medium: "Medium", .low: "Low",
    ]

    var level: QualityLevel { QualityLevel(rawValue: rawValue) ?? .high }
}

/// Compresses files from Shortcuts, Spotlight or Siri and returns the smaller versions.
struct CompressFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Compress Files"
    static let description = IntentDescription("Makes images, videos, GIFs and PDFs smaller.")

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.image", "public.movie", "public.audio", "com.adobe.pdf", "org.openxmlformats.wordprocessingml.document", "org.openxmlformats.presentationml.presentation", "org.openxmlformats.spreadsheetml.sheet", "org.idpf.epub-container"], inputConnectionBehavior: .connectToPreviousIntentResult)
    var files: [IntentFile]

    @Parameter(title: "Quality", default: .high)
    var quality: QualityOption

    static var parameterSummary: some ParameterSummary {
        Summary("Compress \(\.$files) at \(\.$quality) quality")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("intent-\(UUID().uuidString)", isDirectory: true)
        let outputs = work.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Copy inputs next to each other so every file has a readable path of its own.
        var inputs: [URL] = []
        for (index, file) in files.enumerated() {
            let folder = work.appendingPathComponent("in-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(file.filename)
            try file.data.write(to: target)
            inputs.append(target)
        }

        let queue = JobQueue(
            registry: Engines.registry(),
            maxConcurrent: 2, kindLimits: [.video: 1])
        let ids = await queue.enqueue(urls: inputs, preset: Preset(level: quality.level), outputPolicy: .folder(outputs)).accepted
        await queue.waitUntilIdle()

        var results: [IntentFile] = []
        for (id, input) in zip(ids, inputs) {
            guard case .completed(let result)? = await queue.job(id)?.state else { continue }
            // "Kept original" means the output is the input itself.
            results.append(IntentFile(data: try Data(contentsOf: result.outputURL), filename: result.outputURL.lastPathComponent == input.lastPathComponent ? input.lastPathComponent : result.outputURL.lastPathComponent))
        }
        return .result(value: results)
    }
}

struct CompressShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CompressFilesIntent(),
            phrases: ["Compress files with \(.applicationName)", "Make files smaller with \(.applicationName)"],
            shortTitle: "Compress Files", systemImageName: "arrow.down.right.and.arrow.up.left")
    }
}
