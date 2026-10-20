import Foundation

/// Runs compression jobs with a concurrency limit, and reports their progress.
public actor JobQueue {
    private let registry: CompressorRegistry
    private var maxConcurrent: Int
    /// Extra limits for heavy kinds, e.g. one video at a time, so hardware coders aren't oversubscribed.
    private let kindLimits: [MediaKind: Int]

    private var jobs: [JobID: CompressionJob] = [:]
    private var order: [JobID] = []
    private var running: [JobID: Task<Void, Never>] = [:]
    private var observers: [UUID: AsyncStream<JobEvent>.Continuation] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(registry: CompressorRegistry, maxConcurrent: Int = 2, kindLimits: [MediaKind: Int] = [:]) {
        self.registry = registry
        self.maxConcurrent = max(1, maxConcurrent)
        self.kindLimits = kindLimits
    }

    // MARK: Queries

    /// All jobs in the order they were added.
    public func snapshot() -> [CompressionJob] { order.compactMap { jobs[$0] } }

    public func job(_ id: JobID) -> CompressionJob? { jobs[id] }

    /// A stream of changes. Each call returns an independent stream that ends when its consumer stops.
    public func updates() -> AsyncStream<JobEvent> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<JobEvent>.makeStream(bufferingPolicy: .unbounded)
        observers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(token) }
        }
        return stream
    }

    /// Returns once nothing is queued or running.
    public func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: Commands

    /// Adds a job for every supported file. Unsupported files are returned in `rejected`.
    @discardableResult
    public func enqueue(
        urls: [URL],
        preset: Preset = .default,
        outputPolicy: OutputPolicy = .suffix("-compressed")
    ) -> (accepted: [JobID], rejected: [URL]) {
        var accepted: [JobID] = []
        var rejected: [URL] = []
        for url in urls {
            guard let kind = MediaKind(url: url) else {
                rejected.append(url)
                continue
            }
            let job = CompressionJob(sourceURL: url, kind: kind, preset: preset, outputPolicy: outputPolicy)
            jobs[job.id] = job
            order.append(job.id)
            accepted.append(job.id)
            publish(.changed(job))
        }
        pump()
        return (accepted, rejected)
    }

    /// Cancels a queued or running job. Finished jobs are left alone.
    public func cancel(_ id: JobID) {
        guard let job = jobs[id] else { return }
        switch job.state {
        case .queued:
            setState(id, .cancelled)
            pump()
        case .running:
            running[id]?.cancel()  // `finish` records the cancellation
        case .completed, .failed, .cancelled:
            break
        }
    }

    public func cancelAll() {
        for id in order { cancel(id) }
    }

    /// Puts a failed or cancelled job back in the queue.
    public func retry(_ id: JobID) {
        guard let state = jobs[id]?.state else { return }
        switch state {
        case .failed, .cancelled:
            setState(id, .queued)
            pump()
        case .queued, .running, .completed:
            break
        }
    }

    /// Removes one finished job from the list.
    public func remove(_ id: JobID) {
        guard jobs[id]?.state.isFinished == true else { return }
        jobs[id] = nil
        order.removeAll { $0 == id }
        publish(.removed(id))
    }

    /// Removes finished jobs from the list.
    public func clearFinished() {
        for id in order where jobs[id]?.state.isFinished == true {
            jobs[id] = nil
            publish(.removed(id))
        }
        order.removeAll { jobs[$0] == nil }
    }

    public func setMaxConcurrent(_ value: Int) {
        maxConcurrent = max(1, value)
        pump()
    }

    // MARK: Scheduling

    private var isIdle: Bool {
        running.isEmpty && !jobs.values.contains { $0.state == .queued }
    }

    private func runningCount(of kind: MediaKind) -> Int {
        running.keys.filter { jobs[$0]?.kind == kind }.count
    }

    /// The first queued job that is allowed to start now.
    private func nextStartable() -> JobID? {
        order.first { id in
            guard let job = jobs[id], job.state == .queued else { return false }
            guard let limit = kindLimits[job.kind] else { return true }
            return runningCount(of: job.kind) < limit
        }
    }

    private func pump() {
        while running.count < maxConcurrent, let id = nextStartable() {
            start(id)
        }
        if isIdle {
            let waiters = idleWaiters
            idleWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    private func start(_ id: JobID) {
        guard let job = jobs[id] else { return }
        guard let compressor = registry[job.kind, job.preset.operation.family] else {
            setState(id, .failed(CompressionError.noCompressor(job.kind).localizedDescription))
            return
        }
        setState(id, .running(progress: 0))
        running[id] = Task {
            let outcome: Result<JobResult, Error>
            do {
                let result = try await Self.run(job, with: compressor) { fraction in
                    Task { await self.report(id, progress: fraction) }
                }
                outcome = .success(result)
            } catch {
                outcome = .failure(error)
            }
            self.finish(id, outcome)
        }
    }

    private func report(_ id: JobID, progress: Double) {
        guard case .running = jobs[id]?.state else { return }
        setState(id, .running(progress: min(max(progress, 0), 1)))
    }

    private func finish(_ id: JobID, _ outcome: Result<JobResult, Error>) {
        running[id] = nil
        switch outcome {
        case .success(let result):
            setState(id, .completed(result))
        case .failure(let error) where error is CancellationError:
            setState(id, .cancelled)
        case .failure(let error):
            setState(id, .failed(error.localizedDescription))
        }
        pump()
    }

    private func setState(_ id: JobID, _ state: JobState) {
        guard var job = jobs[id] else { return }
        job.state = state
        jobs[id] = job
        publish(.changed(job))
    }

    private func publish(_ event: JobEvent) {
        observers.values.forEach { $0.yield(event) }
    }

    private func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    // MARK: Work

    /// Compresses into a scratch file, then keeps it only if it is smaller than the original.
    @concurrent
    private static func run(
        _ job: CompressionJob,
        with compressor: any Compressor,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> JobResult {
        let fm = FileManager.default
        let source = job.sourceURL
        try Preflight.check(source: source, policy: job.outputPolicy)
        let ext = compressor.outputExtension(for: source, preset: job.preset)

        // Scratch space lives on the destination's volume. For a chosen folder that folder is used,
        // because under the sandbox the source's own folder may not be writable.
        var anchor = source
        if case .folder(let folder) = job.outputPolicy {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            anchor = folder
        }
        let workDir = try fm.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: anchor, create: true)
        defer { try? fm.removeItem(at: workDir) }
        var temp = workDir.appendingPathComponent(source.deletingPathExtension().lastPathComponent)
        if !ext.isEmpty { temp = temp.appendingPathExtension(ext) }  // an empty extension means the result is a folder

        try await compressor.compress(input: source, output: temp, preset: job.preset, progress: progress)
        try Task.checkCancellation()

        guard fm.fileExists(atPath: temp.path) else { throw CompressionError.outputMissing }
        let originalBytes = try fileSize(source)
        let outputBytes = try fileSize(temp)

        // Compression must never make a file bigger: keep the original and discard the attempt.
        // Other tools produce a different file on purpose, so size says nothing about success.
        let isCompression = job.preset.operation.family == .compress
        if isCompression, outputBytes >= originalBytes {
            return JobResult(
                outputURL: source, originalBytes: originalBytes, outputBytes: originalBytes, outcome: .keptOriginal)
        }

        try Task.checkCancellation()
        let placed = try OutputPlanner.place(
            temp: temp, source: source, outputExtension: ext, policy: job.outputPolicy)
        return JobResult(
            outputURL: placed.url, originalBytes: originalBytes, outputBytes: outputBytes,
            outcome: isCompression ? .compressed : .processed, backupURL: placed.backup)
    }

    /// The size of a file, or of everything inside a folder.
    private static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard values.isDirectory == true else { return Int64(values.fileSize ?? 0) }
        var total: Int64 = 0
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
