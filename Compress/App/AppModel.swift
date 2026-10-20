import AppKit
import UniformTypeIdentifiers
import CompressCore
import Observation

enum OutputMode: String, CaseIterable, Identifiable {
    case suffix
    case folder
    case replace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .suffix: "Next to original"
        case .folder: "Chosen folder"
        case .replace: "Replace original"
        }
    }

    var symbol: String {
        switch self {
        case .suffix: "doc.on.doc"
        case .folder: "folder"
        case .replace: "arrow.triangle.2.circlepath"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private let queue: JobQueue
    private let defaults: UserDefaults
    let access: FolderAccess
    /// Folders whose new files are compressed automatically. Set at the end of `init`.
    @ObservationIgnored private(set) var watch: WatchService!
    let entitlements: Entitlements
    let store: Store
    #if DIRECT
    /// License key unlocking and update checks, which replace the App Store purchase in the direct edition.
    let license: LicenseManager
    let updater = Updater()
    #endif
    /// Set when the free allowance runs out, so the window can offer the unlock.
    var showPaywall = false
    /// Jobs that count against today's free allowance, until they finish.
    @ObservationIgnored private var reservedJobs: Set<JobID> = []

    private(set) var jobs: [CompressionJob] = []

    /// The tool that new files go to.
    var tool: Tool {
        didSet {
            defaults.set(tool.rawValue, forKey: "tool")
            selection = nil
            inspectorTab = .options
        }
    }
    let settings = ToolSettings()
    /// Files waiting in each tool for the user to press its button.
    private(set) var stagedByTool: [Tool: [StagedFile]] = [:]
    /// The file shown in the inspector, either waiting or finished.
    var selection: UUID? {
        didSet { if selection != nil { inspectorTab = .details; showInspector = true } }
    }
    var showInspector = true
    /// Pixel size of the file the options apply to, for the live readouts.
    var targetSize: CGSize?
    var inspectorTab: InspectorTab = .options
    /// A short message shown above the list, e.g. "2 unsupported files skipped".
    var notice: String?

    var level: QualityLevel {
        didSet { defaults.set(level.rawValue, forKey: "level") }
    }
    var stripMetadata: Bool {
        didSet { defaults.set(stripMetadata, forKey: "stripMetadata") }
    }
    var outputMode: OutputMode {
        didSet { defaults.set(outputMode.rawValue, forKey: "outputMode") }
    }
    /// Longest side images are scaled down to; nil keeps the original size.
    var maxDimension: Int? {
        didSet { defaults.set(maxDimension ?? 0, forKey: "maxDimension") }
    }
    var videoCodec: VideoCodec {
        didSet { defaults.set(videoCodec.rawValue, forKey: "videoCodec") }
    }
    /// Frame rate videos are capped at; nil keeps the original.
    var maxFrameRate: Int? {
        didSet { defaults.set(maxFrameRate ?? 0, forKey: "maxFrameRate") }
    }
    /// Turns videos into animated GIFs instead of compressing them as video.
    var videoToGIF: Bool {
        didSet { defaults.set(videoToGIF, forKey: "videoToGIF") }
    }
    /// Longest stretch of video that goes into a GIF, in seconds.
    var gifSeconds: Double {
        didSet { defaults.set(gifSeconds, forKey: "gifSeconds") }
    }
    var concurrentJobs: Int {
        didSet {
            defaults.set(concurrentJobs, forKey: "concurrentJobs")
            Task { await queue.setMaxConcurrent(concurrentJobs) }
        }
    }
    var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") }
    }
    /// Shows a wheel of actions when files are dragged with Shift held.
    var dragWheel: Bool {
        didSet {
            defaults.set(dragWheel, forKey: "dragWheel")
            DragWheelController.shared.setEnabled(dragWheel, model: self)
        }
    }
    var notifyWhenDone: Bool {
        didSet { defaults.set(notifyWhenDone, forKey: "notifyWhenDone") }
    }
    private(set) var outputFolder: URL?
    @ObservationIgnored private var wasActive = false

    private var pendingOpenURLs: [URL] = []
    private var flushTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        registry: CompressorRegistry = AppModel.defaultRegistry(),
        entitlements: Entitlements? = nil
    ) {
        self.defaults = defaults
        let entitlements = entitlements ?? Entitlements(defaults: defaults)
        self.entitlements = entitlements
        self.store = Store(entitlements: entitlements)
        #if DIRECT
        self.license = LicenseManager(entitlements: entitlements)
        #endif
        self.access = FolderAccess(defaults: defaults)
        let saved = defaults.integer(forKey: "concurrentJobs")
        let jobLimit = saved > 0 ? saved : 2
        self.concurrentJobs = jobLimit
        self.showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        self.dragWheel = defaults.object(forKey: "dragWheel") as? Bool ?? true
        self.notifyWhenDone = defaults.object(forKey: "notifyWhenDone") as? Bool ?? true
        self.queue = JobQueue(registry: registry, maxConcurrent: jobLimit, kindLimits: [.video: 1])
        self.level = defaults.string(forKey: "level").flatMap(QualityLevel.init) ?? .high
        self.stripMetadata = defaults.bool(forKey: "stripMetadata")
        self.outputMode = defaults.string(forKey: "outputMode").flatMap(OutputMode.init) ?? .suffix
        self.tool = defaults.string(forKey: "tool").flatMap(Tool.init) ?? .compress
        self.videoCodec = defaults.string(forKey: "videoCodec").flatMap(VideoCodec.init) ?? .hevc
        self.videoToGIF = defaults.bool(forKey: "videoToGIF")
        let savedSeconds = defaults.double(forKey: "gifSeconds")
        self.gifSeconds = savedSeconds > 0 ? savedSeconds : 10
        let savedRate = defaults.integer(forKey: "maxFrameRate")
        self.maxFrameRate = savedRate > 0 ? savedRate : nil
        let savedDimension = defaults.integer(forKey: "maxDimension")
        self.maxDimension = savedDimension > 0 ? savedDimension : nil
        if let path = defaults.string(forKey: "outputFolderPath") {
            self.outputFolder = access.grantedFolder(atPath: path)
        }
        self.watch = WatchService(
            defaults: defaults, access: access,
            basePreset: { [unowned self] in self.preset },
            isAllowed: { [unowned self] in self.entitlements.isUnlocked },
            enqueue: { [unowned self] urls, preset, policy in
                await self.queue.enqueue(urls: urls, preset: preset, outputPolicy: policy).accepted
            })
    }

    static func defaultRegistry() -> CompressorRegistry { Engines.registry() }

    // MARK: Derived

    /// Results of the current tool, newest last.
    var toolJobs: [CompressionJob] { jobs.filter { $0.preset.operation.family == tool.family } }
    var staged: [StagedFile] { stagedByTool[tool] ?? [] }
    /// What the inspector and the visual editors look at: the selection, or else the first file waiting.
    var previewTarget: (url: URL, kind: MediaKind)? {
        if let file = selectedStaged ?? staged.first { return (file.url, file.kind) }
        if let job = selectedJob { return (job.sourceURL, job.kind) }
        return nil
    }
    var selectedStaged: StagedFile? { staged.first { $0.id == selection } }
    var selectedJob: CompressionJob? { jobs.first { $0.id == selection } }

    /// Staged files of every tool, so the sidebar can show a count.
    func stagedCount(_ tool: Tool) -> Int { stagedByTool[tool]?.count ?? 0 }

    var preset: Preset {
        Preset(level: level, stripMetadata: stripMetadata, maxDimension: maxDimension,
               videoCodec: videoCodec, maxFrameRate: maxFrameRate,
               videoToGIF: videoToGIF, gifMaxSeconds: gifSeconds)
    }

    var finishedCount: Int { jobs.filter { $0.state.isFinished }.count }
    var hasFinished: Bool { finishedCount > 0 }
    var hasActive: Bool { jobs.contains { !$0.state.isFinished } }

    var totalSavedBytes: Int64 {
        jobs.reduce(0) { total, job in
            if case .completed(let result) = job.state { total + result.savedBytes } else { total }
        }
    }

    #if DEBUG
    func setDemo(_ jobs: [CompressionJob]) { self.jobs = jobs }
    func demoStage(_ urls: [URL]) { stage(urls) }
    #endif

    // MARK: Syncing with the queue

    /// Mirrors the queue into `jobs` for as long as the calling task lives.
    func run() async {
        let stream = await queue.updates()
        jobs = await queue.snapshot()
        for await event in stream { apply(event) }
    }

    private func apply(_ event: JobEvent) {
        switch event {
        case .changed(let job):
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index] = job
            } else {
                jobs.append(job)
            }
            if job.state.isFinished {
                watch.jobFinished(job)
                releaseReservation(for: job)
            }
            batchProgressChanged()
        case .removed(let id):
            jobs.removeAll { $0.id == id }
        }
    }

    /// Work that didn't happen doesn't use up the free allowance.
    private func releaseReservation(for job: CompressionJob) {
        guard reservedJobs.remove(job.id) != nil else { return }
        switch job.state {
        case .failed, .cancelled: entitlements.refund(1)
        default: break
        }
    }

    /// Posts a notification when the last running job of a batch finishes.
    private func batchProgressChanged() {
        let active = hasActive
        defer { wasActive = active }
        guard wasActive, !active, notifyWhenDone else { return }
        let done = jobs.filter { if case .completed = $0.state { true } else { false } }.count
        let failed = jobs.filter { if case .failed = $0.state { true } else { false } }.count
        guard done + failed > 0 else { return }
        Notifier.post(compressed: done, failed: failed, savedBytes: totalSavedBytes)
    }

    // MARK: Adding files

    /// Handles `compress://` links. Files can't be passed this way (the sandbox wouldn't let us read
    /// them); use `open -a Compress <files>` for that.
    func handle(url: URL) {
        guard url.scheme == "squeezo" else {
            receive(urls: [url])
            return
        }
        switch url.host {
        case "dropzone": DropZoneController.shared.toggle(model: self)
        case "pause": watch.isPaused = true
        case "resume": watch.isPaused = false
        default: break
        }
    }

    /// Collects URLs from several open events that arrive together, then adds them as one batch.
    func receive(urls: [URL]) {
        pendingOpenURLs += urls
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let batch = pendingOpenURLs
            pendingOpenURLs = []
            await add(urls: batch)
        }
    }

    func chooseFiles() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie, .pdf, .audio] + ["docx", "pptx", "xlsx", "epub"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        await add(urls: panel.urls)
    }

    /// Adds files to the current tool. Compression starts at once; other tools wait for their button.
    func add(urls: [URL]) async {
        if tool.runsOnDrop { await compressFiles(urls) } else { stage(urls) }
    }

    // MARK: Other tools

    func stage(_ urls: [URL]) {
        let files = FileCollector.collect(urls)
        var list = stagedByTool[tool] ?? []
        var skipped = 0
        for url in files {
            guard let kind = MediaKind(url: url), tool.accepts(kind) else { skipped += 1; continue }
            if !list.contains(where: { $0.url == url }) { list.append(StagedFile(url: url, kind: kind)) }
        }
        stagedByTool[tool] = list
        notice = skipped > 0 ? "\(skipped) \(skipped == 1 ? "file" : "files") skipped: \(tool.title) doesn't work on them" : nil
        if selection == nil, let first = list.first {
            selection = first.id
            // Tools you set up by looking at the picture open on their options.
            if tool.hasVisualOptions { inspectorTab = .options }
        }
    }

    /// Reads the pixel size of the file the options apply to.
    func refreshTargetSize() async {
        guard let target = previewTarget, target.kind != .pdf, target.kind != .audio else { targetSize = nil; return }
        let info = await MediaInfo.load(target.url, kind: target.kind)
        guard let text = info.rows.first(where: { $0.label == "Dimensions" })?.value else { targetSize = nil; return }
        let numbers = text.replacingOccurrences(of: "px", with: "").split(separator: "×").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        targetSize = numbers.count == 2 ? CGSize(width: numbers[0], height: numbers[1]) : nil
    }

    func unstage(_ id: UUID) {
        stagedByTool[tool]?.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    func clearStaged() {
        stagedByTool[tool] = []
        selection = nil
    }

    /// Moves a waiting file up or down, which sets the page order when merging.
    func moveStaged(_ id: UUID, by offset: Int) {
        guard var list = stagedByTool[tool], let index = list.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard list.indices.contains(target) else { return }
        list.swapAt(index, target)
        stagedByTool[tool] = list
    }

    /// Whether the current options are enough to run. Explains what's missing when they aren't.
    var runBlocker: String? {
        switch tool {
        case .crop where settings.crop.isFull: "Drag the corners to choose what to keep."
        case .rotate where settings.rotate.isIdentity: "Choose a turn or a flip."
        case .watermark where settings.watermarkUsesImage && settings.watermarkImagePath == nil: "Choose a logo picture."
        case .watermark where !settings.watermarkUsesImage && settings.watermarkText.trimmingCharacters(in: .whitespaces).isEmpty: "Type the watermark text."
        case .splitPDF where settings.splitKind == .ranges && settings.splitRanges.trimmingCharacters(in: .whitespaces).isEmpty: "Enter the pages to keep, such as 1-3, 5."
        case .mergePDF where staged.count < 2: "Add at least two files to merge."
        default: nil
        }
    }

    /// Runs the current tool on everything waiting in it.
    func runStaged() async {
        let files = staged
        guard !files.isEmpty, runBlocker == nil else { return }
        let tool = tool
        let accepted = await run(tool, on: files) { [settings] kind, sources in settings.action(for: tool, kind: kind, sources: sources) }
        if accepted { stagedByTool[tool] = []; selection = nil }
    }

    /// Runs a tool on files that skipped the staging area, e.g. dropped on the drag wheel. `action` decides
    /// what to do to a file of a given kind, and is given every source when the files combine into one.
    /// Returns whether anything was queued.
    @discardableResult
    func run(_ tool: Tool, on files: [StagedFile], action: (MediaKind, [URL]) -> ToolAction) async -> Bool {
        // Where results go. Tools that make folders or new documents never replace the original.
        let policy: OutputPolicy
        switch outputMode {
        case .folder:
            guard let folder = outputFolder ?? chooseOutputFolder() else {
                notice = "Choose an output folder to continue."
                return false
            }
            policy = .folder(folder)
        case .replace where !tool.cannotReplaceOriginal:
            policy = .replaceAndTrash
        default:
            policy = .suffix(tool.family.suffix)
        }

        // Permission to save next to the originals.
        var runnable = files
        if case .folder = policy {} else {
            let inputs = tool.combinesFiles ? Array(files.prefix(1)) : files
            let denied = access.ensureWritable(directories: Set(inputs.map { $0.url.deletingLastPathComponent().standardizedFileURL }))
            if !denied.isEmpty {
                runnable = files.filter { !denied.contains($0.url.deletingLastPathComponent().standardizedFileURL) }
                notice = "\(files.count - runnable.count) files skipped: no permission to save next to them"
                if runnable.isEmpty { return false }
            }
        }

        // Free users have a daily allowance.
        let jobsNeeded = tool.combinesFiles ? 1 : runnable.count
        let granted = entitlements.reserve(jobsNeeded)
        if granted < jobsNeeded {
            if !tool.combinesFiles { runnable = Array(runnable.prefix(granted)) }
            notice = "Daily limit reached: \(jobsNeeded - granted) not processed"
            showPaywall = true
            if granted == 0 { return false }
        }

        var accepted: [JobID] = []
        if tool.combinesFiles {
            let sources = runnable.map(\.url)
            let preset = makePreset(action(runnable[0].kind, sources))
            accepted += await queue.enqueue(urls: [sources[0]], preset: preset, outputPolicy: policy).accepted
        } else {
            let groups = Dictionary(grouping: runnable) { makePreset(action($0.kind, [])) }
            for (preset, group) in groups {
                accepted += await queue.enqueue(urls: group.map(\.url), preset: preset, outputPolicy: policy).accepted
            }
        }
        reservedJobs.formUnion(accepted)
        if notice?.hasPrefix("Daily limit") != true { notice = nil }
        return true
    }

    private func makePreset(_ action: ToolAction) -> Preset {
        Preset(level: .highest, stripMetadata: stripMetadata, videoCodec: videoCodec, gifMaxSeconds: gifSeconds, operation: action)
    }

    // MARK: Compression

    func compressFiles(_ urls: [URL]) async {
        let files = FileCollector.collect(urls)
        let supported = files.filter { MediaKind(url: $0) != nil }
        let unsupportedCount = files.count - supported.count
        var allowed = supported
        var messages: [String] = []
        let policy: OutputPolicy

        switch outputMode {
        case .suffix, .replace:
            policy = outputMode == .replace ? .replaceAndTrash : .suffix("-compressed")
            let candidates = allowed
            let folders = Set(candidates.map { $0.deletingLastPathComponent().standardizedFileURL })
            let denied = access.ensureWritable(directories: folders)
            if !denied.isEmpty {
                allowed = candidates.filter {
                    !denied.contains($0.deletingLastPathComponent().standardizedFileURL)
                }
                messages.append("\(candidates.count - allowed.count) files skipped: no permission to save next to them")
            }
        case .folder:
            guard let folder = outputFolder ?? chooseOutputFolder() else {
                notice = "Choose an output folder to continue."
                return
            }
            policy = .folder(folder)
        }

        // Free users have a daily allowance; the rest waits for the unlock.
        let granted = entitlements.reserve(allowed.count)
        if granted < allowed.count {
            let over = allowed.count - granted
            allowed = Array(allowed.prefix(granted))
            messages.append("Daily limit reached: \(over) \(over == 1 ? "file" : "files") not compressed")
            showPaywall = true
        }
        if unsupportedCount > 0 {
            messages.append("\(unsupportedCount) unsupported \(unsupportedCount == 1 ? "file" : "files") skipped")
        }
        notice = messages.isEmpty ? nil : messages.joined(separator: " · ")
        guard !allowed.isEmpty else { return }
        // A video turned into a GIF is a new file, so it never replaces (and trashes) the original.
        if videoToGIF, case .replaceAndTrash = policy {
            let videos = allowed.filter { MediaKind(url: $0) == .video }
            let others = allowed.filter { MediaKind(url: $0) != .video }
            let ids = await queue.enqueue(urls: videos, preset: preset, outputPolicy: .suffix("-compressed")).accepted
                + queue.enqueue(urls: others, preset: preset, outputPolicy: policy).accepted
            reservedJobs.formUnion(ids)
        } else {
            reservedJobs.formUnion(await queue.enqueue(urls: allowed, preset: preset, outputPolicy: policy).accepted)
        }
    }

    // MARK: Output

    /// Changes where results go. Replacing originals is destructive, so it asks first.
    func requestOutputMode(_ mode: OutputMode) {
        guard mode == .replace, outputMode != .replace else {
            outputMode = mode
            return
        }
        let alert = NSAlert()
        alert.messageText = "Replace the original files?"
        alert.informativeText = "Each compressed file takes the place of its original. The originals are moved to the Trash, and you can undo a replacement from the list."
        alert.addButton(withTitle: "Replace Originals")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn { outputMode = .replace }
    }

    @discardableResult
    func chooseOutputFolder() -> URL? {
        guard let folder = access.requestAccess(
            to: outputFolder,
            message: "Choose where compressed files are saved.",
            prompt: "Choose") else { return nil }
        access.remember(folder)
        outputFolder = folder
        defaults.set(folder.standardizedFileURL.path, forKey: "outputFolderPath")
        return folder
    }

    // MARK: Job actions

    func cancel(_ id: JobID) { Task { await queue.cancel(id) } }
    func cancelAll() { Task { await queue.cancelAll() } }
    func retry(_ id: JobID) { Task { await queue.retry(id) } }
    func clearFinished() { Task { await queue.clearFinished() } }

    /// Whether a finished job can be undone: its original is in the Trash, or it made a separate copy.
    func canUndo(_ job: CompressionJob) -> Bool {
        guard case .completed(let result) = job.state, result.outcome == .compressed else { return false }
        return result.backupURL != nil || result.outputURL != job.sourceURL
    }

    /// Puts the original back (or removes the compressed copy) and drops the job from the list.
    func undo(_ job: CompressionJob) {
        guard canUndo(job), case .completed(let result) = job.state else { return }
        let fm = FileManager.default
        do {
            if let backup = result.backupURL {
                try? fm.removeItem(at: result.outputURL)
                try fm.moveItem(at: backup, to: job.sourceURL)
                watch.markHandled(job.sourceURL)
            } else {
                try fm.trashItem(at: result.outputURL, resultingItemURL: nil)
            }
            Task { await queue.remove(job.id) }
        } catch {
            notice = "Couldn't undo: \(error.localizedDescription)"
        }
    }

    /// Brings the main window to the front, opening it again if it was closed.
    func showMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
